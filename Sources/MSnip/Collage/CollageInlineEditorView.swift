import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 拼图工作室原窗口内嵌图片编辑器（零新开窗口：复用工作室顶栏与主舞台，支持单张素材与合成拼图的裁剪/旋转/翻转/11种标注/隐私打码）
@MainActor
final class CollageInlineEditorView: NSView {
    enum Mode {
        case sourceItem(index: Int, hasBackup: Bool)
        case stitchedCollage(hasRevert: Bool)
    }

    var onBack: (() -> Void)?
    var onApplySourceItem: ((Int, CGImage) -> Void)?
    var onRevertSourceItem: ((Int) -> Void)?
    var onCommitStitched: ((CGImage, CGImage, AnnotationDocument, Bool) -> Void)?
    var onRevertStitched: (() -> Void)?
    var onExportStitched: ((CGImage, CGFloat, CollageStudioController.ExportAction) -> Void)?

    let topControlsView = GeekFlippedView(frame: .zero)
    var backBtn, cropBtn, rotateBtn, flipBtn, revertBtn: GeekButton?
    var copyOutBtn, pinOutBtn, saveOutBtn, primaryBtn: GeekButton?
    var titleLabel: NSTextField?

    var stageWell: CollageEditorBackdropWellView?
    var imageStageView: CollageEditorImageStageView?
    var annotationCanvas: PinAnnotationCanvasView?
    var cropOverlay: PinCropOverlayView?
    var botDiv, bottomDock: GeekSurfaceView?
    let toolbarView = ToolbarView()
    let subbarView = ToolbarSubbarView()

    private(set) var isActive = false
    var mode: Mode = .stitchedCollage(hasRevert: false)
    var baseImage: CGImage?
    var imageScale: CGFloat = 2.0
    var fitZoom: CGFloat = 1.0
    var geometryModified = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        topControlsView.isHidden = true
        buildUI()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        let tLbl = NSTextField(labelWithString: "")
        tLbl.font = .systemFont(ofSize: 12.0, weight: .semibold)
        tLbl.lineBreakMode = .byTruncatingTail
        topControlsView.addSubview(tLbl)
        titleLabel = tLbl

        func tBtn(_ title: String, sym: String? = nil, style: GeekButton.Style = .subtle, tip: String? = nil, action: @escaping () -> Void) -> GeekButton {
            let b = GeekButton(title: title, symbol: sym, style: style); b.toolTip = tip; b.onClick = action
            topControlsView.addSubview(b); return b
        }
        backBtn = tBtn("返回", sym: "chevron.left", style: .subtle, tip: "返回拼图工作台 (Esc)") { [weak self] in self?.cancelAndExit() }
        cropBtn = tBtn("裁剪", sym: "crop", tip: "自由框选裁剪画面") { [weak self] in self?.toggleCropMode() }
        rotateBtn = tBtn("旋转", sym: "rotate.right", tip: "顺时针无损旋转 90°") { [weak self] in self?.applyGeometryTransform(ImageTransform.rotateClockwise90) }
        flipBtn = tBtn("翻转", sym: "arrow.left.and.right.righttriangle.left.righttriangle.right", tip: "水平镜像翻转") { [weak self] in self?.applyGeometryTransform(ImageTransform.flipHorizontal) }
        revertBtn = tBtn("还原", sym: "arrow.uturn.backward", style: .amberSoft, tip: "恢复编辑前初始图像") { [weak self] in self?.handleRevertAction() }

        copyOutBtn = tBtn("复制", sym: "doc.on.doc", tip: "复制标注后的成品到剪贴板 (⌘C)") { [weak self] in self?.finishWithExport(.copy) }
        pinOutBtn = tBtn("贴图", sym: "pin", tip: "将标注后的成品贴到桌面") { [weak self] in self?.finishWithExport(.pin) }
        saveOutBtn = tBtn("保存", sym: "square.and.arrow.down", tip: "保存标注后的高清图片 (⌘S)") { [weak self] in self?.finishWithExport(.save) }
        primaryBtn = tBtn("完成 (↩)", sym: "checkmark", style: .accent, tip: "应用当前修改并返回 (↩)") { [weak self] in self?.commitPrimaryAction() }

        let well = CollageEditorBackdropWellView(frame: .zero)
        addSubview(well)
        let imgV = CollageEditorImageStageView(frame: .zero)
        well.addSubview(imgV)

        let bDiv = GeekSurfaceView(frame: .zero, fill: GeekTheme.divider); addSubview(bDiv)
        let bDock = GeekSurfaceView(frame: .zero, fill: GeekTheme.barBg); addSubview(bDock)
        toolbarView.isPinEditorMode = true; toolbarView.activeTool = .arrow
        subbarView.isPinEditorMode = true; subbarView.activeTool = .arrow
        bDock.addSubview(toolbarView); bDock.addSubview(subbarView)

        let handleBar: (ToolbarView.Action) -> Void = { [weak self] act in self?.handleToolbarAction(act) }
        toolbarView.onAction = handleBar; subbarView.onAction = handleBar

        stageWell = well; imageStageView = imgV; botDiv = bDiv; bottomDock = bDock
    }

    func enter(
        title: String,
        cgImage: CGImage,
        scaleFactor: CGFloat,
        mode: Mode,
        initialDoc: AnnotationDocument = AnnotationDocument(),
        alreadyModifiedGeometry: Bool = false
    ) {
        self.isActive = true
        self.mode = mode
        self.imageScale = max(1.0, scaleFactor)
        self.geometryModified = alreadyModifiedGeometry
        self.isHidden = false
        self.topControlsView.isHidden = false
        titleLabel?.textColor = GeekTheme.inkPrimary

        if toolbarView.activeTool == nil {
            toolbarView.activeTool = .arrow; subbarView.activeTool = .arrow
        }
        loadBaseImage(cgImage, titlePrefix: title, initialDoc: initialDoc)
        configureHeaderButtons()
        layoutEditor()
        if let canvas = annotationCanvas { window?.makeFirstResponder(canvas) }
    }

    func dismissInline() {
        guard isActive || baseImage != nil else { return }
        isActive = false
        isHidden = true
        topControlsView.isHidden = true
        cropOverlay?.removeFromSuperview(); cropOverlay = nil; cropBtn?.style = .subtle
        annotationCanvas?.commitTextField()
        annotationCanvas?.removeFromSuperview(); annotationCanvas = nil
        imageStageView?.cgImage = nil
        baseImage = nil
        AnnotationRenderer.purgeCaches()
    }

    func cancelAndExit() {
        if let ov = cropOverlay {
            ov.removeFromSuperview(); cropOverlay = nil; cropBtn?.style = .subtle
            if let c = annotationCanvas { window?.makeFirstResponder(c) }
            return
        }
        dismissInline()
        onBack?()
    }

    func layoutEditor() {
        let tw = topControlsView.bounds.width, th = topControlsView.bounds.height
        let cy = round((th - 25) * 0.5)
        backBtn?.frame = NSRect(x: 2, y: cy, width: 56, height: 25)

        var rx = tw - 10
        switch mode {
        case .sourceItem:
            let pw: CGFloat = 108
            rx -= pw; primaryBtn?.frame = NSRect(x: rx, y: cy, width: pw, height: 25)
        case .stitchedCollage:
            let pw: CGFloat = 82
            rx -= pw; primaryBtn?.frame = NSRect(x: rx, y: cy, width: pw, height: 25)
            for b in [saveOutBtn, pinOutBtn, copyOutBtn] {
                rx -= 59; b?.frame = NSRect(x: rx, y: cy, width: 54, height: 25)
            }
        }

        let geoBtns = [cropBtn, rotateBtn, flipBtn, revertBtn].compactMap { $0 }.filter { !$0.isHidden }
        let geoW = CGFloat(geoBtns.count) * 56 + CGFloat(max(0, geoBtns.count - 1)) * 5
        var gx = max(140, rx - geoW - 12)
        for b in geoBtns {
            b.frame = NSRect(x: gx, y: cy, width: 56, height: 25); gx += 61
        }
        let titleMaxW = max(60, (geoBtns.first?.frame.minX ?? rx) - 70)
        titleLabel?.frame = NSRect(x: 64, y: round((th - 18) * 0.5), width: titleMaxW, height: 18)

        let w = bounds.width, h = bounds.height
        let showSub = (annotationCanvas?.activeTool != nil)
        let dockH: CGFloat = showSub ? 88 : 50
        botDiv?.frame = NSRect(x: 0, y: h - dockH - 1, width: w, height: 1)
        bottomDock?.frame = NSRect(x: 0, y: h - dockH, width: w, height: dockH)
        toolbarView.frame.origin = NSPoint(x: round((w - toolbarView.frame.width) * 0.5), y: 6)
        if showSub {
            subbarView.frame.origin = NSPoint(x: round((w - subbarView.frame.width) * 0.5), y: 6 + ToolbarView.barHeight + 4)
        }

        let wellRect = NSRect(x: 10, y: 9, width: max(120, w - 20), height: max(120, h - dockH - 18))
        stageWell?.frame = wellRect
        if baseImage != nil, let canvas = annotationCanvas {
            let availW = max(40, wellRect.width - 20), availH = max(40, wellRect.height - 20)
            fitZoom = max(0.05, min(availW / max(1, canvas.baseSize.width), availH / max(1, canvas.baseSize.height)))
            let dw = round(canvas.baseSize.width * fitZoom), dh = round(canvas.baseSize.height * fitZoom)
            let imgR = NSRect(x: round((wellRect.width - dw) * 0.5), y: round((wellRect.height - dh) * 0.5), width: dw, height: dh)
            stageWell?.imageFrame = imgR
            imageStageView?.frame = imgR; canvas.frame = imgR; cropOverlay?.frame = imgR
        }
    }
}

/// 与预览主画布同款的点阵暗房舞台（让进入/退出原窗口内嵌标注毫无割裂感）
final class CollageEditorBackdropWellView: NSView {
    var imageFrame: NSRect = .zero { didSet { if oldValue != imageFrame { needsDisplay = true } } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let isDark = GeekTheme.isDark
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = CGPath(roundedRect: r, cornerWidth: 11.5, cornerHeight: 11.5, transform: nil)
        ctx.saveGState()
        let bg = isDark ? NSColor(srgbRed: 0.088, green: 0.098, blue: 0.120, alpha: 1) : NSColor(srgbRed: 0.925, green: 0.936, blue: 0.956, alpha: 1)
        ctx.setFillColor(bg.cgColor); ctx.addPath(p); ctx.fillPath()
        ctx.addPath(p); ctx.clip()
        ctx.setFillColor((isDark ? NSColor(white: 1, alpha: 0.055) : NSColor(srgbRed: 0.1, green: 0.16, blue: 0.28, alpha: 0.065)).cgColor)
        var gy: CGFloat = 12
        while gy < bounds.height - 6 {
            var gx: CGFloat = 12
            while gx < bounds.width - 6 { ctx.fillEllipse(in: CGRect(x: gx, y: gy, width: 1.3, height: 1.3)); gx += 16 }
            gy += 16
        }
        if imageFrame.width > 4 && imageFrame.height > 4 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 5), blur: 18, color: NSColor.black.withAlphaComponent(isDark ? 0.50 : 0.16).cgColor)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.2).cgColor)
            ctx.fill(imageFrame)
            ctx.restoreGState()
        }
        ctx.restoreGState()
        ctx.saveGState()
        ctx.setStrokeColor(GeekTheme.border.cgColor); ctx.setLineWidth(1.0); ctx.addPath(p); ctx.strokePath()
        ctx.restoreGState()
    }
}

final class CollageEditorImageStageView: NSView {
    var cgImage: CGImage? { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let cg = cgImage, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        let isDark = GeekTheme.isDark
        ctx.setFillColor((isDark ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.96, alpha: 1)).cgColor); ctx.fill(bounds)
        ctx.setFillColor((isDark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.88, alpha: 1)).cgColor)
        var y: CGFloat = 0, row = 0
        while y < bounds.height {
            var x: CGFloat = (row % 2 == 0) ? 0 : 10
            while x < bounds.width { ctx.fill(CGRect(x: x, y: y, width: 10, height: 10)); x += 20 }
            y += 10; row += 1
        }
        NSImage(cgImage: cg, size: bounds.size).draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
        ctx.restoreGState()
    }
}

/// 顶栏标题旁轻量等宽像素元信息胶囊（如 `2 张 · 2448×579`）
final class CollageMetaPillView: NSView {
    var text: String = "" { didSet { if oldValue != text { isHidden = text.isEmpty; needsDisplay = true } } }
    override var isFlipped: Bool { true }

    func fittingWidth() -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return ceil(GeekTheme.measureTextWidth(text, font: .monospacedDigitSystemFont(ofSize: 10.2, weight: .medium))) + 14
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = CGPath(roundedRect: r, cornerWidth: r.height * 0.5, cornerHeight: r.height * 0.5, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(GeekTheme.pillSubtle.cgColor); ctx.addPath(p); ctx.fillPath()
        ctx.setStrokeColor(GeekTheme.border.cgColor); ctx.setLineWidth(0.75); ctx.addPath(p); ctx.strokePath()
        GeekTheme.drawText(text, in: r, font: .monospacedDigitSystemFont(ofSize: 10.2, weight: .medium), color: GeekTheme.inkSecondary, align: .center)
        ctx.restoreGState()
    }
}
