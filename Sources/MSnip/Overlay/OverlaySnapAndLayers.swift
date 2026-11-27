import AppKit
import CoreGraphics
import Foundation
import MSnipCore
import QuartzCore

/// 覆盖层的 PixPin 级零延迟矩阵吸附、最新优先后台合并探测与干脆 VSync 过渡扩展
extension OverlayView {
    func refreshAutoSnapAtCurrentMouse() {
        guard let win = window else { return }
        let winPt = win.convertPoint(fromScreen: NSEvent.mouseLocation)
        let localPt = convert(winPt, from: nil)
        if bounds.contains(localPt) {
            updateAutoSnap(at: localPt, immediate: true)
        }
    }

    /// 0ms 瞬时响应光标移动：
    /// 1. 先查 0.005ms 内存快表（程序坞/菜单栏/已缓存控件/窗口边界）立即出框，绝不因防抖而冻住；
    /// 2. 未命中的新位置立即推入 0ms 最新优先后台队列（Latest-Wins），拿到真实 AX/视觉框后干脆落位。
    func updateAutoSnap(at localPoint: CGPoint, previousPoint: CGPoint? = nil, immediate: Bool = false, fastWindowOnly: Bool? = nil) {
        guard selection == nil else { return }

        // 光标离开滚轮切层锚点 > 14pt 时自动重置回最内层目标，做到指哪吸哪、绝不粘滞
        if let anchor = autoSnap.tierAnchorPoint, hypot(localPoint.x - anchor.x, localPoint.y - anchor.y) > 14.0 {
            autoSnap.tierAnchorPoint = nil
            autoSnap.manualTierOffset = 0
        }

        let now = ProcessInfo.processInfo.systemUptime
        let dist = previousPoint.map { hypot(localPoint.x - $0.x, localPoint.y - $0.y) } ?? 0
        if previousPoint != nil && !immediate {
            let dtMove = max(0.004, min(0.12, now - autoSnap.lastMoveUptime))
            let instSpeed = dist / CGFloat(dtMove)
            autoSnap.smoothedSpeed = (dtMove > 0.08) ? instSpeed : (autoSnap.smoothedSpeed * 0.65 + instSpeed * 0.35)
        } else {
            autoSnap.smoothedSpeed = 0
        }
        autoSnap.lastMoveUptime = now

        // 高速扫屏移动时保持整窗级稳定，不频繁乱跳路过的小控件；减速/停稳后 55ms 精准细化到目标卡片或按钮
        let isFastSweep = !immediate && (fastWindowOnly != true) && (autoSnap.smoothedSpeed > 950.0)
        let effectiveWindowOnly = (fastWindowOnly == true) || isFastSweep
        let fast = regionDetector.fastMemoryHierarchy(at: localPoint, in: snapshot, windowOnly: effectiveWindowOnly)
        let crossedWindow: Bool = {
            switch (autoSnap.activeWindowRect, fast.winRect) {
            case (nil, nil): return false
            case (let a?, let b?): return !Self.isSameRegion(a, b, tol: 8)
            default: return true
            }
        }()
        let leftCurrentTarget: Bool = {
            guard let cur = hoveredAutoRect else { return true }
            return !cur.contains(localPoint)
        }()

        // 命中预索引系统栏、命中已校验空间缓存（含全屏/最大化窗口内单卡片命中）、首次上屏、跨入新窗口、高速扫屏或光标离开当前旧框 -> 0ms 立即更新，杜绝旧框粘滞不跟手！
        let hasFineCacheHit = !effectiveWindowOnly && fast.hasFineHit
        if fast.isComplete || hasFineCacheHit || effectiveWindowOnly || autoSnap.displayedRect == nil || crossedWindow || leftCurrentTarget {
            autoSnap.activeWindowRect = fast.winRect
            if isFastSweep || crossedWindow {
                autoSnap.appliedSeq = autoSnap.querySeq
            }
            applyDetectedSnapStack(fast.stack, immediate: immediate || autoSnap.displayedRect == nil)
        }
        if fast.isComplete || fastWindowOnly == true {
            autoSnap.settleTimer?.invalidate(); autoSnap.settleTimer = nil
            return
        }
        if isFastSweep {
            autoSnap.settleTimer?.invalidate(); autoSnap.settleTimer = nil
            scheduleTrailingSnapSettle(after: 0.055)
            return
        }

        let minInterval: TimeInterval = (dist > 14.0) ? 0.038 : 0.020
        let elapsed = now - autoSnap.lastQueryDispatchUptime
        if immediate || elapsed >= minInterval {
            dispatchRefinedSnapQuery(at: localPoint, immediate: immediate)
        } else {
            scheduleTrailingSnapSettle(after: max(0.016, minInterval - elapsed))
        }
    }

    private func dispatchRefinedSnapQuery(at localPoint: CGPoint, immediate: Bool) {
        autoSnap.settleTimer?.invalidate(); autoSnap.settleTimer = nil
        autoSnap.lastQueryDispatchUptime = ProcessInfo.processInfo.systemUptime
        autoSnap.querySeq &+= 1
        let seq = autoSnap.querySeq
        let token = autoSnap.cancelToken
        regionDetector.requestLatestHierarchy(at: localPoint, in: snapshot) { [weak self] refined, winRect in
            guard let self, self.selection == nil,
                  self.autoSnap.cancelToken == token,
                  seq > self.autoSnap.appliedSeq else { return }
            // 若异步查询期间光标已大幅移走且返回的首选目标不再包含当前光标，直接丢弃过期结果，绝不把高亮框拉回旧位置
            if let livePt = self.lastMousePoint {
                let movedFar = hypot(livePt.x - localPoint.x, livePt.y - localPoint.y) > 18.0
                if movedFar && !(refined.first?.contains(livePt) ?? false) { return }
            }
            self.autoSnap.appliedSeq = seq
            self.autoSnap.activeWindowRect = winRect
            self.applyDetectedSnapStack(refined, immediate: immediate && self.autoSnap.displayedRect == nil)
        }
    }

    private func scheduleTrailingSnapSettle(after delay: TimeInterval) {
        guard autoSnap.settleTimer == nil else { return }
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.autoSnap.settleTimer = nil
                self.autoSnap.smoothedSpeed = 0
                guard self.selection == nil, let pt = self.lastMousePoint, self.bounds.contains(pt) else { return }
                self.dispatchRefinedSnapQuery(at: pt, immediate: false)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        autoSnap.settleTimer = t
    }

    private func applyDetectedSnapStack(_ newStack: [CGRect], immediate: Bool) {
        guard !newStack.isEmpty else { return }
        let prevTarget = hoveredAutoRect
        let chosenIndex = min(max(0, autoSnap.manualTierOffset), newStack.count - 1)
        autoSnap.stack = newStack
        autoSnap.index = chosenIndex
        autoSnap.scrollAccumulator = 0

        guard let target = hoveredAutoRect else { return }
        if immediate || autoSnap.displayedRect == nil {
            let prevDisplayed = autoSnap.displayedRect
            stopSnapGlide(cancelPendingQuery: false)
            autoSnap.displayedRect = target
            invalidateAutoSnapTransition(from: prevDisplayed, to: target)
        } else if prevTarget != target {
            startSnapGlideToTarget()
        } else {
            invalidateAutoSnapTransition(from: autoSnap.displayedRect, to: target)
        }
    }

    func stepAutoSnapTier(by step: Int) {
        guard autoSnap.stack.count > 1 else { return }
        let nextIdx = min(max(0, autoSnap.index + step), autoSnap.stack.count - 1)
        guard nextIdx != autoSnap.index else { return }
        autoSnap.index = nextIdx
        autoSnap.manualTierOffset = nextIdx
        autoSnap.tierAnchorPoint = lastMousePoint
        if let target = hoveredAutoRect {
            startSnapGlideToTarget()
            invalidateAutoSnapTransition(from: autoSnap.displayedRect, to: target)
        }
    }

    /// 启动统一 VSync 驱动循环（macOS 14+ 锁定屏幕最高刷新率 `CADisplayLink`，每帧直读实时硬件指针 `NSEvent.mouseLocation`，消除非激活面板事件队列拖尾）
    func startOverlayVSync() {
        guard autoSnap.vsyncLink == nil, autoSnap.vsyncTimer == nil else { return }
        if #available(macOS 14.0, *) {
            let link = self.displayLink(target: self, selector: #selector(onOverlayVSyncTick(_:)))
            let maxFPS = Float(max(60, snapshot.screen.maximumFramesPerSecond))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: maxFPS, maximum: maxFPS, preferred: maxFPS)
            link.add(to: .main, forMode: .common)
            autoSnap.vsyncLink = link
            return
        }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepOverlayVSync(dt: 1.0 / 60.0) }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoSnap.vsyncTimer = timer
    }

    func stopOverlayVSync() {
        stopSnapGlide(cancelPendingQuery: true)
        autoSnap.vsyncTimer?.invalidate(); autoSnap.vsyncTimer = nil
        if #available(macOS 14.0, *), let dl = autoSnap.vsyncLink as? CADisplayLink {
            dl.invalidate()
        }
        autoSnap.vsyncLink = nil
        autoSnap.lastPolledScreenPoint = nil
    }

    var isOverlayVSyncActive: Bool { autoSnap.vsyncLink != nil || autoSnap.vsyncTimer != nil }

    func stopSnapGlide(cancelPendingQuery: Bool = true) {
        if cancelPendingQuery {
            autoSnap.cancelToken &+= 1
            autoSnap.settleTimer?.invalidate()
            autoSnap.settleTimer = nil
        }
        autoSnap.isGliding = false
    }

    func autoSnapHudText(for targetRect: CGRect) -> String {
        let pxW = Int((targetRect.width * snapshot.scaleFactor).rounded())
        let pxH = Int((targetRect.height * snapshot.scaleFactor).rounded())
        let prefix = isRecordingMode ? "录屏 · " : quickLaunchMode.hudPrefix
        let tierInfo: String
        if autoSnap.stack.count > 1 {
            let kind = semanticTierLabel(for: targetRect)
            tierInfo = "  ·  \(kind) \(autoSnap.index + 1)/\(autoSnap.stack.count) 滚轮切层"
        } else {
            let pxX = Int((targetRect.minX * snapshot.scaleFactor).rounded())
            let pxY = Int((targetRect.minY * snapshot.scaleFactor).rounded())
            tierInfo = "  (\(pxX),\(pxY))"
        }
        return "\(prefix)\(pxW) × \(pxH) px\(tierInfo)"
    }

    private func semanticTierLabel(for rect: CGRect) -> String {
        if Self.isSameRegion(rect, bounds, tol: 4) { return "全屏" }
        if let winRect = autoSnap.activeWindowRect, Self.isSameRegion(rect, winRect, tol: 6) { return "窗口" }
        if rect.width <= 160 && rect.height <= 72 { return "控件" }
        return "区域"
    }

    private func startSnapGlideToTarget() {
        guard let target = hoveredAutoRect else { return }
        if autoSnap.displayedRect == nil {
            autoSnap.displayedRect = target
            invalidateAutoSnapTransition(from: nil, to: target)
            return
        }
        autoSnap.isGliding = true
        if !isOverlayVSyncActive { startOverlayVSync() }
    }

    @available(macOS 14.0, *)
    @objc private func onOverlayVSyncTick(_ link: CADisplayLink) {
        let dt = min(0.05, max(0.004, link.duration))
        stepOverlayVSync(dt: dt)
    }

    private func stepOverlayVSync(dt: TimeInterval) {
        let screenPt = NSEvent.mouseLocation
        let sf = snapshot.screen.frame
        if sf.contains(screenPt) {
            let localPt = CGPoint(x: screenPt.x - sf.minX, y: sf.maxY - screenPt.y)
            if autoSnap.lastPolledScreenPoint != screenPt {
                autoSnap.lastPolledScreenPoint = screenPt
                if dragOp == nil && NSEvent.pressedMouseButtons == 0 {
                    processLiveHoverPoint(localPt)
                } else {
                    lastMousePoint = localPt
                    syncMagnifierView()
                }
            }
        } else if autoSnap.lastPolledScreenPoint != nil {
            autoSnap.lastPolledScreenPoint = nil
            clearAllChromeHover()
        }
        if autoSnap.isGliding {
            advanceSnapGlide(dt: dt)
        }
    }

    private func advanceSnapGlide(dt: TimeInterval) {
        guard selection == nil, let target = hoveredAutoRect, var cur = autoSnap.displayedRect else {
            stopSnapGlide(cancelPendingQuery: false)
            return
        }
        let prevDisplayed = cur
        // 干脆利落的 35ms 高速阻尼（对标 PixPin 即指即吸手感，不拖泥带水）
        let k = CGFloat(1.0 - pow(1e-12, dt))
        cur.origin.x += (target.origin.x - cur.origin.x) * k
        cur.origin.y += (target.origin.y - cur.origin.y) * k
        cur.size.width += (target.size.width - cur.size.width) * k
        cur.size.height += (target.size.height - cur.size.height) * k

        let maxErr = max(
            max(abs(target.origin.x - cur.origin.x), abs(target.origin.y - cur.origin.y)),
            max(abs(target.size.width - cur.size.width), abs(target.size.height - cur.size.height))
        )
        if maxErr < 1.0 {
            autoSnap.displayedRect = target
            stopSnapGlide(cancelPendingQuery: false)
        } else {
            autoSnap.displayedRect = cur
        }
        invalidateAutoSnapTransition(from: prevDisplayed, to: autoSnap.displayedRect)
    }

    private static func isSameRegion(_ a: CGRect, _ b: CGRect, tol: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tol &&
        abs(a.minY - b.minY) <= tol &&
        abs(a.maxX - b.maxX) <= tol &&
        abs(a.maxY - b.maxY) <= tol
    }
}

// MARK: - GPU 图层合成与选区遮罩更新

/// 覆盖层光标形态去重枚举（杜绝 `mouseMoved` 每次触发都发起同步 WindowServer `NSCursor.set()` IPC）
enum OverlayCursorKind: Equatable {
    case crosshair
    case arrow
    case openHand

    func apply() {
        switch self {
        case .crosshair: NSCursor.crosshair.set()
        case .arrow:     NSCursor.arrow.set()
        case .openHand:  NSCursor.openHand.set()
        }
    }
}

/// 纯 GPU 硬件合成的四边暗化遮罩 + 自动吸附高亮框（零 CPU 全屏位图重绘、零 GPU 纹理上传）
final class OverlayDimAndSnapView: NSView {
    private let dimTop = CALayer()
    private let dimBottom = CALayer()
    private let dimLeft = CALayer()
    private let dimRight = CALayer()
    private let snapBorder = CALayer()

    private static let dimColor = NSColor.black.withAlphaComponent(0.46).cgColor

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        guard let root = layer else { return }
        root.isGeometryFlipped = true
        for l in [dimTop, dimBottom, dimLeft, dimRight] {
            l.backgroundColor = Self.dimColor
            l.isOpaque = false
            root.addSublayer(l)
        }
        snapBorder.backgroundColor = nil
        snapBorder.borderWidth = 2.0
        snapBorder.isHidden = true
        root.addSublayer(snapBorder)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(highlightRect: CGRect?, showDim: Bool, showSnapBorder: Bool, borderColor: CGColor) {
        let w = bounds.width, h = bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if !showDim {
            dimTop.isHidden = true; dimBottom.isHidden = true
            dimLeft.isHidden = true; dimRight.isHidden = true
        } else if let raw = highlightRect, raw.width > 0, raw.height > 0 {
            let hl = raw.intersection(bounds)
            if hl.isNull || hl.width <= 0 || hl.height <= 0 {
                dimTop.isHidden = false; dimTop.frame = bounds
                dimBottom.isHidden = true; dimLeft.isHidden = true; dimRight.isHidden = true
            } else {
                let topH = max(0, hl.minY), botH = max(0, h - hl.maxY)
                let leftW = max(0, hl.minX), rightW = max(0, w - hl.maxX)
                dimTop.isHidden = topH <= 0; dimTop.frame = CGRect(x: 0, y: 0, width: w, height: topH)
                dimBottom.isHidden = botH <= 0; dimBottom.frame = CGRect(x: 0, y: hl.maxY, width: w, height: botH)
                dimLeft.isHidden = leftW <= 0; dimLeft.frame = CGRect(x: 0, y: hl.minY, width: leftW, height: hl.height)
                dimRight.isHidden = rightW <= 0; dimRight.frame = CGRect(x: hl.maxX, y: hl.minY, width: rightW, height: hl.height)
            }
        } else {
            dimTop.isHidden = false; dimTop.frame = bounds
            dimBottom.isHidden = true; dimLeft.isHidden = true; dimRight.isHidden = true
        }

        if showSnapBorder, let raw = highlightRect, raw.width > 0, raw.height > 0 {
            snapBorder.isHidden = false
            snapBorder.borderColor = borderColor
            snapBorder.frame = raw.insetBy(dx: -0.5, dy: -0.5)
        } else {
            snapBorder.isHidden = true
        }
    }
}

/// 独立缓存的尺寸/状态胶囊视图（带静态 `shadowPath`，过渡滑行期间仅 GPU 移动坐标，零文本重绘）
final class OverlayHudPillView: NSView {
    private static let textAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12.0, weight: .semibold),
        .foregroundColor: MSnipUITheme.inkPrimary
    ]

    private var currentText: String = ""
    private var textSize: CGSize = .zero

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(text: String?, anchorRect: CGRect?, containerBounds: CGRect) {
        guard let text, !text.isEmpty, let anchor = anchorRect else {
            if !isHidden { isHidden = true }
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let textChanged = (text != currentText)
        if textChanged {
            currentText = text
            textSize = (text as NSString).size(withAttributes: Self.textAttrs)
            let w = ceil(textSize.width + 16), h: CGFloat = 24
            if frame.size != NSSize(width: w, height: h) {
                setFrameSize(NSSize(width: w, height: h))
                layer?.shadowPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: 6, cornerHeight: 6, transform: nil)
            }
            needsDisplay = true
        }
        let w = frame.width, h = frame.height
        let bx = round(min(max(8, anchor.minX), containerBounds.width - w - 8))
        let by = round(anchor.minY >= (h + 10) ? (anchor.minY - h - 7) : (anchor.minY + 7))
        let origin = NSPoint(x: bx, y: by)
        if frame.origin != origin { setFrameOrigin(origin) }
        if isHidden { isHidden = false }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !currentText.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let pill = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 6.0, cornerHeight: 6.0, transform: nil)
        ctx.setFillColor(MSnipUITheme.cardBg.cgColor)
        ctx.addPath(pill); ctx.fillPath()
        ctx.setStrokeColor(MSnipUITheme.borderStrong.cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(pill); ctx.strokePath()
        (currentText as NSString).draw(
            at: CGPoint(x: round(8), y: round((bounds.height - textSize.height) * 0.5)),
            withAttributes: Self.textAttrs
        )
    }
}

/// 独立 GPU 缓存的快捷键提示卡（内容仅在模式切换时绘制一次，避让移动零 `blur: 22` 重绘）
final class OverlayShortcutTipsView: NSView {
    private static let headerTitleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12.0, weight: .bold),
        .foregroundColor: MSnipUITheme.accent
    ]
    private static let headerHintAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11.0, weight: .medium),
        .foregroundColor: MSnipUITheme.inkMuted
    ]
    private static let keycapKeyAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12.5, weight: .bold),
        .foregroundColor: MSnipUITheme.inkPrimary
    ]
    private static let keycapDescAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13.5, weight: .medium),
        .foregroundColor: MSnipUITheme.inkPrimary
    ]
    private static var textSizeCache: [String: CGSize] = [:]

    private var rows: [(key: String, desc: String)] = []
    private var hideKey: String = "H"
    private var maxKeyCapW: CGFloat = 0
    private var contentSignature: String = ""

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -8)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func cachedSize(_ str: String, isKey: Bool) -> CGSize {
        let token = isKey ? "K:\(str)" : "D:\(str)"
        if let hit = textSizeCache[token] { return hit }
        let sz = (str as NSString).size(withAttributes: isKey ? keycapKeyAttrs : keycapDescAttrs)
        textSizeCache[token] = sz
        return sz
    }

    func updateContentIfNeeded(signature: String, rows: () -> [(key: String, desc: String)], hideKey: String) -> CGSize {
        if signature == contentSignature, frame.width > 10, frame.height > 10 { return frame.size }
        self.contentSignature = signature
        self.rows = rows()
        self.hideKey = hideKey
        var maxCap: CGFloat = 0, maxDesc: CGFloat = 0
        for row in self.rows {
            maxCap = max(maxCap, max(26, ceil(Self.cachedSize(row.key, isKey: true).width + 16)))
            maxDesc = max(maxDesc, ceil(Self.cachedSize(row.desc, isKey: false).width))
        }
        self.maxKeyCapW = maxCap
        let sz = CGSize(width: max(224, ceil(36 + maxCap + 14 + maxDesc)), height: ceil(40 + CGFloat(self.rows.count) * 32 - 6 + 15))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setFrameSize(sz)
        layer?.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: sz), cornerWidth: 12, cornerHeight: 12, transform: nil)
        CATransaction.commit()
        needsDisplay = true
        return sz
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !rows.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds
        let path = CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 12, cornerHeight: 12, transform: nil)
        ctx.setFillColor(MSnipUITheme.cardBg.cgColor)
        ctx.addPath(path); ctx.fillPath()
        ctx.setStrokeColor(MSnipUITheme.borderStrong.cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(path); ctx.strokePath()

        let padX: CGFloat = 18
        ("快捷键操作" as NSString).draw(at: CGPoint(x: padX, y: 9), withAttributes: Self.headerTitleAttrs)
        let hideHint = "按 \(hideKey) 隐藏" as NSString
        let hideSz = hideHint.size(withAttributes: Self.headerHintAttrs)
        hideHint.draw(at: CGPoint(x: round(rect.width - padX - hideSz.width), y: 9), withAttributes: Self.headerHintAttrs)
        ctx.setFillColor(MSnipUITheme.borderHairline.cgColor)
        ctx.fill(CGRect(x: padX, y: 31, width: rect.width - padX * 2, height: 1))

        let keySpineRightX = round(padX + maxKeyCapW), descLeftX = round(keySpineRightX + 14)
        for (idx, row) in rows.enumerated() {
            let rowTopY = round(41 + CGFloat(idx) * 32)
            let kSz = Self.cachedSize(row.key, isKey: true), dSz = Self.cachedSize(row.desc, isKey: false)
            let capW = max(26, ceil(kSz.width + 16))
            let capRect = CGRect(x: keySpineRightX - capW, y: rowTopY, width: capW, height: 24)
            let capPath = CGPath(roundedRect: capRect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 5.5, cornerHeight: 5.5, transform: nil)
            ctx.setFillColor(MSnipUITheme.subtleFill.cgColor)
            ctx.addPath(capPath); ctx.fillPath()
            ctx.setStrokeColor(MSnipUITheme.borderStrong.cgColor)
            ctx.setLineWidth(1.0)
            ctx.addPath(capPath); ctx.strokePath()
            (row.key as NSString).draw(at: CGPoint(x: round(capRect.minX + (capW - kSz.width) * 0.5), y: round(capRect.minY + (24 - kSz.height) * 0.5)), withAttributes: Self.keycapKeyAttrs)
            (row.desc as NSString).draw(at: CGPoint(x: descLeftX, y: round(rowTopY + (24 - dSz.height) * 0.5)), withAttributes: Self.keycapDescAttrs)
        }
    }
}
