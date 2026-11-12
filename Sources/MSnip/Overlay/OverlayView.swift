import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 覆盖层交互阶段与拖拽状态
enum DragOperation {
    case pendingSnapOrCreate(anchor: CGPoint, snapRect: CGRect?)
    case creatingSelection(anchor: CGPoint)
    case movingSelection(initialRect: CGRect, mouseStart: CGPoint)
    case resizingSelection(handle: ResizeHandle, initialRect: CGRect, mouseStart: CGPoint)
    case drawingAnnotation(tool: ToolKind, start: CGPoint)
    case movingAnnotation(index: Int, lastPoint: CGPoint, moved: Bool)
}

/// 单块显示器的全屏冻结覆盖层画布（`isFlipped = true`，左上角为 `(0, 0)`）
final class OverlayView: NSView, NSTextFieldDelegate {
    let snapshot: ScreenSnapshot
    let regionDetector: RegionDetector
    private let frozenNSImage: NSImage
    let toolbar = ToolbarView()

    // 外部会话回调
    var onSelectionActivated: ((OverlayView) -> Void)?
    var onFinishCopy: ((CGImage, CGFloat, CGRect) -> Void)?
    var onFinishSave: ((CGImage, CGFloat, CGRect) -> Void)?
    var onFinishPin: ((CGImage, CGFloat, CGPoint, NSScreen, CGRect) -> Void)?
    var onFinishCopyColor: ((String, RGBAColor, NSPoint) -> Void)?
    var onFinishCopyText: ((String, NSPoint) -> Void)?
    var onFinishExtractText: ((CGImage, NSPoint, CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onStyleChanged: ((Int, CGFloat) -> Void)?
    var onPrefsChanged: ((ColorCopyFormat, Bool) -> Void)?

    // 自动矩阵识别预览与平滑过渡状态（逻辑见 OverlayAutoSnap.swift）
    var autoSnapStack: [CGRect] = []
    var autoSnapIndex: Int = 0
    var scrollSnapAccumulator: CGFloat = 0
    var preferredSnapArea: CGFloat?
    var displayedAutoRect: CGRect?
    var snapAnimTimer: Timer?

    var hoveredAutoRect: CGRect? {
        guard selection == nil, autoSnapStack.indices.contains(autoSnapIndex) else { return nil }
        return autoSnapStack[autoSnapIndex]
    }

    // PixPin 风格取色放大镜、快捷键提示与选区增强状态
    var lastMousePoint: CGPoint?
    var colorCopyFormat: ColorCopyFormat { didSet { needsDisplay = true } }
    var showShortcutTips: Bool { didSet { needsDisplay = true } }
    var lastHistorySelection: CGRect?
    var cornerRadiusPt: CGFloat = 0 { didSet { toolbar.cornerRadiusPt = cornerRadiusPt; needsDisplay = true } }
    var customPickedColor: RGBAColor? {
        didSet { toolbar.customColor = customPickedColor; if let c = customPickedColor { style.color = c } }
    }
    var eyedropperActive = false { didSet { toolbar.eyedropperActive = eyedropperActive; needsDisplay = true } }
    var optionPressed = false { didSet { if oldValue != optionPressed { needsDisplay = true } } }
    var magnifierPinned = false { didSet { needsDisplay = true } }
    var useRelativeCoordinates = false { didSet { needsDisplay = true } }
    var shiftTapCandidate = false

    // 正式选区与标注编辑状态
    var selection: CGRect? {
        didSet {
            if selection != nil { stopSnapGlide() }
            updateToolbarLayout()
            needsDisplay = true
        }
    }
    var doc = AnnotationDocument()
    var activeTool: ToolKind? {
        didSet {
            toolbar.activeTool = activeTool
            needsDisplay = true
        }
    }
    var colorIndex: Int = 0 {
        didSet {
            if customPickedColor == nil {
                style.color = RGBAColor.presets[min(max(0, colorIndex), RGBAColor.presets.count - 1)]
            }
            toolbar.colorIndex = colorIndex
        }
    }
    var style = AnnotationStyle()
    var selectedObjectIndex: Int? { didSet { needsDisplay = true } }
    var draftAnnotation: Annotation? { didSet { needsDisplay = true } }
    var dragOp: DragOperation?
    var spacePressed = false

    // 文本输入框状态（实现见 OverlayTextEdit.swift）
    var textField: NSTextField?
    var editingTextOrigin: CGPoint?
    var editingExistingIndex: Int?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(
        snapshot: ScreenSnapshot,
        regionDetector: RegionDetector,
        initialColorIndex: Int,
        initialLineWidth: CGFloat,
        colorCopyFormat: ColorCopyFormat,
        showShortcutTips: Bool,
        lastHistorySelection: CGRect?,
        pinHint: String
    ) {
        self.snapshot = snapshot
        self.regionDetector = regionDetector
        self.colorCopyFormat = colorCopyFormat
        self.showShortcutTips = showShortcutTips
        self.lastHistorySelection = lastHistorySelection
        let screenSize = snapshot.screen.frame.size
        self.frozenNSImage = NSImage(cgImage: snapshot.cgImage, size: screenSize)
        super.init(frame: NSRect(origin: .zero, size: screenSize))

        self.colorIndex = initialColorIndex
        self.style.color = RGBAColor.presets[min(max(0, initialColorIndex), RGBAColor.presets.count - 1)]
        self.style.lineWidth = initialLineWidth

        toolbar.colorIndex = initialColorIndex
        toolbar.lineWidth = initialLineWidth
        toolbar.pinHint = pinHint
        toolbar.isHidden = true
        toolbar.onAction = { [weak self] action in
            self?.handleToolbarAction(action)
        }
        addSubview(toolbar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { stopSnapGlide() }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        frozenNSImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0, respectFlipped: true, hints: nil)

        let highlightRect = selection ?? displayedAutoRect ?? hoveredAutoRect
        let activeRadius = (selection != nil && cornerRadiusPt > 0.5)
            ? min(cornerRadiusPt, min(selection!.width, selection!.height) * 0.5)
            : 0

        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.46).cgColor)
        if let hl = highlightRect, hl.width > 0, hl.height > 0 {
            ctx.addRect(bounds)
            if activeRadius > 0.5 {
                ctx.addPath(CGPath(roundedRect: hl, cornerWidth: activeRadius, cornerHeight: activeRadius, transform: nil))
            } else {
                ctx.addRect(hl)
            }
            ctx.fillPath(using: .evenOdd)
        } else {
            ctx.fill(bounds)
        }
        ctx.restoreGState()

        if selection == nil {
            if let target = hoveredAutoRect {
                drawAutoSnapChrome(ctx: ctx, displayRect: displayedAutoRect ?? target, targetRect: target)
            }
            drawShortcutTipsHUD(ctx: ctx)
            drawCursorMagnifier(ctx: ctx)
            return
        }

        guard let sel = selection, sel.width >= 1, sel.height >= 1 else {
            drawShortcutTipsHUD(ctx: ctx)
            drawCursorMagnifier(ctx: ctx)
            return
        }

        ctx.saveGState()
        if activeRadius > 0.5 {
            ctx.addPath(CGPath(roundedRect: sel, cornerWidth: activeRadius, cornerHeight: activeRadius, transform: nil))
            ctx.clip()
        }
        AnnotationRenderer.drawAnnotations(
            in: ctx,
            annotations: doc.objects,
            draft: draftAnnotation,
            skipIndex: editingExistingIndex,
            sampler: snapshot.sampler,
            imageScale: snapshot.scaleFactor,
            clipRect: sel
        )
        ctx.restoreGState()

        if let idx = selectedObjectIndex, doc.objects.indices.contains(idx) {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.systemCyan.cgColor)
            ctx.setLineWidth(1.2)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(doc.objects[idx].bounds)
            ctx.restoreGState()
        }

        drawSelectionChrome(ctx: ctx, sel: sel, cornerRadius: activeRadius)
        drawShortcutTipsHUD(ctx: ctx)
        drawCursorMagnifier(ctx: ctx)
    }

    private func drawSelectionChrome(ctx: CGContext, sel: CGRect, cornerRadius: CGFloat) {
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5)
        if cornerRadius > 0.5 {
            ctx.addPath(CGPath(roundedRect: sel, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
            ctx.strokePath()
        } else {
            ctx.stroke(sel)
        }

        for handle in ResizeHandle.allCases {
            let p = handle.point(in: sel)
            let hr = CGRect(x: p.x - 4.0, y: p.y - 4.0, width: 8.0, height: 8.0)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: hr)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: hr)
        }
        ctx.restoreGState()

        let pxW = Int((sel.width * snapshot.scaleFactor).rounded())
        let pxH = Int((sel.height * snapshot.scaleFactor).rounded())
        let cornerSuffix = cornerRadius > 0.5 ? "  ·  圆角 \(Int(cornerRadiusPt))pt" : ""
        drawHUDPill(ctx: ctx, anchorRect: sel, text: "\(pxW) × \(pxH)\(cornerSuffix)")
    }

    func updateToolbarLayout() {
        toolbar.canUndo = doc.canUndo
        toolbar.canRedo = doc.canRedo
        toolbar.refreshState()

        guard let sel = selection, sel.width >= 6, sel.height >= 6 else {
            toolbar.isHidden = true
            return
        }
        toolbar.isHidden = false
        let barSize = toolbar.frame.size
        let x = min(max(8, sel.maxX - barSize.width), bounds.width - barSize.width - 8)
        let belowY = sel.maxY + 8
        let aboveY = sel.minY - barSize.height - 8
        let y = (belowY + barSize.height + 8 <= bounds.height)
            ? belowY
            : (aboveY >= 8 ? aboveY : max(8, sel.maxY - barSize.height - 8))
        toolbar.setFrameOrigin(NSPoint(x: round(x), y: round(y)))
    }

    func clearSelectionFromSibling() {
        cancelTextEditing()
        stopSnapGlide()
        selection = nil
        lastMousePoint = nil
        eyedropperActive = false
        autoSnapStack = []
        displayedAutoRect = nil
        preferredSnapArea = nil
        selectedObjectIndex = nil
        draftAnnotation = nil
        doc = AnnotationDocument()
    }
}
