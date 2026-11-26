import AppKit
import CoreGraphics
import Foundation
import MSnipCore
import QuartzCore

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
    var onHoverFocusRequest: ((OverlayView) -> Bool)?
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
    var inPlaceOCRToken: UInt64 = 0
    var copiedAnnotation: Annotation?; var pasteCascadeCount: Int = 0

    func clearSessionCallbacks() {
        onSelectionActivated = nil; onHoverFocusRequest = nil; onFinishCopy = nil; onFinishCopyWithPath = nil
        onFinishSave = nil; onFinishSaveToFolder = nil; onQuickSaveInPlace = nil; onFinishPin = nil
        onFinishIsolatedWindow = nil; onFinishCopyColor = nil; onFinishCopyText = nil
        onFinishExtractText = nil; onFinishSilentOCR = nil; onFinishRecognizeLatex = nil
        onFinishTranslateWindow = nil; onOpenTranslationSettings = nil; onStartLongShot = nil
        onStartRecording = nil; onCancel = nil; onStyleChanged = nil; onCapsuleChanged = nil
        onPrefsChanged = nil; onRecordingPrefsChanged = nil; onRecordingModeChanged = nil; onGlowStrengthChanged = nil
    }

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

// MARK: - 局部脏矩形增量重绘调度

/// 覆盖层局部脏矩形失效（Partial Dirty-Rect Invalidation）、拖拽期无遮挡隐藏与零拷贝底图切片绘制支持
extension OverlayView {
    var isDraggingSelectionBox: Bool {
        guard let op = dragOp else { return false }
        switch op {
        case .creatingSelection, .movingSelection, .resizingSelection:
            return true
        case .pendingSnapOrCreate, .drawingAnnotation, .erasing, .movingAnnotation, .resizingAnnotation:
            return false
        }
    }

    func autoSnapDirtyBounds(for rect: CGRect) -> CGRect {
        let minX = min(rect.minX - 10, max(0, bounds.width - 390))
        return CGRect(
            x: minX,
            y: rect.minY - 38,
            width: max(rect.maxX - minX + 12, 380),
            height: rect.height + 48
        ).intersection(bounds)
    }

    func selectionDirtyBounds(for rect: CGRect) -> CGRect {
        let pad: CGFloat = (glowStrength > 0.005) ? ceil(14.0 + 22.0 * glowStrength) : 14.0
        return CGRect(
            x: rect.minX - pad,
            y: rect.minY - 40 - pad,
            width: max(rect.width + pad * 2, 340),
            height: rect.height + 50 + pad * 2
        ).intersection(bounds)
    }

    /// 纯 GPU 刷新暗化遮罩四边图层、自动吸附边框、尺寸胶囊与快捷键提示卡（零 CPU 全屏位图重绘）
    func syncGPUChromeLayers() {
        let hideAllForCaliper = (selection == nil && caliperActive)
        let activeRadius = (selection != nil && cornerRadiusPt > 0.5)
            ? min(cornerRadiusPt, min(selection!.width, selection!.height) * 0.5)
            : 0
        let highlightRect = selection ?? autoSnap.displayedRect ?? hoveredAutoRect
        let showGPUDim = !hideAllForCaliper && activeRadius <= 0.5
        let showSnapBorder = !hideAllForCaliper && (selection == nil) && (hoveredAutoRect != nil)
        let borderCol = (isRecordingMode ? MSnipUITheme.danger : MSnipUITheme.accent).withAlphaComponent(0.95).cgColor
        dimSnapView.update(highlightRect: highlightRect, showDim: showGPUDim, showSnapBorder: showSnapBorder, borderColor: borderCol)

        if hideAllForCaliper {
            hudPillView.update(text: nil, anchorRect: nil, containerBounds: bounds)
        } else if let sel = selection, sel.width >= 1, sel.height >= 1 {
            hudPillView.update(text: selectionHudText(for: sel, cornerRadius: activeRadius), anchorRect: sel, containerBounds: bounds)
        } else if let target = hoveredAutoRect {
            let disp = autoSnap.displayedRect ?? target
            hudPillView.update(text: autoSnapHudText(for: target), anchorRect: disp, containerBounds: bounds)
        } else {
            hudPillView.update(text: nil, anchorRect: nil, containerBounds: bounds)
        }
        syncShortcutTipsView()
    }

    func invalidateAutoSnapTransition(from oldRect: CGRect?, to newRect: CGRect?) {
        syncGPUChromeLayers()
    }

    func invalidateSelectionTransition(from oldSel: CGRect?, to newSel: CGRect?) {
        syncGPUChromeLayers()
        if (oldSel == nil) != (newSel == nil) {
            needsDisplay = true
            return
        }
        if let o = oldSel { setNeedsDisplay(selectionDirtyBounds(for: o)) }
        if let n = newSel { setNeedsDisplay(selectionDirtyBounds(for: n)) }
    }

    func invalidateMagnifierMove(from oldPt: CGPoint?, to newPt: CGPoint?) {
        syncMagnifierView()
        syncCaliperView()
        if activeTool == .eraser, selection != nil {
            let pad = style.eraserRadius + 6
            if let o = oldPt { setNeedsDisplay(CGRect(x: o.x - pad, y: o.y - pad, width: pad * 2, height: pad * 2)) }
            if let n = newPt { setNeedsDisplay(CGRect(x: n.x - pad, y: n.y - pad, width: pad * 2, height: pad * 2)) }
        }
        if showShortcutTips, !cachedTipsTriggerZone.isEmpty {
            let wasIn = oldPt.map { cachedTipsTriggerZone.contains($0) } ?? false
            let nowIn = newPt.map { cachedTipsTriggerZone.contains($0) } ?? false
            if wasIn != nowIn {
                syncShortcutTipsView()
            }
        }
    }

    func updateToolbarLayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // PixPin 丝滑交互：拖拽拉框、平移或缩放选区期间暂时隐藏悬浮栏，松手瞬间一步到位呈现，零遮挡零阴影重算卡顿
        if isDraggingSelectionBox {
            toolbar.isHidden = true
            subbar.isHidden = true
            sidePills.isHidden = true
            cornerSlider.isHidden = true
            saveMenu.isHidden = true
            caliperView.isHidden = true
            if let ocrV = inPlaceOCRView, let sel = selection { ocrV.frame = sel }
            if let trV = inPlaceTranslateView, let sel = selection { trV.frame = sel }
            return
        }

        toolbar.canUndo = doc.canUndo
        toolbar.canRedo = doc.canRedo
        toolbar.nextStepNumber = doc.nextStepNumber()
        toolbar.textCapsule = style.textCapsule
        toolbar.refreshState()

        subbar.activeTool = activeTool
        subbar.lineWidth = style.lineWidth
        subbar.colorIndex = colorIndex
        subbar.customColor = customPickedColor
        subbar.eyedropperActive = eyedropperActive
        subbar.textCapsule = style.textCapsule

        sidePills.hasCorner = (cornerRadiusRatio > 0.005 || activeSideSlider == .corner)
        sidePills.hasGlow = (glowStrength > 0.005 || activeSideSlider == .glow)

        guard let sel = selection, sel.width >= 6, sel.height >= 6 else {
            toolbar.isHidden = true
            subbar.isHidden = true
            sidePills.isHidden = true
            activeSideSlider = nil
            cornerSlider.isHidden = true
            isSaveMenuVisible = false
            saveMenu.isHidden = true
            return
        }
        toolbar.isHidden = false
        let barSize = toolbar.frame.size
        if let manual = manualToolbarOrigin {
            let cx = min(max(6, manual.x), bounds.width - barSize.width - 6)
            let cy = min(max(6, manual.y), bounds.height - barSize.height - 6)
            toolbar.setFrameOrigin(NSPoint(x: round(cx), y: round(cy)))
        } else {
            let dockBottom = max(12, snapshot.screen.visibleFrame.minY - snapshot.screen.frame.minY + 12)
            let x = min(max(16, sel.maxX - barSize.width), bounds.width - barSize.width - 16)
            let belowY = sel.maxY + 10
            let aboveY = sel.minY - barSize.height - 10
            let y = (belowY + barSize.height + 44 <= bounds.height - dockBottom)
                ? belowY
                : (aboveY >= 16 ? aboveY : max(16, sel.maxY - barSize.height - 10))
            toolbar.setFrameOrigin(NSPoint(x: round(x), y: round(y)))
        }
        repositionSubbar()

        if isRecordingMode {
            sidePills.isHidden = true
            activeSideSlider = nil; cornerSlider.isHidden = true
            isSaveMenuVisible = false; saveMenu.isHidden = true
            return
        }

        sidePills.isHidden = false
        let pillSz = OverlaySidePillsView.viewSize
        let rightX = sel.maxX + 10
        let leftX = sel.minX - pillSz.width - 10
        let px = (rightX + pillSz.width + 6 <= bounds.width) ? rightX : max(6, leftX)
        let py = min(max(8, sel.minY + 2), bounds.height - pillSz.height - 8)
        sidePills.setFrameOrigin(NSPoint(x: round(px), y: round(py)))

        if let sliderMode = activeSideSlider {
            cornerSlider.mode = sliderMode
            cornerSlider.ratio = (sliderMode == .glow) ? glowStrength : cornerRadiusRatio
            cornerSlider.isHidden = false
            let sSz = OverlayCornerSliderView.barSize
            let preferRightX = sidePills.frame.maxX + 8
            let altLeftX = sidePills.frame.minX - sSz.width - 8
            let sx = (preferRightX + sSz.width + 6 <= bounds.width)
                ? preferRightX
                : max(6, min(altLeftX, bounds.width - sSz.width - 6))
            let anchorOffsetY: CGFloat = (sliderMode == .glow) ? (OverlaySidePillsView.pillSize + OverlaySidePillsView.gap) : 0
            let sy = min(max(6, sidePills.frame.minY + anchorOffsetY - 1), bounds.height - sSz.height - 6)
            cornerSlider.setFrameOrigin(NSPoint(x: round(sx), y: round(sy)))
        } else {
            cornerSlider.isHidden = true
        }

        if isSaveMenuVisible {
            saveMenu.isHidden = false
            let mSz = saveMenu.frame.size
            let tf = toolbar.frame
            let mx = min(max(8, tf.maxX - mSz.width - 54), bounds.width - mSz.width - 8)
            let belowY = tf.maxY + 6
            let aboveY = tf.minY - mSz.height - 6
            let my = (belowY + mSz.height + 8 <= bounds.height) ? belowY : max(8, aboveY)
            saveMenu.setFrameOrigin(NSPoint(x: round(mx), y: round(my)))
        } else {
            saveMenu.isHidden = true
        }

        if let ocrV = inPlaceOCRView { ocrV.frame = sel }
        if let trV = inPlaceTranslateView { trV.frame = sel }
        syncShortcutTipsView()
    }

    func clearSelectionFromSibling() {
        cancelTextEditing()
        barcodeScanTask?.cancel(); barcodeScanTask = nil
        deactivateInPlaceOCR()
        deactivateInPlaceTranslate()
        stopSnapGlide()
        activeSideSlider = nil
        cornerRadiusRatio = 0
        glowStrength = 0
        didAdjustGlow = false
        cornerSlider.isHidden = true
        isSaveMenuVisible = false
        saveMenu.isHidden = true
        caliperActive = false
        selection = nil
        lastMousePoint = nil
        syncMagnifierView()
        syncCaliperView()
        eyedropperActive = false
        autoSnap.clearTargets()
        selectedObjectIndex = nil
        draftAnnotation = nil
        doc = AnnotationDocument()
    }

    func repositionSubbar() {
        let shouldShow = !isRecordingMode && !toolbar.isHidden && !toolbar.inPlaceOCRActive && !toolbar.inPlaceTranslateActive && (activeTool != nil || selectedObjectIndex != nil)
        guard shouldShow else {
            subbar.isHidden = true
            return
        }
        subbar.refresh()
        subbar.isHidden = false
        let tf = toolbar.frame
        let sz = subbar.frame.size
        let sx = min(max(6, tf.minX), bounds.width - sz.width - 6)
        let belowY = tf.maxY + 6
        let sy = (belowY + sz.height + 6 <= bounds.height) ? belowY : max(6, tf.minY - sz.height - 6)
        subbar.setFrameOrigin(NSPoint(x: round(sx), y: round(sy)))
    }

    func drawLiveGlowFrameIfNeeded(ctx: CGContext, sel: CGRect, cornerRadius: CGFloat) {
        let s = min(1.0, max(0.0, glowStrength))
        guard s > 0.005 else { return }
        let pad: CGFloat = ceil(10.0 + 18.0 * s)
        let outer = sel.insetBy(dx: -pad, dy: -pad)
        let innerPath = cornerRadius > 0.5
            ? CGPath(roundedRect: sel, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            : CGPath(rect: sel, transform: nil)
        let blur: CGFloat = 3.0 + 10.0 * s

        ctx.saveGState()
        ctx.addRect(outer)
        ctx.addPath(innerPath)
        ctx.clip(using: .evenOdd)
        ctx.setShadow(offset: .zero, blur: blur, color: NSColor.white.withAlphaComponent(0.45 + 0.45 * s).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addPath(innerPath)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.32 + 0.42 * s).cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(innerPath)
        ctx.strokePath()
        ctx.restoreGState()
    }
}
