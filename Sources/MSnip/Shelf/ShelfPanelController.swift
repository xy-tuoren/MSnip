import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 顶部轻盈晾衣架（MSnip Shelf）控制器：
/// 无笨重底框的悬链晾衣绳 + 小夹子卡片，缝隙 100% 透明穿透，支持 550ms 悬停防误触、新截图 3s 自动探头、快捷键切换与常驻挂绳。
@MainActor
final class ShelfPanelController {
    var onCopyHistory: ((CaptureHistoryEntry) -> Void)?
    var onPinHistory: ((CaptureHistoryEntry) -> Void)?
    var onOCRHistory: ((CaptureHistoryEntry) -> Void)?
    var onPinText: ((String) -> Void)?
    var onQuickCollage: (() -> Void)?

    let store = ShelfStore()
    unowned let historyRing: CaptureHistoryRing
    private let edgeWatcher = ShelfEdgeWatcher()

    private var panel: NSPanel?
    private var clotheslineView: ShelfClotheslineView?
    private var scrollView: ShelfHorizontalScrollView?
    private var stripView: GeekFlippedView?
    private var countLabel: NSTextField?
    private var clipBtn: GeekButton?
    private var collageBtn: GeekButton?
    private var pinBtn: GeekButton?
    private var closeBtn: GeekButton?
    private var leftNavBtn: GeekButton?
    private var rightNavBtn: GeekButton?
    private var emptyPill: NSTextField?

    private var isPinnedOpen = false
    private var manuallyHidden = false
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

    /// 新截图入库后联动：悬停模式下探头展示 3 秒供顺手拖走/复制；展开或常驻时即时刷新卡片
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
        let w = min(820, max(540, targetScreen.frame.width - 80)), h: CGFloat = 166
        let x = round(targetScreen.frame.midX - w * 0.5)
        let targetY = round(targetScreen.visibleFrame.maxY - h)
        let targetRect = NSRect(x: x, y: targetY, width: w, height: h)
        layoutSubviews(width: w, height: h)
        reloadCards()

        if !isVisible {
            panel.setFrame(NSRect(x: x, y: targetY + 20, width: w, height: h), display: false)
            panel.alphaValue = 0.0; panel.orderFrontRegardless(); isVisible = true
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.20; ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
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
        guard isVisible, let panel else { return }
        isVisible = false
        let endRect = panel.frame.offsetBy(dx: 0, dy: 18)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(endRect, display: true)
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isVisible else { return }
                self.panel?.orderOut(nil)
                self.stripView?.subviews.forEach { $0.removeFromSuperview() }
            }
        })
    }

    func refreshIfVisible() { if isVisible { reloadCards() } }

    // MARK: - Panel Construction & Reload

    private func ensurePanelBuilt() {
        guard panel == nil else { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 166),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar; p.isFloatingPanel = true; p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false; p.animationBehavior = .none

        let root = ShelfClotheslineView(frame: NSRect(x: 0, y: 0, width: 760, height: 166))
        root.onDropFiles = { [weak self] urls in
            guard let self else { return }
            let n = self.store.addFileURLs(urls)
            if n > 0 { self.reloadCards(); ToastHUD.show(message: "已挂上晾衣绳 · \(n) 个文件") }
        }
        root.onDropText = { [weak self] txt in
            guard let self else { return }
            if self.store.addText(txt) { self.reloadCards(); ToastHUD.show(message: "已将文本挂上晾衣绳") }
        }

        let sv = ShelfHorizontalScrollView(frame: .zero)
        sv.drawsBackground = false; sv.borderType = .noBorder
        sv.hasHorizontalScroller = false; sv.hasVerticalScroller = false
        sv.onScrollOffsetChanged = { [weak self] in self?.updateScrollNavButtons(); self?.syncCardsToRope() }
        let strip = GeekFlippedView(frame: .zero)
        sv.documentView = strip; root.addSubview(sv)

        let cnt = NSTextField(labelWithString: "晾衣架")
        cnt.font = .systemFont(ofSize: 10.8, weight: .semibold); root.addSubview(cnt)

        func addBtn(_ title: String, action: @escaping () -> Void) -> GeekButton {
            let b = GeekButton(title: title, style: .subtle); b.onClick = action; root.addSubview(b); return b
        }
        let cBtn = addBtn("+ 剪贴板") { [weak self] in
            guard let self else { return }
            if let msg = self.store.addFromClipboard(historyRing: self.historyRing) {
                self.reloadCards(); ToastHUD.show(message: msg)
            } else { ToastHUD.show(message: "剪贴板暂无可挂绳的图片、文件或文本") }
        }
        let colBtn = addBtn("对比") { [weak self] in self?.onQuickCollage?() }
        let pBtn = addBtn("钉住") { [weak self] in
            guard let self else { return }
            self.isPinnedOpen.toggle()
            self.pinBtn?.title = self.isPinnedOpen ? "已钉" : "钉住"
            self.pinBtn?.style = self.isPinnedOpen ? .accent : .subtle
        }
        let xBtn = addBtn("✕") { [weak self] in self?.isPinnedOpen = false; self?.hide(manual: true) }
        let lBtn = addBtn("‹") { [weak self] in self?.scrollView?.scrollBy(deltaX: -280) }
        let rBtn = addBtn("›") { [weak self] in self?.scrollView?.scrollBy(deltaX: 280) }

        let empty = NSTextField(labelWithString: "晾衣绳暂无内容 · 截图后自动挂上，或拖入文件 / 文字")
        empty.font = .systemFont(ofSize: 11.5, weight: .medium); empty.alignment = .center
        empty.wantsLayer = true; empty.layer?.cornerRadius = 11; empty.layer?.masksToBounds = true
        root.addSubview(empty)

        root.hitTestTargetsProvider = { [weak sv, weak lBtn, weak rBtn] in [sv, lBtn, rBtn].compactMap { $0 } }
        p.contentView = root
        panel = p; clotheslineView = root; scrollView = sv; stripView = strip
        countLabel = cnt; clipBtn = cBtn; collageBtn = colBtn; pinBtn = pBtn; closeBtn = xBtn
        leftNavBtn = lBtn; rightNavBtn = rBtn; emptyPill = empty
    }

    private func layoutSubviews(width w: CGFloat, height h: CGFloat) {
        clotheslineView?.frame = NSRect(x: 0, y: 0, width: w, height: h)
        let showCollage = historyRing.originalEntries.count >= 2
        let pillW: CGFloat = showCollage ? 256 : 210, pillH: CGFloat = 24
        let pillX = w - pillW - 14, pillY: CGFloat = 2
        clotheslineView?.utilityPillRect = CGRect(x: pillX, y: pillY, width: pillW, height: pillH)

        countLabel?.frame = NSRect(x: pillX + 10, y: pillY + 5, width: 64, height: 14)
        var rx = pillX + pillW - 4
        rx -= 22; closeBtn?.frame = NSRect(x: rx, y: pillY + 2, width: 22, height: 20)
        rx -= 44; pinBtn?.frame = NSRect(x: rx, y: pillY + 2, width: 40, height: 20)
        collageBtn?.isHidden = !showCollage
        if showCollage { rx -= 44; collageBtn?.frame = NSRect(x: rx, y: pillY + 2, width: 40, height: 20) }
        rx -= 64; clipBtn?.frame = NSRect(x: rx, y: pillY + 2, width: 60, height: 20)

        scrollView?.frame = NSRect(x: 18, y: 20, width: w - 36, height: h - 22)
        leftNavBtn?.frame = NSRect(x: 4, y: 78, width: 20, height: 28)
        rightNavBtn?.frame = NSRect(x: w - 24, y: 78, width: 20, height: 28)
        emptyPill?.frame = NSRect(x: round(w * 0.5 - 164), y: 58, width: 328, height: 24)
    }

    private func updateScrollNavButtons() {
        guard let sv = scrollView, let doc = sv.documentView else { return }
        let maxX = max(0, doc.frame.width - sv.contentView.bounds.width)
        let curX = sv.contentView.bounds.origin.x
        leftNavBtn?.isHidden = maxX <= 4 || curX <= 4
        rightNavBtn?.isHidden = maxX <= 4 || curX >= maxX - 4
    }

    private func applyTheme() {
        let isDark = GeekTheme.isDark
        panel?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        countLabel?.textColor = GeekTheme.inkSecondary
        emptyPill?.textColor = GeekTheme.inkSecondary
        emptyPill?.layer?.backgroundColor = (isDark ? NSColor(white: 0.14, alpha: 0.86) : NSColor(white: 0.98, alpha: 0.92)).cgColor
        clotheslineView?.needsDisplay = true
    }

    func reloadCards() {
        guard let stripView, let scrollView, let root = clotheslineView else { return }
        stripView.subviews.forEach { $0.removeFromSuperview() }
        let items = store.mergedItems(historyRing: historyRing)
        countLabel?.stringValue = items.isEmpty ? "晾衣架" : "晾衣架 \(items.count)"
        emptyPill?.isHidden = !items.isEmpty
        layoutSubviews(width: root.bounds.width, height: root.bounds.height)

        let gap: CGFloat = 14
        let cardW = ShelfCardView.cardSize.width, cardH = ShelfCardView.cardSize.height
        let contentW = CGFloat(items.count) * cardW + CGFloat(max(0, items.count - 1)) * gap
        let startX = max(8.0, round((scrollView.bounds.width - contentW) * 0.5))
        var x = startX
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        for item in items {
            let card = buildCardView(for: item, timeFormatter: tf)
            card.frame = NSRect(x: x, y: 6, width: cardW, height: cardH)
            stripView.addSubview(card)
            x += cardW + gap
        }
        stripView.frame = NSRect(x: 0, y: 0, width: max(scrollView.bounds.width, x + 8), height: scrollView.bounds.height)
        syncCardsToRope()
        updateScrollNavButtons()
    }

    /// 按悬链线公式将每张卡片的小夹子精准贴合到当前弧形细绳高度
    private func syncCardsToRope() {
        guard let root = clotheslineView, let sv = scrollView, let strip = stripView else { return }
        let x0 = ShelfClotheslineView.ropeMarginX, x1 = root.bounds.width - ShelfClotheslineView.ropeMarginX
        let scrollOffset = sv.contentView.bounds.origin.x
        for view in strip.subviews {
            let centerInRoot = sv.frame.minX + view.frame.midX - scrollOffset
            let ropeY = ShelfTriggerGeometry.ropeY(
                atX: centerInRoot, startX: x0, endX: x1,
                baseY: ShelfClotheslineView.ropeBaseY, sag: ShelfClotheslineView.ropeSag
            )
            let desiredY = round(ropeY - sv.frame.minY - 6.0)
            if abs(view.frame.origin.y - desiredY) > 0.5 { view.frame.origin.y = desiredY }
        }
    }
}
