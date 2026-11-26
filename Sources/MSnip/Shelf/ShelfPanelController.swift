import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 顶部高密度实用暂存条（MSnip Shelf）控制器：
/// 仅 `98pt` 紧凑高度、零浪费顶栏、右侧 3 行规整工具列与自适应宽度卡片带，兼顾 550ms 顶边悬停呼出与 3 模式切换（截图静默入架不弹窗打扰）。
@MainActor
final class ShelfPanelController {
    static let panelHeight: CGFloat = 98.0
    static let railWidth: CGFloat = 112.0
    static let cardGap: CGFloat = 7.0

    var onCopyHistory: ((CaptureHistoryEntry) -> Void)?
    var onEditHistory: ((CaptureHistoryEntry) -> Void)?
    var onPinHistory: ((CaptureHistoryEntry) -> Void)?
    var onOCRHistory: ((CaptureHistoryEntry) -> Void)?
    var onEditImage: ((CGImage, CGFloat) -> Void)?
    var onPinImage: ((CGImage, CGFloat) -> Void)?
    var onOCRImage: ((CGImage, CGFloat) -> Void)?
    var onPinText: ((String) -> Void)?
    var onOpenCollageStudio: (([CaptureHistoryEntry], [(String, CGImage, CGFloat)]) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onHistoryMutated: (() -> Void)?

    let store = ShelfStore()
    unowned let historyRing: CaptureHistoryRing
    private let edgeWatcher = ShelfEdgeWatcher()

    var panel: NSPanel?
    var effectView: NSVisualEffectView?
    fileprivate var rootView: ShelfClotheslineView?
    var scrollView: ShelfHorizontalScrollView?
    var stripView: GeekFlippedView?
    var railView: ShelfActionRailView?
    var leftNavBtn: ShelfEdgeArrowButton?
    var rightNavBtn: ShelfEdgeArrowButton?
    var emptyLabel: NSTextField?
    weak var activeHoveredCard: ShelfCardView?
    var selectedItemIDs: [UUID] = []

    var isPinnedOpen = false
    private var manuallyHidden = false
    private(set) var isVisible = false
    private var activeScreenFrame: NSRect?
    var hoverGlobalMonitor: Any?
    var hoverLocalMonitor: Any?
    private var interactiveActivityToken: NSObjectProtocol?
    nonisolated(unsafe) private var appearanceObserver: NSObjectProtocol?

    var triggerMode: TopShelfTriggerMode {
        get { edgeWatcher.triggerMode }
        set { applyTriggerMode(newValue) }
    }
    var isSuppressed: (() -> Bool)? { get { edgeWatcher.isSuppressed } set { edgeWatcher.isSuppressed = newValue } }

    init(historyRing: CaptureHistoryRing) {
        self.historyRing = historyRing
        edgeWatcher.onTriggerShow = { [weak self] in self?.show(on: nil, peekDuration: 0, fromHotkey: false) }
        edgeWatcher.onTriggerHide = { [weak self] in self?.hide(manual: false) }
        edgeWatcher.hasItemsProvider = { [weak self] in
            guard let self else { return false }
            return !self.historyRing.entries.isEmpty || !self.store.customItems.isEmpty
        }
        edgeWatcher.panelFrameProvider = { [weak self] in self?.panel?.frame }
        edgeWatcher.panelScreenFrameProvider = { [weak self] in self?.activeScreenFrame }
        edgeWatcher.isPinnedProvider = { [weak self] in self?.isPinnedOpen ?? false }
        edgeWatcher.isVisibleProvider = { [weak self] in self?.isVisible ?? false }
        appearanceObserver = NotificationCenter.default.addObserver(forName: .msnipAppearanceDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applyTheme() }
        }
    }

    deinit { if let obs = appearanceObserver { NotificationCenter.default.removeObserver(obs) } }

    func applyTriggerMode(_ mode: TopShelfTriggerMode) {
        let changed = (edgeWatcher.triggerMode != mode)
        edgeWatcher.triggerMode = mode
        guard changed else { return }
        manuallyHidden = (mode == .manualOnly)
        switch mode {
        case .alwaysShown:
            isPinnedOpen = false
            show(on: screenUnderCursor(), peekDuration: 0, fromHotkey: false)
        case .manualOnly:
            isPinnedOpen = false
            if isVisible { hide(manual: true) }
        case .topEdgeHover:
            isPinnedOpen = false
            if isVisible { edgeWatcher.startAutoHideWatch(peekDuration: 0, fromHotkey: false) }
        }
    }

    func presentInitiallyIfNeeded() {
        if triggerMode == .alwaysShown && !manuallyHidden {
            show(on: screenUnderCursor(), peekDuration: 0, fromHotkey: false)
        }
    }

    func toggle() {
        if isVisible {
            hide(manual: true)
        } else {
            manuallyHidden = false
            show(on: screenUnderCursor(), peekDuration: 0, fromHotkey: true)
        }
    }

    func notifyNewCaptureRecorded() {
        if isVisible {
            reloadCards()
            return
        }
        if triggerMode == .alwaysShown && !manuallyHidden {
            show(on: screenUnderCursor(), peekDuration: 0, fromHotkey: false)
        }
    }

    func show(on screen: NSScreen? = nil, peekDuration: TimeInterval = 0, fromHotkey: Bool = false) {
        guard let targetScreen = screen ?? screenUnderCursor() else { return }
        activeScreenFrame = targetScreen.frame
        ensurePanelBuilt()
        guard let panel else { return }
        applyTheme()
        let items = store.mergedItems(historyRing: historyRing)
        let targetRect = computePanelFrame(forItemCount: items.count, on: targetScreen)
        layoutSubviews(width: targetRect.width, height: targetRect.height)
        populateCards(items)
        // 仅在短暂自动收起悬停期内保活，常驻/钉住/热键打开均不阻止 macOS App Nap 节能
        if triggerMode != .alwaysShown && !isPinnedOpen && !fromHotkey {
            if interactiveActivityToken == nil {
                let opts: ProcessInfo.ActivityOptions = { if #available(macOS 13.0, *) { return [.userInteractive, .latencyCritical] }; return [.userInitiated, .latencyCritical] }()
                interactiveActivityToken = ProcessInfo.processInfo.beginActivity(options: opts, reason: "MSnip Top Shelf Hover Tracking")
            }
        } else {
            endInteractiveActivity()
        }
        startVisibleHoverMonitors()

        if !isVisible {
            panel.setFrame(targetRect.offsetBy(dx: 0, dy: 14), display: false)
            panel.alphaValue = 0.0; panel.orderFrontRegardless(); isVisible = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.17; ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(targetRect, display: true); panel.animator().alphaValue = 1.0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated { self?.syncHoverWithCurrentMouse() }
            })
        } else {
            panel.setFrame(targetRect, display: true); panel.orderFrontRegardless()
            syncHoverWithCurrentMouse()
        }
        edgeWatcher.startAutoHideWatch(peekDuration: peekDuration, fromHotkey: fromHotkey)
    }

    func endInteractiveActivity() {
        if let tok = interactiveActivityToken {
            ProcessInfo.processInfo.endActivity(tok)
            interactiveActivityToken = nil
        }
    }

    func hide(manual: Bool = false) {
        edgeWatcher.stopTransientTimers()
        stopVisibleHoverMonitors()
        endInteractiveActivity()
        if manual { manuallyHidden = true }
        clearAllHoverStates()
        guard isVisible, let panel else { return }
        isVisible = false
        let endRect = panel.frame.offsetBy(dx: 0, dy: 14)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14; ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(endRect, display: true); panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isVisible else { return }
                self.panel?.orderOut(nil)
                self.stripView?.subviews.forEach { $0.removeFromSuperview() }
            }
        })
    }

    func refreshIfVisible() { if isVisible { reloadCards() } }

    func reloadCards() {
        let items = store.mergedItems(historyRing: historyRing)
        if let panel, isVisible,
           let scr = NSScreen.screens.first(where: { activeScreenFrame == $0.frame }) ?? screenUnderCursor() {
            let rect = computePanelFrame(forItemCount: items.count, on: scr)
            if abs(panel.frame.width - rect.width) > 2 || abs(panel.frame.origin.x - rect.origin.x) > 2 {
                panel.setFrame(rect, display: true)
            }
            layoutSubviews(width: rect.width, height: rect.height)
        }
        populateCards(items)
    }

    func setActiveHoveredCard(_ card: ShelfCardView) {
        if activeHoveredCard !== card {
            activeHoveredCard?.clearHover()
            activeHoveredCard = card
        }
    }

    // MARK: - Construction & Layout

    private func computePanelFrame(forItemCount count: Int, on screen: NSScreen) -> NSRect {
        let maxW = min(1140.0, screen.frame.width - 40.0)
        let w = ShelfTriggerGeometry.dockPanelWidth(
            itemCount: count,
            cardWidth: ShelfCardView.cardSize.width,
            cardGap: Self.cardGap,
            railWidth: Self.railWidth,
            maxWidth: maxW
        )
        let h = Self.panelHeight
        let x = round(screen.frame.midX - w * 0.5)
        let y = round(screen.visibleFrame.maxY - h - 3.0)
        return NSRect(x: x, y: y, width: w, height: h)
    }

    private func ensurePanelBuilt() {
        guard panel == nil else { return }
        let initRect = NSRect(x: 0, y: 0, width: 640, height: Self.panelHeight)
        let p = NSPanel(contentRect: initRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true; p.level = .statusBar; p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.animationBehavior = .none
        p.acceptsMouseMovedEvents = true

        let ev = NSVisualEffectView(frame: initRect)
        ev.material = .popover; ev.blendingMode = .behindWindow; ev.state = .active
        ev.wantsLayer = true; ev.layer?.cornerRadius = 14; ev.layer?.masksToBounds = true; ev.layer?.borderWidth = 0.75

        let root = ShelfClotheslineView(frame: initRect)
        root.onPointerMoved = { [weak self] in self?.syncHoverWithCurrentMouse() }
        root.onPointerExited = { [weak self] in self?.clearAllHoverStates() }
        root.onDropFiles = { [weak self] urls in
            guard let self else { return }
            let n = self.store.addFileURLs(urls)
            if n > 0 { self.reloadCards(); ToastHUD.show(message: "已挂架 \(n) 个文件") }
        }
        root.onDropImage = { [weak self] cg in
            guard let self else { return }
            _ = self.historyRing.record(cgImage: cg, scaleFactor: NSScreen.main?.backingScaleFactor ?? 2.0)
            self.reloadCards(); self.onHistoryMutated?(); ToastHUD.show(message: "已将图片挂上暂存架")
        }
        root.onDropText = { [weak self] txt in
            guard let self else { return }
            if self.store.addText(txt) { self.reloadCards(); ToastHUD.show(message: "已将文本挂上暂存架") }
        }
        ev.addSubview(root)

        let sv = ShelfHorizontalScrollView(frame: .zero)
        sv.drawsBackground = false; sv.borderType = .noBorder; sv.hasHorizontalScroller = false; sv.hasVerticalScroller = false
        sv.onScrollOffsetChanged = { [weak self] in self?.updateScrollNavButtons(); self?.syncHoverWithCurrentMouse() }
        let strip = GeekFlippedView(frame: .zero)
        sv.documentView = strip; root.addSubview(sv)

        let rail = ShelfActionRailView(frame: .zero)
        rail.onTogglePin = { [weak self] in
            guard let self else { return }
            self.isPinnedOpen.toggle(); self.railView?.isPinned = self.isPinnedOpen
            if self.isPinnedOpen {
                self.edgeWatcher.stopTransientTimers(); self.endInteractiveActivity(); self.stopVisibleHoverMonitors()
            } else if self.triggerMode != .alwaysShown {
                self.edgeWatcher.startAutoHideWatch(peekDuration: 0, fromHotkey: false); self.startVisibleHoverMonitors()
            }
        }
        rail.onClose = { [weak self] in self?.isPinnedOpen = false; self?.railView?.isPinned = false; self?.hide(manual: true) }
        rail.onAddClipboard = { [weak self] in
            guard let self else { return }
            if let msg = self.store.addFromClipboard(historyRing: self.historyRing) {
                self.reloadCards(); self.onHistoryMutated?(); ToastHUD.show(message: msg)
            } else { ToastHUD.show(message: "剪贴板暂无可加入的图片、文件或文本") }
        }
        rail.onOpenCollage = { [weak self] in self?.triggerCollageStudio() }
        root.addSubview(rail)

        let lBtn = ShelfEdgeArrowButton(symbolName: "chevron.left", toolTip: "向左翻页")
        lBtn.onClick = { [weak self] in self?.scrollView?.scrollBy(deltaX: -340) }; root.addSubview(lBtn)
        let rBtn = ShelfEdgeArrowButton(symbolName: "chevron.right", toolTip: "向右翻页")
        rBtn.onClick = { [weak self] in self?.scrollView?.scrollBy(deltaX: 340) }; root.addSubview(rBtn)

        let empty = NSTextField(labelWithString: "暂无条目 · 截图与录屏自动收录于此，或直接拖入文件 / 文字")
        empty.font = .systemFont(ofSize: 11.5, weight: .regular); empty.alignment = .center; root.addSubview(empty)

        p.contentView = ev
        panel = p; effectView = ev; rootView = root; scrollView = sv; stripView = strip
        railView = rail; leftNavBtn = lBtn; rightNavBtn = rBtn; emptyLabel = empty
    }
}

// MARK: - 暂存架视觉容器与卡片网格

/// 顶部紧凑暂存条根容器：负责高通透毛玻璃底衬、内圈微高光描边、右侧精致竖向分割线与拖入高亮
private final class ShelfClotheslineView: NSView {
    var onDropFiles: (([URL]) -> Void)?
    var onDropImage: ((CGImage) -> Void)?
    var onDropText: ((String) -> Void)?
    var onPointerMoved: (() -> Void)?
    var onPointerExited: (() -> Void)?
    var dividerX: CGFloat = 0 { didSet { if abs(oldValue - dividerX) > 0.5 { needsDisplay = true } } }

    private var isDragTargeted = false { didSet { if oldValue != isDragTargeted { needsDisplay = true } } }
    private var hoverTrackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .png, .tiff, .string])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = hoverTrackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(ta); hoverTrackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) { onPointerMoved?() }
    override func mouseMoved(with event: NSEvent) { onPointerMoved?() }
    override func mouseExited(with event: NSEvent) { onPointerExited?() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDragTargeted = true; return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { isDragTargeted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragTargeted = false
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onDropFiles?(urls); return true
        }
        if let raw = pb.data(forType: .png) ?? pb.data(forType: .tiff),
           let ns = NSImage(data: raw), let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            onDropImage?(ImageTransform.detachedCopy(cg)); return true
        }
        if let txt = pb.string(forType: .string), !txt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onDropText?(txt); return true
        }
        return false
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let isDark = GeekTheme.isDark

        // 1) 柔和毛玻璃润色层：浅色下清透乳白不发灰，深色下沉稳深炭有层次
        let tint = isDark
            ? NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 0.62)
            : NSColor(srgbRed: 0.97, green: 0.975, blue: 0.985, alpha: 0.72)
        ctx.setFillColor(tint.cgColor)
        ctx.fill(bounds)

        // 2) 内圈 0.75pt 光学镜面细边（接近 macOS 控制中心 / Raycast 质感）
        let inner = bounds.insetBy(dx: 0.9, dy: 0.9)
        let innerPath = CGPath(roundedRect: inner, cornerWidth: 13.2, cornerHeight: 13.2, transform: nil)
        ctx.setStrokeColor((isDark ? NSColor.white.withAlphaComponent(0.11) : NSColor.white.withAlphaComponent(0.62)).cgColor)
        ctx.setLineWidth(0.75)
        ctx.addPath(innerPath); ctx.strokePath()

        // 3) 右侧实用工具列精致竖向分割线
        if dividerX > 10 && dividerX < bounds.width - 10 {
            ctx.setFillColor((isDark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.08)).cgColor)
            ctx.fill(CGRect(x: floor(dividerX) + 0.5, y: 11, width: 1, height: bounds.height - 22))
        }

        // 4) 拖入文件/文字时的虚线高亮反馈
        guard isDragTargeted else { return }
        let r = bounds.insetBy(dx: 2.5, dy: 2.5)
        let path = CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(GeekTheme.accent.withAlphaComponent(isDark ? 0.16 : 0.10).cgColor)
        ctx.addPath(path); ctx.fillPath()
        ctx.setStrokeColor(GeekTheme.accent.withAlphaComponent(0.92).cgColor)
        ctx.setLineWidth(1.8); ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.addPath(path); ctx.strokePath()
        ctx.restoreGState()
    }
}

/// 顶部实用暂存条布局、翻页对称指示与卡片填充扩展
extension ShelfPanelController {
    func layoutSubviews(width w: CGFloat, height h: CGFloat) {
        effectView?.frame = NSRect(x: 0, y: 0, width: w, height: h)
        rootView?.frame = NSRect(x: 0, y: 0, width: w, height: h)
        let railX = w - Self.railWidth
        rootView?.dividerX = railX

        // 右侧精炼控制列（10pt 呼吸留白）
        railView?.frame = NSRect(x: railX + 9, y: 8, width: Self.railWidth - 18, height: h - 16)

        leftNavBtn?.frame = NSRect(x: 3, y: 7, width: 22, height: h - 14)
        rightNavBtn?.frame = NSRect(x: railX - 25, y: 7, width: 22, height: h - 14)
        emptyLabel?.frame = NSRect(x: 14, y: round(h * 0.5 - 9), width: railX - 28, height: 18)
        applyScrollFrame(railX: railX, height: h, hasOverflow: !(leftNavBtn?.isHidden ?? true) || !(rightNavBtn?.isHidden ?? true))
    }

    func applyScrollFrame(railX: CGFloat, height h: CGFloat, hasOverflow: Bool) {
        let inset: CGFloat = hasOverflow ? 27 : 8
        scrollView?.frame = NSRect(x: inset, y: 7, width: max(60, railX - inset * 2), height: h - 14)
    }

    func updateScrollNavButtons() {
        guard let sv = scrollView, let doc = sv.documentView, let root = rootView else { return }
        let railX = root.bounds.width - Self.railWidth
        let overflow = doc.frame.width > (railX - 16) + 2
        applyScrollFrame(railX: railX, height: root.bounds.height, hasOverflow: overflow)
        let maxX = max(0, doc.frame.width - sv.contentView.bounds.width)
        let curX = sv.contentView.bounds.origin.x
        leftNavBtn?.isHidden = !overflow
        rightNavBtn?.isHidden = !overflow
        leftNavBtn?.isNavEnabled = curX > 2
        rightNavBtn?.isNavEnabled = curX < maxX - 2
    }

    func applyTheme() {
        let isDark = GeekTheme.isDark
        effectView?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        effectView?.layer?.borderColor = (isDark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.12)).cgColor
        emptyLabel?.textColor = GeekTheme.inkMuted
        if let rootView { ResultWindowChrome.invalidateSubtree(rootView) }
    }

    func populateCards(_ items: [ShelfCardItem]) {
        guard let stripView, let scrollView else { return }
        activeHoveredCard = nil
        let validIDs = Set(items.map(\.id))
        selectedItemIDs.removeAll { !validIDs.contains($0) }
        stripView.subviews.forEach { $0.removeFromSuperview() }
        railView?.itemCount = items.count
        railView?.selectedCount = selectedItemIDs.count
        railView?.isPinned = isPinnedOpen
        emptyLabel?.isHidden = !items.isEmpty

        let cardW = ShelfCardView.cardSize.width, cardH = ShelfCardView.cardSize.height
        var x: CGFloat = 0
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        for item in items {
            let card = buildCardView(for: item, timeFormatter: tf)
            card.selectionOrder = selectedItemIDs.firstIndex(of: item.id).map { $0 + 1 }
            card.onHoverStart = { [weak self] c in self?.setActiveHoveredCard(c) }
            card.onToggleSelect = { [weak self] it in self?.toggleSelection(for: it) }
            card.frame = NSRect(x: x, y: 0, width: cardW, height: cardH)
            stripView.addSubview(card)
            x += cardW + Self.cardGap
        }
        let totalW = max(0, x - (items.isEmpty ? 0 : Self.cardGap))
        stripView.frame = NSRect(x: 0, y: 0, width: max(scrollView.bounds.width, totalW), height: cardH)
        updateScrollNavButtons()
        if isVisible { syncHoverWithCurrentMouse() }
    }

    func toggleSelection(for item: ShelfCardItem) {
        if let idx = selectedItemIDs.firstIndex(of: item.id) {
            selectedItemIDs.remove(at: idx)
        } else {
            selectedItemIDs.append(item.id)
        }
        if let stripView {
            for case let card as ShelfCardView in stripView.subviews {
                card.selectionOrder = selectedItemIDs.firstIndex(of: card.item.id).map { $0 + 1 }
            }
        }
        railView?.selectedCount = selectedItemIDs.count
    }

    /// 仅在短暂悬停展开期间启用全局监听；常驻/钉住模式走面板内局部 `NSTrackingArea`，屏幕外零唤醒
    func startVisibleHoverMonitors() {
        if triggerMode == .alwaysShown || isPinnedOpen { stopVisibleHoverMonitors(); return }
        guard hoverGlobalMonitor == nil, hoverLocalMonitor == nil else { return }
        hoverGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncHoverWithCurrentMouse() }
        }
        hoverLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] ev in
            self?.syncHoverWithCurrentMouse()
            return ev
        }
    }

    func stopVisibleHoverMonitors() {
        if let m = hoverGlobalMonitor { NSEvent.removeMonitor(m); hoverGlobalMonitor = nil }
        if let m = hoverLocalMonitor { NSEvent.removeMonitor(m); hoverLocalMonitor = nil }
    }

    func clearAllHoverStates() {
        if let prev = activeHoveredCard { prev.clearHover(); activeHoveredCard = nil }
        railView?.clearHover()
    }

    func syncHoverWithCurrentMouse() {
        guard isVisible, let panel else { return }
        let screenPt = NSEvent.mouseLocation
        guard ShelfTriggerGeometry.containsInclusive(panel.frame.insetBy(dx: -4, dy: -4), point: screenPt) else {
            clearAllHoverStates()
            return
        }
        let winPt = panel.convertPoint(fromScreen: screenPt)
        railView?.syncHover(atWindowPoint: winPt)

        guard let sv = scrollView, let strip = stripView else { return }
        let visibleScrollRect = sv.convert(sv.bounds, to: nil)
        guard visibleScrollRect.contains(winPt) else {
            if let prev = activeHoveredCard { prev.clearHover(); activeHoveredCard = nil }
            return
        }
        let sp = strip.convert(winPt, from: nil)
        let step = ShelfCardView.cardSize.width + Self.cardGap
        let idx = Int(floor(sp.x / step))
        if idx >= 0, idx < strip.subviews.count,
           let card = strip.subviews[idx] as? ShelfCardView {
            let lp = card.convert(winPt, from: nil)
            if card.bounds.contains(lp) {
                setActiveHoveredCard(card)
                card.updateHover(at: lp)
                return
            }
        }
        if let prev = activeHoveredCard { prev.clearHover(); activeHoveredCard = nil }
    }
}
