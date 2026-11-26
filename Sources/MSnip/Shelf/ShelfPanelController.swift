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
    var rootView: ShelfClotheslineView?
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
    }

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
        let targetScreen = screen ?? screenUnderCursor()
        activeScreenFrame = targetScreen.frame
        ensurePanelBuilt()
        guard let panel else { return }
        applyTheme()
        let items = store.mergedItems(historyRing: historyRing)
        let targetRect = computePanelFrame(forItemCount: items.count, on: targetScreen)
        layoutSubviews(width: targetRect.width, height: targetRect.height)
        populateCards(items)
        if interactiveActivityToken == nil && triggerMode != .alwaysShown {
            let opts: ProcessInfo.ActivityOptions = { if #available(macOS 13.0, *) { return [.userInteractive, .latencyCritical] }; return [.userInitiated, .latencyCritical] }()
            interactiveActivityToken = ProcessInfo.processInfo.beginActivity(options: opts, reason: "MSnip Top Shelf Hover Tracking")
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

    func hide(manual: Bool = false) {
        edgeWatcher.stopTransientTimers()
        stopVisibleHoverMonitors()
        if let tok = interactiveActivityToken {
            ProcessInfo.processInfo.endActivity(tok)
            interactiveActivityToken = nil
        }
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
        if let panel, isVisible {
            let scr = NSScreen.screens.first(where: { activeScreenFrame == $0.frame }) ?? screenUnderCursor()
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
        root.onDropFiles = { [weak self] urls in
            guard let self else { return }
            let n = self.store.addFileURLs(urls)
            if n > 0 { self.reloadCards(); ToastHUD.show(message: "已挂架 \(n) 个文件") }
        }
        root.onDropText = { [weak self] txt in
            guard let self else { return }
            if self.store.addText(txt) { self.reloadCards(); ToastHUD.show(message: "已将文本挂上暂存架") }
        }
        ev.addSubview(root)

        let sv = ShelfHorizontalScrollView(frame: .zero)
        sv.drawsBackground = false; sv.borderType = .noBorder
        sv.hasHorizontalScroller = false; sv.hasVerticalScroller = false
        sv.onScrollOffsetChanged = { [weak self] in
            self?.updateScrollNavButtons()
            self?.syncHoverWithCurrentMouse()
        }
        let strip = GeekFlippedView(frame: .zero)
        sv.documentView = strip; root.addSubview(sv)

        let rail = ShelfActionRailView(frame: .zero)
        rail.onTogglePin = { [weak self] in
            guard let self else { return }
            self.isPinnedOpen.toggle()
            self.railView?.isPinned = self.isPinnedOpen
        }
        rail.onClose = { [weak self] in
            self?.isPinnedOpen = false
            self?.railView?.isPinned = false
            self?.hide(manual: true)
        }
        rail.onAddClipboard = { [weak self] in
            guard let self else { return }
            if let msg = self.store.addFromClipboard(historyRing: self.historyRing) {
                self.reloadCards(); ToastHUD.show(message: msg)
            } else { ToastHUD.show(message: "剪贴板暂无可加入的图片、文件或文本") }
        }
        rail.onOpenCollage = { [weak self] in self?.triggerCollageStudio() }
        root.addSubview(rail)

        let lBtn = ShelfEdgeArrowButton(symbolName: "chevron.left", toolTip: "向左翻页")
        lBtn.onClick = { [weak self] in self?.scrollView?.scrollBy(deltaX: -340) }
        root.addSubview(lBtn)

        let rBtn = ShelfEdgeArrowButton(symbolName: "chevron.right", toolTip: "向右翻页")
        rBtn.onClick = { [weak self] in self?.scrollView?.scrollBy(deltaX: 340) }
        root.addSubview(rBtn)

        let empty = NSTextField(labelWithString: "暂无条目 · 截图自动收录于此，或直接拖入文件 / 文字")
        empty.font = .systemFont(ofSize: 11.5, weight: .regular); empty.alignment = .center
        root.addSubview(empty)

        p.contentView = ev
        panel = p; effectView = ev; rootView = root; scrollView = sv; stripView = strip
        railView = rail; leftNavBtn = lBtn; rightNavBtn = rBtn; emptyLabel = empty
    }
}
