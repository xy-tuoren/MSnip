import CoreGraphics
import Foundation

/// 纯原生滚动长截图拼接状态机（零外部依赖）：
/// 自动剥离顶部/底部 Sticky 固定栏、屏蔽右侧滚动条、支持中途回滚去重与过快滚动告警
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
    private var latestFooterStrip: CGImage?
    private var strips: [CGImage] = []
    private var bodyHeightPx: Int = 0

    public var totalHeightPx: Int {
        if strips.isEmpty { return frameHeightPx }
        return bodyHeightPx + (latestFooterStrip?.height ?? 0)
    }

    public var hasScrolled: Bool { !strips.isEmpty }

    public init(maxHeightPx: Int = ScrollStitcher.defaultMaxHeightPx) {
        self.maxHeightPx = max(1200, maxHeightPx)
    }

    /// 喂入最新采集到的选区帧（物理像素尺寸需保持一致）
    public func ingest(frame: CGImage) -> StepResult {
        let w = frame.width, h = frame.height
        guard w >= 24, h >= 32 else { return .unchanged }

        let digest = ScrollFrameDigest.build(for: frame)
        if frontierDigest == nil || (strips.isEmpty && (w != widthPx || h != frameHeightPx)) {
            widthPx = w
            frameHeightPx = h
            let detached = ScrollFrameDigest.detachCopy(frame, rect: CGRect(x: 0, y: 0, width: w, height: h)) ?? frame
            firstFrame = detached
            frontierDigest = ScrollFrameDigest(image: detached, sampler: PixelSampler(cgImage: detached), rows: digest.rows)
            return .initialized(widthPx: w, heightPx: h)
        }
        guard let anchor = frontierDigest, w == widthPx, h == frameHeightPx else { return .unchanged }
        if totalHeightPx >= maxHeightPx { return .reachedHeightLimit }

        // 1) 静止帧快速过滤
        var unchangedRows = 0
        for y in 0..<h where anchor.rows[y].diff(to: digest.rows[y]) <= 4 {
            unchangedRows += 1
        }
        if unchangedRows * 100 >= h * 97 { return .unchanged }

        // 2) 检测上下静态边距（匹配时排除所有未动边缘，裁剪条带时仅剥离真正 Sticky 固定栏）
        let margins = ScrollFrameDigest.detectStaticMargins(a: anchor.rows, b: digest.rows, height: h)
        let workTop = min(h * 42 / 100, max(lockedTopFixed, margins.matchTop))
        let workBottom = h - min(h * 42 / 100, max(lockedBottomFixed, margins.matchBottom))
        let workH = workBottom - workTop
        guard workH >= 36 else { return .unchanged }

        // 3) 在有效滚动窗口内搜索最佳纵向偏移 dy
        let minOverlap = max(28, workH * 20 / 100)
        let maxForwardDy = workH - minOverlap
        let minBackwardDy = -min(workH / 2, 240)
        guard maxForwardDy >= 2 else { return .unchanged }

        var bestDy = 0
        var bestScore = Double.greatestFiniteMagnitude

        for dy in minBackwardDy...maxForwardDy {
            let overlapStart = max(workTop, workTop - dy)
            let overlapEnd = min(workBottom, workBottom - dy)
            let overlapLen = overlapEnd - overlapStart
            if overlapLen < minOverlap { continue }

            var weightedDiff: Double = 0
            var weightSum: Double = 0
            var texturedCount = 0
            let rowStep = overlapLen > 240 ? 2 : 1

            var cy = overlapStart
            while cy < overlapEnd {
                let ra = anchor.rows[cy + dy]
                let rc = digest.rows[cy]
                let d = Double(ra.diff(to: rc))
                let isTextured = ra.grad >= 4 || rc.grad >= 4
                let wgt: Double = isTextured ? 3.0 : 0.6
                if isTextured { texturedCount += 1 }
                weightedDiff += d * wgt
                weightSum += wgt
                cy += rowStep
            }
            guard weightSum > 0 else { continue }
            var meanScore = (weightedDiff / weightSum) * (1.0 + Double(abs(dy)) / Double(workH * 6))
            if texturedCount < 3 { meanScore += 2.5 }

            if meanScore < bestScore {
                bestScore = meanScore
                bestDy = dy
            }
        }

        // 4) 二维原图像素抽检确认
        guard bestScore <= 16.0,
              ScrollFrameDigest.verify2DOverlap(
                  anchor: anchor.sampler, curr: digest.sampler,
                  width: w, workTop: workTop, workBottom: workBottom, dy: bestDy
              ) else {
            return .mismatchLostOverlap
        }

        if bestDy == 0 { return .unchanged }
        if bestDy < 0 { return .scrolledBackward }

        // 5) 有效向下滚动：追加新增像素条带并推进前沿锚点
        if strips.isEmpty, let initial = firstFrame {
            lockedTopFixed = margins.stickyTop
            lockedBottomFixed = margins.stickyBottom
            let initH = h - lockedBottomFixed
            if let s0 = ScrollFrameDigest.detachCopy(initial, rect: CGRect(x: 0, y: 0, width: w, height: initH)) {
                strips.append(s0)
                bodyHeightPx = s0.height
            }
        } else {
            lockedTopFixed = max(lockedTopFixed, margins.stickyTop)
        }

        let activeWorkBottom = h - lockedBottomFixed
        let stripTopY = max(0, activeWorkBottom - bestDy)
        let allowedAddH = min(activeWorkBottom - stripTopY, maxHeightPx - lockedBottomFixed - bodyHeightPx)
        guard allowedAddH > 0 else { return .reachedHeightLimit }

        let stripRect = CGRect(x: 0, y: stripTopY, width: w, height: allowedAddH)
        guard let newStrip = ScrollFrameDigest.detachCopy(frame, rect: stripRect) else { return .unchanged }
        strips.append(newStrip)
        bodyHeightPx += newStrip.height

        if lockedBottomFixed > 0 {
            latestFooterStrip = ScrollFrameDigest.detachCopy(
                frame, rect: CGRect(x: 0, y: activeWorkBottom, width: w, height: lockedBottomFixed)
            )
        }

        let detachedAnchor = ScrollFrameDigest.detachCopy(frame, rect: CGRect(x: 0, y: 0, width: w, height: h)) ?? frame
        frontierDigest = ScrollFrameDigest(image: detachedAnchor, sampler: PixelSampler(cgImage: detachedAnchor), rows: digest.rows)

        if totalHeightPx >= maxHeightPx { return .reachedHeightLimit }
        return .appended(addedPx: newStrip.height, totalHeightPx: totalHeightPx)
    }

    public func renderFinalImage() -> CGImage? {
        strips.isEmpty ? firstFrame : composeStrips(scaleDownToMaxSide: nil)
    }

    public func renderPreviewImage(maxSidePx: Int = 680) -> CGImage? {
        strips.isEmpty ? firstFrame : composeStrips(scaleDownToMaxSide: maxSidePx)
    }

    private func composeStrips(scaleDownToMaxSide: Int?) -> CGImage? {
        let fullW = widthPx, fullH = totalHeightPx
        guard fullW > 0, fullH > 0 else { return nil }

        var scale: CGFloat = 1.0
        if let maxSide = scaleDownToMaxSide, max(fullW, fullH) > maxSide {
            scale = CGFloat(maxSide) / CGFloat(max(fullW, fullH))
        }
        let outW = max(1, Int((CGFloat(fullW) * scale).rounded()))
        let outH = max(1, Int((CGFloat(fullH) * scale).rounded()))
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = scale < 1.0 ? .medium : .none
        var cursorTopPx = 0
        var allParts = strips
        if let footer = latestFooterStrip { allParts.append(footer) }

        for part in allParts {
            let ph = part.height
            let dstY = CGFloat(fullH - cursorTopPx - ph) * scale
            ctx.draw(part, in: CGRect(x: 0, y: dstY, width: CGFloat(outW), height: CGFloat(ph) * scale))
            cursorTopPx += ph
        }
        return ctx.makeImage()
    }
}
