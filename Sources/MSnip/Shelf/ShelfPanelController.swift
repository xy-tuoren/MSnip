import AppKit
import CoreGraphics
import Foundation
import ImageIO
import MSnipCore

/// 顶部轻暂存架（MSnip Shelf）控制器：
/// 屏幕顶部居中毛玻璃抽屉，聚合最近截图与拖入的文件/文本，支持点击复制、拖出分享、拖入挂架、一键贴图/识字/并排对比。
@MainActor
final class ShelfPanelController {
    var onCopyHistory: ((CaptureHistoryEntry) -> Void)?
    var onPinHistory: ((CaptureHistoryEntry) -> Void)?
    var onOCRHistory: ((CaptureHistoryEntry) -> Void)?
    var onPinText: ((String) -> Void)?
    var onQuickCollage: (() -> Void)?

    let store = ShelfStore()
    private unowned let historyRing: CaptureHistoryRing
    private let edgeWatcher = ShelfEdgeWatcher()

    private var panel: NSPanel?
    private var effectView: NSVisualEffectView?
    private var dropContainer: ShelfDropContainerView?
    private var scrollView: NSScrollView?
    private var stripView: GeekFlippedView?
    private var titleLabel: NSTextField?
    private var clipBtn: GeekButton?
    private var closeBtn: GeekButton?
    private var pinBtn: GeekButton?
    private var collageBtn: GeekButton?
    private var emptyLabel: NSTextField?

    private var isPinnedOpen = false
    private(set) var isVisible = false

    var hoverTriggerEnabled: Bool {
        get { edgeWatcher.isEnabled }
        set { edgeWatcher.isEnabled = newValue }
    }
    var isSuppressed: (() -> Bool)? {
        get { edgeWatcher.isSuppressed }
        set { edgeWatcher.isSuppressed = newValue }
    }

    init(historyRing: CaptureHistoryRing) {
        self.historyRing = historyRing
        edgeWatcher.onTriggerShow = { [weak self] in self?.show(on: nil) }
        edgeWatcher.onTriggerHide = { [weak self] in self?.hide() }
        edgeWatcher.panelFrameProvider = { [weak self] in self?.panel?.frame }
        edgeWatcher.isPinnedProvider = { [weak self] in self?.isPinnedOpen ?? false }
        edgeWatcher.isVisibleProvider = { [weak self] in self?.isVisible ?? false }
    }

    func toggle() { if isVisible { hide() } else { show(on: screenUnderCursor()) } }

    func show(on screen: NSScreen? = nil) {
        let targetScreen = screen ?? screenUnderCursor()
        ensurePanelBuilt()
        guard let panel else { return }
        applyTheme()
        let w = min(692, targetScreen.frame.width - 64), h: CGFloat = 148
        let x = round(targetScreen.frame.midX - w * 0.5)
        let y = round(targetScreen.visibleFrame.maxY - h - 4)
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: false)
        layoutSubviews(width: w, height: h)
        reloadCards()

        if !isVisible {
            panel.alphaValue = 0.0
            panel.orderFrontRegardless()
            isVisible = true
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.16; panel.animator().alphaValue = 1.0 }
        } else {
            panel.orderFrontRegardless()
        }
        edgeWatcher.startAutoHideWatch()
    }

    func hide() {
        edgeWatcher.stopTransientTimers()
        guard isVisible, let panel else { return }
        isVisible = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14; panel.animator().alphaValue = 0.0
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
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: 148),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar; p.isFloatingPanel = true; p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.animationBehavior = .none

        let ev = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 680, height: 148))
        ev.material = .hudWindow; ev.blendingMode = .behindWindow; ev.state = .active
        ev.wantsLayer = true; ev.layer?.cornerRadius = 15; ev.layer?.masksToBounds = true; ev.layer?.borderWidth = 0.8

        let drop = ShelfDropContainerView(frame: ev.bounds)
        drop.onDropFiles = { [weak self] urls in
            guard let self else { return }
            let n = self.store.addFileURLs(urls)
            if n > 0 { self.reloadCards(); ToastHUD.show(message: "已挂架 \(n) 个文件") }
        }
        drop.onDropText = { [weak self] txt in
            guard let self else { return }
            if self.store.addText(txt) { self.reloadCards(); ToastHUD.show(message: "已将文本挂上暂存架") }
        }
        ev.addSubview(drop)

        let title = NSTextField(labelWithString: "MSnip 暂存架")
        title.font = .systemFont(ofSize: 12.0, weight: .semibold)
        drop.addSubview(title)

        let clipBtn = GeekButton(title: "+ 剪贴板", style: .subtle)
        clipBtn.onClick = { [weak self] in
            guard let self else { return }
            if let msg = self.store.addFromClipboard(historyRing: self.historyRing) {
                self.reloadCards(); ToastHUD.show(message: msg)
            } else { ToastHUD.show(message: "剪贴板暂无可挂架的图片、文件或文本") }
        }
        drop.addSubview(clipBtn)

        let colBtn = GeekButton(title: "并排对比", style: .subtle)
        colBtn.onClick = { [weak self] in self?.onQuickCollage?() }
        drop.addSubview(colBtn)

        let pBtn = GeekButton(title: "钉住", style: .subtle)
        pBtn.onClick = { [weak self] in
            guard let self else { return }
            self.isPinnedOpen.toggle()
            self.pinBtn?.title = self.isPinnedOpen ? "已钉住" : "钉住"
            self.pinBtn?.style = self.isPinnedOpen ? .accent : .subtle
        }
        drop.addSubview(pBtn)

        let closeBtn = GeekButton(title: "✕", style: .subtle)
        closeBtn.onClick = { [weak self] in self?.isPinnedOpen = false; self?.hide() }
        drop.addSubview(closeBtn)

        let sv = NSScrollView(frame: .zero)
        sv.drawsBackground = false; sv.borderType = .noBorder
        sv.hasHorizontalScroller = true; sv.hasVerticalScroller = false; sv.autohidesScrollers = true
        let strip = GeekFlippedView(frame: .zero)
        sv.documentView = strip; drop.addSubview(sv)

        let empty = NSTextField(labelWithString: "暂无条目 · 截图会自动收纳于此，或直接将文件 / 文字拖到这里挂架")
        empty.font = .systemFont(ofSize: 12.0, weight: .regular); empty.alignment = .center
        drop.addSubview(empty)

        p.contentView = ev
        panel = p; effectView = ev; dropContainer = drop; scrollView = sv; stripView = strip
        titleLabel = title; self.clipBtn = clipBtn; self.closeBtn = closeBtn
        pinBtn = pBtn; collageBtn = colBtn; emptyLabel = empty
    }

    private func layoutSubviews(width w: CGFloat, height h: CGFloat) {
        effectView?.frame = NSRect(x: 0, y: 0, width: w, height: h)
        dropContainer?.frame = NSRect(x: 0, y: 0, width: w, height: h)
        titleLabel?.frame = NSRect(x: 14, y: 9, width: 240, height: 18)
        closeBtn?.frame = NSRect(x: w - 38, y: 6, width: 26, height: 22)
        pinBtn?.frame = NSRect(x: w - 98, y: 6, width: 54, height: 22)
        collageBtn?.frame = NSRect(x: w - 170, y: 6, width: 66, height: 22)
        clipBtn?.frame = NSRect(x: w - 246, y: 6, width: 70, height: 22)
        scrollView?.frame = NSRect(x: 10, y: 34, width: w - 20, height: h - 42)
        emptyLabel?.frame = NSRect(x: 20, y: 74, width: w - 40, height: 20)
    }

    private func applyTheme() {
        let isDark = GeekTheme.isDark
        effectView?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        effectView?.layer?.borderColor = (isDark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.12)).cgColor
        titleLabel?.textColor = GeekTheme.inkPrimary
        emptyLabel?.textColor = GeekTheme.inkMuted
    }

    private func reloadCards() {
        guard let stripView, let scrollView else { return }
        stripView.subviews.forEach { $0.removeFromSuperview() }
        let items = store.mergedItems(historyRing: historyRing)
        titleLabel?.stringValue = items.isEmpty ? "MSnip 暂存架" : "MSnip 暂存架 · \(items.count)"
        collageBtn?.isHidden = historyRing.originalEntries.count < 2
        emptyLabel?.isHidden = !items.isEmpty

        var x: CGFloat = 4
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        for item in items {
            let card = buildCardView(for: item, timeFormatter: tf)
            card.frame = NSRect(x: x, y: 4, width: ShelfCardView.cardSize.width, height: ShelfCardView.cardSize.height)
            stripView.addSubview(card)
            x += ShelfCardView.cardSize.width + 8
        }
        stripView.frame = NSRect(x: 0, y: 0, width: max(scrollView.bounds.width, x), height: scrollView.bounds.height)
    }

    private func buildCardView(for item: ShelfCardItem, timeFormatter: DateFormatter) -> ShelfCardView {
        let thumb: NSImage?, title: String, sub: String, sym: String?, snippet: String?, canOCR: Bool
        switch item {
        case .history(let e):
            let url = historyRing.fileURL(for: e)
            thumb = url.flatMap { ShelfStore.loadCardThumbnail(fileURL: $0) } ?? historyRing.menuThumbnail(for: e)
            title = e.isCollage ? "多图对比" : "截图 \(timeFormatter.string(from: e.createdAt))"
            sub = "\(e.pixelWidth)×\(e.pixelHeight)"; sym = "photo"; snippet = nil; canOCR = true
        case .custom(let c):
            if c.kind == .file, let p = c.filePath {
                let u = URL(fileURLWithPath: p), ext = u.pathExtension.lowercased()
                let isImg = ["png", "jpg", "jpeg", "webp", "heic", "gif", "tiff", "bmp"].contains(ext)
                thumb = isImg ? ShelfStore.loadCardThumbnail(fileURL: u) : nil
                title = c.title; sub = ext.isEmpty ? "文件" : ext.uppercased()
                sym = isImg ? "photo" : (["mp4", "mov"].contains(ext) ? "film" : "doc.fill")
                snippet = nil; canOCR = isImg
            } else {
                thumb = nil; title = c.title; sub = "\((c.textContent ?? "").count) 字"
                sym = nil; snippet = c.textContent; canOCR = false
            }
        }
        let card = ShelfCardView(item: item, thumbnail: thumb, title: title, subtitle: sub, symbol: sym, textSnippet: snippet, canOCR: canOCR)
        card.onCopy = { [weak self] it in self?.handleCopy(it) }
        card.onPin = { [weak self] it in self?.handlePin(it) }
        card.onOCR = { [weak self] it in self?.handleOCR(it) }
        card.onRemove = { [weak self] it in self?.handleRemove(it) }
        card.dragWriterProvider = { [weak self] it in self?.pasteboardWriter(for: it) }
        return card
    }

    private func handleCopy(_ item: ShelfCardItem) {
        switch item {
        case .history(let e): onCopyHistory?(e)
        case .custom(let c):
            if c.kind == .file, let p = c.filePath {
                let pb = NSPasteboard.general; pb.clearContents(); pb.writeObjects([URL(fileURLWithPath: p) as NSURL])
                ToastHUD.show(message: "已复制文件：\(c.title)")
            } else if let txt = c.textContent {
                ClipboardAndSave.copyText(txt); ToastHUD.show(message: "已复制暂存文本 (\(txt.count) 字)")
            }
        }
    }

    private func handlePin(_ item: ShelfCardItem) {
        switch item {
        case .history(let e): onPinHistory?(e)
        case .custom(let c):
            if c.kind == .text, let txt = c.textContent { onPinText?(txt) }
            else if c.kind == .file, let p = c.filePath, let cg = loadImage(at: p),
                    let entry = historyRing.record(cgImage: cg, scaleFactor: NSScreen.main?.backingScaleFactor ?? 2.0) { onPinHistory?(entry) }
        }
    }

    private func handleOCR(_ item: ShelfCardItem) {
        switch item {
        case .history(let e): onOCRHistory?(e)
        case .custom(let c):
            if c.kind == .file, let p = c.filePath, let cg = loadImage(at: p),
               let entry = historyRing.record(cgImage: cg, scaleFactor: 2.0) { onOCRHistory?(entry) }
        }
    }

    private func handleRemove(_ item: ShelfCardItem) {
        switch item {
        case .history: ToastHUD.show(message: "截图条目自动随历史环滚动清理，拖入条目可单独移除")
        case .custom(let c): store.removeCustom(id: c.id); reloadCards()
        }
    }

    private func pasteboardWriter(for item: ShelfCardItem) -> NSPasteboardWriting? {
        switch item {
        case .history(let e): return historyRing.fileURL(for: e) as NSURL?
        case .custom(let c): return c.kind == .file ? c.filePath.map { URL(fileURLWithPath: $0) as NSURL } : c.textContent as NSString?
        }
    }

    private func loadImage(at path: String) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private func screenUnderCursor() -> NSScreen {
        let pt = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(pt) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
