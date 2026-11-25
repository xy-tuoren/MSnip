import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 顶部高密度实用暂存条（MSnip Shelf）控制器：
/// 仅 `98pt` 紧凑高度、零浪费顶栏、右侧 3 行规整工具列与自适应宽度卡片带，兼顾 550ms 悬停防误触、新截图 3s 自动探头与 3 模式切换。
@MainActor
final class ShelfPanelController {
    static let panelHeight: CGFloat = 98.0
    static let railWidth: CGFloat = 104.0
    static let cardGap: CGFloat = 7.0

    var onCopyHistory: ((CaptureHistoryEntry) -> Void)?
    var onPinHistory: ((CaptureHistoryEntry) -> Void)?
    var onOCRHistory: ((CaptureHistoryEntry) -> Void)?
    var onPinText: ((String) -> Void)?
    var onQuickCollage: (() -> Void)?
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
    var countLabel: NSTextField?
    var clipBtn: GeekButton?
    var secondaryBtn: GeekButton?
    var pinBtn: GeekButton?
    var closeBtn: GeekButton?
    var leftNavBtn: GeekButton?
    var rightNavBtn: GeekButton?
    var emptyLabel: NSTextField?
    weak var activeHoveredCard: ShelfCardView?

    private var isPinnedOpen = false
    private var manuallyHidden = false
    var showsCollageAction = false
    private(set) var isVisible = false
    private var activeScreenFrame: NSRect?

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
            return !self.store.mergedItems(historyRing: self.historyRing).isEmpty
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
            if triggerMode == .topEdgeHover { edgeWatcher.extendPeek(duration: 3.0) }
            return
        }
        if triggerMode == .topEdgeHover, !(isSuppressed?() ?? false) {
            show(on: screenUnderCursor(), peekDuration: 3.0, fromHotkey: false)
        } else if triggerMode == .alwaysShown && !manuallyHidden {
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

        if !isVisible {
            panel.setFrame(targetRect.offsetBy(dx: 0, dy: 14), display: false)
            panel.alphaValue = 0.0; panel.orderFrontRegardless(); isVisible = true
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.17; ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(targetRect, display: true); panel.animator().alphaValue = 1.0
            }
        } else {
            panel.setFrame(targetRect, display: true); panel.orderFrontRegardless()
        }
        edgeWatcher.startAutoHideWatch(peekDuration: peekDuration, fromHotkey: fromHotkey)
    }

    func hide(manual: Bool = false) {
        edgeWatcher.stopTransientTimers()
        if manual { manuallyHidden = true }
        activeHoveredCard?.clearHover(); activeHoveredCard = nil
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
        p.level = .statusBar; p.isFloatingPanel = true; p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.animationBehavior = .none

        let ev = NSVisualEffectView(frame: initRect)
        ev.material = .hudWindow; ev.blendingMode = .behindWindow; ev.state = .active
        ev.wantsLayer = true; ev.layer?.cornerRadius = 13; ev.layer?.masksToBounds = true; ev.layer?.borderWidth = 0.8

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
        sv.onScrollOffsetChanged = { [weak self] in self?.updateScrollNavButtons() }
        let strip = GeekFlippedView(frame: .zero)
        sv.documentView = strip; root.addSubview(sv)

        let cnt = NSTextField(labelWithString: "0 项")
        cnt.font = .monospacedDigitSystemFont(ofSize: 11.0, weight: .semibold); root.addSubview(cnt)

        func addBtn(_ title: String, tip: String? = nil, action: @escaping () -> Void) -> GeekButton {
            let b = GeekButton(title: title, style: .subtle)
            b.toolTip = tip; b.onClick = action; root.addSubview(b); return b
        }
        let pBtn = addBtn("钉", tip: "钉住常开 / 取消钉住") { [weak self] in
            guard let self else { return }
            self.isPinnedOpen.toggle()
            self.pinBtn?.style = self.isPinnedOpen ? .accent : .subtle
        }
        let xBtn = addBtn("✕", tip: "收起暂存架 (Esc)") { [weak self] in self?.isPinnedOpen = false; self?.hide(manual: true) }
        let cBtn = addBtn("+ 剪贴板", tip: "将剪贴板图片、文件或文本加入暂存架") { [weak self] in
            guard let self else { return }
            if let msg = self.store.addFromClipboard(historyRing: self.historyRing) {
                self.reloadCards(); ToastHUD.show(message: msg)
            } else { ToastHUD.show(message: "剪贴板暂无可加入的图片、文件或文本") }
        }
        let secBtn = addBtn("并排对比", tip: "将最近 2 张截图横向并排拼接对比") { [weak self] in
            guard let self else { return }
            if self.showsCollageAction { self.onQuickCollage?() } else { self.hide(manual: true); self.onOpenSettings?() }
        }
        let lBtn = addBtn("‹", tip: "向左翻页") { [weak self] in self?.scrollView?.scrollBy(deltaX: -340) }
        let rBtn = addBtn("›", tip: "向右翻页") { [weak self] in self?.scrollView?.scrollBy(deltaX: 340) }

        let empty = NSTextField(labelWithString: "暂无条目 · 截图自动收录于此，或直接拖入文件 / 文字")
        empty.font = .systemFont(ofSize: 11.5, weight: .regular); empty.alignment = .center
        root.addSubview(empty)

        p.contentView = ev
        panel = p; effectView = ev; rootView = root; scrollView = sv; stripView = strip
        countLabel = cnt; pinBtn = pBtn; closeBtn = xBtn; clipBtn = cBtn; secondaryBtn = secBtn
        leftNavBtn = lBtn; rightNavBtn = rBtn; emptyLabel = empty
    }
}
