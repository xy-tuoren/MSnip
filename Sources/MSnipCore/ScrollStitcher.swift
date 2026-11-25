import CoreGraphics
import Foundation

/// 滚动长截图拼接方向（纵向向下 / 横向向右）
public enum ScrollStitchAxis: String, CaseIterable, Codable, Sendable {
    case vertical
    case horizontal
}

/// 纯原生滚动长截图拼接状态机（零外部依赖）：
/// - 「洁净中缝提交 + 动态尾段替换」消除悬浮按钮（如 `↓` 置底键）与固定底栏反复重影；
/// - 「关键帧步长 + 橡皮筋回弹撤消」杜绝高帧率微切片漂移与触控板触底多余空白；
/// - 停滚后严格检验上区纹丝不动再静默刷新尾段，既吸收淡出图标又不误吞稀疏页微滚动。
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
    public private(set) var axis: ScrollStitchAxis
    public private(set) var widthPx: Int = 0
    public private(set) var frameHeightPx: Int = 0
    public private(set) var lockedTopFixed: Int = 0
    public private(set) var lockedBottomFixed: Int = 0

    private let lock = NSLock()
    private var firstFrame: CGImage?
    private var anchorDigest: ScrollFrameDigest?
    private var pendingDigest: ScrollFrameDigest?
    private var pendingDy: Int = 0
    private var resyncDigest: ScrollFrameDigest?
    private var seamY: Int = 0
    private var canvas = ScrollStripCanvas()
    private var undoStack: [ScrollUndoSnapshot] = []

    public var totalHeightPx: Int { lock.lock(); defer { lock.unlock() }; return totalHeightPxUnlocked }
    private var totalHeightPxUnlocked: Int { canvas.isEmpty ? frameHeightPx : canvas.totalHeightPx }
    public var outputSizePx: (width: Int, height: Int) {
        lock.lock(); defer { lock.unlock() }
        return axis == .horizontal ? (totalHeightPxUnlocked, widthPx) : (widthPx, totalHeightPxUnlocked)
    }
    public var hasScrolled: Bool { lock.lock(); defer { lock.unlock() }; return !canvas.isEmpty }
    public var canUndoAppend: Bool { lock.lock(); defer { lock.unlock() }; return !undoStack.isEmpty || pendingDy > 0 }

    public init(maxHeightPx: Int = ScrollStitcher.defaultMaxHeightPx, axis: ScrollStitchAxis = .vertical) {
        self.maxHeightPx = max(1200, maxHeightPx)
        self.axis = axis
    }

    public func reset(axis newAxis: ScrollStitchAxis) {
        lock.lock(); defer { lock.unlock() }
        axis = newAxis
        widthPx = 0; frameHeightPx = 0; lockedTopFixed = 0; lockedBottomFixed = 0; seamY = 0
        firstFrame = nil; anchorDigest = nil; pendingDigest = nil; pendingDy = 0; resyncDigest = nil
        canvas.removeAll(); undoStack.removeAll()
    }

    @discardableResult
    public func undoLastAppend() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if pendingDy > 0, let anchor = anchorDigest {
            pendingDy = 0; pendingDigest = nil; resyncDigest = nil
            if canvas.strips.count <= 1 && undoStack.isEmpty { canvas.removeAll(); seamY = 0 }
            else { canvas.updateLiveTail(from: anchor.image, topY: seamY, width: widthPx, frameHeight: frameHeightPx) }
            return true
        }
        guard let snap = undoStack.popLast() else { return false }
        canvas.restore(stripCount: snap.stripCount, bodyHeight: snap.bodyHeightPx, liveTail: snap.liveTailStrip, previewTail: snap.previewTailStrip)
        seamY = snap.seamY; lockedTopFixed = snap.lockedTopFixed; lockedBottomFixed = snap.lockedBottomFixed
        anchorDigest = snap.anchorDigest; pendingDy = 0; pendingDigest = nil; resyncDigest = nil
        return true
    }

    @discardableResult
    public func trimTail(pixels: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let ok = canvas.trimTail(pixels: pixels, width: widthPx, frameHeight: frameHeightPx, lockedBottomFixed: lockedBottomFixed)
        if ok { pendingDy = 0; pendingDigest = nil; undoStack.removeAll() }
        return ok
    }

    public func ingest(frame rawFrame: CGImage) -> StepResult {
        lock.lock(); defer { lock.unlock() }
        let frame: CGImage
        if axis == .horizontal {
            guard let rotated = ImageTransform.rotateClockwise90(rawFrame) else { return .unchanged }
            frame = rotated
        } else { frame = rawFrame }
        let w = frame.width, h = frame.height
        guard w >= 24, h >= 32 else { return .unchanged }

        if anchorDigest == nil || (canvas.isEmpty && (w != widthPx || h != frameHeightPx)) {
            widthPx = w; frameHeightPx = h
            let detached = ScrollFrameDigest.build(for: frame, detach: true)
            firstFrame = detached.image; anchorDigest = detached
            pendingDigest = nil; pendingDy = 0; resyncDigest = nil
            let sz = axis == .horizontal ? (totalHeightPxUnlocked, widthPx) : (widthPx, totalHeightPxUnlocked)
            return .initialized(widthPx: sz.0, heightPx: sz.1)
        }
        guard let anchor = anchorDigest, w == widthPx, h == frameHeightPx else { return .unchanged }
        if totalHeightPxUnlocked >= maxHeightPx { return .reachedHeightLimit }

        let digest = ScrollFrameDigest.build(for: frame, detach: false)
        let latest = pendingDigest ?? anchor
        var exactSame = true
        for y in 0..<h where latest.rows[y].fullDiff(to: digest.rows[y]) > 2 { exactSame = false; break }
        if exactSame { return .unchanged }
        if !canvas.isEmpty, ScrollOverlapVerifier.isSettledTailRefresh(a: latest, b: digest, workTop: lockedTopFixed, seamY: seamY, height: h) {
            refreshSettledTail(from: frame, digest: digest)
            return .unchanged
        }

        if let match = ScrollOverlapVerifier.matchDisplacement(
            anchor: anchor, curr: digest, width: w, height: h, lockedTop: lockedTopFixed, lockedBottom: lockedBottomFixed
        ) {
            resyncDigest = nil
            if match.dy == pendingDy { if !canvas.isEmpty { refreshSettledTail(from: frame, digest: digest) }; return .unchanged }
            if match.dy < pendingDy { rollbackRubberBandIfBlank(matchDy: match.dy, frame: frame, digest: digest); return .scrolledBackward }
            return processForwardMatch(frame: frame, digest: digest, dy: match.dy, margins: match.margins)
        }
        if let pending = pendingDigest, pendingDy > 0,
           let bridge = ScrollOverlapVerifier.matchDisplacement(
               anchor: pending, curr: digest, width: w, height: h, lockedTop: lockedTopFixed, lockedBottom: lockedBottomFixed
           ) {
            resyncDigest = nil
            if bridge.dy <= 0 { return bridge.dy == 0 ? .unchanged : .scrolledBackward }
            commitPendingAsKeyframe()
            return processForwardMatch(frame: frame, digest: digest, dy: bridge.dy, margins: bridge.margins)
        }
        if let resync = resyncDigest {
            var sameAsResync = 0
            for y in 0..<h where resync.rows[y].fullDiff(to: digest.rows[y]) <= 4 { sameAsResync += 1 }
            if sameAsResync * 100 >= h * 97 { return .unchanged }
            if let rec = ScrollOverlapVerifier.matchDisplacement(
                anchor: resync, curr: digest, width: w, height: h, lockedTop: lockedTopFixed, lockedBottom: lockedBottomFixed
            ) {
                if rec.dy == 0 { return .unchanged }
                if rec.dy >= 24 { resyncDigest = nil; return applySelfResync(resyncBase: resync, currFrame: frame, currDigest: digest, dy: rec.dy) }
            }
        }
        resyncDigest = ScrollFrameDigest.build(for: frame, detach: true)
        return .mismatchLostOverlap
    }

    private func refreshSettledTail(from frame: CGImage, digest: ScrollFrameDigest) {
        canvas.updateLiveTail(from: frame, topY: max(lockedTopFixed, seamY - pendingDy), width: widthPx, frameHeight: frameHeightPx)
        if let det = digest.detachedCopy() {
            if pendingDigest != nil { pendingDigest = det } else { anchorDigest = det }
        }
    }

    /// 检测并撤消 macOS 触控板触底橡皮筋回弹：仅当多拉出的底段确为纯空白且随即自动弹回时回退 `pendingDy`
    private func rollbackRubberBandIfBlank(matchDy: Int, frame: CGImage, digest: ScrollFrameDigest) {
        guard matchDy >= 0, let pending = pendingDigest else { return }
        let rebound = pendingDy - matchDy
        guard ScrollFrameDigest.isBlankRubberBand(rows: pending.rows, workBottom: frameHeightPx - lockedBottomFixed, depth: rebound) else { return }
        pendingDy = matchDy
        pendingDigest = matchDy > 0 ? digest.detachedCopy() : nil
        canvas.updateLiveTail(from: frame, topY: max(lockedTopFixed, seamY - matchDy), width: widthPx, frameHeight: frameHeightPx)
    }

    private func processForwardMatch(
        frame: CGImage, digest: ScrollFrameDigest, dy: Int,
        margins: (matchTop: Int, matchBottom: Int, stickyTop: Int, stickyBottom: Int)
    ) -> StepResult {
        guard let anchor = anchorDigest else { return .unchanged }
        let w = widthPx, h = frameHeightPx
        let clampedDelta = min(dy - pendingDy, maxHeightPx - totalHeightPxUnlocked)
        guard clampedDelta > 0 else { return .reachedHeightLimit }
        var effectiveDy = pendingDy + clampedDelta

        let isFirstScroll = canvas.isEmpty
        if isFirstScroll, let initial = firstFrame {
            lockedTopFixed = margins.stickyTop; lockedBottomFixed = margins.stickyBottom
            seamY = ScrollFrameDigest.pickCleanSeamY(
                anchor: anchor.rows, curr: digest.rows, dy: effectiveDy,
                workTop: lockedTopFixed, workBottom: h - lockedBottomFixed
            )
            canvas.appendBodyStrip(from: initial, y: 0, height: seamY, width: w)
        } else if margins.matchTop < lockedTopFixed {
            lockedTopFixed = min(lockedTopFixed, margins.stickyTop)
        }

        let workBottom = h - lockedBottomFixed
        let workH = max(32, workBottom - lockedTopFixed)
        let minCommitDy = max(24, min(workH * 22 / 100, 160))

        // 若此前已挂起真实正文、而本次新增恰好是纯空白橡皮筋拉出且跨过步长，先固化真实正文，将空白留在 pending 等待回弹
        if effectiveDy >= minCommitDy, pendingDy > 0,
           ScrollFrameDigest.isBlankRubberBand(rows: digest.rows, workBottom: workBottom, depth: clampedDelta),
           clampedDelta <= max(1, seamY - lockedTopFixed) {
            commitPendingAsKeyframe()
            effectiveDy = clampedDelta
            pendingDy = effectiveDy; pendingDigest = digest.detachedCopy()
            canvas.updateLiveTail(from: frame, topY: seamY - effectiveDy, width: w, frameHeight: h)
            return totalHeightPxUnlocked >= maxHeightPx ? .reachedHeightLimit : .appended(addedPx: clampedDelta, totalHeightPx: totalHeightPxUnlocked)
        }

        if effectiveDy < minCommitDy && effectiveDy <= max(1, seamY - lockedTopFixed) {
            pendingDy = effectiveDy; pendingDigest = digest.detachedCopy()
            canvas.updateLiveTail(from: frame, topY: seamY - effectiveDy, width: w, frameHeight: h)
            return totalHeightPxUnlocked >= maxHeightPx ? .reachedHeightLimit : .appended(addedPx: clampedDelta, totalHeightPx: totalHeightPxUnlocked)
        }

        pushUndoSnapshot(baseIsInitial: isFirstScroll)
        commitInteriorDelta(anchorImage: anchor.image, currFrame: frame, dy: effectiveDy, currentMatchTop: margins.matchTop)
        if let det = digest.detachedCopy() { anchorDigest = det }
        pendingDy = 0; pendingDigest = nil
        canvas.updateLiveTail(from: frame, topY: seamY, width: w, frameHeight: h)
        return totalHeightPxUnlocked >= maxHeightPx ? .reachedHeightLimit : .appended(addedPx: clampedDelta, totalHeightPx: totalHeightPxUnlocked)
    }

    private func commitPendingAsKeyframe() {
        guard pendingDy > 0, let anchor = anchorDigest, let pending = pendingDigest else { return }
        pushUndoSnapshot(baseIsInitial: false)
        commitInteriorDelta(anchorImage: anchor.image, currFrame: pending.image, dy: pendingDy, currentMatchTop: lockedTopFixed)
        anchorDigest = pending; pendingDy = 0; pendingDigest = nil
        canvas.updateLiveTail(from: pending.image, topY: seamY, width: widthPx, frameHeight: frameHeightPx)
    }

    private func commitInteriorDelta(anchorImage: CGImage, currFrame: CGImage, dy: Int, currentMatchTop: Int) {
        let w = widthPx, workBottom = frameHeightPx - lockedBottomFixed
        let workH = max(32, workBottom - lockedTopFixed)
        let topFloor = max(lockedTopFixed, min(seamY - 24, currentMatchTop))
        let topPad = (workH >= 220) ? min(48, workH / 12) : 0
        let safeTop = max(topFloor, min(seamY - 8, min(topFloor + topPad, workBottom - dy)))

        if seamY - dy >= safeTop {
            canvas.appendBodyStrip(from: currFrame, y: seamY - dy, height: dy, width: w)
        } else {
            let currSpan = max(0, seamY - safeTop), anchorSpan = dy - currSpan
            if anchorSpan > 0 { canvas.appendBodyStrip(from: anchorImage, y: seamY, height: min(anchorSpan, max(0, workBottom - seamY)), width: w) }
            if currSpan > 0 { canvas.appendBodyStrip(from: currFrame, y: safeTop, height: currSpan, width: w) }
        }
    }

    private func applySelfResync(resyncBase: ScrollFrameDigest, currFrame: CGImage, currDigest: ScrollFrameDigest, dy: Int) -> StepResult {
        if pendingDy > 0 { commitPendingAsKeyframe() }
        guard let oldAnchor = anchorDigest else { return .unchanged }
        let w = widthPx, h = frameHeightPx, workBottom = h - lockedBottomFixed
        if canvas.isEmpty, let initial = firstFrame {
            seamY = max(lockedTopFixed + 16, lockedTopFixed + (workBottom - lockedTopFixed) * 43 / 100)
            canvas.appendBodyStrip(from: initial, y: 0, height: seamY, width: w)
        }
        pushUndoSnapshot(baseIsInitial: false)
        let beforeTotal = totalHeightPxUnlocked
        let takeOld = min(max(0, workBottom - seamY), max(0, maxHeightPx - canvas.bodyHeightPx - (h - seamY)))
        if takeOld > 0 { canvas.appendBodyStrip(from: oldAnchor.image, y: seamY, height: takeOld, width: w) }
        let takeNew = min(max(0, seamY - lockedTopFixed), max(0, maxHeightPx - canvas.bodyHeightPx - (h - seamY)))
        if takeNew > 0 { canvas.appendBodyStrip(from: resyncBase.image, y: lockedTopFixed, height: takeNew, width: w) }
        let takeDy = min(dy, max(0, maxHeightPx - canvas.bodyHeightPx - (h - seamY)))
        if takeDy > 0 { commitInteriorDelta(anchorImage: resyncBase.image, currFrame: currFrame, dy: takeDy, currentMatchTop: lockedTopFixed) }
        if let det = currDigest.detachedCopy() { anchorDigest = det }
        canvas.updateLiveTail(from: currFrame, topY: seamY, width: w, frameHeight: h)
        let added = max(0, totalHeightPxUnlocked - beforeTotal)
        return totalHeightPxUnlocked >= maxHeightPx ? .reachedHeightLimit : .appended(addedPx: added, totalHeightPx: totalHeightPxUnlocked)
    }

    private func pushUndoSnapshot(baseIsInitial: Bool) {
        if undoStack.count >= 12 { undoStack.removeFirst() }
        let tail = baseIsInitial ? nil : anchorDigest.flatMap {
            ScrollStripCanvas.detachCopy($0.image, rect: CGRect(x: 0, y: seamY, width: widthPx, height: frameHeightPx - seamY))
        }
        undoStack.append(ScrollUndoSnapshot(
            stripCount: baseIsInitial ? 0 : canvas.strips.count, bodyHeightPx: baseIsInitial ? 0 : canvas.bodyHeightPx,
            seamY: baseIsInitial ? 0 : seamY, lockedTopFixed: baseIsInitial ? 0 : lockedTopFixed,
            lockedBottomFixed: baseIsInitial ? 0 : lockedBottomFixed, anchorDigest: anchorDigest,
            liveTailStrip: tail, previewTailStrip: tail.map { ScrollStripCanvas.makePreviewSlice($0) }
        ))
    }

    public func renderFinalImage() -> CGImage? { renderImage(previewMaxSide: nil) }
    public func renderPreviewImage(maxSidePx: Int = 680) -> CGImage? { renderImage(previewMaxSide: maxSidePx) }

    private func renderImage(previewMaxSide: Int?) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        let composed: CGImage?
        if canvas.isEmpty { composed = firstFrame }
        else if let maxSide = previewMaxSide { composed = canvas.composeTailPreview(widthPx: widthPx, maxSidePx: maxSide) }
        else { composed = canvas.compose(widthPx: widthPx, scaleDownToMaxSide: nil, usePreviewSlices: false) }
        guard let img = composed else { return nil }
        return axis == .horizontal ? ImageTransform.rotateCounterClockwise90(img) : img
    }
}
