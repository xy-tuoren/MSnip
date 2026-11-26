import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 贴图悬浮状态事件驱动协调器：
/// - 弥补后台 `.accessory` 应用下 `NSTrackingArea` 在弹窗出生、右键菜单关闭、跨应用切焦点、
///   VisionKit 异步挂载与透明圆角边缘时的 `mouseEntered` 漏报问题；
/// - 零贴图或全部暂藏/穿透时自动注销全部事件监听（闲时 0% CPU）；有贴图时先做 O(N) 纯矩形预筛，
///   仅在光标真正靠近贴图或已有悬浮条可见时才调用 1 次 WindowServer 遮挡判定。
@MainActor
final class PinHoverCoordinator {
    var windowsProvider: (() -> [PinWindow])?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var menuCloseObserver: NSObjectProtocol?
    private var reconcileWorkItem: DispatchWorkItem?
    private var lastThrottledUptime: TimeInterval = 0

    func syncMonitors() {
        let hasEligible = (windowsProvider?() ?? []).contains { $0.isVisible && !$0.isClickThrough }
        if !hasEligible {
            stop()
            return
        }
        guard globalMonitor == nil, localMonitor == nil else { return }

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseUp, .rightMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] ev in
            let immediate = (ev.type != .mouseMoved)
            MainActor.assumeIsolated { self?.handlePointerEvent(immediate: immediate) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] ev in
            self?.handlePointerEvent(immediate: ev.type != .mouseMoved)
            return ev
        }
        menuCloseObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcileSoon(delay: 0.03) }
        }
    }

    func stop() {
        reconcileWorkItem?.cancel()
        reconcileWorkItem = nil
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let o = menuCloseObserver { NotificationCenter.default.removeObserver(o); menuCloseObserver = nil }
    }

    func reconcileSoon(delay: TimeInterval = 0.05) {
        reconcileWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.reconcileWorkItem = nil
                self?.reconcileNow()
            }
        }
        reconcileWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func reconcileNow() {
        let pins = windowsProvider?() ?? []
        guard !pins.isEmpty else { return }
        let mouse = NSEvent.mouseLocation

        // 快速预筛：若鼠标不在任何贴图/悬浮条热区且当前没有任何贴图处于悬停态，零 WindowServer 调用直接返回
        var needsWindowServerQuery = false
        for pin in pins {
            if pin.isMouseInPin || pin.isMouseInHoverBar || pin.hoverBarPanel.isVisible {
                needsWindowServerQuery = true
                break
            }
            guard pin.isHoverBarAllowed,
                  PinHoverGeometry.isPointInHoverZone(
                      point: mouse,
                      pinFrame: pin.interactiveHoverFrame,
                      barFrame: nil,
                      isBarVisible: false
                  ) else { continue }
            needsWindowServerQuery = true
            break
        }
        guard needsWindowServerQuery else { return }

        let topWin = NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0)
        var pinWindowNumbers = Set<Int>()
        pinWindowNumbers.reserveCapacity(pins.count * 2)
        for pin in pins where pin.isVisible {
            pinWindowNumbers.insert(pin.windowNumber)
            if pin.hoverBarPanel.isVisible { pinWindowNumbers.insert(pin.hoverBarPanel.windowNumber) }
        }

        for pin in pins {
            pin.reconcileHover(mouse: mouse, topWindowNumber: topWin, allPinWindowNumbers: pinWindowNumbers)
        }
    }

    private func handlePointerEvent(immediate: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if !immediate && (now - lastThrottledUptime) < 0.024 { return }
        lastThrottledUptime = now
        reconcileNow()
    }
}

/// 贴图窗口悬浮态自愈与真实光标复核扩展
extension PinWindow {
    var interactiveHoverFrame: NSRect {
        let r = PinGlowContainerView.outerResizeReach
        return imageScreenFrame.insetBy(dx: -r, dy: -r)
    }

    var isHoverBarAllowed: Bool {
        isVisible && isOnActiveSpace && !isClickThrough
            && editorCanvas == nil && cropOverlay == nil && !pinContentView.isAnnotating
    }

    func updatePinHover(_ inside: Bool) {
        if inside {
            guard isHoverBarAllowed else { return }
            let changed = !isMouseInPin
            isMouseInPin = true
            pinContentView.syncMouseInsideFlag(true)
            if changed { syncGlowState(); syncResizeChromeVisibility() }
            if changed || !hoverBarPanel.isVisible || !hoverBarPanel.isOnActiveSpace { syncHoverBarVisibility() }
            return
        }

        // 防止 VisionKit / 边角跟踪区重建导致鼠标仍在图内或外沿缩放带时发出伪 mouseExited
        let mouse = NSEvent.mouseLocation
        if isHoverBarAllowed,
           PinHoverGeometry.containsPointInclusive(interactiveHoverFrame, mouse),
           isPinUncovered(at: mouse, topWindowNumber: NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0)) {
            pinContentView.syncMouseInsideFlag(true)
            return
        }
        guard isMouseInPin else { return }
        isMouseInPin = false
        pinContentView.syncMouseInsideFlag(false)
        clearResizeHoverCursorIfNeeded()
        syncGlowState()
        syncHoverBarVisibility()
    }

    func updateHoverBarHover(_ inside: Bool) {
        guard isMouseInHoverBar != inside || (inside && (!hoverBarPanel.isVisible || !hoverBarPanel.isOnActiveSpace)) else { return }
        isMouseInHoverBar = inside
        syncGlowState()
        syncHoverBarVisibility()
    }

    func reconcileHoverFromCurrentMouse() {
        let mouse = NSEvent.mouseLocation
        let topWin = NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0)
        reconcileHover(mouse: mouse, topWindowNumber: topWin, allPinWindowNumbers: [])
    }

    func reconcileHover(mouse: NSPoint, topWindowNumber topWin: Int, allPinWindowNumbers: Set<Int>) {
        if isActivelyDraggingOrResizing { return }
        guard isHoverBarAllowed else {
            if isMouseInPin || isMouseInHoverBar || hoverBarPanel.isVisible {
                isMouseInPin = false
                isMouseInHoverBar = false
                pinContentView.syncMouseInsideFlag(false)
                clearResizeHoverCursorIfNeeded()
                syncGlowState()
                hoverBarPanel.hideCleanly()
            }
            return
        }

        let barVisible = hoverBarPanel.isVisible && hoverBarPanel.isOnActiveSpace
        let inBar = barVisible
            && PinHoverGeometry.containsPointInclusive(hoverBarPanel.frame, mouse)
            && isHoverBarUncovered(at: mouse, topWindowNumber: topWin)

        let inPinRect = PinHoverGeometry.containsPointInclusive(interactiveHoverFrame, mouse)
        let blockedByOtherPin = allPinWindowNumbers.contains(topWin)
            && topWin != windowNumber && topWin != hoverBarPanel.windowNumber
        let inPin = !inBar && inPinRect && !blockedByOtherPin && isPinUncovered(at: mouse, topWindowNumber: topWin)

        let inBridge = !inPin && !inBar && barVisible && !blockedByOtherPin
            && PinHoverGeometry.containsPointInclusive(
                PinHoverGeometry.bridgeCorridor(pinFrame: imageScreenFrame, barFrame: hoverBarPanel.frame),
                mouse
            )
            && isHoverBarUncovered(at: mouse, topWindowNumber: topWin)

        if inBar { hoverBarPanel.barView.reconcileHover(screenPoint: mouse) }

        let prevPin = isMouseInPin, prevBar = isMouseInHoverBar
        if inPin || inBar {
            isMouseInPin = inPin
            isMouseInHoverBar = inBar
            pinContentView.syncMouseInsideFlag(inPin)
            if inPin {
                _ = handleResizeHover(contentPoint: pinContentView.convert(convertPoint(fromScreen: mouse), from: nil))
            } else {
                clearResizeHoverCursorIfNeeded()
            }
            if prevPin != inPin || prevBar != inBar { syncGlowState(); syncResizeChromeVisibility() }
            if prevPin != inPin || prevBar != inBar || !barVisible { syncHoverBarVisibility() }
        } else if inBridge {
            // 正在跨过贴图与悬浮条之间的 5pt 间隙：保持悬浮条不闪退
            if prevPin || prevBar {
                isMouseInPin = false
                isMouseInHoverBar = false
                pinContentView.syncMouseInsideFlag(false)
                clearResizeHoverCursorIfNeeded()
                syncGlowState()
                syncHoverBarVisibility()
            }
        } else if prevPin || prevBar {
            isMouseInPin = false
            isMouseInHoverBar = false
            pinContentView.syncMouseInsideFlag(false)
            clearResizeHoverCursorIfNeeded()
            syncGlowState()
            syncHoverBarVisibility()
        } else if hoverBarPanel.isVisible && hideHoverWorkItem == nil {
            syncHoverBarVisibility()
        }
    }

    /// `hideHoverWorkItem` 真正隐藏前再次核验实时光标位置，杜绝在桥接区或贴图内被误隐藏
    func shouldKeepHoverBarAliveNow() -> Bool {
        guard isHoverBarAllowed else { return false }
        let mouse = NSEvent.mouseLocation
        let topWin = NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0)
        if PinHoverGeometry.containsPointInclusive(interactiveHoverFrame, mouse),
           isPinUncovered(at: mouse, topWindowNumber: topWin) {
            isMouseInPin = true
            pinContentView.syncMouseInsideFlag(true)
            syncGlowState()
            return true
        }
        if hoverBarPanel.isVisible,
           PinHoverGeometry.containsPointInclusive(hoverBarPanel.frame, mouse),
           isHoverBarUncovered(at: mouse, topWindowNumber: topWin) {
            isMouseInHoverBar = true
            syncGlowState()
            return true
        }
        if hoverBarPanel.isVisible,
           PinHoverGeometry.containsPointInclusive(
               PinHoverGeometry.bridgeCorridor(pinFrame: imageScreenFrame, barFrame: hoverBarPanel.frame),
               mouse
           ),
           isHoverBarUncovered(at: mouse, topWindowNumber: topWin) {
            syncHoverBarVisibility()
            return true
        }
        return false
    }

    func hideForToggle() {
        hideHoverWorkItem?.cancel()
        hideHoverWorkItem = nil
        isMouseInPin = false
        isMouseInHoverBar = false
        pinContentView.syncMouseInsideFlag(false)
        clearResizeHoverCursorIfNeeded()
        hoverBarPanel.hideCleanly()
        orderOut(nil)
    }

    private func isPinUncovered(at mouse: NSPoint, topWindowNumber topWin: Int) -> Bool {
        if topWin == windowNumber { return true }
        let belowPin = NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: windowNumber)
        return PinHoverGeometry.isWindowUncovered(
            pinWindowNumber: windowNumber,
            topWindowNumber: topWin,
            belowPinWindowNumber: belowPin
        )
    }

    private func isHoverBarUncovered(at mouse: NSPoint, topWindowNumber topWin: Int) -> Bool {
        let barNum = hoverBarPanel.windowNumber
        if topWin == barNum { return true }
        let belowBar = NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: barNum)
        return PinHoverGeometry.isWindowUncovered(
            pinWindowNumber: barNum,
            topWindowNumber: topWin,
            belowPinWindowNumber: belowBar
        )
    }
}

// MARK: - 贴图拖拽外投、Live Text 与悬停交互

/// 贴图画面纯净化容器（画面内部 100% 零悬浮按钮遮挡，直接支持原图划词复制与 `⌘+拖拽` 导出文件）
final class PinContentView: NSView, NSDraggingSource {
    let liveTextView = LiveTextImageView(scaling: .scaleAxesIndependently)
    var onHoverChanged: ((Bool) -> Void)?
    var onMouseMoved: ((NSPoint) -> Void)?
    var onVisualStateChanged: (() -> Void)?

    var isGhostMode: Bool = false { didSet { updateBorderStyle() } }
    var isAnnotating: Bool = false { didSet { updateBorderStyle() } }
    var isSelectedKey: Bool = false { didSet { updateBorderStyle() } }
    private var isMouseInside = false { didSet { updateBorderStyle() } }

    init(cgImage: CGImage, baseSize: NSSize, initialSize: NSSize? = nil) {
        super.init(frame: NSRect(origin: .zero, size: initialSize ?? baseSize))
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.masksToBounds = false
        layer?.borderWidth = 0

        liveTextView.frame = bounds
        liveTextView.autoresizingMask = [.width, .height]
        liveTextView.configure(cgImage: cgImage, logicalSize: baseSize)
        addSubview(liveTextView)
        updateTrackingAreas()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { isMouseInside = true; onHoverChanged?(true) }
    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt), !isMouseInside { isMouseInside = true; onHoverChanged?(true) }
        onMouseMoved?(pt)
    }
    override func mouseExited(with event: NSEvent) { isMouseInside = false; onHoverChanged?(false) }
    func syncMouseInsideFlag(_ inside: Bool) { if isMouseInside != inside { isMouseInside = inside } }

    private func updateBorderStyle() {
        layer?.borderWidth = 0
        layer?.borderColor = nil
        onVisualStateChanged?()
    }

    func startPNGFileDrag(with event: NSEvent, cgImage: CGImage, scaleFactor: CGFloat) {
        guard let fileURL = ClipboardAndSave.writeTempPNGFile(cgImage: cgImage, scaleFactor: scaleFactor) else {
            NSSound.beep()
            return
        }
        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        let aspect = CGFloat(cgImage.width) / max(1.0, CGFloat(cgImage.height))
        let maxSide: CGFloat = 150
        let thumbSize = aspect >= 1.0
            ? NSSize(width: maxSide, height: max(32, maxSide / aspect))
            : NSSize(width: max(32, maxSide * aspect), height: maxSide)
        let preview = NSImage(cgImage: cgImage, size: thumbSize)
        let localPt = convert(event.locationInWindow, from: nil)
        let dragRect = NSRect(
            x: localPt.x - thumbSize.width * 0.5,
            y: localPt.y - thumbSize.height * 0.5,
            width: thumbSize.width,
            height: thumbSize.height
        )
        item.setDraggingFrame(dragRect, contents: preview)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

/// 贴图外侧顶部独立悬浮控制条窗口（零遮挡贴图内部文字，贴顶时自动翻至贴图下方）
final class PinHoverBarPanel: NSPanel {
    enum Action {
        case annotate, ocr, translate, copy, save, close
    }

    let barView = PinHoverBarView()

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: PinHoverBarView.barSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.animationBehavior = .none
        self.isFloatingPanel = true
        self.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        self.becomesKeyOnlyIfNeeded = true
        self.hidesOnDeactivate = false
        self.acceptsMouseMovedEvents = true
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.contentView = barView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func hideCleanly() {
        barView.resetHoverState()
        orderOut(nil)
    }

    func reposition(anchoringTo pinFrame: NSRect, on screen: NSScreen?) {
        let center = NSPoint(x: pinFrame.midX, y: pinFrame.midY)
        let scr = NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? screen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(pinFrame) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let vf = scr?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let target = PinHoverGeometry.hoverBarFrame(anchoringTo: pinFrame, barSize: PinHoverBarView.barSize, visibleBounds: vf)
        setFrame(target, display: true)
    }
}

/// 贴图外侧悬浮微操作胶囊视图：`[ ✥ 拖动 | ✎ 标注 | 识字 | 翻译 | 复制 | ↓ 保存 | ✕ 关闭 ]`
final class PinHoverBarView: NSView {
    static let barSize = NSSize(width: 196, height: 28)

    var onAction: ((PinHoverBarPanel.Action) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onDragStart: (() -> Void)?
    var onDragMove: (() -> Void)?
    var onDragEnd: (() -> Void)?

    private struct ActionSlot {
        let rect: CGRect
        let symbol: String
        let tip: String
        let tint: NSColor
        let action: PinHoverBarPanel.Action?
    }

    private let slots: [ActionSlot] = [
        ActionSlot(rect: CGRect(x: 4, y: 2, width: 28, height: 24), symbol: "arrow.up.and.down.and.arrow.left.and.right",
                   tip: "按住拖动整张贴图（满屏文字无空白处时可直接拖这里）", tint: MSnipUITheme.accent, action: nil),
        ActionSlot(rect: CGRect(x: 38, y: 2, width: 25, height: 24), symbol: "pencil.tip",
                   tip: "二次圈记标注贴图 (E)", tint: MSnipUITheme.inkPrimary, action: .annotate),
        ActionSlot(rect: CGRect(x: 64, y: 2, width: 25, height: 24), symbol: "text.viewfinder",
                   tip: "提取图中文字 (T)", tint: MSnipUITheme.inkPrimary, action: .ocr),
        ActionSlot(rect: CGRect(x: 90, y: 2, width: 25, height: 24), symbol: "character.bubble",
                   tip: "翻译图中文字 (Y)", tint: MSnipUITheme.inkPrimary, action: .translate),
        ActionSlot(rect: CGRect(x: 116, y: 2, width: 25, height: 24), symbol: "doc.on.doc",
                   tip: "复制贴图图像 (⌘C)", tint: MSnipUITheme.inkPrimary, action: .copy),
        ActionSlot(rect: CGRect(x: 142, y: 2, width: 25, height: 24), symbol: "square.and.arrow.down",
                   tip: "保存到默认目录 (⌘S · 按住 ⇧ 点击另存为)", tint: MSnipUITheme.inkPrimary, action: .save),
        ActionSlot(rect: CGRect(x: 168, y: 2, width: 24, height: 24), symbol: "xmark",
                   tip: "关闭贴图 (Esc / 双击空白处)", tint: MSnipUITheme.danger, action: .close)
    ]

    private var hoveredIdx: Int? { didSet { if oldValue != hoveredIdx { needsDisplay = true } } }
    private var isDraggingPin = false { didSet { if oldValue != isDraggingPin { needsDisplay = true } } }
    private var isMouseInsideBar = false
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect = NSRect(origin: .zero, size: PinHoverBarView.barSize)) {
        super.init(frame: frameRect)
        updateTrackingAreas()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseInsideBar = true
        onHoverChanged?(true)
        syncHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt), !isMouseInsideBar { isMouseInsideBar = true; onHoverChanged?(true) }
        syncHover(at: pt)
    }

    override func mouseExited(with event: NSEvent) {
        resetHoverState()
        onHoverChanged?(false)
    }

    func resetHoverState() {
        let wasHovered = isMouseInsideBar || hoveredIdx != nil
        isMouseInsideBar = false
        hoveredIdx = nil
        toolTip = nil
        if wasHovered && !isDraggingPin { NSCursor.arrow.set() }
    }

    func reconcileHover(screenPoint: NSPoint) {
        guard let win = window else { return }
        let pt = convert(win.convertPoint(fromScreen: screenPoint), from: nil)
        guard bounds.contains(pt) else { return }
        isMouseInsideBar = true
        syncHover(at: pt)
    }

    private func syncHover(at pt: CGPoint) {
        let idx = slots.firstIndex(where: { $0.rect.contains(pt) })
        hoveredIdx = idx
        toolTip = idx.map { slots[$0].tip }
        if idx == 0 {
            NSCursor.openHand.set()
        } else if idx != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.openHand.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let hit = slots.first(where: { $0.rect.contains(pt) }), let action = hit.action {
            onAction?(action)
            return
        }
        isDraggingPin = true
        NSCursor.closedHand.set()
        onDragStart?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingPin else { return }
        onDragMove?()
    }

    override func mouseUp(with event: NSEvent) {
        guard isDraggingPin else { return }
        isDraggingPin = false
        NSCursor.openHand.set()
        onDragEnd?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        MSnipUITheme.drawPorcelainBar(ctx: ctx, bounds: bounds, radius: 8.5)
        ctx.setFillColor(MSnipUITheme.borderHairline.cgColor)
        ctx.fill(CGRect(x: 34.5, y: 6, width: 1, height: bounds.height - 12))

        for (i, s) in slots.enumerated() {
            let hov = (hoveredIdx == i) || (i == 0 && isDraggingPin)
            ToolbarView.drawButtonBg(ctx: ctx, rect: s.rect, active: i == 0 && isDraggingPin, hovered: hov)
            ToolbarView.drawSymbol(s.symbol, in: s.rect, alpha: 0.94, tint: s.tint)
        }
    }
}

// MARK: - 贴图边缘光晕与阴影容器

/// 贴图窗口外发光柔和容器：
/// - 静置态呈现淡淡发光白边（兼顾浅色壁纸环境分离），鼠标悬浮/选中/标注时平滑点亮柔和蓝色外光晕；
/// - 采用 even-odd 外环裁切，仅向图像外围渲染光晕，绝不向透明圆角图像内部填底色。
final class PinGlowContainerView: NSView {
    static let glowPadding: CGFloat = 14.0
    /// 允许鼠标贴着外发光轮廓外侧 4pt 内直接触发 8 向缩放光标与拖拽，外围 10pt 柔和光晕继续穿透点击
    static let outerResizeReach: CGFloat = 4.0

    let contentHost: PinContentView
    var glowStrength: CGFloat = 0.45 { didSet { if abs(oldValue - glowStrength) > 0.001 { needsDisplay = true } } }
    var isHoveredOrFocused: Bool = false { didSet { if oldValue != isHoveredOrFocused { needsDisplay = true } } }
    var isAnnotating: Bool = false { didSet { if oldValue != isAnnotating { needsDisplay = true } } }
    var isGhostMode: Bool = false { didSet { if oldValue != isGhostMode { needsDisplay = true } } }

    init(contentView: PinContentView, glowStrength: CGFloat) {
        self.contentHost = contentView
        self.glowStrength = min(1.0, max(0.0, glowStrength))
        let pad = Self.glowPadding
        let fullSize = NSSize(width: contentView.frame.width + pad * 2, height: contentView.frame.height + pad * 2)
        super.init(frame: NSRect(origin: .zero, size: fullSize))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        contentView.frame = NSRect(x: pad, y: pad, width: contentView.frame.width, height: contentView.frame.height)
        contentView.autoresizingMask = [.width, .height]
        addSubview(contentView)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let activeRect = (!isGhostMode && !isAnnotating)
            ? contentHost.frame.insetBy(dx: -Self.outerResizeReach, dy: -Self.outerResizeReach)
            : contentHost.frame
        guard activeRect.contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let imgRect = contentHost.frame
        guard imgRect.width >= 4, imgRect.height >= 4 else { return }

        let activeBlue = isHoveredOrFocused || isAnnotating
        let s = min(1.0, max(0.0, glowStrength))

        ctx.saveGState()
        // 外环 even-odd 裁切：确保光晕与外沿缩放热区严格位于贴图外部，绝不污染透明圆角内部
        ctx.addRect(bounds)
        ctx.addRect(imgRect)
        ctx.clip(using: .evenOdd)

        // 为外沿 4pt 缩放热区铺一层肉眼不可见的非零 alpha 捕获带，确保即使关掉光晕 WindowServer 也能路由缩放光标
        if !isGhostMode && !isAnnotating {
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.008).cgColor)
            ctx.fill(imgRect.insetBy(dx: -Self.outerResizeReach, dy: -Self.outerResizeReach))
        }

        if !activeBlue && !isGhostMode && s <= 0.005 {
            ctx.restoreGState()
            return
        }

        if activeBlue {
            let eff = max(0.35, s)
            let outerBlur = 3.5 + 8.5 * eff
            let coreBlur = max(2.0, outerBlur * 0.42)
            // 1) 宽柔蓝色外光晕
            ctx.setShadow(
                offset: .zero,
                blur: outerBlur,
                color: NSColor(srgbRed: 0.14, green: 0.50, blue: 1.0, alpha: 0.58 + 0.34 * eff).cgColor
            )
            ctx.setFillColor(NSColor(srgbRed: 0.18, green: 0.54, blue: 1.0, alpha: 1.0).cgColor)
            ctx.fill(imgRect)
            // 2) 贴边高亮蓝光核心层
            ctx.setShadow(
                offset: .zero,
                blur: coreBlur,
                color: NSColor(srgbRed: 0.28, green: 0.62, blue: 1.0, alpha: 0.78 + 0.18 * eff).cgColor
            )
            ctx.fill(imgRect)
            ctx.restoreGState()

            // 3) 精致 1pt 亮蓝外描边
            ctx.saveGState()
            ctx.setStrokeColor(NSColor(srgbRed: 0.32, green: 0.66, blue: 1.0, alpha: 0.92).cgColor)
            ctx.setLineWidth(1.0)
            ctx.stroke(imgRect.insetBy(dx: -0.5, dy: -0.5))
            ctx.restoreGState()
            return
        }

        if isGhostMode {
            let blur = max(3.5, 2.5 + 6.0 * s)
            ctx.setShadow(
                offset: .zero,
                blur: blur,
                color: NSColor(srgbRed: 0.20, green: 0.54, blue: 1.0, alpha: 0.45).cgColor
            )
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(imgRect)
            ctx.restoreGState()
            ctx.saveGState()
            ctx.setStrokeColor(NSColor(srgbRed: 0.30, green: 0.62, blue: 1.0, alpha: 0.55).cgColor)
            ctx.setLineWidth(1.0)
            ctx.stroke(imgRect.insetBy(dx: -0.5, dy: -0.5))
            ctx.restoreGState()
            return
        }

        // 默认静置态：淡淡发光白边 + 柔和环境分离影（深色桌面通透微光、纯白浅色网页下边界同样清晰常亮）
        let blur = 3.0 + 8.6 * s
        ctx.setShadow(
            offset: .zero,
            blur: blur * 0.85,
            color: NSColor.black.withAlphaComponent(0.20 + 0.16 * s).cgColor
        )
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(imgRect)

        ctx.setShadow(
            offset: .zero,
            blur: blur,
            color: NSColor.white.withAlphaComponent(0.46 + 0.44 * s).cgColor
        )
        ctx.fill(imgRect)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.32 + 0.36 * s).cgColor)
        ctx.setLineWidth(0.85)
        ctx.stroke(imgRect.insetBy(dx: -0.45, dy: -0.45))
        ctx.restoreGState()
    }
}
