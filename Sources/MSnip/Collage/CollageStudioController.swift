import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 轻量实用「多图拼接与合并 PDF」工作室：
/// 顶部/右侧采用与设置中心一致的极客卡片分层，清晰区分「拼成一张图」与「合并多页 PDF」双模式，零黑底错位、所见即所得。
@MainActor
final class CollageStudioController: NSObject, NSWindowDelegate {
    enum StudioMode: Int { case collage = 0, pdfMerge = 1 }

    var onCopyCollage: ((CGImage, CGFloat) -> Void)?
    var onPinCollage: ((CGImage, CGFloat) -> Void)?
    var onSaveCollage: ((CGImage, CGFloat) -> Void)?
    var historyRingProvider: (() -> CaptureHistoryRing?)?

    var window: CollageStudioWindow?
    var rootView: GeekSurfaceView?
    var canvasView: CollagePreviewCanvasView?
    var stripCard: GeekCardView?
    var stripScrollView: ShelfHorizontalScrollView?
    private var stripDocView: GeekFlippedView?
    var stripHeaderLabel: NSTextField?
    var addClipBtn: GeekButton?
    var addRecentBtn: GeekButton?
    var clearBtn: GeekButton?

    var modeSeg: GeekSegmentControl?
    var layoutCard: GeekCardView?
    var layoutHeader: NSTextField?
    var layoutSeg: GeekSegmentControl?
    var colsHeader: NSTextField?
    var colsSeg: GeekSegmentControl?

    var paramsCard: GeekCardView?
    var paramsHeader: NSTextField?
    var gapRow: CollageSliderRow?
    var padRow: CollageSliderRow?
    var radiusRow: CollageSliderRow?
    var bgHeader: NSTextField?
    var bgSwatch: CollageBgSwatchView?
    var pdfHintLabel: NSTextField?

    var copyBtn: GeekButton?
    var pinBtn: GeekButton?
    var saveBtn: GeekButton?
    var pdfBtn: GeekButton?

    var items: [CollageSourceItem] = []
    var options = CollageOptions()
    var studioMode: StudioMode = .collage
    private let lightbox = CollageImageLightbox()
    private var renderSeq: UInt64 = 0

    func present(initialEntries: [CaptureHistoryEntry] = [], initialImages: [(title: String, cgImage: CGImage, scale: CGFloat)] = []) {
        ensureWindowBuilt()
        items.removeAll()
        if !initialImages.isEmpty {
            for (title, cg, scale) in initialImages {
                items.append(makeSourceItem(title: title, cgImage: cg, scaleFactor: scale))
            }
        } else if let ring = historyRingProvider?() {
            let sourceEntries = initialEntries.isEmpty ? Array(ring.originalEntries.prefix(2).reversed()) : initialEntries
            let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss"
            for entry in sourceEntries {
                if let cg = ring.loadCGImage(for: entry) {
                    items.append(makeSourceItem(title: "截图 \(tf.string(from: entry.createdAt))", cgImage: cg, scaleFactor: entry.scaleFactor))
                }
            }
        }
        applyTheme()
        layoutUI()
        reloadFilmstrip()
        schedulePreviewRender()

        NSApp.activate(ignoringOtherApps: true)
        if let win = window {
            if !win.isVisible { MSnipUITheme.centerOnActiveScreen(win) }
            win.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        renderSeq &+= 1
        lightbox.dismiss()
        items.removeAll()
        canvasView?.previewImage = nil
        canvasView?.pdfPageItems = []
        stripDocView?.subviews.forEach { $0.removeFromSuperview() }
    }

    func windowDidResize(_ notification: Notification) { layoutUI() }

    // MARK: - Build & Layout

    private func ensureWindowBuilt() {
        guard window == nil else { return }
        let win = CollageStudioWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 630),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        win.title = "多图拼接与合并 PDF"
        win.minSize = NSSize(width: 800, height: 540)
        win.isReleasedWhenClosed = false
        win.appearance = GeekTheme.windowAppearance
        win.backgroundColor = GeekTheme.windowBg
        win.delegate = self
        win.onCopyShortcut = { [weak self] in
            guard let self, self.studioMode == .collage else { return }
            self.exportCollage(action: .copy)
        }
        win.onSaveShortcut = { [weak self] in
            guard let self else { return }
            if self.studioMode == .pdfMerge { self.exportPDF() } else { self.exportCollage(action: .save) }
        }

        // 使用 GeekSurfaceView 在 draw(_:) 中按 window.appearance 动态填充背景，彻底消除浅色模式下黑底错位
        let root = GeekSurfaceView(frame: win.contentLayoutRect, fill: GeekTheme.windowBg)

        let canvas = CollagePreviewCanvasView(frame: .zero)
        canvas.onDropImageURLs = { [weak self] urls in self?.appendImageURLs(urls) }
        canvas.onInspectCollage = { [weak self] in self?.openCollageLightbox() }
        canvas.onInspectPDFPage = { [weak self] idx in self?.openSourceLightbox(startIndex: idx) }
        root.addSubview(canvas)

        lightbox.onCopyImage = { [weak self] img, scale in
            ClipboardAndSave.copyToClipboard(cgImage: img, scaleFactor: scale)
            ToastHUD.show(message: "✓ 已复制当前预览图到剪贴板 · \(img.width) × \(img.height) px")
            _ = self
        }

        // 底部素材卡片
        let sCard = GeekCardView(frame: .zero)
        root.addSubview(sCard)
        let stripHdr = NSTextField(labelWithString: "素材顺序")
        stripHdr.font = .systemFont(ofSize: 12.0, weight: .semibold); sCard.addSubview(stripHdr)

        func addBtn(in parent: NSView, _ title: String, sym: String? = nil, style: GeekButton.Style = .subtle, action: @escaping () -> Void) -> GeekButton {
            let b = GeekButton(title: title, symbol: sym, style: style); b.onClick = action; parent.addSubview(b); return b
        }
        let cBtn = addBtn(in: sCard, "剪贴板", sym: "doc.on.clipboard") { [weak self] in self?.appendFromClipboard() }
        let rBtn = addBtn(in: sCard, "最近截图", sym: "clock") { [weak self] in self?.showRecentCapturesPicker() }
        let clrBtn = addBtn(in: sCard, "清空", style: .ghost) { [weak self] in self?.clearAllItems() }

        let sv = ShelfHorizontalScrollView(frame: .zero)
        sv.drawsBackground = false; sv.borderType = .noBorder
        sv.hasHorizontalScroller = false; sv.hasVerticalScroller = false
        let doc = GeekFlippedView(frame: .zero); sv.documentView = doc; sCard.addSubview(sv)

        // 右侧模式分段切换：拼成一张图 / 合并多页 PDF
        let mSeg = GeekSegmentControl(items: ["拼成一张图", "合并多页 PDF"], symbols: ["rectangle.split.2x2", "doc.richtext"], selectedIndex: 0)
        mSeg.onSelect = { [weak self] idx in
            guard let self, let next = StudioMode(rawValue: idx) else { return }
            self.studioMode = next
            if next == .pdfMerge && self.options.background == .transparent { self.options.background = .white }
            self.bgSwatch?.availableStyles = next == .pdfMerge ? [.white, .lightGray, .dark] : CollageBackgroundStyle.allCases
            self.bgSwatch?.selected = self.options.background
            self.layoutUI(); self.schedulePreviewRender()
        }
        root.addSubview(mSeg)

        // 右侧卡片 1：布局方式
        let lCard = GeekCardView(frame: .zero); root.addSubview(lCard)
        let lHdr = NSTextField(labelWithString: "排列布局"); lHdr.font = .systemFont(ofSize: 11.5, weight: .semibold); lCard.addSubview(lHdr)
        let lSeg = GeekSegmentControl(items: CollageLayoutMode.allCases.map(\.title), selectedIndex: 0)
        lSeg.onSelect = { [weak self] idx in
            guard let self, CollageLayoutMode.allCases.indices.contains(idx) else { return }
            self.options.layout = CollageLayoutMode.allCases[idx]; self.layoutUI(); self.schedulePreviewRender()
        }
        lCard.addSubview(lSeg)
        let cHdr = NSTextField(labelWithString: "网格列数"); cHdr.font = .systemFont(ofSize: 11.5, weight: .semibold); lCard.addSubview(cHdr)
        let cSeg = GeekSegmentControl(items: ["2 列", "3 列", "4 列"], selectedIndex: 0)
        cSeg.onSelect = { [weak self] idx in self?.options.gridColumns = idx + 2; self?.schedulePreviewRender() }
        lCard.addSubview(cSeg)

        // 右侧卡片 2：画布参数 & 底色
        let pCard = GeekCardView(frame: .zero); root.addSubview(pCard)
        let pHdr = NSTextField(labelWithString: "画布样式"); pHdr.font = .systemFont(ofSize: 11.5, weight: .semibold); pCard.addSubview(pHdr)
        let gRow = CollageSliderRow(title: "图片间距", min: 0, max: 80, value: options.gapPx)
        gRow.onChange = { [weak self] v in self?.options.gapPx = v; self?.schedulePreviewRender() }
        let pRow = CollageSliderRow(title: "外边距", min: 0, max: 100, value: options.padPx)
        pRow.onChange = { [weak self] v in self?.options.padPx = v; self?.schedulePreviewRender() }
        let rdRow = CollageSliderRow(title: "圆角弧度", min: 0, max: 40, value: Int(options.cornerRadiusPx))
        rdRow.onChange = { [weak self] v in self?.options.cornerRadiusPx = CGFloat(v); self?.schedulePreviewRender() }
        [gRow, pRow, rdRow].forEach { pCard.addSubview($0) }

        let bHdr = NSTextField(labelWithString: "背景底色"); bHdr.font = .systemFont(ofSize: 11.5, weight: .semibold); pCard.addSubview(bHdr)
        let bg = CollageBgSwatchView(frame: .zero); bg.selected = options.background
        bg.onSelect = { [weak self] st in self?.options.background = st; self?.schedulePreviewRender() }
        pCard.addSubview(bg)

        let pdfHint = NSTextField(wrappingLabelWithString: "每张素材自动生成独立一页，保留原图清晰度，可在底部素材条悬停调序。")
        pdfHint.font = .systemFont(ofSize: 11.2, weight: .regular); pCard.addSubview(pdfHint)

        // 底部主操作按钮组
        let cpBtn = addBtn(in: root, "复制拼图 (⌘C)", sym: "doc.on.doc", style: .accent) { [weak self] in self?.exportCollage(action: .copy) }
        let pnBtn = addBtn(in: root, "贴到桌面", sym: "pin", style: .subtle) { [weak self] in self?.exportCollage(action: .pin) }
        let svBtn = addBtn(in: root, "保存图片 (⌘S)", sym: "square.and.arrow.down", style: .subtle) { [weak self] in self?.exportCollage(action: .save) }
        let pdBtn = addBtn(in: root, "导出多页 PDF… (⌘S)", sym: "doc.richtext", style: .accent) { [weak self] in self?.exportPDF() }

        win.contentView = root
        window = win; rootView = root; canvasView = canvas; stripCard = sCard
        stripScrollView = sv; stripDocView = doc; stripHeaderLabel = stripHdr
        addClipBtn = cBtn; addRecentBtn = rBtn; clearBtn = clrBtn; modeSeg = mSeg
        layoutCard = lCard; layoutHeader = lHdr; layoutSeg = lSeg; colsHeader = cHdr; colsSeg = cSeg
        paramsCard = pCard; paramsHeader = pHdr; gapRow = gRow; padRow = pRow; radiusRow = rdRow
        bgHeader = bHdr; bgSwatch = bg; pdfHintLabel = pdfHint
        copyBtn = cpBtn; pinBtn = pnBtn; saveBtn = svBtn; pdfBtn = pdBtn
        layoutUI()
    }

    func reloadFilmstrip() {
        guard let doc = stripDocView, let sv = stripScrollView else { return }
        doc.subviews.forEach { $0.removeFromSuperview() }
        stripHeaderLabel?.stringValue = "素材列表（\(items.count) 张 · 悬停可调序/移除）"
        let hasItems = !items.isEmpty
        [copyBtn, pinBtn, saveBtn, pdfBtn, clearBtn].forEach { $0?.isEnabled = hasItems }

        var x: CGFloat = 0
        for (i, item) in items.enumerated() {
            let card = CollageFilmstripCardView(index: i, totalCount: items.count, item: item)
            card.frame = NSRect(x: x, y: 2, width: CollageFilmstripCardView.cardSize.width, height: CollageFilmstripCardView.cardSize.height)
            card.onInspect = { [weak self] idx in self?.openSourceLightbox(startIndex: idx) }
            card.onMoveLeft = { [weak self] idx in self?.moveItem(from: idx, to: idx - 1) }
            card.onMoveRight = { [weak self] idx in self?.moveItem(from: idx, to: idx + 1) }
            card.onRemove = { [weak self] idx in self?.removeItem(at: idx) }
            doc.addSubview(card)
            x += CollageFilmstripCardView.cardSize.width + 8
        }
        let addTile = CollageAddTileView(frame: NSRect(x: x, y: 2, width: 64, height: CollageFilmstripCardView.cardSize.height))
        addTile.onClick = { [weak self] in self?.pickImageFiles() }
        doc.addSubview(addTile)
        x += 68
        doc.frame = NSRect(x: 0, y: 0, width: max(sv.bounds.width, x), height: sv.bounds.height)
    }

    private func openSourceLightbox(startIndex: Int) {
        let list = items.map { CollageImageLightbox.Entry(title: $0.title, cgImage: $0.cgImage, scaleFactor: $0.scaleFactor) }
        lightbox.show(entries: list, startIndex: startIndex, showsCheckerboard: false)
    }

    private func openCollageLightbox() {
        let imgs = items.map(\.cgImage), opts = options, refScale = items.last?.scaleFactor ?? 2.0
        guard !imgs.isEmpty else { return }
        Task { @MainActor [weak self] in
            let hd = await Task.detached(priority: .userInitiated) {
                ImageCollageStitcher.stitch(images: imgs, options: opts, maxRefSide: 2400)
            }.value
            guard let self, let hd else { return }
            let entry = CollageImageLightbox.Entry(title: "\(opts.layout.title)拼图预览", cgImage: hd, scaleFactor: refScale)
            self.lightbox.show(entries: [entry], startIndex: 0, showsCheckerboard: opts.background == .transparent)
        }
    }

    private func moveItem(from: Int, to: Int) {
        guard items.indices.contains(from), items.indices.contains(to) else { return }
        items.swapAt(from, to); reloadFilmstrip(); schedulePreviewRender()
    }

    private func removeItem(at idx: Int) {
        guard items.indices.contains(idx) else { return }
        items.remove(at: idx); reloadFilmstrip(); schedulePreviewRender()
    }

    func schedulePreviewRender() {
        renderSeq &+= 1
        let seq = renderSeq
        let isPDF = (studioMode == .pdfMerge)
        canvasView?.isPDFMode = isPDF
        canvasView?.pdfBgStyle = options.background == .transparent ? .white : options.background
        canvasView?.pdfPageItems = items
        canvasView?.showsCheckerboard = (options.background == .transparent)

        if isPDF {
            canvasView?.statusBadgeText = items.isEmpty ? "" : "PDF 预览 · 共 \(items.count) 页（原图无损）"
            return
        }
        let imgs = items.map(\.cgImage), opts = options
        guard !imgs.isEmpty else {
            canvasView?.previewImage = nil; canvasView?.statusBadgeText = ""; return
        }
        Task { @MainActor [weak self] in
            let preview = await Task.detached(priority: .userInitiated) {
                ImageCollageStitcher.stitch(images: imgs, options: opts, maxRefSide: 960)
            }.value
            guard let self, self.renderSeq == seq else { return }
            self.canvasView?.previewImage = preview
            if let preview {
                self.canvasView?.statusBadgeText = "\(opts.layout.title) · \(imgs.count) 张 · 预览 \(preview.width)×\(preview.height)"
            }
        }
    }
}
