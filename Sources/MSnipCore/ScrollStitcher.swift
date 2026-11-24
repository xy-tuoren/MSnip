import CoreGraphics
import Foundation

/// 滚动长截图拼接方向（纵向向下 / 横向向右）
public enum ScrollStitchAxis: String, CaseIterable, Codable, Sendable {
    case vertical
    case horizontal
}

/// 纯原生滚动长截图拼接状态机（零外部依赖）：
/// 支持纵向/横向切换、自动剥离 Sticky 固定栏、屏蔽侧边栏与滚动条、撤回上一段、尾部微调裁剪及跨屏失步自愈续接
public final class ScrollStitcher: @unchecked Sendable {
    public enum StepResult: Equatable, Sendable {
        case initialized(widthPx: Int, heightPx: Int)
        case unchanged
        case scrolledBackward
        case appended(addedPx: Int, totalHeightPx: Int)
        case mismatchLostOverlap
        case reachedHeightLimit
    }

    private struct UndoSnapshot {
        let stripCount: Int
        let bodyHeightPx: Int
        let lockedTopFixed: Int
        let lockedBottomFixed: Int
        let frontierDigest: ScrollFrameDigest?
        let latestFooterStrip: CGImage?
        let previewFooterStrip: CGImage?
    }

    public static let defaultMaxHeightPx = 24_000

    public let maxHeightPx: Int
    public private(set) var axis: ScrollStitchAxis
    public private(set) var widthPx: Int = 0
    public private(set) var frameHeightPx: Int = 0
    public private(set) var lockedTopFixed: Int = 0
    public private(set) var lockedBottomFixed: Int = 0

    private let lock = NSLock()
    private var firstFrame: CGImage?
    private var frontierDigest: ScrollFrameDigest?
    private var resyncDigest: ScrollFrameDigest?
    private var latestFooterStrip: CGImage?
    private var previewFooterStrip: CGImage?
    private var strips: [CGImage] = []
    private var previewStrips: [CGImage] = []
    private var bodyHeightPx: Int = 0
    private var undoStack: [UndoSnapshot] = []

    /// 内部拼接方向上的累计像素长度（纵向为总高度，横向为总宽度）
    public var totalHeightPx: Int { lock.lock(); defer { lock.unlock() }; return totalHeightPxUnlocked }
    private var totalHeightPxUnlocked: Int { strips.isEmpty ? frameHeightPx : bodyHeightPx + (latestFooterStrip?.height ?? 0) }
    /// 对外输出图像尺寸（横向模式下自动映射为 `totalWidth × frameHeight`）
    public var outputSizePx: (width: Int, height: Int) {
        lock.lock(); defer { lock.unlock() }
        return axis == .horizontal ? (totalHeightPxUnlocked, widthPx) : (widthPx, totalHeightPxUnlocked)
    }
    public var hasScrolled: Bool { lock.lock(); defer { lock.unlock() }; return !strips.isEmpty }
    public var canUndoAppend: Bool { lock.lock(); defer { lock.unlock() }; return !undoStack.isEmpty }

    public init(maxHeightPx: Int = ScrollStitcher.defaultMaxHeightPx, axis: ScrollStitchAxis = .vertical) {
        self.maxHeightPx = max(1200, maxHeightPx)
        self.axis = axis
    }

    /// 重置全部已拼接状态并切换拼接方向
    public func reset(axis newAxis: ScrollStitchAxis) {
        lock.lock(); defer { lock.unlock() }
        axis = newAxis
        widthPx = 0; frameHeightPx = 0; lockedTopFixed = 0; lockedBottomFixed = 0
        firstFrame = nil; frontierDigest = nil; resyncDigest = nil
        latestFooterStrip = nil; previewFooterStrip = nil
        strips.removeAll(); previewStrips.removeAll(); undoStack.removeAll(); bodyHeightPx = 0
    }

    /// 撤回最近一次成功拼接的增量段落（恢复精确前沿锚点以便立即继续滚动）
    @discardableResult
    public func undoLastAppend() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let snap = undoStack.popLast() else { return false }
        if strips.count > snap.stripCount {
            strips.removeLast(strips.count - snap.stripCount)
            previewStrips.removeLast(previewStrips.count - snap.stripCount)
        }
        bodyHeightPx = snap.bodyHeightPx
        lockedTopFixed = snap.lockedTopFixed
        lockedBottomFixed = snap.lockedBottomFixed
        frontierDigest = snap.frontierDigest
        latestFooterStrip = snap.latestFooterStrip
        previewFooterStrip = snap.previewFooterStrip
        resyncDigest = nil
        return true
    }

    /// 裁剪已拼接正文的尾部指定像素（用于去除误拼的多余尾部段）
    @discardableResult
    public func trimTail(pixels: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pixels > 0, !strips.isEmpty else { return false }
        var remaining = min(pixels, max(0, bodyHeightPx - max(32, frameHeightPx / 2)))
        guard remaining > 0 else { return false }
        while remaining > 0, let last = strips.last {
            if last.height <= remaining, strips.count > 1 {
                strips.removeLast(); previewStrips.removeLast()
                bodyHeightPx -= last.height; remaining -= last.height
            } else {
                let keepH = max(16, last.height - remaining)
                if let cropped = ScrollFrameDigest.detachCopy(last, rect: CGRect(x: 0, y: 0, width: last.width, height: keepH)) {
                    strips[strips.count - 1] = cropped
                    previewStrips[previewStrips.count - 1] = ScrollFrameDigest.makePreviewSlice(cropped)
                    bodyHeightPx -= (last.height - keepH)
                }
                break
            }
        }
        undoStack.removeAll()
        return true
    }

    /// 喂入最新采集到的选区帧（横向模式自动执行 90° 无损转置，复用完整抗 Sticky 纵向拼接引擎）
    public func ingest(frame rawFrame: CGImage) -> StepResult {
        lock.lock(); defer { lock.unlock() }
        let frame: CGImage
        if axis == .horizontal {
            guard let rotated = ImageTransform.rotateClockwise90(rawFrame) else { return .unchanged }
            frame = rotated
        } else {
            frame = rawFrame
        }
        let w = frame.width, h = frame.height
        guard w >= 24, h >= 32 else { return .unchanged }

        if frontierDigest == nil || (strips.isEmpty && (w != widthPx || h != frameHeightPx)) {
            widthPx = w; frameHeightPx = h
            let detached = ScrollFrameDigest.build(for: frame, detach: true)
            firstFrame = detached.image; frontierDigest = detached; resyncDigest = nil
            let sz = axis == .horizontal ? (totalHeightPxUnlocked, widthPx) : (widthPx, totalHeightPxUnlocked)
            return .initialized(widthPx: sz.0, heightPx: sz.1)
        }
        guard let anchor = frontierDigest, w == widthPx, h == frameHeightPx else { return .unchanged }
        if totalHeightPxUnlocked >= maxHeightPx { return .reachedHeightLimit }

        let digest = ScrollFrameDigest.build(for: frame, detach: false)
        var unchangedRows = 0
        for y in 0..<h where anchor.rows[y].fullDiff(to: digest.rows[y]) <= 5 { unchangedRows += 1 }
        if unchangedRows * 100 >= h * 97 { return .unchanged }

        if let match = matchDisplacement(anchor: anchor, curr: digest, width: w, height: h) {
            resyncDigest = nil
            if match.dy == 0 { return .unchanged }
            if match.dy < 0 { return .scrolledBackward }
            return appendMatchedDelta(from: frame, digest: digest, dy: match.dy, margins: match.margins, resyncBase: nil)
        }

        if let pending = resyncDigest {
            var sameAsPending = 0
            for y in 0..<h where pending.rows[y].fullDiff(to: digest.rows[y]) <= 5 { sameAsPending += 1 }
            if sameAsPending * 100 >= h * 97 { return .unchanged }
            if let rec = matchDisplacement(anchor: pending, curr: digest, width: w, height: h) {
                if rec.dy == 0 { return .unchanged }
                if rec.dy >= 8 {
                    resyncDigest = nil
                    return appendMatchedDelta(from: frame, digest: digest, dy: rec.dy, margins: rec.margins, resyncBase: pending.image)
                }
            }
        }
        resyncDigest = ScrollFrameDigest.build(for: frame, detach: true)
        return .mismatchLostOverlap
    }

    private func matchDisplacement(
        anchor: ScrollFrameDigest, curr: ScrollFrameDigest, width w: Int, height h: Int
    ) -> (dy: Int, margins: (matchTop: Int, matchBottom: Int, stickyTop: Int, stickyBottom: Int))? {
        let margins = ScrollFrameDigest.detectStaticMargins(a: anchor.rows, b: curr.rows, height: h)
        let workTop = min(h * 30 / 100, max(lockedTopFixed, margins.matchTop))
        let workBottom = h - min(h * 30 / 100, max(lockedBottomFixed, margins.matchBottom))
        let workH = workBottom - workTop
        guard workH >= 32 else { return nil }
        let minOverlap = max(20, workH * 12 / 100), maxForwardDy = workH - minOverlap, minBackwardDy = -min(workH / 2, 260)
        guard maxForwardDy >= 2 else { return nil }
        let activeBands = ScrollFrameDigest.detectActiveBands(a: anchor.rows, b: curr.rows, workTop: workTop, workBottom: workBottom)

        func score(at dy: Int, rowStep: Int) -> Double {
            let ovS = max(workTop, workTop - dy), ovE = min(workBottom, workBottom - dy)
            if ovE - ovS < minOverlap { return .greatestFiniteMagnitude }
            var wDiff = 0.0, wSum = 0.0, textured = 0, cy = ovS
            while cy < ovE {
                let ra = anchor.rows[cy + dy], rc = curr.rows[cy]
                let d = Double(ra.maskedDiff(to: rc, activeMask: activeBands.mask, activeCount: activeBands.count))
                let isTex = ra.grad >= 4 || rc.grad >= 4
                let wgt = isTex ? 3.5 : 0.45
                if isTex { textured += 1 }
                wDiff += d * wgt; wSum += wgt; cy += rowStep
            }
            guard wSum > 0 else { return .greatestFiniteMagnitude }
            var m = (wDiff / wSum) * (1.0 + Double(abs(dy)) / Double(workH * 8))
            if textured < 3 { m += 4.0 }
            return m
        }

        var topCands: [(dy: Int, sc: Double)] = []
        var cDy = minBackwardDy
        while cDy <= maxForwardDy {
            let sc = score(at: cDy, rowStep: 2)
            if sc < .greatestFiniteMagnitude {
                if topCands.count < 3 { topCands.append((cDy, sc)); topCands.sort { $0.sc < $1.sc } }
                else if sc < topCands[2].sc { topCands[2] = (cDy, sc); topCands.sort { $0.sc < $1.sc } }
            }
            cDy += 2
        }
        var bestDy = 0, bestScore = Double.greatestFiniteMagnitude
        for cand in topCands {
            for dy in max(minBackwardDy, cand.dy - 3)...min(maxForwardDy, cand.dy + 3) {
                let sc = score(at: dy, rowStep: 1)
                if sc < bestScore { bestScore = sc; bestDy = dy }
            }
        }
        guard bestScore <= 18.0, ScrollFrameDigest.verify2DOverlap(
            anchor: anchor.sampler, curr: curr.sampler, width: w, height: h,
            workTop: workTop, workBottom: workBottom, dy: bestDy, activeMask: activeBands.mask
        ) else { return nil }
        return (bestDy, margins)
    }

    private func appendMatchedDelta(
        from frame: CGImage, digest: ScrollFrameDigest, dy: Int,
        margins: (matchTop: Int, matchBottom: Int, stickyTop: Int, stickyBottom: Int), resyncBase: CGImage?
    ) -> StepResult {
        if undoStack.count >= 8 { undoStack.removeFirst() }
        undoStack.append(UndoSnapshot(
            stripCount: strips.count, bodyHeightPx: bodyHeightPx, lockedTopFixed: lockedTopFixed,
            lockedBottomFixed: lockedBottomFixed, frontierDigest: frontierDigest,
            latestFooterStrip: latestFooterStrip, previewFooterStrip: previewFooterStrip
        ))
        let w = widthPx, h = frameHeightPx
        if strips.isEmpty, let initial = firstFrame {
            lockedTopFixed = margins.stickyTop; lockedBottomFixed = margins.stickyBottom
            if let s0 = ScrollFrameDigest.detachCopy(initial, rect: CGRect(x: 0, y: 0, width: w, height: h - lockedBottomFixed)) {
                strips.append(s0); previewStrips.append(ScrollFrameDigest.makePreviewSlice(s0)); bodyHeightPx = s0.height
            }
        } else if margins.matchTop < lockedTopFixed {
            lockedTopFixed = min(lockedTopFixed, margins.stickyTop)
        }
        var totalAdded = 0
        let activeWorkBottom = h - lockedBottomFixed
        if let baseImg = resyncBase {
            let baseH = min(max(0, activeWorkBottom - lockedTopFixed), maxHeightPx - lockedBottomFixed - bodyHeightPx)
            if baseH > 0, let bs = ScrollFrameDigest.detachCopy(baseImg, rect: CGRect(x: 0, y: lockedTopFixed, width: w, height: baseH)) {
                strips.append(bs); previewStrips.append(ScrollFrameDigest.makePreviewSlice(bs)); bodyHeightPx += bs.height; totalAdded += bs.height
            }
        }
        let stripTopY = max(lockedTopFixed, activeWorkBottom - dy)
        let allowedAddH = min(activeWorkBottom - stripTopY, maxHeightPx - lockedBottomFixed - bodyHeightPx)
        guard allowedAddH > 0 else { _ = undoStack.popLast(); return .reachedHeightLimit }
        guard let newStrip = ScrollFrameDigest.detachCopy(frame, rect: CGRect(x: 0, y: stripTopY, width: w, height: allowedAddH)) else {
            _ = undoStack.popLast(); return .unchanged
        }
        strips.append(newStrip); previewStrips.append(ScrollFrameDigest.makePreviewSlice(newStrip))
        bodyHeightPx += newStrip.height; totalAdded += newStrip.height
        if lockedBottomFixed > 0 {
            let footer = ScrollFrameDigest.detachCopy(frame, rect: CGRect(x: 0, y: activeWorkBottom, width: w, height: lockedBottomFixed))
            latestFooterStrip = footer; previewFooterStrip = footer.map { ScrollFrameDigest.makePreviewSlice($0) }
        }
        if let detached = ScrollFrameDigest.detachCopy(frame, rect: CGRect(x: 0, y: 0, width: w, height: h)) {
            frontierDigest = ScrollFrameDigest(image: detached, sampler: PixelSampler(cgImage: detached), rows: digest.rows)
        }
        return totalHeightPxUnlocked >= maxHeightPx ? .reachedHeightLimit : .appended(addedPx: totalAdded, totalHeightPx: totalHeightPxUnlocked)
    }

    public func renderFinalImage() -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        let composed = strips.isEmpty ? firstFrame : ScrollFrameDigest.composeStrips(
            widthPx: widthPx, totalHeightPx: totalHeightPxUnlocked, strips: strips, previewStrips: previewStrips,
            footer: latestFooterStrip, previewFooter: previewFooterStrip, scaleDownToMaxSide: nil, usePreviewSlices: false
        )
        guard let img = composed else { return nil }
        return axis == .horizontal ? ImageTransform.rotateCounterClockwise90(img) : img
    }

    public func renderPreviewImage(maxSidePx: Int = 680) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        let composed = strips.isEmpty ? firstFrame : ScrollFrameDigest.composeStrips(
            widthPx: widthPx, totalHeightPx: totalHeightPxUnlocked, strips: strips, previewStrips: previewStrips,
            footer: latestFooterStrip, previewFooter: previewFooterStrip, scaleDownToMaxSide: maxSidePx, usePreviewSlices: true
        )
        guard let img = composed else { return nil }
        return axis == .horizontal ? ImageTransform.rotateCounterClockwise90(img) : img
    }
}
