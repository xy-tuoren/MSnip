import CoreGraphics
import Foundation

/// 纯原生滚动长截图拼接状态机（零外部依赖）：
/// 自动剥离顶部/底部 Sticky 固定栏、屏蔽侧边栏与滚动条、支持中途回滚去重、高速滚动宽窗口匹配及跨屏失步自愈续接
public final class ScrollStitcher: @unchecked Sendable {
    public enum StepResult: Equatable, Sendable {
        case initialized(widthPx: Int, heightPx: Int)
        case unchanged
        case scrolledBackward
        case appended(addedPx: Int, totalHeightPx: Int)
        case mismatchLostOverlap
        case reachedHeightLimit
    }

    public static let defaultMaxHeightPx = 24_000

    public let maxHeightPx: Int
    public private(set) var widthPx: Int = 0
    public private(set) var frameHeightPx: Int = 0
    public private(set) var lockedTopFixed: Int = 0
    public private(set) var lockedBottomFixed: Int = 0

    private var firstFrame: CGImage?
    private var frontierDigest: ScrollFrameDigest?
    private var resyncDigest: ScrollFrameDigest?
    private var latestFooterStrip: CGImage?
    private var previewFooterStrip: CGImage?
    private var strips: [CGImage] = []
    private var previewStrips: [CGImage] = []
    private var bodyHeightPx: Int = 0

    public var totalHeightPx: Int {
        if strips.isEmpty { return frameHeightPx }
        return bodyHeightPx + (latestFooterStrip?.height ?? 0)
    }

    public var hasScrolled: Bool { !strips.isEmpty }

    public init(maxHeightPx: Int = ScrollStitcher.defaultMaxHeightPx) {
        self.maxHeightPx = max(1200, maxHeightPx)
    }

    /// 喂入最新采集到的选区帧（物理像素尺寸保持一致）
    public func ingest(frame: CGImage) -> StepResult {
        let w = frame.width, h = frame.height
        guard w >= 24, h >= 32 else { return .unchanged }

        if frontierDigest == nil || (strips.isEmpty && (w != widthPx || h != frameHeightPx)) {
            widthPx = w
            frameHeightPx = h
            let detachedDigest = ScrollFrameDigest.build(for: frame, detach: true)
            firstFrame = detachedDigest.image
            frontierDigest = detachedDigest
            resyncDigest = nil
            return .initialized(widthPx: w, heightPx: h)
        }
        guard let anchor = frontierDigest, w == widthPx, h == frameHeightPx else { return .unchanged }
        if totalHeightPx >= maxHeightPx { return .reachedHeightLimit }

        let digest = ScrollFrameDigest.build(for: frame, detach: false)

        // 1) 静止帧快速过滤
        var unchangedRows = 0
        for y in 0..<h where anchor.rows[y].fullDiff(to: digest.rows[y]) <= 5 {
            unchangedRows += 1
        }
        if unchangedRows * 100 >= h * 97 { return .unchanged }

        // 2) 优先与当前主前沿匹配
        if let match = matchDisplacement(anchor: anchor, curr: digest, width: w, height: h) {
            resyncDigest = nil
            if match.dy == 0 { return .unchanged }
            if match.dy < 0 { return .scrolledBackward }
            return appendMatchedDelta(
                from: frame,
                digest: digest,
                dy: match.dy,
                margins: match.margins,
                resyncBase: nil
            )
        }

        // 3) 跨整屏快滚自愈：若用户未回滚而是继续平稳向下滚动，自动在当前位置重锚续接，彻底告别死锁报错
        if let pending = resyncDigest {
            var sameAsPending = 0
            for y in 0..<h where pending.rows[y].fullDiff(to: digest.rows[y]) <= 5 {
                sameAsPending += 1
            }
            if sameAsPending * 100 >= h * 97 { return .unchanged }

            if let recMatch = matchDisplacement(anchor: pending, curr: digest, width: w, height: h) {
                if recMatch.dy == 0 { return .unchanged }
                if recMatch.dy >= 8 {
                    resyncDigest = nil
                    return appendMatchedDelta(
                        from: frame,
                        digest: digest,
                        dy: recMatch.dy,
                        margins: recMatch.margins,
                        resyncBase: pending.image
                    )
                }
            }
        }

        resyncDigest = ScrollFrameDigest.build(for: frame, detach: true)
        return .mismatchLostOverlap
    }

    private func matchDisplacement(
        anchor: ScrollFrameDigest,
        curr: ScrollFrameDigest,
        width w: Int,
        height h: Int
    ) -> (dy: Int, margins: (matchTop: Int, matchBottom: Int, stickyTop: Int, stickyBottom: Int))? {
        let margins = ScrollFrameDigest.detectStaticMargins(a: anchor.rows, b: curr.rows, height: h)
        let workTop = min(h * 30 / 100, max(lockedTopFixed, margins.matchTop))
        let workBottom = h - min(h * 30 / 100, max(lockedBottomFixed, margins.matchBottom))
        let workH = workBottom - workTop
        guard workH >= 32 else { return nil }

        let minOverlap = max(20, workH * 12 / 100)
        let maxForwardDy = workH - minOverlap
        let minBackwardDy = -min(workH / 2, 260)
        guard maxForwardDy >= 2 else { return nil }
        let activeBands = ScrollFrameDigest.detectActiveBands(a: anchor.rows, b: curr.rows, workTop: workTop, workBottom: workBottom)

        func score(at dy: Int, rowStep: Int) -> Double {
            let overlapStart = max(workTop, workTop - dy)
            let overlapEnd = min(workBottom, workBottom - dy)
            let overlapLen = overlapEnd - overlapStart
            if overlapLen < minOverlap { return .greatestFiniteMagnitude }

            var weightedDiff: Double = 0
            var weightSum: Double = 0
            var texturedCount = 0
            var cy = overlapStart
            while cy < overlapEnd {
                let ra = anchor.rows[cy + dy]
                let rc = curr.rows[cy]
                let d = Double(ra.maskedDiff(to: rc, activeMask: activeBands.mask, activeCount: activeBands.count))
                let isTextured = ra.grad >= 4 || rc.grad >= 4
                let wgt: Double = isTextured ? 3.5 : 0.45
                if isTextured { texturedCount += 1 }
                weightedDiff += d * wgt
                weightSum += wgt
                cy += rowStep
            }
            guard weightSum > 0 else { return .greatestFiniteMagnitude }
            var meanScore = (weightedDiff / weightSum) * (1.0 + Double(abs(dy)) / Double(workH * 8))
            if texturedCount < 3 { meanScore += 4.0 }
            return meanScore
        }

        // 粗搜 (步长 2) + 局部单像素精搜，兼顾 <0.4ms 极速吞吐与 @1x 细笔画精准峰值
        var topCands: [(dy: Int, sc: Double)] = []
        var cDy = minBackwardDy
        while cDy <= maxForwardDy {
            let sc = score(at: cDy, rowStep: 2)
            if sc < .greatestFiniteMagnitude {
                if topCands.count < 3 {
                    topCands.append((cDy, sc))
                    topCands.sort { $0.sc < $1.sc }
                } else if sc < topCands[2].sc {
                    topCands[2] = (cDy, sc)
                    topCands.sort { $0.sc < $1.sc }
                }
            }
            cDy += 2
        }

        var bestDy = 0
        var bestScore = Double.greatestFiniteMagnitude
        for cand in topCands {
            let lo = max(minBackwardDy, cand.dy - 3)
            let hi = min(maxForwardDy, cand.dy + 3)
            for dy in lo...hi {
                let sc = score(at: dy, rowStep: 1)
                if sc < bestScore {
                    bestScore = sc
                    bestDy = dy
                }
            }
        }

        guard bestScore <= 18.0,
              ScrollFrameDigest.verify2DOverlap(
                  anchor: anchor.sampler, curr: curr.sampler,
                  width: w, height: h, workTop: workTop, workBottom: workBottom,
                  dy: bestDy, activeMask: activeBands.mask
              ) else {
            return nil
        }
        return (bestDy, margins)
    }

    private func appendMatchedDelta(
        from frame: CGImage,
        digest: ScrollFrameDigest,
        dy: Int,
        margins: (matchTop: Int, matchBottom: Int, stickyTop: Int, stickyBottom: Int),
        resyncBase: CGImage?
    ) -> StepResult {
        let w = widthPx, h = frameHeightPx
        if strips.isEmpty, let initial = firstFrame {
            lockedTopFixed = margins.stickyTop
            lockedBottomFixed = margins.stickyBottom
            let initH = h - lockedBottomFixed
            if let s0 = ScrollFrameDigest.detachCopy(initial, rect: CGRect(x: 0, y: 0, width: w, height: initH)) {
                strips.append(s0)
                previewStrips.append(ScrollFrameDigest.makePreviewSlice(s0))
                bodyHeightPx = s0.height
            }
        } else if margins.matchTop < lockedTopFixed {
            // 仅在后续帧证明原顶部区域实际发生了滚动时向下收敛，绝不因空白留白向上膨胀
            lockedTopFixed = min(lockedTopFixed, margins.stickyTop)
        }

        var totalAdded = 0
        let activeWorkBottom = h - lockedBottomFixed

        // 若为失步后的自动重锚续接，先把新锚点帧的正文区完整接上，再追加本次 dy 增量
        if let baseImg = resyncBase {
            let baseTop = lockedTopFixed
            let baseH = min(max(0, activeWorkBottom - baseTop), maxHeightPx - lockedBottomFixed - bodyHeightPx)
            if baseH > 0,
               let baseStrip = ScrollFrameDigest.detachCopy(baseImg, rect: CGRect(x: 0, y: baseTop, width: w, height: baseH)) {
                strips.append(baseStrip)
                previewStrips.append(ScrollFrameDigest.makePreviewSlice(baseStrip))
                bodyHeightPx += baseStrip.height
                totalAdded += baseStrip.height
            }
        }

        let stripTopY = max(lockedTopFixed, activeWorkBottom - dy)
        let allowedAddH = min(activeWorkBottom - stripTopY, maxHeightPx - lockedBottomFixed - bodyHeightPx)
        guard allowedAddH > 0 else { return .reachedHeightLimit }

        let stripRect = CGRect(x: 0, y: stripTopY, width: w, height: allowedAddH)
        guard let newStrip = ScrollFrameDigest.detachCopy(frame, rect: stripRect) else { return .unchanged }
        strips.append(newStrip)
        previewStrips.append(ScrollFrameDigest.makePreviewSlice(newStrip))
        bodyHeightPx += newStrip.height
        totalAdded += newStrip.height

        if lockedBottomFixed > 0 {
            let footer = ScrollFrameDigest.detachCopy(
                frame, rect: CGRect(x: 0, y: activeWorkBottom, width: w, height: lockedBottomFixed)
            )
            latestFooterStrip = footer
            previewFooterStrip = footer.map { ScrollFrameDigest.makePreviewSlice($0) }
        }

        if let detached = ScrollFrameDigest.detachCopy(frame, rect: CGRect(x: 0, y: 0, width: w, height: h)) {
            frontierDigest = ScrollFrameDigest(image: detached, sampler: PixelSampler(cgImage: detached), rows: digest.rows)
        }

        if totalHeightPx >= maxHeightPx { return .reachedHeightLimit }
        return .appended(addedPx: totalAdded, totalHeightPx: totalHeightPx)
    }

    public func renderFinalImage() -> CGImage? {
        strips.isEmpty ? firstFrame : ScrollFrameDigest.composeStrips(
            widthPx: widthPx, totalHeightPx: totalHeightPx, strips: strips, previewStrips: previewStrips,
            footer: latestFooterStrip, previewFooter: previewFooterStrip, scaleDownToMaxSide: nil, usePreviewSlices: false
        )
    }

    public func renderPreviewImage(maxSidePx: Int = 680) -> CGImage? {
        strips.isEmpty ? firstFrame : ScrollFrameDigest.composeStrips(
            widthPx: widthPx, totalHeightPx: totalHeightPx, strips: strips, previewStrips: previewStrips,
            footer: latestFooterStrip, previewFooter: previewFooterStrip, scaleDownToMaxSide: maxSidePx, usePreviewSlices: true
        )
    }
}
