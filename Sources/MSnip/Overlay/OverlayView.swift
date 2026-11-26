import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 单块显示器的全屏冻结覆盖层画布（`isFlipped = true`，左上角为 `(0, 0)`，支持页内识字、双层工具栏与局部脏区重绘）
final class OverlayView: NSView, NSTextFieldDelegate {
    let snapshot: ScreenSnapshot
    let regionDetector: RegionDetector
    let toolbar = ToolbarView()
    let subbar = ToolbarSubbarView()
    let sidePills = OverlaySidePillsView()
    let cornerSlider = OverlayCornerSliderView()
    let saveMenu = OverlaySaveMenuView()
    let caliperView = OverlayCaliperLayerView()
    let magnifierView = OverlayMagnifierLayerView()
    let dimSnapView = OverlayDimAndSnapView()
    let hudPillView = OverlayHudPillView()
    let shortcutTipsView = OverlayShortcutTipsView()
    var inPlaceOCRView: LiveTextImageView?
    var inPlaceTranslateView: InPlaceTranslationOverlayView?
    var manualToolbarOrigin: NSPoint?
    var appliedCursorKind: OverlayCursorKind?
    var lastMagnifierKey: String = ""
    var cachedTipsTriggerZone: CGRect = .zero

    // 外部会话回调
    var onSelectionActivated: ((OverlayView) -> Void)?
    var onFinishCopy: ((CGImage, CGFloat, CGRect) -> Void)?
    var onFinishCopyWithPath: ((CGImage, CGFloat, CGRect) -> Void)?
    var onFinishSave: ((CGImage, CGFloat, CGRect) -> Void)?
    var onFinishSaveToFolder: ((CGImage, CGFloat, String, CGRect) -> Void)?
    var onQuickSaveInPlace: ((CGImage, CGFloat, CGRect) -> Void)?
    var onFinishPin: ((CGImage, CGFloat, CGPoint, NSScreen, CGRect, CGFloat?) -> Void)?
    var onFinishIsolatedWindow: ((CGWindowID, CGFloat, BackdropStyle, Bool, CGPoint, NSScreen) -> Void)?
    var onFinishCopyColor: ((String, RGBAColor, NSPoint) -> Void)?
    var onFinishCopyText: ((String, NSPoint) -> Void)?
    var onFinishExtractText: ((CGImage, CGFloat, NSScreen, CGRect) -> Void)?
    var onFinishSilentOCR: ((CGImage, CGFloat, NSScreen, CGRect) -> Void)?
    var onFinishRecognizeLatex: ((CGImage, CGFloat, NSScreen, CGRect) -> Void)?
    var onFinishTranslateWindow: ((CGImage, CGFloat, NSScreen, CGRect) -> Void)?
    var onOpenTranslationSettings: (() -> Void)?
    var onStartLongShot: ((NSScreen, CGRect, CGImage?) -> Void)?
    var onStartRecording: ((NSScreen, CGRect, CGImage?) -> Void)?
    var onCancel: (() -> Void)?
    var onStyleChanged: ((Int, CGFloat) -> Void)?
    var onCapsuleChanged: ((Bool) -> Void)?
    var onPrefsChanged: ((ColorCopyFormat, Bool) -> Void)?
    var onRecordingPrefsChanged: ((RecordingFormat, Bool) -> Void)?
    var onRecordingModeChanged: ((Bool) -> Void)?
    var onGlowStrengthChanged: ((CGFloat) -> Void)?
    var isRecordingMode: Bool { toolbar.isRecordingMode }
    var quickLaunchMode: OverlayQuickLaunchMode = .standard
    var canvasKeyMap: [CanvasAction: String] = CanvasAction.defaultMap
    var activePinCombo: KeyCombo?
    var ocrPresentation: OCRDefaultPresentation = .inPlace
    var translateAutoOpenDualPane: Bool = false; var ocrAutoCopy: Bool = true
    var backdropAspectRatio: BackdropAspectRatio = .auto; var backdropWatermark: String = ""
    var defaultPinGlowStrength: CGFloat = 0.45; var didAdjustGlow: Bool = false
    var magnifierLegendCache: (key: String, image: CGImage)?; var barcodeScanTask: Task<Void, Never>?
    var copiedAnnotation: Annotation?; var pasteCascadeCount: Int = 0

    func keyUpper(_ action: CanvasAction) -> String {
        (canvasKeyMap[action] ?? action.defaultKey).uppercased()
    }

    // 自动矩阵识别内聚状态
    var autoSnap = OverlayAutoSnapState()
    var hoveredAutoRect: CGRect? { autoSnap.hoveredRect(hasSelection: selection != nil) }

    // 取色放大镜、快捷键提示与选区增强状态
    var lastMousePoint: CGPoint?
    var colorCopyFormat: ColorCopyFormat { didSet { syncMagnifierView() } }
    var showShortcutTips: Bool { didSet { syncShortcutTipsView() } }
    var lastHistorySelection: CGRect?
    var activeSideSlider: OverlaySideSliderMode?
    var isSaveMenuVisible = false
    var saveFolderOptions: [QuickSaveFolder] = []
    var cornerRadiusRatio: CGFloat = 0 {
        didSet {
            toolbar.cornerRadiusPt = cornerRadiusPt
            sidePills.hasCorner = (cornerRadiusRatio > 0.005 || activeSideSlider == .corner)
            if activeSideSlider == .corner { cornerSlider.ratio = cornerRadiusRatio }
            syncGPUChromeLayers()
            if (oldValue > 0.005) != (cornerRadiusRatio > 0.005) { needsDisplay = true }
            else if let sel = selection { setNeedsDisplay(selectionDirtyBounds(for: sel)) }
        }
    }
    var glowStrength: CGFloat = 0 {
        didSet {
            sidePills.hasGlow = (glowStrength > 0.005 || activeSideSlider == .glow)
            if activeSideSlider == .glow { cornerSlider.ratio = glowStrength }
            syncGPUChromeLayers()
            if let sel = selection { setNeedsDisplay(selectionDirtyBounds(for: sel)) }
        }
    }
    var cornerRadiusPt: CGFloat {
        guard let sel = selection ?? hoveredAutoRect, cornerRadiusRatio > 0.005 else { return 0 }
        return min(sel.width, sel.height) * 0.5 * min(1.0, max(0.0, cornerRadiusRatio))
    }
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
            syncMagnifierView()
        }
    }
    var optionPressed = false { didSet { if oldValue != optionPressed { syncMagnifierView() } } }
    var magnifierVisibilityOverride: Bool? = nil { didSet { syncMagnifierView() } }
    var caliperActive = false {
        didSet {
            if oldValue != caliperActive {
                syncCaliperView(); syncMagnifierView(); syncGPUChromeLayers()
            }
        }
    }
    var useRelativeCoordinates = false { didSet { syncMagnifierView() } }
    var shiftTapCandidate = false

    // 正式选区与标注编辑状态
    var selection: CGRect? {
        didSet {
            if selection != nil { stopSnapGlide() } else { manualToolbarOrigin = nil }
            updateToolbarLayout()
            invalidateSelectionTransition(from: oldValue, to: selection)
            syncMagnifierView()
        }
    }
    var doc = AnnotationDocument()
    var activeTool: ToolKind? {
        didSet { toolbar.activeTool = activeTool; subbar.activeTool = activeTool; syncMagnifierView() }
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
        super.init(frame: NSRect(origin: .zero, size: snapshot.screen.frame.size))

        self.colorIndex = initialColorIndex
        self.style.color = RGBAColor.presets[min(max(0, initialColorIndex), RGBAColor.presets.count - 1)]
        let initW = min(ToolbarSubbarView.maxStroke, max(ToolbarSubbarView.minStroke, initialLineWidth.rounded()))
        self.style.lineWidth = initW
        self.style.fontSize = min(64.0, max(12.0, round(10.0 + initW * 3.0)))
        self.style.mosaicBlockSize = min(36.0, max(5.0, round(4.0 + initW * 1.8)))
        setupFloatingControls(initialColorIndex: initialColorIndex, initialLineWidth: initW, pinHint: pinHint)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
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
        if newWindow == nil { stopOverlayVSync() }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // 未锁定选区期间：暗化遮罩、蓝框、尺寸胶囊、快捷键提示卡、放大镜与卡尺均由独立 GPU 图层承载，零主画布重绘！
        guard let sel = selection, sel.width >= 1, sel.height >= 1 else { return }
        let clip = dirtyRect.intersection(bounds)
        guard !clip.isNull, clip.width > 0, clip.height > 0,
              let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.clip(to: clip)

        let activeRadius = (cornerRadiusPt > 0.5) ? min(cornerRadiusPt, min(sel.width, sel.height) * 0.5) : 0
        if activeRadius > 0.5 {
            drawRoundedDimmedMask(ctx: ctx, clip: clip, highlightRect: sel, cornerRadius: activeRadius)
        }
        drawLockedSelectionBody(ctx: ctx, clip: clip, sel: sel, activeRadius: activeRadius)
    }

    private func drawRoundedDimmedMask(ctx: CGContext, clip: CGRect, highlightRect hl: CGRect, cornerRadius: CGFloat) {
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.46).cgColor)
        ctx.addRect(clip.insetBy(dx: -2, dy: -2))
        ctx.addPath(CGPath(roundedRect: hl, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    private func drawLockedSelectionBody(ctx: CGContext, clip: CGRect, sel: CGRect, activeRadius: CGFloat) {
        if !isRecordingMode {
            drawLiveGlowFrameIfNeeded(ctx: ctx, sel: sel, cornerRadius: activeRadius)
        }
        if !isRecordingMode, sel.intersects(clip), inPlaceTranslateView == nil {
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
            ctx.setLineDash(phase: 0, lengths: [])
            for hp in doc.objects[idx].editableHandles() {
                let r = CGRect(x: hp.point.x - 4.5, y: hp.point.y - 4.5, width: 9, height: 9)
                ctx.setFillColor(NSColor.white.cgColor); ctx.fillEllipse(in: r)
                ctx.setStrokeColor(MSnipUITheme.accent.cgColor); ctx.setLineWidth(1.6); ctx.strokeEllipse(in: r)
            }
            ctx.restoreGState()
        }
        drawSelectionChrome(ctx: ctx, sel: sel, cornerRadius: activeRadius)
        drawEraserCursorRingIfNeeded(in: ctx, sel: sel)
    }
}
