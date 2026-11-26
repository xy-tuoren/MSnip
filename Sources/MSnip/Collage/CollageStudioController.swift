import AppKit
import CoreGraphics
import Foundation
import ImageIO
import MSnipCore
import UniformTypeIdentifiers

/// 精致大画布「拼图与 PDF」工作室（892×568 一体化顶栏浮窗）：
/// 左侧高清大预览画布 + 原窗口内嵌无弹窗图片编辑器（单张素材与合成拼图双阶段裁剪/旋转/11种标注打码）。
@MainActor
final class CollageStudioController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    enum StudioMode: Int { case collage = 0, pdfMerge = 1 }

    static let presets: [(title: String, gap: Int, pad: Int, radius: Int)] = [
        ("紧贴", 0, 0, 0),
        ("标准", 24, 32, 14),
        ("展示", 28, 48, 18)
    ]

    var onCopyCollage: ((CGImage, CGFloat) -> Void)?
    var onPinCollage: ((CGImage, CGFloat) -> Void)?
    var onSaveCollage: ((CGImage, CGFloat) -> Void)?
    var onOptionsChanged: ((CollageOptions) -> Void)?
    var historyRingProvider: (() -> CaptureHistoryRing?)?

    var window: CollageStudioWindow?
    var rootView, topBarView, topBarDivider: GeekSurfaceView?
    var titleLabel: NSTextField?
    var metaPill: CollageMetaPillView?
    var modeSeg: GeekSegmentControl?

    var canvasView: CollagePreviewCanvasView?
    var stripCard: GeekCardView?
    var stripScrollView: ShelfHorizontalScrollView?
    var stripDivider: GeekSurfaceView?
    var stripDocView: GeekFlippedView?
    var addClipBtn, addRecentBtn, clearBtn: GeekButton?

    var inspectorCard: GeekCardView?
    var layoutSeg, colsSeg, alignSeg, aspectSeg, badgeSeg, pdfPageNumSeg, watermarkSeg: GeekSegmentControl?
    var div1, div2, div3, divExport: GeekSurfaceView?
    var styleHeaderLabel, bgLabel, alignLabel, aspectLabel, badgeLabel, watermarkLabel, pdfHintLabel: NSTextField?
    var presetBar: CollageInlinePresetBar?
    var gapRow, padRow, radiusRow: CollageFineSliderRow?
    var bgTrigger: CollageBgTriggerPill?
    var bgEyedropperBtn: GeekButton?
    var shadowPill: CollageMiniTogglePill?
    var watermarkField: NSTextField?
    var watermarkBox: GeekInputBox?
    var copyBtn, annotateBtn, pinBtn, saveBtn, pdfBtn: GeekButton?

    var items: [CollageSourceItem] = []
    var options = CollageOptions()
    var studioMode: StudioMode = .collage
    var dragTargetIndex: Int?

    var editedCollageOverride: CGImage?
    var collageEditorBase: CGImage?
    var collageEditorDoc = AnnotationDocument()
    var collageEditorGeoModified = false
    var lastDiscardedCollageBackup: (override: CGImage, base: CGImage, doc: AnnotationDocument, geoMod: Bool)?
    var backupExpireWork: DispatchWorkItem?
    nonisolated(unsafe) var appearanceObserver: NSObjectProtocol?

    deinit { if let obs = appearanceObserver { NotificationCenter.default.removeObserver(obs) } }

    let colorPopover = CollageColorPickerPopover()
    let inlineEditor = CollageInlineEditorView(frame: .zero)
    let lightbox = CollageImageLightbox()
    var renderSeq: UInt64 = 0
    var isRenderingPreview = false
    var hasPendingPreviewRender = false

    func present(initialEntries: [CaptureHistoryEntry] = [], initialImages: [(title: String, cgImage: CGImage, scale: CGFloat)] = []) {
        ensureWindowBuilt()
        inlineEditor.dismissInline(); clearDiscardedBackup(); resetCollageEdits(); items.removeAll()
        if !initialImages.isEmpty {
            items = initialImages.map { makeSourceItem(title: $0.title, cgImage: $0.cgImage, scaleFactor: $0.scale) }
        } else if let ring = historyRingProvider?() {
            let src = initialEntries.isEmpty ? Array(ring.originalEntries.prefix(2).reversed()) : initialEntries
            let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss"
            items = src.compactMap { e in ring.loadCGImage(for: e).map { makeSourceItem(title: "截图 \(tf.string(from: e.createdAt))", cgImage: $0, scaleFactor: e.scaleFactor) } }
        }
        syncControlsFromOptions(); applyTheme(); layoutUI(); reloadFilmstrip(); schedulePreviewRender()
        NSApp.activate(ignoringOtherApps: true)
        if let win = window { if !win.isVisible { MSnipUITheme.centerOnActiveScreen(win) }; win.makeKeyAndOrderFront(nil) }
    }

    func windowWillClose(_ notification: Notification) {
        renderSeq &+= 1; isRenderingPreview = false; hasPendingPreviewRender = false; dragTargetIndex = nil
        colorPopover.closeIfShown(); inlineEditor.dismissInline(); lightbox.dismiss()
        resetCollageEdits(); clearDiscardedBackup(); items.removeAll()
        canvasView?.previewImage = nil; canvasView?.pdfPageItems = []
        stripDocView?.subviews.forEach { $0.removeFromSuperview() }
    }

    func windowDidResize(_ notification: Notification) { layoutUI() }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === watermarkField else { return }
        options.watermarkText = field.stringValue
        invalidateCollageEditsAndRender()
    }

    private func ensureWindowBuilt() {
        guard window == nil else { return }
        let win = CollageStudioWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        win.title = "拼图与 PDF"; win.titleVisibility = .hidden; win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.minSize = NSSize(width: 780, height: 504); win.isReleasedWhenClosed = false
        win.appearance = GeekTheme.windowAppearance; win.backgroundColor = GeekTheme.windowBg; win.delegate = self
        if appearanceObserver == nil {
            appearanceObserver = NotificationCenter.default.addObserver(forName: .msnipAppearanceDidChange, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.applyTheme() }
            }
        }
        win.onEscapeShortcut = { [weak self] in
            guard let self, self.inlineEditor.isActive else { return false }
            self.inlineEditor.cancelAndExit(); return true
        }
        win.onCopyShortcut = { [weak self] in
            guard let self else { return }
            if self.inlineEditor.isActive {
                if case .stitchedCollage = self.inlineEditor.mode { self.inlineEditor.finishWithExport(.copy) }
            } else if self.studioMode == .collage { self.exportCollage(action: .copy) }
        }
        win.onPasteShortcut = { [weak self] in if let self, !self.inlineEditor.isActive { self.appendFromClipboard() } }
        win.onSaveShortcut = { [weak self] in
            guard let self else { return }
            if self.inlineEditor.isActive {
                if case .stitchedCollage = self.inlineEditor.mode { self.inlineEditor.finishWithExport(.save) }
                else { self.inlineEditor.commitPrimaryAction() }
            } else if self.studioMode == .pdfMerge { self.exportPDF() }
            else { self.exportCollage(action: .save) }
        }

        let root = GeekSurfaceView(frame: NSRect(x: 0, y: 0, width: 920, height: 580), fill: GeekTheme.windowBg)
        let tBar = GeekSurfaceView(frame: .zero, fill: GeekTheme.barBg); root.addSubview(tBar)
        let tDiv = GeekSurfaceView(frame: .zero, fill: GeekTheme.divider); root.addSubview(tDiv)
        let tLbl = NSTextField(labelWithString: "拼图与 PDF"); tLbl.font = .systemFont(ofSize: 12.5, weight: .semibold); tBar.addSubview(tLbl)
        let mPill = CollageMetaPillView(frame: .zero); tBar.addSubview(mPill)
        tBar.addSubview(inlineEditor.topControlsView)

        let mSeg = GeekSegmentControl(items: ["拼成一图", "多页 PDF"], symbols: ["rectangle.split.2x2", "doc.richtext"], selectedIndex: 0)
        mSeg.onSelect = { [weak self] idx in
            guard let self, let next = StudioMode(rawValue: idx) else { return }
            self.colorPopover.closeIfShown(); self.studioMode = next
            // 切至 PDF 模式时仅在渲染层把透明底色回退为纯白，不破坏性覆盖用户的拼图透明背景设置
            self.syncControlsFromOptions(); self.layoutUI(); self.schedulePreviewRender()
        }
        tBar.addSubview(mSeg)

        let canvas = CollagePreviewCanvasView(frame: .zero)
        canvas.onDropImageURLs = { [weak self] urls in self?.appendImageURLs(urls) }
        canvas.onDropImages = { [weak self] imgs in self?.appendDroppedCGImages(imgs) }
        canvas.onInspectCollage = { [weak self] in self?.openCollageLightbox() }
        canvas.onEditCollage = { [weak self] in self?.openCollageEditor() }
        canvas.onInspectPDFPage = { [weak self] idx in self?.openSourceLightbox(startIndex: idx) }
        root.addSubview(canvas)
        root.addSubview(inlineEditor)
        wireInlineEditorCallbacks()

        lightbox.onCopyImage = { img, scale in
            ClipboardAndSave.copyToClipboard(cgImage: img, scaleFactor: scale)
            ToastHUD.show(message: "✓ 已复制当前预览图到剪贴板 · \(img.width) × \(img.height) px")
        }

        func addBtn(in p: NSView, _ title: String, sym: String? = nil, style: GeekButton.Style = .subtle, tip: String? = nil, action: @escaping () -> Void) -> GeekButton {
            let b = GeekButton(title: title, symbol: sym, style: style); b.toolTip = tip; b.onClick = action; p.addSubview(b); return b
        }
        func addDiv(in p: NSView) -> GeekSurfaceView { let d = GeekSurfaceView(frame: .zero, fill: GeekTheme.divider); p.addSubview(d); return d }
        func addLbl(in p: NSView, _ text: String, size: CGFloat = 11.2) -> NSTextField {
            let l = NSTextField(labelWithString: text); l.font = .systemFont(ofSize: size, weight: .medium); p.addSubview(l); return l
        }

        let sCard = GeekCardView(frame: .zero); root.addSubview(sCard)
        let sv = ShelfHorizontalScrollView(frame: .zero)
        sv.drawsBackground = false; sv.borderType = .noBorder; sv.hasHorizontalScroller = false; sv.hasVerticalScroller = false
        let doc = GeekFlippedView(frame: .zero); sv.documentView = doc; sCard.addSubview(sv)
        let sDiv = addDiv(in: sCard)
        let cBtn = addBtn(in: sCard, "剪贴板", sym: "doc.on.clipboard", tip: "粘贴剪贴板图片或文件 (⌘V)") { [weak self] in self?.appendFromClipboard() }
        let rBtn = addBtn(in: sCard, "最近", sym: "clock", tip: "从最近截图中挑选添加") { [weak self] in self?.showRecentCapturesPicker() }
        let clrBtn = addBtn(in: sCard, "", sym: "trash", style: .ghost, tip: "清空所有素材") { [weak self] in self?.clearAllItems() }

        let iCard = GeekCardView(frame: .zero); root.addSubview(iCard)
        let lSeg = GeekSegmentControl(items: ["横向", "纵向", "网格"], symbols: ["rectangle.split.2x1", "rectangle.split.1x2", "square.grid.2x2"], selectedIndex: 0)
        lSeg.onSelect = { [weak self] idx in
            guard let self, CollageLayoutMode.allCases.indices.contains(idx) else { return }
            self.options.layout = CollageLayoutMode.allCases[idx]; self.layoutUI(); self.invalidateCollageEditsAndRender()
        }
        iCard.addSubview(lSeg)
        let cSeg = GeekSegmentControl(items: ["2 列", "3 列", "4 列"], selectedIndex: 0)
        cSeg.onSelect = { [weak self] idx in self?.options.gridColumns = idx + 2; self?.invalidateCollageEditsAndRender() }
        iCard.addSubview(cSeg); let d1 = addDiv(in: iCard)

        let stHdr = addLbl(in: iCard, "留白与圆角", size: 10.8)
        let pBar = CollageInlinePresetBar(items: Self.presets.map(\.title), selectedIndex: 1)
        pBar.onSelect = { [weak self] idx in
            guard let self, Self.presets.indices.contains(idx) else { return }
            let p = Self.presets[idx]; self.options.gapPx = p.gap; self.options.padPx = p.pad; self.options.cornerRadiusPx = CGFloat(p.radius)
            self.syncControlsFromOptions(); self.invalidateCollageEditsAndRender()
        }
        iCard.addSubview(pBar)

        let gRow = CollageFineSliderRow(title: "间距", min: 0, max: 80, value: options.gapPx, defaultValue: 24)
        gRow.onChange = { [weak self] v in self?.options.gapPx = v; self?.syncPresetHighlight(); self?.invalidateCollageEditsAndRender() }
        let pRow = CollageFineSliderRow(title: "边距", min: 0, max: 100, value: options.padPx, defaultValue: 32)
        pRow.onChange = { [weak self] v in self?.options.padPx = v; self?.syncPresetHighlight(); self?.invalidateCollageEditsAndRender() }
        let rdRow = CollageFineSliderRow(title: "圆角", min: 0, max: 40, value: Int(options.cornerRadiusPx), defaultValue: 14)
        rdRow.onChange = { [weak self] v in self?.options.cornerRadiusPx = CGFloat(v); self?.syncPresetHighlight(); self?.invalidateCollageEditsAndRender() }
        [gRow, pRow, rdRow].forEach { iCard.addSubview($0) }

        let bgLbl = addLbl(in: iCard, "底色")
        let bgTrig = CollageBgTriggerPill(frame: .zero)
        bgTrig.toolTip = "点击打开极客取色板（2D 色盘 / #HEX / 精选纯色与多款渐变）"
        bgTrig.onClick = { [weak self] in self?.presentBgColorPopover() }
        iCard.addSubview(bgTrig)
        let bgEye = addBtn(in: iCard, "", sym: "eyedropper", style: .subtle, tip: "从屏幕或截图中吸取背景色") { [weak self] in self?.pickBackgroundFromScreen() }
        let shPill = CollageMiniTogglePill(title: "柔影", isOn: options.cardShadow)
        shPill.onToggle = { [weak self] on in self?.options.cardShadow = on; self?.invalidateCollageEditsAndRender() }
        iCard.addSubview(shPill); let d2 = addDiv(in: iCard)

        let alLbl = addLbl(in: iCard, "对齐")
        let alSeg = GeekSegmentControl(items: ["齐平", "居中", "顶齐"], selectedIndex: 0)
        alSeg.onSelect = { [weak self] idx in self?.options.scaleAlignment = CollageScaleAlignment(rawValue: idx) ?? .uniformFill; self?.invalidateCollageEditsAndRender() }
        iCard.addSubview(alSeg)

        let asLbl = addLbl(in: iCard, "画幅")
        let asSeg = GeekSegmentControl(items: ["自动", "16:9", "4:3", "1:1"], selectedIndex: 0)
        asSeg.onSelect = { [weak self] idx in self?.options.aspectPreset = CollageAspectPreset(rawValue: idx) ?? .auto; self?.invalidateCollageEditsAndRender() }
        iCard.addSubview(asSeg); let d3 = addDiv(in: iCard)

        let bLbl = addLbl(in: iCard, "角标")
        let bSeg = GeekSegmentControl(items: ["无", "序号", "对比"], selectedIndex: 0)
        bSeg.onSelect = { [weak self] idx in self?.options.badge = CollageBadgeStyle(rawValue: idx) ?? .none; self?.invalidateCollageEditsAndRender() }
        iCard.addSubview(bSeg)
        let pnSeg = GeekSegmentControl(items: ["无", "1/N", "第N页"], selectedIndex: options.pdfPageNumber.rawValue)
        pnSeg.onSelect = { [weak self] idx in self?.options.pdfPageNumber = CollagePDFPageNumberStyle(rawValue: idx) ?? .none; self?.schedulePreviewRender() }
        iCard.addSubview(pnSeg)

        let wLbl = addLbl(in: iCard, "水印")
        let wSeg = GeekSegmentControl(items: ["关", "角标", "平铺"], selectedIndex: 0)
        wSeg.onSelect = { [weak self] idx in
            guard let self else { return }
            self.options.watermark = CollageWatermarkStyle(rawValue: idx) ?? .none
            self.layoutUI(); self.invalidateCollageEditsAndRender()
            if self.options.watermark != .none, let f = self.watermarkField, f.stringValue.isEmpty { self.window?.makeFirstResponder(f) }
        }
        iCard.addSubview(wSeg)

        let wmField = NSTextField(frame: .zero); wmField.delegate = self
        let wmBox = GeekInputBox(frame: NSRect(x: 0, y: 0, width: 206, height: 25), field: wmField, placeholder: "水印文字（留空默认 MSnip）", mono: false)
        iCard.addSubview(wmBox)

        let pdfHint = NSTextField(wrappingLabelWithString: "点击底部缩略图左下角 ✎ 可在窗内直接裁剪/打码单页；页码与水印以原生矢量写入。")
        pdfHint.font = .systemFont(ofSize: 10.6, weight: .regular); iCard.addSubview(pdfHint)
        let dExp = addDiv(in: iCard)

        let cpBtn = addBtn(in: iCard, "复制拼图 (⌘C)", sym: "doc.on.doc", style: .accent) { [weak self] in self?.exportCollage(action: .copy) }
        let anBtn = addBtn(in: iCard, "标注", sym: "pencil", style: .subtle, tip: "直接在当前窗口内对合成拼图画箭头/红框/裁剪/打码") { [weak self] in self?.openCollageEditor() }
        let pnBtn = addBtn(in: iCard, "贴图", sym: "pin", style: .subtle, tip: "将合成拼图贴到桌面") { [weak self] in self?.exportCollage(action: .pin) }
        let svBtn = addBtn(in: iCard, "保存", sym: "square.and.arrow.down", style: .subtle, tip: "保存高清拼图文件 (⌘S)") { [weak self] in self?.exportCollage(action: .save) }
        let pdBtn = addBtn(in: iCard, "导出多页 PDF… (⌘S)", sym: "doc.richtext", style: .accent) { [weak self] in self?.exportPDF() }

        win.contentView = root
        window = win; rootView = root; topBarView = tBar; topBarDivider = tDiv; titleLabel = tLbl; metaPill = mPill; modeSeg = mSeg
        canvasView = canvas; stripCard = sCard; stripScrollView = sv; stripDocView = doc; stripDivider = sDiv
        addClipBtn = cBtn; addRecentBtn = rBtn; clearBtn = clrBtn; inspectorCard = iCard
        layoutSeg = lSeg; colsSeg = cSeg; div1 = d1; styleHeaderLabel = stHdr; presetBar = pBar
        gapRow = gRow; padRow = pRow; radiusRow = rdRow; bgLabel = bgLbl; bgTrigger = bgTrig; bgEyedropperBtn = bgEye; shadowPill = shPill; div2 = d2
        alignLabel = alLbl; alignSeg = alSeg; aspectLabel = asLbl; aspectSeg = asSeg; div3 = d3
        badgeLabel = bLbl; badgeSeg = bSeg; pdfPageNumSeg = pnSeg; watermarkLabel = wLbl; watermarkSeg = wSeg
        watermarkField = wmField; watermarkBox = wmBox; pdfHintLabel = pdfHint; divExport = dExp
        copyBtn = cpBtn; annotateBtn = anBtn; pinBtn = pnBtn; saveBtn = svBtn; pdfBtn = pdBtn
        layoutUI()
    }
}

// MARK: - 拼图工作室窗口子类

/// 拼图工作室自定义浮窗（自动兼容内嵌标注画布的 Esc / ⌘Z / ⌘C / ⌘V / ⌘S 快捷键分发）
final class CollageStudioWindow: NSWindow {
    var onCopyShortcut: (() -> Void)?
    var onPasteShortcut: (() -> Void)?
    var onSaveShortcut: (() -> Void)?
    var onEscapeShortcut: (() -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command && ch == "w" { close(); return true }
        if firstResponder is NSTextView {
            if flags == .command && ch == "s" { onSaveShortcut?(); return true }
            if flags.isEmpty && event.keyCode == 53 && !(firstResponder?.nextResponder is PinAnnotationCanvasView) {
                makeFirstResponder(nil); return true
            }
            return super.performKeyEquivalent(with: event)
        }
        if firstResponder is PinCropOverlayView { return false }
        if let canvas = firstResponder as? PinAnnotationCanvasView {
            if flags == .command && ch == "s" { onSaveShortcut?(); return true }
            if flags == .command && ch == "c" && canvas.selectedIndex == nil { onCopyShortcut?(); return true }
            return canvas.performKeyEquivalent(with: event)
        }
        if flags == .command && ch == "c" { onCopyShortcut?(); return true }
        if flags == .command && ch == "v" { onPasteShortcut?(); return true }
        if flags == .command && ch == "s" { onSaveShortcut?(); return true }
        if flags.isEmpty && event.keyCode == 53 {
            if onEscapeShortcut?() == true { return true }
            close(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// 大图查看器无边框窗口（支持 Esc/Space 关闭、←/→ 切图、0/1 适应与 1:1、⌘C 复制）
final class CollageLightboxWindow: NSWindow {
    enum KeyAction { case close, prev, next, fit, actual100, copy }
    var onKeyAction: ((KeyAction) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53, 49: onKeyAction?(.close)
        case 123:    onKeyAction?(.prev)
        case 124:    onKeyAction?(.next)
        case 29:     onKeyAction?(.fit)
        case 18:     onKeyAction?(.actual100)
        default:     super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command && ch == "c" { onKeyAction?(.copy); return true }
        if flags == .command && ch == "0" { onKeyAction?(.fit); return true }
        if flags == .command && ch == "1" { onKeyAction?(.actual100); return true }
        if flags.isEmpty && event.keyCode == 53 { onKeyAction?(.close); return true }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - 右侧参数检查器控件

/// 拼图工作室素材导入、高清拼图导出与多页 PDF 合并扩展
extension CollageStudioController {
    enum ExportAction { case copy, pin, save }

    func openSourceLightbox(startIndex: Int) {
        let list = items.map { CollageImageLightbox.Entry(title: $0.title, cgImage: $0.cgImage, scaleFactor: $0.scaleFactor) }
        lightbox.show(entries: list, startIndex: startIndex, showsCheckerboard: false)
    }

    func openCollageLightbox() {
        let refScale = items.last?.scaleFactor ?? 2.0
        if let edited = editedCollageOverride {
            lightbox.show(entries: [.init(title: "已标注拼图预览", cgImage: edited, scaleFactor: refScale)], startIndex: 0, showsCheckerboard: options.background == .transparent)
            return
        }
        let imgs = items.map(\.cgImage), opts = options
        guard !imgs.isEmpty else { return }
        Task { @MainActor [weak self] in
            let hd = await Task.detached(priority: .userInitiated) { ImageCollageStitcher.stitch(images: imgs, options: opts, maxRefSide: 2400) }.value
            guard let self, let hd else { return }
            self.lightbox.show(entries: [.init(title: "\(opts.layout.title)拼图预览", cgImage: hd, scaleFactor: refScale)], startIndex: 0, showsCheckerboard: opts.background == .transparent)
        }
    }

    func layoutTopBarMeta() {
        guard let tBar = topBarView else { return }
        let barH: CGFloat = 38, editing = inlineEditor.isActive
        titleLabel?.isHidden = editing
        metaPill?.isHidden = editing || (metaPill?.text.isEmpty ?? true)
        modeSeg?.isHidden = editing
        inlineEditor.topControlsView.isHidden = !editing
        inlineEditor.topControlsView.frame = NSRect(x: 74, y: 0, width: max(200, tBar.bounds.width - 74), height: barH)
        if !editing {
            titleLabel?.frame = NSRect(x: 78, y: 10, width: 74, height: 18)
            metaPill?.frame = NSRect(x: 154, y: 9, width: metaPill?.fittingWidth() ?? 0, height: 20)
            modeSeg?.frame = NSRect(x: tBar.bounds.width - 12 - 182, y: round((barH - 26) * 0.5), width: 182, height: 26)
        }
        if let close = window?.standardWindowButton(.closeButton), let mini = window?.standardWindowButton(.miniaturizeButton),
           let zoom = window?.standardWindowButton(.zoomButton), let sup = close.superview {
            let cy = round(sup.bounds.height - barH * 0.5 - close.frame.height * 0.5)
            close.setFrameOrigin(NSPoint(x: 14, y: cy)); mini.setFrameOrigin(NSPoint(x: 34, y: cy)); zoom.setFrameOrigin(NSPoint(x: 54, y: cy))
        }
    }

    func applyTheme() {
        window?.appearance = GeekTheme.windowAppearance; window?.backgroundColor = GeekTheme.windowBg
        titleLabel?.textColor = GeekTheme.inkPrimary; styleHeaderLabel?.textColor = GeekTheme.inkMuted
        [bgLabel, alignLabel, aspectLabel, badgeLabel, watermarkLabel].forEach { $0?.textColor = GeekTheme.inkSecondary }
        pdfHintLabel?.textColor = GeekTheme.inkMuted
        [rootView, topBarView, topBarDivider, metaPill, canvasView, stripDivider, div1, div2, div3, divExport].forEach { $0?.needsDisplay = true }
        lightbox.refreshAppearance()
    }

    func syncControlsFromOptions() {
        if let lIdx = CollageLayoutMode.allCases.firstIndex(of: options.layout) { layoutSeg?.selectedIndex = lIdx }
        colsSeg?.selectedIndex = min(2, max(0, options.gridColumns - 2))
        gapRow?.intValue = options.gapPx; padRow?.intValue = options.padPx; radiusRow?.intValue = Int(options.cornerRadiusPx)
        bgTrigger?.style = (studioMode == .pdfMerge && options.background == .transparent) ? .white : options.background
        bgTrigger?.customColor = options.customBackgroundColor; bgTrigger?.gradientPreset = options.gradientPreset
        shadowPill?.isOn = options.cardShadow
        alignSeg?.selectedIndex = options.scaleAlignment.rawValue; aspectSeg?.selectedIndex = options.aspectPreset.rawValue
        badgeSeg?.selectedIndex = options.badge.rawValue; pdfPageNumSeg?.selectedIndex = options.pdfPageNumber.rawValue
        watermarkSeg?.selectedIndex = options.watermark.rawValue; watermarkField?.stringValue = options.watermarkText
        syncPresetHighlight()
    }

    func presentBgColorPopover() {
        guard let anchor = bgTrigger else { return }
        colorPopover.show(anchoredTo: anchor, options: options, allowsTransparent: studioMode == .collage) { [weak self] sel in
            guard let self else { return }
            switch sel {
            case .transparent: self.options.background = .transparent; self.options.customBackgroundColor = nil
            case .gradient(let g): self.options.background = .gradient; self.options.gradientPreset = g; self.options.customBackgroundColor = nil
            case .solid(let rgb): self.options.background = .lightGray; self.options.customBackgroundColor = rgb
            }
            self.syncControlsFromOptions(); self.invalidateCollageEditsAndRender()
        }
    }

    func pickBackgroundFromScreen() {
        colorPopover.closeIfShown()
        NSColorSampler().show { [weak self] picked in
            guard let srgb = picked?.usingColorSpace(.sRGB) else { return }
            let rgb = RGBAColor(
                UInt8(min(255, max(0, Int((srgb.redComponent * 255).rounded())))),
                UInt8(min(255, max(0, Int((srgb.greenComponent * 255).rounded())))),
                UInt8(min(255, max(0, Int((srgb.blueComponent * 255).rounded()))))
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.options.background = .lightGray; self.options.customBackgroundColor = rgb
                self.syncControlsFromOptions(); self.invalidateCollageEditsAndRender()
            }
        }
    }

    func syncPresetHighlight() {
        presetBar?.selectedIndex = Self.presets.firstIndex { $0.gap == options.gapPx && $0.pad == options.padPx && $0.radius == Int(options.cornerRadiusPx) } ?? -1
    }

    func pickImageFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false; panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK { appendImageURLs(panel.urls) }
    }

    @discardableResult
    func appendImageURLs(_ urls: [URL]) -> Int {
        var added = 0
        for u in urls where u.isFileURL {
            guard let cg = ImageOrientationLoader.loadOrientedCGImage(from: u) else { continue }
            items.append(makeSourceItem(title: u.lastPathComponent, cgImage: cg, scaleFactor: 2.0)); added += 1
        }
        if added > 0 { reloadFilmstrip(); invalidateCollageEditsAndRender() }
        return added
    }

    func appendDroppedCGImages(_ images: [CGImage]) {
        guard !images.isEmpty else { return }
        for cg in images { items.append(makeSourceItem(title: "网页图片", cgImage: cg, scaleFactor: 2.0)) }
        reloadFilmstrip(); invalidateCollageEditsAndRender()
    }

    func appendFromClipboard() {
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty, appendImageURLs(urls) > 0 { return }
        guard let ns = ClipboardAndSave.readImageFromClipboard(), let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            ToastHUD.show(message: "剪贴板暂无图片"); return
        }
        items.append(makeSourceItem(title: "剪贴板图片", cgImage: cg, scaleFactor: 2.0))
        reloadFilmstrip(); invalidateCollageEditsAndRender()
    }

    func clearAllItems() {
        guard !items.isEmpty else { return }
        if items.count >= 2 || editedCollageOverride != nil {
            let alert = NSAlert()
            alert.messageText = "清空当前全部 \(items.count) 张素材？"
            alert.informativeText = editedCollageOverride != nil ? "已完成的拼图标注也将一并清除。" : "清空后可重新拖入图片或从最近截图添加。"
            alert.addButton(withTitle: "清空"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        items.removeAll(); clearDiscardedBackup(); reloadFilmstrip(); resetCollageEdits(); schedulePreviewRender()
    }

    func showRecentCapturesPicker() {
        guard let ring = historyRingProvider?(), let anchor = addRecentBtn else { return }
        let menu = NSMenu(); let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss"
        if ring.originalEntries.isEmpty {
            let empty = NSMenuItem(title: "暂无最近截图", action: nil, keyEquivalent: ""); empty.isEnabled = false; menu.addItem(empty)
        } else {
            for (idx, e) in ring.originalEntries.prefix(10).enumerated() {
                let it = NSMenuItem(title: "\(tf.string(from: e.createdAt)) · \(e.pixelWidth)×\(e.pixelHeight)", action: #selector(pickRecentItem(_:)), keyEquivalent: "")
                it.tag = idx; it.target = self; it.setVisibleImage(ring.menuThumbnail(for: e)); menu.addItem(it)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 2), in: anchor)
    }

    @objc func pickRecentItem(_ sender: NSMenuItem) {
        guard let ring = historyRingProvider?(), ring.originalEntries.indices.contains(sender.tag) else { return }
        let e = ring.originalEntries[sender.tag]
        guard let cg = ring.loadCGImage(for: e) else { return }
        let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss"
        items.append(makeSourceItem(title: "截图 \(tf.string(from: e.createdAt))", cgImage: cg, scaleFactor: e.scaleFactor))
        reloadFilmstrip(); invalidateCollageEditsAndRender()
    }

    func exportCollage(action: ExportAction) {
        let refScale = items.last?.scaleFactor ?? 2.0
        if let edited = editedCollageOverride { deliverStitchedExport(edited, scale: refScale, action: action); return }
        let imgs = items.map(\.cgImage), opts = options
        guard !imgs.isEmpty else { return }
        Task { @MainActor [weak self] in
            let hd = await Task.detached(priority: .userInitiated) { ImageCollageStitcher.stitch(images: imgs, options: opts, maxRefSide: 2400) }.value
            guard let self, let hd else { ToastHUD.show(message: "拼图合成失败"); return }
            self.deliverStitchedExport(hd, scale: refScale, action: action)
        }
    }

    func deliverStitchedExport(_ hd: CGImage, scale: CGFloat, action: ExportAction) {
        switch action {
        case .copy: onCopyCollage?(hd, scale)
        case .pin:  window?.close(); onPinCollage?(hd, scale)
        case .save: onSaveCollage?(hd, scale)
        }
    }

    func exportPDF() {
        let imgs = items.map(\.cgImage), opts = options, bg = opts.background == .transparent ? .white : opts.background
        guard !imgs.isEmpty else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]
        let tf = DateFormatter(); tf.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "MSnip-合并文档-\(tf.string(from: Date())).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            let ok = await Task.detached(priority: .userInitiated) {
                ImageCollageStitcher.exportMultiPagePDF(images: imgs, padPx: opts.padPx, background: bg, customBackgroundColor: opts.customBackgroundColor,
                                                        gradientPreset: opts.gradientPreset, watermark: opts.watermark, watermarkText: opts.watermarkText, pageNumber: opts.pdfPageNumber, to: url)
            }.value
            if ok {
                ToastHUD.show(message: "✓ 已合并导出 \(imgs.count) 页 PDF 文档", subtitle: url.lastPathComponent,
                              actionTitle: "在访达中显示", onAction: { ClipboardAndSave.revealInFinder(url) })
            } else { ToastHUD.show(message: "导出 PDF 失败") }
        }
    }

    func makeSourceItem(title: String, cgImage: CGImage, scaleFactor: CGFloat) -> CollageSourceItem {
        let thumb = ImageOrientationLoader.makeThumbnailNSImage(from: cgImage, maxPixelSize: 240)
        return CollageSourceItem(title: title, cgImage: cgImage, scaleFactor: scaleFactor, thumbnail: thumb)
    }

    func schedulePreviewRender() {
        renderSeq &+= 1; let isPDF = (studioMode == .pdfMerge)
        onOptionsChanged?(options)
        canvasView?.isPDFMode = isPDF
        canvasView?.pdfPadPx = options.padPx
        canvasView?.pdfBgStyle = options.background == .transparent ? .white : options.background
        canvasView?.pdfCustomBgColor = options.customBackgroundColor; canvasView?.pdfGradientPreset = options.gradientPreset
        canvasView?.pdfPageItems = items; canvasView?.pdfPageNumStyle = options.pdfPageNumber
        canvasView?.pdfWatermarkStyle = options.watermark; canvasView?.pdfWatermarkText = options.watermarkText
        canvasView?.showsCheckerboard = (options.background == .transparent)
        if isPDF {
            hasPendingPreviewRender = false
            metaPill?.text = items.isEmpty ? "" : "共 \(items.count) 页 · 原图无损"
            layoutTopBarMeta(); return
        }
        if let edited = editedCollageOverride {
            hasPendingPreviewRender = false
            canvasView?.previewImage = edited
            metaPill?.text = "\(items.count) 张 · \(edited.width)×\(edited.height) · 已标注"
            layoutTopBarMeta(); return
        }
        if items.isEmpty {
            hasPendingPreviewRender = false
            canvasView?.previewImage = nil; metaPill?.text = ""; layoutTopBarMeta(); return
        }
        if isRenderingPreview { hasPendingPreviewRender = true; return }
        runNextCoalescedPreviewRender()
    }

    /// 单飞合并渲染：滑条或 2D 色盘高频拖动时最多保持 1 个后台 CGContext 合成在途，消除并发内存峰值
    private func runNextCoalescedPreviewRender() {
        hasPendingPreviewRender = false
        let seq = renderSeq, imgs = items.map(\.cgImage), opts = options
        guard !imgs.isEmpty, studioMode == .collage, editedCollageOverride == nil else {
            isRenderingPreview = false; return
        }
        isRenderingPreview = true
        Task { @MainActor [weak self] in
            let preview = await Task.detached(priority: .userInitiated) {
                ImageCollageStitcher.stitch(images: imgs, options: opts, maxRefSide: 1440)
            }.value
            guard let self else { return }
            if self.renderSeq == seq {
                self.canvasView?.previewImage = preview
                let est = ImageCollageStitcher.estimatedCanvasSize(images: imgs, options: opts, maxRefSide: 2400)
                self.metaPill?.text = est.map { "\(imgs.count) 张 · \($0.width)×\($0.height)" } ?? ""
                self.layoutTopBarMeta()
            }
            if self.hasPendingPreviewRender {
                self.runNextCoalescedPreviewRender()
            } else {
                self.isRenderingPreview = false
            }
        }
    }
}
