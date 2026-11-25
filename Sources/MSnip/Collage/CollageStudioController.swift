import AppKit
import CoreGraphics
import Foundation
import ImageIO
import MSnipCore
import UniformTypeIdentifiers

/// 轻量实用「多图拼接与合并 PDF」工作室窗口：
/// 支持自由拖入/增删/调序、横向并排 / 纵向长拼 / 网格拼图、实时调间距/边距/圆角/底色，一键复制 / 贴图 / 保存图片 / 合并导出多页 PDF。
@MainActor
final class CollageStudioController: NSObject, NSWindowDelegate {
    var onCopyCollage: ((CGImage, CGFloat) -> Void)?
    var onPinCollage: ((CGImage, CGFloat) -> Void)?
    var onSaveCollage: ((CGImage, CGFloat) -> Void)?
    var historyRingProvider: (() -> CaptureHistoryRing?)?

    var window: NSWindow?
    private var rootView: GeekFlippedView?
    private var canvasView: CollagePreviewCanvasView?
    private var stripScrollView: ShelfHorizontalScrollView?
    private var stripDocView: GeekFlippedView?
    private var stripHeaderLabel: NSTextField?
    private var addFileBtn: GeekButton?
    private var addClipBtn: GeekButton?
    var addRecentBtn: GeekButton?
    private var layoutSeg: GeekSegmentControl?
    private var colsHeader: NSTextField?
    private var colsSeg: GeekSegmentControl?
    private var gapRow: CollageSliderRow?
    private var padRow: CollageSliderRow?
    private var radiusRow: CollageSliderRow?
    private var bgSwatch: CollageBgSwatchView?
    private var infoLabel: NSTextField?
    private var copyBtn: GeekButton?
    private var pinBtn: GeekButton?
    private var saveBtn: GeekButton?
    private var pdfBtn: GeekButton?
    private var inspectorLabels: [NSTextField] = []

    var items: [CollageSourceItem] = []
    var options = CollageOptions()
    private var renderSeq: UInt64 = 0
    private var previewSizePx: (w: Int, h: Int)?

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
        reloadFilmstrip()
        schedulePreviewRender()

        NSApp.activate(ignoringOtherApps: true)
        if let win = window {
            if !win.isVisible { MSnipUITheme.centerOnActiveScreen(win) }
            win.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        // 关窗即释：零全尺寸 CGImage 常驻内存
        renderSeq &+= 1
        items.removeAll()
        canvasView?.previewImage = nil
        stripDocView?.subviews.forEach { $0.removeFromSuperview() }
    }

    func windowDidResize(_ notification: Notification) { layoutUI() }

    // MARK: - Build & Layout

    private func ensureWindowBuilt() {
        guard window == nil else { return }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 610),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        win.title = "多图拼接与合并（MSnip）"
        win.minSize = NSSize(width: 780, height: 520)
        win.isReleasedWhenClosed = false
        win.delegate = self

        let root = GeekFlippedView(frame: win.contentLayoutRect)
        root.wantsLayer = true

        let canvas = CollagePreviewCanvasView(frame: .zero)
        canvas.onDropImageURLs = { [weak self] urls in self?.appendImageURLs(urls) }
        root.addSubview(canvas)

        let stripHdr = NSTextField(labelWithString: "素材顺序")
        stripHdr.font = .systemFont(ofSize: 12.0, weight: .semibold); root.addSubview(stripHdr)

        func addBtn(_ title: String, sym: String? = nil, style: GeekButton.Style = .subtle, action: @escaping () -> Void) -> GeekButton {
            let b = GeekButton(title: title, symbol: sym, style: style); b.onClick = action; root.addSubview(b); return b
        }
        let fBtn = addBtn("添加图片", sym: "plus") { [weak self] in self?.pickImageFiles() }
        let cBtn = addBtn("剪贴板", sym: "doc.on.clipboard") { [weak self] in self?.appendFromClipboard() }
        let rBtn = addBtn("最近截图", sym: "clock") { [weak self] in self?.showRecentCapturesPicker() }

        let sv = ShelfHorizontalScrollView(frame: .zero)
        sv.drawsBackground = false; sv.borderType = .noBorder
        sv.hasHorizontalScroller = true; sv.hasVerticalScroller = false; sv.autohidesScrollers = true
        let doc = GeekFlippedView(frame: .zero); sv.documentView = doc; root.addSubview(sv)

        func addSecHeader(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: 11.5, weight: .semibold)
            root.addSubview(l); inspectorLabels.append(l); return l
        }
        _ = addSecHeader("布局方式")
        let lSeg = GeekSegmentControl(items: CollageLayoutMode.allCases.map(\.title), selectedIndex: 0)
        lSeg.onSelect = { [weak self] idx in
            guard let self, CollageLayoutMode.allCases.indices.contains(idx) else { return }
            self.options.layout = CollageLayoutMode.allCases[idx]
            self.layoutUI(); self.schedulePreviewRender()
        }
        root.addSubview(lSeg)

        let cHdr = addSecHeader("网格列数")
        let cSeg = GeekSegmentControl(items: ["2 列", "3 列", "4 列"], selectedIndex: 0)
        cSeg.onSelect = { [weak self] idx in
            self?.options.gridColumns = idx + 2; self?.schedulePreviewRender()
        }
        root.addSubview(cSeg)

        _ = addSecHeader("画布参数")
        let gRow = CollageSliderRow(title: "图片间距", min: 0, max: 80, value: options.gapPx)
        gRow.onChange = { [weak self] v in self?.options.gapPx = v; self?.schedulePreviewRender() }
        let pRow = CollageSliderRow(title: "画布外边距", min: 0, max: 100, value: options.padPx)
        pRow.onChange = { [weak self] v in self?.options.padPx = v; self?.schedulePreviewRender() }
        let rdRow = CollageSliderRow(title: "卡片圆角", min: 0, max: 40, value: Int(options.cornerRadiusPx))
        rdRow.onChange = { [weak self] v in self?.options.cornerRadiusPx = CGFloat(v); self?.schedulePreviewRender() }
        [gRow, pRow, rdRow].forEach { root.addSubview($0) }

        _ = addSecHeader("背景底色")
        let bg = CollageBgSwatchView(frame: .zero)
        bg.selected = options.background
        bg.onSelect = { [weak self] st in self?.options.background = st; self?.schedulePreviewRender() }
        root.addSubview(bg)

        let info = NSTextField(labelWithString: "暂无图片")
        info.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular); root.addSubview(info)

        let cpBtn = addBtn("复制图像", sym: "doc.on.doc", style: .accent) { [weak self] in self?.exportCollage(action: .copy) }
        let pnBtn = addBtn("贴到桌面", sym: "pin", style: .subtle) { [weak self] in self?.exportCollage(action: .pin) }
        let svBtn = addBtn("保存图片", sym: "square.and.arrow.down", style: .subtle) { [weak self] in self?.exportCollage(action: .save) }
        let pdBtn = addBtn("合并 PDF", sym: "doc.richtext", style: .emeraldSoft) { [weak self] in self?.exportPDF() }

        win.contentView = root
        window = win; rootView = root; canvasView = canvas; stripScrollView = sv; stripDocView = doc
        stripHeaderLabel = stripHdr; addFileBtn = fBtn; addClipBtn = cBtn; addRecentBtn = rBtn
        layoutSeg = lSeg; colsHeader = cHdr; colsSeg = cSeg
        gapRow = gRow; padRow = pRow; radiusRow = rdRow; bgSwatch = bg; infoLabel = info
        copyBtn = cpBtn; pinBtn = pnBtn; saveBtn = svBtn; pdfBtn = pdBtn
        layoutUI()
    }

    private func layoutUI() {
        guard let root = rootView else { return }
        let w = root.bounds.width, h = root.bounds.height
        let sideW: CGFloat = 264, pad: CGFloat = 16, gap: CGFloat = 16
        let leftW = max(360, w - sideW - pad * 2 - gap)
        let stripBlockH: CGFloat = 104
        let canvasH = max(240, h - pad * 2 - stripBlockH - 12)

        canvasView?.frame = NSRect(x: pad, y: pad, width: leftW, height: canvasH)

        let sy = pad + canvasH + 12
        stripHeaderLabel?.frame = NSRect(x: pad, y: sy + 4, width: 220, height: 18)
        addRecentBtn?.frame = NSRect(x: pad + leftW - 86, y: sy, width: 86, height: 24)
        addClipBtn?.frame = NSRect(x: pad + leftW - 166, y: sy, width: 74, height: 24)
        addFileBtn?.frame = NSRect(x: pad + leftW - 256, y: sy, width: 84, height: 24)
        stripScrollView?.frame = NSRect(x: pad, y: sy + 30, width: leftW, height: 74)

        let rx = pad + leftW + gap
        var cy: CGFloat = pad
        inspectorLabels[0].frame = NSRect(x: rx, y: cy, width: sideW, height: 16); cy += 22
        layoutSeg?.frame = NSRect(x: rx, y: cy, width: sideW, height: 30); cy += 42

        let showCols = (options.layout == .grid)
        colsHeader?.isHidden = !showCols; colsSeg?.isHidden = !showCols
        if showCols {
            colsHeader?.frame = NSRect(x: rx, y: cy, width: sideW, height: 16); cy += 22
            colsSeg?.frame = NSRect(x: rx, y: cy, width: sideW, height: 28); cy += 40
        }

        inspectorLabels[2].frame = NSRect(x: rx, y: cy, width: sideW, height: 16); cy += 22
        gapRow?.frame = NSRect(x: rx, y: cy, width: sideW, height: 42); cy += 46
        padRow?.frame = NSRect(x: rx, y: cy, width: sideW, height: 42); cy += 46
        radiusRow?.frame = NSRect(x: rx, y: cy, width: sideW, height: 42); cy += 52

        inspectorLabels[3].frame = NSRect(x: rx, y: cy, width: sideW, height: 16); cy += 22
        bgSwatch?.frame = NSRect(x: rx, y: cy, width: sideW, height: 32); cy += 46

        let btnW = (sideW - 8) * 0.5, btnH: CGFloat = 32
        let row2Y = h - pad - btnH
        let row1Y = row2Y - btnH - 8
        infoLabel?.frame = NSRect(x: rx, y: row1Y - 26, width: sideW, height: 18)
        copyBtn?.frame = NSRect(x: rx, y: row1Y, width: btnW, height: btnH)
        pinBtn?.frame = NSRect(x: rx + btnW + 8, y: row1Y, width: btnW, height: btnH)
        saveBtn?.frame = NSRect(x: rx, y: row2Y, width: btnW, height: btnH)
        pdfBtn?.frame = NSRect(x: rx + btnW + 8, y: row2Y, width: btnW, height: btnH)
    }

    private func applyTheme() {
        let isDark = GeekTheme.isDark
        window?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        rootView?.layer?.backgroundColor = GeekTheme.windowBg.cgColor
        stripHeaderLabel?.textColor = GeekTheme.inkPrimary
        infoLabel?.textColor = GeekTheme.inkMuted
        for l in inspectorLabels { l.textColor = GeekTheme.inkSecondary }
        [gapRow, padRow, radiusRow].forEach { $0?.applyTheme() }
        canvasView?.needsDisplay = true
    }

    // MARK: - Items & Preview

    func reloadFilmstrip() {
        guard let doc = stripDocView, let sv = stripScrollView else { return }
        doc.subviews.forEach { $0.removeFromSuperview() }
        stripHeaderLabel?.stringValue = "素材顺序（\(items.count) 张 · 悬停可调序/移除）"
        let hasItems = !items.isEmpty
        [copyBtn, pinBtn, saveBtn, pdfBtn].forEach { $0?.isEnabled = hasItems }

        var x: CGFloat = 0
        for (i, item) in items.enumerated() {
            let card = CollageFilmstripCardView(index: i, totalCount: items.count, item: item)
            card.frame = NSRect(x: x, y: 2, width: CollageFilmstripCardView.cardSize.width, height: CollageFilmstripCardView.cardSize.height)
            card.onMoveLeft = { [weak self] idx in self?.moveItem(from: idx, to: idx - 1) }
            card.onMoveRight = { [weak self] idx in self?.moveItem(from: idx, to: idx + 1) }
            card.onRemove = { [weak self] idx in self?.removeItem(at: idx) }
            doc.addSubview(card)
            x += CollageFilmstripCardView.cardSize.width + 8
        }
        doc.frame = NSRect(x: 0, y: 0, width: max(sv.bounds.width, x), height: sv.bounds.height)
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
        canvasView?.showsCheckerboard = (options.background == .transparent)
        let imgs = items.map(\.cgImage), opts = options
        guard !imgs.isEmpty else {
            canvasView?.previewImage = nil
            infoLabel?.stringValue = "请先添加至少 1 张图片"
            return
        }
        Task { @MainActor [weak self] in
            let preview = await Task.detached(priority: .userInitiated) {
                ImageCollageStitcher.stitch(images: imgs, options: opts, maxRefSide: 960)
            }.value
            guard let self, self.renderSeq == seq else { return }
            self.canvasView?.previewImage = preview
            if let preview {
                self.previewSizePx = (preview.width, preview.height)
                self.infoLabel?.stringValue = "\(imgs.count) 张素材 · 预览 \(preview.width)×\(preview.height)（导出自动全高清）"
            }
        }
    }
}
