import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 覆盖层响应悬浮工具栏、二级样式栏及页内功能动作扩展
extension OverlayView {
    func handleToolbarAction(_ action: ToolbarView.Action) {
        commitTextEditing()
        if case .save = action {} else if isSaveMenuVisible {
            isSaveMenuVisible = false
        }
        switch action {
        case .selectTool(let tool):
            eyedropperActive = false
            if tool != nil {
                deactivateInPlaceOCR()
                deactivateInPlaceTranslate()
                selectedObjectIndex = nil
            }
            activeTool = tool
            updateToolbarLayout()
        case .toggleTextCapsule:
            toggleTextCapsuleMode()
        case .selectColor(let idx):
            eyedropperActive = false
            customPickedColor = nil
            colorIndex = idx
            if let selIdx = selectedObjectIndex {
                doc.modifyWithHistory(at: selIdx) { $0.style.color = style.color }
            }
            applyTextFieldVisualStyle()
            updateToolbarLayout()
            onStyleChanged?(colorIndex, style.lineWidth)
            needsDisplay = true
        case .toggleEyedropper:
            eyedropperActive.toggle()
            updateToolbarLayout()
        case .selectStroke(let w):
            applyAnnotationSize(w)
        case .undo:
            selectedObjectIndex = nil
            if doc.undo() { updateToolbarLayout(); needsDisplay = true }
        case .redo:
            selectedObjectIndex = nil
            if doc.redo() { updateToolbarLayout(); needsDisplay = true }
        case .clearAnnotations:
            selectedObjectIndex = nil
            doc.clearAll()
            updateToolbarLayout()
            needsDisplay = true
        case .autoRedact:
            performAutoRedactSensitiveText()
        case .cycleCornerRadius:
            toggleCornerRadiusSlider()
        case .cycleBackdrop:
            toggleGlowSlider()
        case .captureWindow:
            if NSEvent.modifierFlags.contains(.option) {
                captureCurrentWindowAndFinish(pin: false)
            } else {
                snapSelectionToUnderlyingWindow()
            }
        case .toggleInPlaceOCR:
            toggleInPlaceOCR()
        case .extractTextWindow:
            exportAndFinish(mode: .extractText)
        case .silentOCR:
            exportAndFinish(mode: .silentOCR)
        case .recognizeLatex:
            exportAndFinish(mode: .recognizeLatex)
        case .toggleInPlaceTranslate:
            toggleInPlaceTranslate()
        case .translateWindow:
            exportAndFinish(mode: .translateWindow)
        case .startLongShot:
            beginLongShot()
        case .startRecording:
            setRecordingMode(true, notifySiblings: true)
        case .selectRecordingFormat(let fmt):
            toolbar.recordingFormat = fmt
            onRecordingPrefsChanged?(fmt, toolbar.recordingHUDEnabled)
            updateToolbarLayout()
            syncGPUChromeLayers()
            needsDisplay = true
        case .toggleRecordingHUD:
            toolbar.recordingHUDEnabled.toggle()
            onRecordingPrefsChanged?(toolbar.recordingFormat, toolbar.recordingHUDEnabled)
            updateToolbarLayout()
        case .confirmBeginRecording:
            confirmBeginRegionRecording()
        case .exitRecordingMode:
            setRecordingMode(false, notifySiblings: true)
        case .pin:
            exportAndFinish(mode: .pin)
        case .save:
            toggleSaveDirectoryMenu()
        case .quickSave:
            quickSaveInPlace()
        case .cancel:
            onCancel?()
        case .confirmCopy:
            exportAndFinish(mode: .copy)
        }
    }

    func quickSaveInPlace() {
        commitTextEditing()
        guard let targetRect = selection ?? hoveredAutoRect,
              targetRect.width >= 2, targetRect.height >= 2,
              let baked = currentExportableImage(for: targetRect, plainForOCR: false) else { return }
        onQuickSaveInPlace?(baked, snapshot.scaleFactor, targetRect)
    }

    func beginLongShot() {
        commitTextEditing()
        deactivateInPlaceOCR()
        deactivateInPlaceTranslate()
        guard let raw = selection ?? hoveredAutoRect else {
            ToastHUD.show(message: L("请先框选或悬停要滚动截取的区域"))
            return
        }
        let rect = CGRect(
            x: round(raw.minX), y: round(raw.minY),
            width: round(raw.width), height: round(raw.height)
        ).intersection(bounds)
        guard rect.width >= 48, rect.height >= 64 else {
            ToastHUD.show(message: L("长截图区域至少需 48 × 64 pt"))
            return
        }
        let s = snapshot.scaleFactor
        let pxRect = CGRect(
            x: round(rect.minX * s), y: round(rect.minY * s),
            width: CGFloat(max(24, Int((rect.width * s).rounded()))),
            height: CGFloat(max(32, Int((rect.height * s).rounded())))
        )
        onStartLongShot?(snapshot.screen, rect, snapshot.cgImage.cropping(to: pxRect).map(ImageTransform.detachedCopy))
    }

    func toggleSaveDirectoryMenu() {
        if selection == nil, let snap = hoveredAutoRect { selection = snap }
        if !isSaveMenuVisible {
            saveMenu.reload(folders: saveFolderOptions)
            isSaveMenuVisible = true
        } else {
            isSaveMenuVisible = false
        }
        updateToolbarLayout()
    }

    func toggleTextCapsuleMode() {
        style.textCapsule.toggle()
        toolbar.textCapsule = style.textCapsule
        subbar.textCapsule = style.textCapsule
        applyTextFieldVisualStyle()
        if let idx = selectedObjectIndex, case .text(let origin, let content, _) = doc.objects[idx].payload {
            let newCap = !doc.objects[idx].style.textCapsule
            style.textCapsule = newCap
            toolbar.textCapsule = newCap
            subbar.textCapsule = newCap
            let sz = AnnotationRenderer.measureText(content, fontSize: doc.objects[idx].style.fontSize, capsule: newCap)
            doc.modifyWithHistory(at: idx) {
                $0.style.textCapsule = newCap
                $0.payload = .text(origin: origin, content: content, measuredSize: sz)
            }
        }
        onCapsuleChanged?(style.textCapsule)
        needsDisplay = true
    }

    func toggleRecordingMode() {
        setRecordingMode(!isRecordingMode, notifySiblings: true)
    }

    func setRecordingMode(_ enabled: Bool, notifySiblings: Bool) {
        commitTextEditing()
        if enabled {
            deactivateInPlaceOCR()
            deactivateInPlaceTranslate()
            eyedropperActive = false
            activeTool = nil
            selectedObjectIndex = nil
            activeSideSlider = nil
            isSaveMenuVisible = false
            cornerRadiusRatio = 0
            glowStrength = 0
            didAdjustGlow = false
            backdropStyle = .none
        }
        toolbar.isRecordingMode = enabled
        updateToolbarLayout()
        syncGPUChromeLayers()
        needsDisplay = true
        if notifySiblings { onRecordingModeChanged?(enabled) }
    }

    func triggerQuickLaunchIfNeeded() {
        switch quickLaunchMode {
        case .standard, .quickRecord: break
        case .quickSilentOCR:
            exportAndFinish(mode: .silentOCR)
        case .quickOCR:
            switch ocrPresentation {
            case .inPlace:    activateInPlaceOCR()
            case .dualPane:   exportAndFinish(mode: .extractText)
            case .silentCopy: exportAndFinish(mode: .silentOCR)
            }
        case .quickTranslate:
            if translateAutoOpenDualPane { exportAndFinish(mode: .translateWindow) } else { activateInPlaceTranslate() }
        case .quickLongShot:  beginLongShot()
        case .quickLatex:     exportAndFinish(mode: .recognizeLatex)
        }
    }

    func confirmBeginRegionRecording() {
        commitTextEditing()
        deactivateInPlaceOCR()
        deactivateInPlaceTranslate()
        guard let raw = selection ?? hoveredAutoRect else {
            ToastHUD.show(message: L("请先点击窗口或拖拽框选要录制的区域"))
            return
        }
        let rect = CGRect(
            x: round(raw.minX), y: round(raw.minY),
            width: round(raw.width), height: round(raw.height)
        ).intersection(bounds)
        guard rect.width >= 48, rect.height >= 48 else {
            ToastHUD.show(message: L("录屏选区至少需 48 × 48 pt"))
            return
        }
        let s = snapshot.scaleFactor
        let pxRect = CGRect(
            x: round(rect.minX * s), y: round(rect.minY * s),
            width: CGFloat(Int((rect.width * s).rounded()) & ~1),
            height: CGFloat(Int((rect.height * s).rounded()) & ~1)
        )
        onStartRecording?(snapshot.screen, rect, snapshot.cgImage.cropping(to: pxRect).map(ImageTransform.detachedCopy))
    }

    /// 离线一键隐私智能打码：扫描选区敏感字段并合并为单步 Undo 事务批量添加马赛克/毛玻璃遮罩
    func performAutoRedactSensitiveText() {
        commitTextEditing()
        if selection == nil, let snap = hoveredAutoRect { selection = snap }
        guard let sel = selection, sel.width >= 16, sel.height >= 16 else {
            ToastHUD.show(message: L("请先框选需要智能打码的区域"))
            return
        }
        guard let cropped = AnnotationRenderer.bakeExportImage(
            sampler: snapshot.sampler, selection: sel, imageScale: snapshot.scaleFactor, annotations: []
        ) else { return }
        let useBlur = (activeTool == .gaussianBlur)
        let curStyle = self.style
        ToastHUD.show(message: L("正在离线扫描隐私敏感信息…"))
        Task { @MainActor [weak self] in
            let normBoxes = await VisionTextExtractor.detectSensitiveBoxesOffMain(cgImage: cropped)
            guard let self, let activeSel = self.selection, activeSel == sel else { return }
            guard !normBoxes.isEmpty else {
                ToastHUD.show(message: L("选区内未检测到 API Key、邮箱、手机号、身份证或 IP"))
                return
            }
            self.doc.beginTransaction()
            var nextObjs = self.doc.objects
            for nb in normBoxes {
                let rawR = CGRect(
                    x: activeSel.minX + nb.minX * activeSel.width,
                    y: activeSel.minY + (1.0 - nb.maxY) * activeSel.height,
                    width: nb.width * activeSel.width,
                    height: nb.height * activeSel.height
                ).insetBy(dx: -3, dy: -2).intersection(activeSel)
                guard rawR.width >= 4, rawR.height >= 4 else { continue }
                let payload: AnnotationPayload = useBlur ? .gaussianBlur(rawR) : .mosaic(rawR)
                nextObjs.append(Annotation(payload: payload, style: curStyle))
            }
            self.doc.replaceObjectsWithoutHistory(nextObjs)
            self.doc.commitTransaction(changed: true)
            self.updateToolbarLayout()
            self.needsDisplay = true
            ToastHUD.show(message: L("✓ 已一键遮盖 %@ 处隐私敏感信息（可按 ⌘Z 撤回）", normBoxes.count))
        }
    }
}

// MARK: - 选区圆角调节滑条

/// 选区右侧滑块模式（圆角比例 / 发光边强度）
enum OverlaySideSliderMode: Equatable {
    case corner
    case glow
}

/// 选区右侧进度条悬浮胶囊（供圆角比例与发光边强度共用：支持点击跳转、丝滑拖拽 0%~100%、滚轮微调与一键归零）
final class OverlayCornerSliderView: NSView {
    var mode: OverlaySideSliderMode = .corner { didSet { needsDisplay = true } }
    var ratio: CGFloat = 0 {
        didSet {
            let clamped = min(1.0, max(0.0, ratio))
            if abs(ratio - clamped) > 0.0001 {
                ratio = clamped
            }
            needsDisplay = true
        }
    }

    var onRatioChanged: ((CGFloat) -> Void)?
    private var isDraggingThumb = false { didSet { needsDisplay = true } }
    private var hoveredReset = false { didSet { needsDisplay = true } }
    private var hoveredTrack = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    static let barSize = NSSize(width: 178, height: 32)
    private let trackMinX: CGFloat = 13
    private let trackMaxX: CGFloat = 113

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.barSize))
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor(srgbRed: 0.04, green: 0.08, blue: 0.16, alpha: 1.0).cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: 3)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    private var resetRect: CGRect {
        CGRect(x: bounds.width - 25, y: 5, width: 21, height: 22)
    }

    override var isHidden: Bool {
        didSet { if isHidden { clearHover() } }
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(atLocalPoint: convert(event.locationInWindow, from: nil))
    }

    func updateHover(atLocalPoint p: CGPoint) {
        guard !isDraggingThumb else { return }
        NSCursor.pointingHand.set()
        let onReset = resetRect.contains(p)
        let onTrack = !onReset && bounds.contains(p)
        if hoveredReset != onReset { hoveredReset = onReset }
        if hoveredTrack != onTrack { hoveredTrack = onTrack }
        let tip: String = (mode == .glow)
            ? (onReset ? L("关闭发光边 (0%)") : L("左右拖拽或滚轮调节发光边强度（0%–100%）"))
            : (onReset ? L("归零圆角 (0%)") : L("左右拖拽或滚轮调节圆角比例（100% 为胶囊/正圆）"))
        FloatingTooltipHUD.show(tip, anchorRectInView: onReset ? resetRect : bounds, of: self)
    }

    func clearHover() {
        FloatingTooltipHUD.hide(for: self)
        if hoveredReset { hoveredReset = false }
        if hoveredTrack { hoveredTrack = false }
    }

    override func mouseExited(with event: NSEvent) { clearHover() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { clearHover() }
    }

    override func mouseDown(with event: NSEvent) {
        FloatingTooltipHUD.hide(for: self)
        let p = convert(event.locationInWindow, from: nil)
        if resetRect.contains(p) {
            applyNewRatio(0)
            return
        }
        isDraggingThumb = true
        updateRatio(atX: p.x)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingThumb else { return }
        let p = convert(event.locationInWindow, from: nil)
        updateRatio(atX: p.x)
    }

    override func mouseUp(with event: NSEvent) {
        isDraggingThumb = false
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? (-event.scrollingDeltaY * 0.004) : (event.scrollingDeltaY > 0 ? 0.02 : -0.02)
        guard abs(delta) > 0.0005 else { return }
        applyNewRatio(min(1.0, max(0.0, ratio + delta)))
    }

    private func updateRatio(atX x: CGFloat) {
        let span = max(1, trackMaxX - trackMinX)
        var raw = (x - trackMinX) / span
        if raw < 0.02 { raw = 0.0 }
        else if raw > 0.98 { raw = 1.0 }
        applyNewRatio(min(1.0, max(0.0, raw)))
    }

    private func applyNewRatio(_ next: CGFloat) {
        ratio = next
        onRatioChanged?(next)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        MSnipUITheme.drawPorcelainBar(ctx: ctx, bounds: bounds, radius: 9.0)

        let cy = bounds.height * 0.5
        let trackH: CGFloat = 5.0
        let trackW = trackMaxX - trackMinX
        let trackRect = CGRect(x: trackMinX, y: round(cy - trackH * 0.5), width: trackW, height: trackH)

        // 1) 进度槽底轨
        ctx.saveGState()
        let bgTrack = CGPath(roundedRect: trackRect, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
        ctx.setFillColor(MSnipUITheme.sidebarBg.cgColor)
        ctx.addPath(bgTrack)
        ctx.fillPath()
        ctx.setStrokeColor(MSnipUITheme.borderHairline.cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(bgTrack)
        ctx.strokePath()

        // 2) 已填充蓝色圆角比例进度条
        let fillW = max(0, min(trackW, trackW * ratio))
        if fillW > 1.0 {
            let fillRect = CGRect(x: trackMinX, y: trackRect.minY, width: fillW, height: trackH)
            ctx.setFillColor(MSnipUITheme.accent.cgColor)
            ctx.addPath(CGPath(roundedRect: fillRect, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
            ctx.fillPath()
        }

        // 3) 白色立体圆形滑块手柄
        let thumbR: CGFloat = (isDraggingThumb || hoveredTrack) ? 7.5 : 6.5
        let thumbX = trackMinX + fillW
        let thumbRect = CGRect(x: thumbX - thumbR, y: cy - thumbR, width: thumbR * 2, height: thumbR * 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 3.0, color: NSColor.black.withAlphaComponent(0.20).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: thumbRect)
        ctx.restoreGState()

        ctx.setStrokeColor(MSnipUITheme.accent.cgColor)
        ctx.setLineWidth(2.0)
        ctx.strokeEllipse(in: thumbRect.insetBy(dx: 0.5, dy: 0.5))

        // 4) 百分比数字读数
        let pct = Int((ratio * 100).rounded())
        let pctStr = "\(pct)%" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: pct > 0 ? MSnipUITheme.accent : MSnipUITheme.inkSecondary
        ]
        let sz = pctStr.size(withAttributes: attrs)
        pctStr.draw(
            at: CGPoint(x: round(trackMaxX + 7), y: round(cy - sz.height * 0.5)),
            withAttributes: attrs
        )

        // 5) 右端一键归零微按钮
        if hoveredReset {
            ToolbarView.drawButtonBg(ctx: ctx, rect: resetRect, active: false, hovered: true)
        }
        ToolbarView.drawSymbol(
            "arrow.counterclockwise",
            in: resetRect,
            alpha: ratio > 0.005 ? 0.90 : 0.35,
            tint: MSnipUITheme.inkSecondary
        )
        ctx.restoreGState()
    }
}

extension OverlayView {
    func setupFloatingControls(initialColorIndex: Int, initialLineWidth: CGFloat, pinHint: String) {
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
            case .cycleCorner(let opt): self.toggleCornerRadiusSlider(resetOnly: opt)
            case .toggleGlow(let opt):  self.toggleGlowSlider(resetOnly: opt)
            case .snapWindow(let opt):
                if opt { self.captureCurrentWindowAndFinish(pin: false) }
                else { self.snapSelectionToUnderlyingWindow() }
            }
        }
        sidePills.onScrollAdjust = { [weak self] slotIdx, delta in
            guard let self else { return }
            if slotIdx == 0 {
                if self.selection == nil, let snap = self.hoveredAutoRect { self.selection = snap }
                self.activeSideSlider = .corner
                self.cornerRadiusRatio = min(1.0, max(0.0, self.cornerRadiusRatio + delta))
                self.updateToolbarLayout()
            } else if slotIdx == 1 {
                if self.selection == nil, let snap = self.hoveredAutoRect { self.selection = snap }
                self.activeSideSlider = .glow
                let base = self.didAdjustGlow ? self.glowStrength : self.defaultPinGlowStrength
                self.applyGlowStrength(min(1.0, max(0.0, base + delta)))
                self.updateToolbarLayout()
            }
        }

        cornerSlider.isHidden = true
        cornerSlider.onRatioChanged = { [weak self] r in
            guard let self else { return }
            if self.activeSideSlider == .glow { self.applyGlowStrength(r) }
            else { self.cornerRadiusRatio = r }
        }

        saveMenu.isHidden = true
        saveMenu.onChoice = { [weak self] choice in
            guard let self else { return }
            self.isSaveMenuVisible = false
            self.updateToolbarLayout()
            switch choice {
            case .folder(let dir): self.exportAndFinish(mode: .saveToFolder(dir))
            case .saveAsPanel:     self.exportAndFinish(mode: .save)
            }
        }

        caliperView.ownerOverlay = self
        caliperView.frame = bounds

        addSubview(hudPillView)
        addSubview(shortcutTipsView)
        addSubview(sidePills)
        addSubview(cornerSlider)
        addSubview(toolbar)
        addSubview(subbar)
        addSubview(saveMenu)
        addSubview(caliperView)
        addSubview(magnifierView)
    }

    func toggleCornerRadiusSlider(resetOnly: Bool = false) {
        if selection == nil, let snap = hoveredAutoRect { selection = snap }
        if resetOnly { cornerRadiusRatio = 0; if activeSideSlider == .corner { activeSideSlider = nil }; updateToolbarLayout(); return }
        if activeSideSlider != .corner { activeSideSlider = .corner; if cornerRadiusRatio < 0.01 { cornerRadiusRatio = 0.16 } }
        else { activeSideSlider = nil }
        updateToolbarLayout()
    }

    func toggleGlowSlider(resetOnly: Bool = false) {
        if selection == nil, let snap = hoveredAutoRect { selection = snap }
        if resetOnly {
            applyGlowStrength(0)
            if activeSideSlider == .glow { activeSideSlider = nil }
            updateToolbarLayout(); return
        }
        if activeSideSlider != .glow {
            activeSideSlider = .glow
            if !didAdjustGlow && glowStrength < 0.01 { applyGlowStrength(max(0.20, defaultPinGlowStrength)) }
        } else { activeSideSlider = nil }
        updateToolbarLayout()
    }

    /// 截图选框右侧的发光边滑条与「设置 → 贴图默认发光边」及桌面贴图实时双向同步（含归零 0%）
    func applyGlowStrength(_ raw: CGFloat) {
        let clamped = min(1.0, max(0.0, raw))
        didAdjustGlow = true
        glowStrength = clamped
        defaultPinGlowStrength = clamped
        onGlowStrengthChanged?(clamped)
    }
}
