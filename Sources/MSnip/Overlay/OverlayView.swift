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

/// 单块显示器的全屏冻结覆盖层画布（`isFlipped = true`，左上角为 `(0, 0)`，支持页内识字、双层工具栏与局部脏区重绘）
final class OverlayView: NSView, NSTextFieldDelegate {
    let snapshot: ScreenSnapshot
    let regionDetector: RegionDetector
    let toolbar = ToolbarView()
    let subbar = ToolbarSubbarView()
    let sidePills = OverlaySidePillsView()
    var inPlaceOCRView: LiveTextImageView?
    var inPlaceTranslateView: InPlaceTranslationOverlayView?
    var manualToolbarOrigin: NSPoint?

    // 外部会话回调
    var onSelectionActivated: ((OverlayView) -> Void)?
    var onFinishCopy: ((CGImage, CGFloat, CGRect) -> Void)?
    var onFinishSave: ((CGImage, CGFloat, CGRect) -> Void)?
    var onQuickSaveInPlace: ((CGImage, CGFloat, CGRect) -> Void)?
    var onFinishPin: ((CGImage, CGFloat, CGPoint, NSScreen, CGRect) -> Void)?
    var onFinishIsolatedWindow: ((CGWindowID, CGFloat, BackdropStyle, Bool, CGPoint, NSScreen) -> Void)?
    var onFinishCopyColor: ((String, RGBAColor, NSPoint) -> Void)?
    var onFinishCopyText: ((String, NSPoint) -> Void)?
    var onFinishExtractText: ((CGImage, CGFloat, NSScreen, CGRect) -> Void)?
    var onFinishTranslateWindow: ((CGImage, CGFloat, NSScreen, CGRect) -> Void)?
    var onOpenTranslationSettings: (() -> Void)?
    var onStartLongShot: ((NSScreen, CGRect, CGImage?) -> Void)?
    var onStartRecording: ((NSScreen, CGRect, CGImage?) -> Void)?
    var onCancel: (() -> Void)?
    var onStyleChanged: ((Int, CGFloat) -> Void)?
    var onCapsuleChanged: ((Bool) -> Void)?
    var onPrefsChanged: ((ColorCopyFormat, Bool) -> Void)?
    var quickOCRMode = false
    var quickTranslateMode = false

    // 自动矩阵识别预览与平滑过渡状态
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
    var colorCopyFormat: ColorCopyFormat { didSet { invalidateMagnifierAtCurrentMouse() } }
    var showShortcutTips: Bool { didSet { needsDisplay = true } }
    var lastHistorySelection: CGRect?
    var cornerRadiusPt: CGFloat = 0 { didSet { toolbar.cornerRadiusPt = cornerRadiusPt; needsDisplay = true } }
    var backdropStyle: BackdropStyle = .none { didSet { toolbar.backdropStyle = backdropStyle; needsDisplay = true } }
    var customPickedColor: RGBAColor? {
        didSet {
            toolbar.customColor = customPickedColor
            subbar.customColor = customPickedColor
            if let c = customPickedColor { style.color = c }
        }
    }
    var eyedropperActive = false {
        didSet {
            toolbar.eyedropperActive = eyedropperActive
            subbar.eyedropperActive = eyedropperActive
            needsDisplay = true
        }
    }
    var optionPressed = false { didSet { if oldValue != optionPressed { needsDisplay = true } } }
    var magnifierPinned = false { didSet { needsDisplay = true } }
    var useRelativeCoordinates = false { didSet { invalidateMagnifierAtCurrentMouse() } }
    var shiftTapCandidate = false

    // 正式选区与标注编辑状态
    var selection: CGRect? {
        didSet {
            if selection != nil { stopSnapGlide() } else { manualToolbarOrigin = nil }
            updateToolbarLayout()
            needsDisplay = true
        }
    }
    var doc = AnnotationDocument()
    var activeTool: ToolKind? {
        didSet {
            toolbar.activeTool = activeTool
            subbar.activeTool = activeTool
            invalidateMagnifierAtCurrentMouse()
        }
    }
    var colorIndex: Int = 0 {
        didSet {
            if customPickedColor == nil {
                style.color = RGBAColor.presets[min(max(0, colorIndex), RGBAColor.presets.count - 1)]
            }
            toolbar.colorIndex = colorIndex
            subbar.colorIndex = colorIndex
        }
    }
    var style = AnnotationStyle()
    var selectedObjectIndex: Int? { didSet { updateToolbarLayout(); needsDisplay = true } }
    var draftAnnotation: Annotation? {
        didSet {
            if let o = oldValue { setNeedsDisplay(o.bounds.insetBy(dx: -14, dy: -14)) }
            if let n = draftAnnotation { setNeedsDisplay(n.bounds.insetBy(dx: -14, dy: -14)) }
        }
    }
    var dragOp: DragOperation?
    var spacePressed = false

    // 文本输入框状态
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
        super.init(frame: NSRect(origin: .zero, size: screenSize))

        self.colorIndex = initialColorIndex
        self.style.color = RGBAColor.presets[min(max(0, initialColorIndex), RGBAColor.presets.count - 1)]
        self.style.lineWidth = initialLineWidth

        toolbar.colorIndex = initialColorIndex
        toolbar.lineWidth = initialLineWidth
        toolbar.pinHint = pinHint
        toolbar.isHidden = true
        toolbar.onAction = { [weak self] action in self?.handleToolbarAction(action) }
        toolbar.onDraggedOrigin = { [weak self] origin in
            self?.manualToolbarOrigin = origin
            self?.repositionSubbar()
        }

        subbar.colorIndex = initialColorIndex
        subbar.lineWidth = initialLineWidth
        subbar.isHidden = true
        subbar.onAction = { [weak self] action in self?.handleToolbarAction(action) }

        sidePills.isHidden = true
        sidePills.onAction = { [weak self] act in
            guard let self else { return }
            switch act {
            case .cycleCorner:   self.cycleCornerRadius()
            case .cycleBackdrop: self.cycleBackdropStyle()
            case .snapWindow(let opt):
                if opt { self.captureCurrentWindowAndFinish(pin: false) }
                else { self.snapSelectionToUnderlyingWindow() }
            }
        }

        addSubview(sidePills)
        addSubview(toolbar)
        addSubview(subbar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil
        ))
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { stopSnapGlide() }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let clip = dirtyRect.intersection(bounds)
        guard !clip.isNull, clip.width > 0, clip.height > 0,
              let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: clip)

        drawFrozenBackgroundSlice(in: ctx, dirtyRect: clip)

        let highlightRect = selection ?? displayedAutoRect ?? hoveredAutoRect
        let activeRadius = (selection != nil && cornerRadiusPt > 0.5)
            ? min(cornerRadiusPt, min(selection!.width, selection!.height) * 0.5)
            : 0

        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.46).cgColor)
        if let hl = highlightRect, hl.width > 0, hl.height > 0 {
            ctx.addRect(clip.insetBy(dx: -2, dy: -2))
            if activeRadius > 0.5 {
                ctx.addPath(CGPath(roundedRect: hl, cornerWidth: activeRadius, cornerHeight: activeRadius, transform: nil))
            } else {
                ctx.addRect(hl)
            }
            ctx.fillPath(using: .evenOdd)
        } else {
            ctx.fill(clip)
        }
        ctx.restoreGState()

        if selection == nil {
            if let target = hoveredAutoRect {
                let disp = displayedAutoRect ?? target
                if autoSnapDirtyBounds(for: disp).intersects(clip) {
                    drawAutoSnapChrome(ctx: ctx, displayRect: disp, targetRect: target)
                }
            }
            drawShortcutTipsHUD(ctx: ctx, dirtyRect: clip)
            drawCursorMagnifier(ctx: ctx, dirtyRect: clip)
            return
        }

        guard let sel = selection, sel.width >= 1, sel.height >= 1 else {
            drawShortcutTipsHUD(ctx: ctx, dirtyRect: clip)
            drawCursorMagnifier(ctx: ctx, dirtyRect: clip)
            return
        }

        drawLiveBackdropFrameIfNeeded(ctx: ctx, sel: sel, cornerRadius: activeRadius)

        if sel.intersects(clip), inPlaceOCRView == nil, inPlaceTranslateView == nil {
            ctx.saveGState()
            if activeRadius > 0.5 {
                ctx.addPath(CGPath(roundedRect: sel, cornerWidth: activeRadius, cornerHeight: activeRadius, transform: nil))
                ctx.clip()
            }
            AnnotationRenderer.drawAnnotations(
                in: ctx, annotations: doc.objects, draft: draftAnnotation,
                skipIndex: editingExistingIndex, sampler: snapshot.sampler,
                imageScale: snapshot.scaleFactor, clipRect: sel
            )
            ctx.restoreGState()
        }

        if let idx = selectedObjectIndex, doc.objects.indices.contains(idx) {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.systemCyan.cgColor)
            ctx.setLineWidth(1.2)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(doc.objects[idx].bounds)
            ctx.restoreGState()
        }

        drawSelectionChrome(ctx: ctx, sel: sel, cornerRadius: activeRadius)
        drawShortcutTipsHUD(ctx: ctx, dirtyRect: clip)
        drawCursorMagnifier(ctx: ctx, dirtyRect: clip)
    }
}
