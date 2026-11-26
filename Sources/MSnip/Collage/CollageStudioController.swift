import AppKit
import CoreGraphics
import Foundation
import MSnipCore

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

    let colorPopover = CollageColorPickerPopover()
    let inlineEditor = CollageInlineEditorView(frame: .zero)
    let lightbox = CollageImageLightbox()
    var renderSeq: UInt64 = 0
    var isRenderingPreview = false
    var hasPendingPreviewRender = false

    func present(initialEntries: [CaptureHistoryEntry] = [], initialImages: [(title: String, cgImage: CGImage, scale: CGFloat)] = []) {
        ensureWindowBuilt()
        inlineEditor.dismissInline(); resetCollageEdits(); items.removeAll()
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
        resetCollageEdits(); items.removeAll()
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
        win.minSize = NSSize(width: 720, height: 504); win.isReleasedWhenClosed = false
        win.appearance = GeekTheme.windowAppearance; win.backgroundColor = GeekTheme.windowBg; win.delegate = self
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
            if next == .pdfMerge && self.options.background == .transparent {
                self.options.background = .white; self.options.customBackgroundColor = nil
            }
            self.syncControlsFromOptions(); self.layoutUI(); self.schedulePreviewRender()
        }
        tBar.addSubview(mSeg)

        let canvas = CollagePreviewCanvasView(frame: .zero)
        canvas.onDropImageURLs = { [weak self] urls in self?.appendImageURLs(urls) }
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
