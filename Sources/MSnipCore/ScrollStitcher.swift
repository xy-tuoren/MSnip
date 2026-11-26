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

// MARK: - 滚动重叠区二次精度校验器

/// 滚动长截图位移搜索与 2D 纹理像素精确验证引擎（抗暗色模式纯背景误配、重复表格干扰及局部悬浮按钮干扰）
enum ScrollOverlapVerifier {
    struct MatchResult {
        let dy: Int
        let margins: (matchTop: Int, matchBottom: Int, stickyTop: Int, stickyBottom: Int)
    }

    static func matchDisplacement(
        anchor: ScrollFrameDigest,
        curr: ScrollFrameDigest,
        width w: Int,
        height h: Int,
        lockedTop: Int,
        lockedBottom: Int
    ) -> MatchResult? {
        let margins = ScrollFrameDigest.detectStaticMargins(a: anchor.rows, b: curr.rows, height: h)
        let workTop = min(h * 32 / 100, max(lockedTop, margins.matchTop))
        let workBottom = h - min(h * 32 / 100, max(lockedBottom, margins.matchBottom))
        let workH = workBottom - workTop
        guard workH >= 32 else { return nil }

        let minOverlap = max(20, workH * 12 / 100)
        let maxForwardDy = workH - minOverlap
        let minBackwardDy = -min(workH / 2, 260)
        guard maxForwardDy >= 2 else { return nil }

        let activeBands = ScrollFrameDigest.detectActiveBands(
            a: anchor.rows, b: curr.rows, workTop: workTop, workBottom: workBottom
        )

        func score1D(at dy: Int, rowStep: Int) -> Double {
            let ovS = max(workTop, workTop - dy), ovE = min(workBottom, workBottom - dy)
            if ovE - ovS < minOverlap { return .greatestFiniteMagnitude }
            var wDiff = 0.0, wSum = 0.0, textured = 0, cy = ovS
            while cy < ovE {
                let ra = anchor.rows[cy + dy], rc = curr.rows[cy]
                let d = Double(ra.maskedDiff(to: rc, activeMask: activeBands.mask, activeCount: activeBands.count))
                let isTex = ra.grad >= 3 || rc.grad >= 3
                let wgt = isTex ? 4.0 : 0.18
                if isTex { textured += 1 }
                wDiff += d * wgt
                wSum += wgt
                cy += rowStep
            }
            guard wSum > 0 else { return .greatestFiniteMagnitude }
            var m = (wDiff / wSum) * (1.0 + Double(abs(dy)) / Double(workH * 10))
            if textured < 3 { m += 4.5 }
            return m
        }

        // 粗扫保留前 5 个候选波谷，避免重复表格分隔线干扰主峰
        var topCands: [(dy: Int, sc: Double)] = []
        var cDy = minBackwardDy
        while cDy <= maxForwardDy {
            let sc = score1D(at: cDy, rowStep: 2)
            if sc < .greatestFiniteMagnitude {
                if topCands.count < 5 {
                    topCands.append((cDy, sc)); topCands.sort { $0.sc < $1.sc }
                } else if sc < topCands[4].sc {
                    topCands[4] = (cDy, sc); topCands.sort { $0.sc < $1.sc }
                }
            }
            cDy += 2
        }

        // 围绕候选峰进行逐像素 1D 精扫，保留前 2 个独立峰交由 2D 纹理验证最终裁决
        var fineCands: [(dy: Int, sc: Double)] = []
        for cand in topCands {
            var localBestDy = cand.dy, localBestSc = Double.greatestFiniteMagnitude
            for dy in max(minBackwardDy, cand.dy - 3)...min(maxForwardDy, cand.dy + 3) {
                let sc = score1D(at: dy, rowStep: 1)
                if sc < localBestSc { localBestSc = sc; localBestDy = dy }
            }
            if localBestSc <= 20.0 && !fineCands.contains(where: { abs($0.dy - localBestDy) <= 2 }) {
                fineCands.append((localBestDy, localBestSc))
            }
        }
        fineCands.sort { $0.sc < $1.sc }
        guard !fineCands.isEmpty else { return nil }

        // 2D 纹理像素精校：用 ±1px 亚像素容差做准入核验，再用无模糊精确误差 exactErr（辅以全行 1D 分数破平）锁定 0px 峰值
        var verifiedDy: Int?
        var verifiedExact = Double.greatestFiniteMagnitude
        var verified1D = Double.greatestFiniteMagnitude
        for cand in fineCands.prefix(3) {
            let lo = max(minBackwardDy, cand.dy - 1)
            let hi = min(maxForwardDy, cand.dy + 1)
            for dy in lo...hi {
                if let exactErr = verify2DTextured(
                    anchor: anchor, curr: curr, width: w, height: h,
                    workTop: workTop, workBottom: workBottom, dy: dy, activeMask: activeBands.mask
                ) {
                    let s1d = score1D(at: dy, rowStep: 1)
                    let isBetter = exactErr + 0.05 < verifiedExact
                        || (abs(exactErr - verifiedExact) <= 0.05 && s1d < verified1D)
                    if isBetter {
                        verifiedExact = exactErr
                        verified1D = s1d
                        verifiedDy = dy
                    }
                }
            }
        }
        guard let bestDy = verifiedDy else { return nil }
        return MatchResult(dy: bestDy, margins: margins)
    }

    /// 严格逐行校验上洁净区 `[workTop ..< seamY]` 是否纹丝不动、且仅下尾段发生局部渐隐变化：
    /// - 只要上区存在任何纹理行移动（即便是极稀疏页面上仅 2 行文字微滚 4px），立即返回 false，绝不误吞滚动；
    /// - 仅当上区静止且下区有局部变化（如 ChatGPT `↓` 按钮或系统滚动条淡出）时返回 true。
    static func isSettledTailRefresh(
        a: ScrollFrameDigest,
        b: ScrollFrameDigest,
        workTop: Int,
        seamY: Int,
        height: Int
    ) -> Bool {
        guard seamY - workTop >= 16, height > seamY else { return false }
        var upperChanged = 0
        for y in workTop..<seamY {
            let d = a.rows[y].fullDiff(to: b.rows[y])
            if d > 3 {
                upperChanged += 1
                if a.rows[y].grad >= 3 || b.rows[y].grad >= 3 || upperChanged > 1 { return false }
            }
        }
        let tailSpan = height - seamY
        var lowerChanged = 0
        for y in seamY..<height where a.rows[y].fullDiff(to: b.rows[y]) > 3 {
            lowerChanged += 1
        }
        return lowerChanged > 0 && lowerChanged * 100 <= tailSpan * 48
    }

    /// 二维纹理像素鲁棒验证（零堆分配直方图 85% 截断均值）：
    /// - 重点考核具备局部边缘/对比度的纹理像素，杜绝暗色模式 88% 纯黑底稀释误差导致的错行误配；
    /// - 截断最差 15% 离群点，天然吸收 ChatGPT 悬浮 `↓` 按钮、闪烁光标或动图引起的局部差异。
    private static func verify2DTextured(
        anchor: ScrollFrameDigest,
        curr: ScrollFrameDigest,
        width: Int,
        height: Int,
        workTop: Int,
        workBottom: Int,
        dy: Int,
        activeMask: UInt16
    ) -> Double? {
        let startY = max(workTop, workTop - dy)
        let endY = min(workBottom, workBottom - dy)
        guard endY - startY >= 16 else { return nil }

        let rightMargin = min(max(10, width / 18), 42)
        let x0 = min(4, width / 16)
        let span = max(16, max(x0 + 16, width - rightMargin) - x0)

        var xs: [Int] = []
        xs.reserveCapacity(32)
        for b in 0..<16 where (activeMask & (1 << b)) != 0 {
            let cx = min(width - 2, x0 + (span * (b * 2 + 1)) / 32)
            xs.append(cx)
            if activeMask.nonzeroBitCount <= 8 {
                xs.append(min(width - 2, cx + max(2, span / 48)))
            }
        }
        if xs.isEmpty { xs = [width * 30 / 100, width * 50 / 100, width * 70 / 100] }

        // 优先采样真实包含文字/边缘的纹理行（绝不被固定步长跳过 5px 细字行），不足时再用均匀网格补足
        var sampleYs: [Int] = []
        sampleYs.reserveCapacity(52)
        var texRows: [Int] = []
        for y in startY..<endY where curr.rows[y].grad >= 2 || anchor.rows[y + dy].grad >= 2 {
            texRows.append(y)
        }
        if !texRows.isEmpty {
            let tStep = max(1, texRows.count / 44)
            var idx = 0
            while idx < texRows.count { sampleYs.append(texRows[idx]); idx += tStep }
        }
        if sampleYs.count < 24 {
            let stepY = max(1, (endY - startY) / 32)
            var y = startY
            while y < endY { sampleYs.append(y); y += stepY }
        }

        var texHist = [Int](repeating: 0, count: 256)
        var exactTexHist = [Int](repeating: 0, count: 256)
        var allHist = [Int](repeating: 0, count: 256)
        var exactAllSum = 0
        var texTotal = 0, texAgreed = 0, allTotal = 0

        let dxProbe = max(1, min(3, span / 64))
        for cy in sampleYs {
            let ay = cy + dy
            let ayPrev = max(0, ay - 1)
            let ayNext = min(height - 1, ay + 1)
            for x in xs {
                let pc = curr.sampler.sampleRGB(px: x, py: cy)
                let p0 = anchor.sampler.sampleRGB(px: x, py: ay)
                let e0 = abs(p0.0 - pc.0) + abs(p0.1 - pc.1) + abs(p0.2 - pc.2)

                let err3: Int
                if e0 <= 9 {
                    err3 = e0
                } else {
                    let pPrev = anchor.sampler.sampleRGB(px: x, py: ayPrev)
                    let pNext = anchor.sampler.sampleRGB(px: x, py: ayNext)
                    let ePrev = abs(pPrev.0 - pc.0) + abs(pPrev.1 - pc.1) + abs(pPrev.2 - pc.2) + 3
                    let eNext = abs(pNext.0 - pc.0) + abs(pNext.1 - pc.1) + abs(pNext.2 - pc.2) + 3
                    let eMid = abs(((p0.0 + pNext.0) >> 1) - pc.0)
                        + abs(((p0.1 + pNext.1) >> 1) - pc.1)
                        + abs(((p0.2 + pNext.2) >> 1) - pc.2) + 2
                    err3 = min(min(e0, eMid), min(ePrev, eNext))
                }
                let perCh = min(255, err3 / 3)
                let exactCh = min(255, e0 / 3)
                allHist[perCh] += 1
                exactAllSum += exactCh
                allTotal += 1

                let pcR = curr.sampler.sampleRGB(px: min(width - 1, x + dxProbe), py: cy)
                let p0R = anchor.sampler.sampleRGB(px: min(width - 1, x + dxProbe), py: ay)
                let cGrad = abs(pc.0 - pcR.0) + abs(pc.1 - pcR.1) + abs(pc.2 - pcR.2)
                let aGrad = abs(p0.0 - p0R.0) + abs(p0.1 - p0R.1) + abs(p0.2 - p0R.2)
                let p0D = anchor.sampler.sampleRGB(px: x, py: ayNext)
                let vGrad = abs(p0.0 - p0D.0) + abs(p0.1 - p0D.1) + abs(p0.2 - p0D.2)
                if cGrad >= 24 || aGrad >= 24 || vGrad >= 24 {
                    texHist[perCh] += 1
                    exactTexHist[exactCh] += 1
                    texTotal += 1
                    if perCh <= 22 { texAgreed += 1 }
                }
            }
        }
        guard allTotal > 0 else { return nil }

        func trimmedMean(_ hist: [Int], total: Int, keepPercent: Int) -> Double {
            let keep = max(1, total * keepPercent / 100)
            var rem = keep, acc = 0
            for v in 0..<256 where hist[v] > 0 {
                let take = min(rem, hist[v])
                acc += take * v
                rem -= take
                if rem == 0 { break }
            }
            return Double(acc) / Double(keep)
        }

        let allTrim = trimmedMean(allHist, total: allTotal, keepPercent: 85)
        if texTotal >= 20 {
            let texTrim = trimmedMean(texHist, total: texTotal, keepPercent: 85)
            let agreeRatio = Double(texAgreed) / Double(texTotal)
            guard texTrim <= 18.0 && agreeRatio >= 0.66 && allTrim <= 16.0 else { return nil }
            return trimmedMean(exactTexHist, total: texTotal, keepPercent: 95)
        }
        guard allTrim <= 12.0 else { return nil }
        return Double(exactAllSum) / Double(allTotal)
    }
}
