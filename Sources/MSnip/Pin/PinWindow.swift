import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 单个置顶贴图窗口：
/// - 原图直接支持实况文本 `I` 光标划词复制，无右下角系统冗余角标；
/// - 悬停时在贴图外框上方浮出微操作条（含「✥ 按住拖动」手柄，满屏文字时也可轻松挪动且零遮挡画面）；
/// - 点击贴图任意位置即选中聚焦，按 `Esc` 立即关闭贴图。
final class PinWindow: NSPanel {
    var onClose: ((PinWindow) -> Void)?
    var onCloseAll: (() -> Void)?
    var onStateChanged: (() -> Void)?
    var onSavePNG: ((CGImage, CGFloat) -> Void)?
    var onQuickSavePNG: ((CGImage, CGFloat) -> Void)?
    var onExtractOCR: ((CGImage, CGFloat, NSScreen) -> Void)?
    var onTranslateImage: ((CGImage, CGFloat, NSScreen) -> Void)?
    var onSnapOrigin: ((NSPoint, NSSize, PinWindow) -> NSPoint)?
    var onGlowStrengthChanged: ((CGFloat) -> Void)?

    var baseCGImage: CGImage
    var activeBaseSampler: PixelSampler?
    var currentCGImage: CGImage
    let imageScale: CGFloat
    var baseSize: NSSize
    var zoomFactor: CGFloat = 1.0
    var glowStrength: CGFloat = 0.45
    var preGhostAlpha: CGFloat = 1.0
    var isClickThrough: Bool = false

    var annotationDoc = AnnotationDocument()
    var editorCanvas: PinAnnotationCanvasView?
    var cropOverlay: PinCropOverlayView?
    var toolbarPanel: PinToolbarPanel?
    let hoverBarPanel = PinHoverBarPanel()

    var isMouseInPin = false
    var isMouseInHoverBar = false
    var isDraggingFromBar = false
    var hideHoverWorkItem: DispatchWorkItem?

    private var isDraggingWindow = false
    private var dragMouseStart: NSPoint = .zero
    private var dragOriginStart: NSPoint = .zero
    var resizeState = PinResizeDragState()
    let pinContentView: PinContentView
    let glowContainer: PinGlowContainerView
    var highlightMenuItem: NSMenuItem?

    var isActivelyDraggingOrResizing: Bool { isDraggingWindow || isDraggingFromBar || resizeState.activeEdge != nil }
    var imageScreenFrame: NSRect { frame.insetBy(dx: PinGlowContainerView.glowPadding, dy: PinGlowContainerView.glowPadding) }
    func setImageScreenFrame(_ imgFrame: NSRect) { let p = PinGlowContainerView.glowPadding; setFrame(imgFrame.insetBy(dx: -p, dy: -p), display: true) }

    init(
        cgImage: CGImage,
        scaleFactor: CGFloat,
        screenOriginTopLeft: CGPoint?,
        on screen: NSScreen,
        cascadeOffset: CGPoint = .zero,
        glowStrength: CGFloat = 0.45
    ) {
        self.baseCGImage = cgImage
        self.currentCGImage = cgImage
        self.glowStrength = min(1.0, max(0.0, glowStrength))
        let s = max(1.0, scaleFactor)
        self.imageScale = s
        let initialBaseSize = NSSize(
            width: max(8, CGFloat(cgImage.width) / s),
            height: max(8, CGFloat(cgImage.height) / s)
        )
        self.baseSize = initialBaseSize

        let snapPx: (CGFloat) -> CGFloat = { v in (v * s).rounded() / s }
        let preferredOrigin: CGPoint? = screenOriginTopLeft.map { topLeft in
            CGPoint(x: snapPx(screen.frame.minX + topLeft.x), y: snapPx(screen.frame.maxY - topLeft.y - initialBaseSize.height))
        }
        let fit = ImageTransform.fittedPinRect(
            baseSize: initialBaseSize,
            visibleBounds: screen.visibleFrame,
            preferredOrigin: preferredOrigin,
            cascadeOffset: cascadeOffset
        )
        self.zoomFactor = fit.zoom
        let initialImgFrame = NSRect(x: snapPx(fit.frame.origin.x), y: snapPx(fit.frame.origin.y), width: fit.frame.width, height: fit.frame.height)
        let pad = PinGlowContainerView.glowPadding
        let content = PinContentView(cgImage: cgImage, baseSize: initialBaseSize, initialSize: initialImgFrame.size)
        self.pinContentView = content
        self.glowContainer = PinGlowContainerView(contentView: content, glowStrength: self.glowStrength)

        super.init(
            contentRect: initialImgFrame.insetBy(dx: -pad, dy: -pad),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.animationBehavior = .none
        self.becomesKeyOnlyIfNeeded = false
        self.isFloatingPanel = true
        self.hidesOnDeactivate = false
        self.acceptsMouseMovedEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.contentView = glowContainer

        pinContentView.onHoverChanged = { [weak self] inside in self?.updatePinHover(inside) }
        attachResizeChrome()
        hoverBarPanel.barView.onHoverChanged = { [weak self] inside in self?.updateHoverBarHover(inside) }
        hoverBarPanel.barView.onAction = { [weak self] act in
            guard let self else { return }
            switch act {
            case .annotate:  self.beginAnnotationEditing()
            case .ocr:       self.openOCRPanel()
            case .translate: self.openTranslatePanel()
            case .copy:      self.copyImage(); ToastHUD.show(message: "已复制贴图图像")
            case .save:      if NSEvent.modifierFlags.contains(.shift) { self.saveImage() } else { self.quickSaveImage() }
            case .close:     self.closePin()
            }
        }
        hoverBarPanel.barView.onDragStart = { [weak self] in
            guard let self else { return }
            self.makeKeyAndOrderFront(nil)
            self.isDraggingFromBar = true
            self.dragMouseStart = NSEvent.mouseLocation
            self.dragOriginStart = self.imageScreenFrame.origin
        }
        hoverBarPanel.barView.onDragMove = { [weak self] in
            guard let self, self.isDraggingFromBar else { return }
            let now = NSEvent.mouseLocation
            self.applyDraggedOrigin(raw: NSPoint(
                x: self.dragOriginStart.x + (now.x - self.dragMouseStart.x),
                y: self.dragOriginStart.y + (now.y - self.dragMouseStart.y)
            ), disableSnap: NSEvent.modifierFlags.contains(.option))
            self.hoverBarPanel.reposition(anchoringTo: self.imageScreenFrame, on: self.screen)
        }
        hoverBarPanel.barView.onDragEnd = { [weak self] in
            guard let self else { return }
            self.isDraggingFromBar = false
            self.reconcileHoverFromCurrentMouse()
        }

        let menu = buildContextMenu()
        pinContentView.menu = menu
        pinContentView.liveTextView.menu = menu
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func becomeKey() { super.becomeKey(); pinContentView.isSelectedKey = true; syncGlowState() }
    override func resignKey() { super.resignKey(); pinContentView.isSelectedKey = false; syncGlowState() }

    func syncGlowState() {
        glowContainer.glowStrength = glowStrength
        glowContainer.isHoveredOrFocused = isMouseInPin || isMouseInHoverBar || isKeyWindow || resizeState.activeEdge != nil
        glowContainer.isAnnotating = (editorCanvas != nil || cropOverlay != nil)
        glowContainer.isGhostMode = isClickThrough
    }

    // MARK: - Event Routing (Direct Text Selection + Blank/Handle Drag + Guaranteed Esc)

    override func sendEvent(_ event: NSEvent) {
        if editorCanvas != nil || cropOverlay != nil { super.sendEvent(event); return }
        switch event.type {
        case .mouseMoved:
            let cp = pinContentView.convert(event.locationInWindow, from: nil)
            let edge = PinResizeEdge.hitTest(point: cp, in: pinContentView.bounds, outerSlop: PinGlowContainerView.outerResizeReach)
            if (edge != nil || pinContentView.bounds.contains(cp)), !isMouseInPin { updatePinHover(true) }
            if handleResizeHover(contentPoint: cp) { return }
            super.sendEvent(event)

        case .cursorUpdate:
            let cp = pinContentView.convert(event.locationInWindow, from: nil)
            if let edge = resizeState.activeEdge ?? PinResizeEdge.hitTest(point: cp, in: pinContentView.bounds, outerSlop: PinGlowContainerView.outerResizeReach) {
                PinResizeCursorFactory.cursor(for: edge).set(); return
            }
            super.sendEvent(event)

        case .leftMouseDown:
            let cp = pinContentView.convert(event.locationInWindow, from: nil)
            let hitEdge = PinResizeEdge.hitTest(point: cp, in: pinContentView.bounds, outerSlop: PinGlowContainerView.outerResizeReach)
            guard hitEdge != nil || pinContentView.bounds.contains(cp) else { return }
            if !isKeyWindow { makeKeyAndOrderFront(nil) }
            if event.modifierFlags.contains(.command) {
                pinContentView.startPNGFileDrag(with: event, cgImage: currentCGImage, scaleFactor: imageScale); return
            }
            if let edge = hitEdge {
                isDraggingWindow = false; beginResizeDrag(edge: edge); return
            }
            let forceDrag = event.modifierFlags.contains(.option)
            if !forceDrag && pinContentView.liveTextView.hasInteractiveItem(atWindowPoint: event.locationInWindow) {
                isDraggingWindow = false; super.sendEvent(event); return
            }
            pinContentView.liveTextView.clearSelection()
            if event.clickCount == 2 { closePin(); return }
            isDraggingWindow = true
            dragMouseStart = NSEvent.mouseLocation
            dragOriginStart = imageScreenFrame.origin

        case .leftMouseDragged:
            if resizeState.activeEdge != nil { updateResizeDrag(); return }
            if isDraggingWindow {
                let now = NSEvent.mouseLocation
                applyDraggedOrigin(raw: NSPoint(x: dragOriginStart.x + (now.x - dragMouseStart.x), y: dragOriginStart.y + (now.y - dragMouseStart.y)), disableSnap: event.modifierFlags.contains(.option))
                if hoverBarPanel.isVisible { hoverBarPanel.reposition(anchoringTo: imageScreenFrame, on: screen) }
                return
            }
            super.sendEvent(event)

        case .leftMouseUp:
            if resizeState.activeEdge != nil { endResizeDrag(); return }
            if isDraggingWindow { isDraggingWindow = false; reconcileHoverFromCurrentMouse(); return }
            super.sendEvent(event)

        case .keyDown:
            if handlePinKeyDown(event) { return }
            super.sendEvent(event)

        default:
            super.sendEvent(event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if editorCanvas != nil { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if (flags == .command || flags == .control) && chars == "c" {
            if pinContentView.liveTextView.copySelectionIfActive() { ToastHUD.show(message: "已复制贴图划选文字"); return true }
            copyImage(); ToastHUD.show(message: "已复制贴图图像"); return true
        }
        if flags == .command && chars == "o" { openOCRPanel(); return true }
        return super.performKeyEquivalent(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }
        if let canvas = editorCanvas {
            let d: CGFloat = delta > 0 ? 1.0 : -1.0
            let nextW = min(ToolbarSubbarView.maxStroke, max(ToolbarSubbarView.minStroke, (canvas.style.lineWidth + d).rounded()))
            canvas.applyStrokeWidth(nextW)
            toolbarPanel?.barView.lineWidth = nextW; toolbarPanel?.subbarView.lineWidth = nextW
            return
        }
        let step: CGFloat = event.hasPreciseScrollingDeltas ? delta * 0.004 : (delta > 0 ? 0.08 : -0.08)
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            alphaValue = min(1.0, max(0.2, alphaValue + step))
        } else if event.modifierFlags.contains(.option) {
            glowStrength = min(1.0, max(0.0, glowStrength + step))
            syncGlowState()
            onGlowStrengthChanged?(glowStrength)
        } else {
            applyZoom(newZoom: min(maxAllowedZoom, max(minAllowedZoom, zoomFactor * (1.0 + step))))
        }
    }

    private func handlePinKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.keyCode == 53 { closePin(); return true }
        if flags.contains(.command), chars == "s" {
            if flags.contains(.shift) { saveImage() } else { quickSaveImage() }
            return true
        }
        if flags.isEmpty {
            switch chars {
            case "e": beginAnnotationEditing(); return true
            case "c": beginCropEditing(); return true
            case "p": enableClickThrough(); return true
            case "t": openOCRPanel(); return true
            case "y": openTranslatePanel(); return true
            case "r": rotateClockwise90(); return true
            case "h": flipHorizontal(); return true
            default: break
            }
        }
        return false
    }

    func applyDraggedOrigin(raw: NSPoint, disableSnap: Bool) {
        let imgSz = imageScreenFrame.size
        let target = (!disableSnap ? onSnapOrigin?(raw, imgSz, self) : nil) ?? raw
        let s = imageScale
        let pad = PinGlowContainerView.glowPadding
        setFrameOrigin(NSPoint(x: (target.x * s).rounded() / s - pad, y: (target.y * s).rounded() / s - pad))
    }
}

// MARK: - 贴图快捷键、复制保存与翻转操作

/// 贴图窗口的外置悬浮条联动、鼠标穿透对照、无损二次标注与右键菜单扩展
extension PinWindow {
    func syncHoverBarVisibility() {
        hideHoverWorkItem?.cancel()
        hideHoverWorkItem = nil

        if !isHoverBarAllowed {
            hoverBarPanel.hideCleanly()
            return
        }

        if isMouseInPin || isMouseInHoverBar || isDraggingFromBar {
            hoverBarPanel.reposition(anchoringTo: imageScreenFrame, on: screen)
            if !hoverBarPanel.isVisible || !hoverBarPanel.isOnActiveSpace {
                hoverBarPanel.orderFrontRegardless()
                if let edge = resizeState.activeEdge ?? resizeState.hoveredEdge {
                    PinResizeCursorFactory.cursor(for: edge).set()
                }
            }
        } else {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isMouseInPin, !self.isMouseInHoverBar, !self.isDraggingFromBar else { return }
                    if self.shouldKeepHoverBarAliveNow() { return }
                    self.hoverBarPanel.hideCleanly()
                }
            }
            hideHoverWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: work)
        }
    }

    @objc func enableClickThrough() { setClickThrough(true) }

    func setClickThrough(_ enabled: Bool) {
        guard isClickThrough != enabled else { return }
        if enabled { endAnnotationEditing(commit: false) }
        isClickThrough = enabled
        ignoresMouseEvents = enabled
        pinContentView.isGhostMode = enabled
        syncHoverBarVisibility()
        if enabled {
            preGhostAlpha = alphaValue
            if alphaValue > 0.82 { alphaValue = 0.68 }
            ToastHUD.show(message: "已开启贴图鼠标穿透对照 · 可在顶部菜单栏一键恢复")
        } else {
            alphaValue = preGhostAlpha
        }
        onStateChanged?()
    }

    private func acquireBaseSampler() -> PixelSampler {
        if let existing = activeBaseSampler { return existing }
        let created = PixelSampler(cgImage: baseCGImage)
        activeBaseSampler = created
        return created
    }

    @objc func beginAnnotationEditing() {
        guard editorCanvas == nil, !isClickThrough else { return }
        pinContentView.liveTextView.clearSelection()
        pinContentView.liveTextView.setPreviewImageOnly(cgImage: baseCGImage, logicalSize: baseSize)
        pinContentView.isAnnotating = true
        syncGlowState()
        syncHoverBarVisibility()

        let canvas = PinAnnotationCanvasView(baseSampler: acquireBaseSampler(), baseSize: baseSize, imageScale: imageScale)
        canvas.frame = pinContentView.bounds
        canvas.autoresizingMask = [.width, .height]
        canvas.doc = annotationDoc
        canvas.zoomProvider = { [weak self] in self?.zoomFactor ?? 1.0 }
        canvas.onCommit = { [weak self] updatedDoc in
            self?.annotationDoc = updatedDoc
            self?.endAnnotationEditing(commit: true)
        }
        canvas.onCancel = { [weak self] in self?.endAnnotationEditing(commit: false) }

        let panel = PinToolbarPanel()
        canvas.onDocStateChanged = { [weak self, weak panel, weak canvas] in
            guard let self, let panel, let canvas else { return }
            panel.barView.activeTool = canvas.activeTool
            panel.barView.textCapsule = canvas.style.textCapsule
            panel.barView.canUndo = canvas.doc.canUndo
            panel.barView.canRedo = canvas.doc.canRedo
            panel.barView.nextStepNumber = canvas.doc.nextStepNumber()
            panel.subbarView.activeTool = canvas.activeTool
            panel.subbarView.lineWidth = canvas.style.lineWidth
            panel.subbarView.colorIndex = canvas.colorIndex
            panel.subbarView.textCapsule = canvas.style.textCapsule
            panel.reposition(anchoringTo: self.imageScreenFrame, on: self.screen)
        }
        let handleBarAct: (ToolbarView.Action) -> Void = { [weak self, weak canvas, weak panel] act in
            guard let self, let canvas, let panel else { return }
            canvas.commitTextField()
            switch act {
            case .selectTool(let t):
                canvas.activeTool = t; panel.barView.activeTool = t; panel.subbarView.activeTool = t
                panel.reposition(anchoringTo: self.imageScreenFrame, on: self.screen)
            case .toggleTextCapsule: canvas.togglePinTextCapsule()
            case .selectColor(let c):
                canvas.applyStyleColor(c); panel.barView.colorIndex = c; panel.subbarView.colorIndex = c
            case .selectStroke(let w):
                canvas.applyStrokeWidth(w); panel.barView.lineWidth = w; panel.subbarView.lineWidth = w
            case .undo: _ = canvas.doc.undo(); canvas.needsDisplay = true; canvas.onDocStateChanged?()
            case .redo: _ = canvas.doc.redo(); canvas.needsDisplay = true; canvas.onDocStateChanged?()
            case .clearAnnotations: canvas.doc.clearAll(); canvas.selectedIndex = nil; canvas.needsDisplay = true; canvas.onDocStateChanged?()
            case .autoRedact:
                let useBlur = (canvas.activeTool == .gaussianBlur), st = canvas.style, img = self.baseCGImage, bSz = self.baseSize
                ToastHUD.show(message: "正在离线扫描隐私敏感信息…")
                Task { @MainActor [weak canvas] in
                    let boxes = await VisionTextExtractor.detectSensitiveBoxesOffMain(cgImage: img)
                    guard let canvas, !boxes.isEmpty else { ToastHUD.show(message: "未检测到隐私敏感信息"); return }
                    canvas.doc.beginTransaction()
                    var objs = canvas.doc.objects
                    for nb in boxes {
                        let r = CGRect(x: nb.minX * bSz.width, y: (1 - nb.maxY) * bSz.height, width: nb.width * bSz.width, height: nb.height * bSz.height).insetBy(dx: -3, dy: -2).intersection(CGRect(origin: .zero, size: bSz))
                        if r.width >= 4, r.height >= 4 { objs.append(Annotation(payload: useBlur ? .gaussianBlur(r) : .mosaic(r), style: st)) }
                    }
                    canvas.doc.replaceObjectsWithoutHistory(objs); canvas.doc.commitTransaction(changed: true)
                    canvas.needsDisplay = true; canvas.onDocStateChanged?()
                    ToastHUD.show(message: "✓ 已一键遮盖 \(boxes.count) 处隐私敏感信息")
                }
            case .cancel: self.endAnnotationEditing(commit: false)
            case .confirmCopy: self.annotationDoc = canvas.doc; self.endAnnotationEditing(commit: true)
            default: break
            }
        }
        panel.barView.onAction = handleBarAct
        panel.subbarView.onAction = handleBarAct

        pinContentView.addSubview(canvas)
        editorCanvas = canvas
        toolbarPanel = panel
        panel.reposition(anchoringTo: imageScreenFrame, on: screen)
        panel.orderFrontRegardless()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(canvas)
        canvas.onDocStateChanged?()
    }

    func endAnnotationEditing(commit: Bool, reanalyzeLiveText: Bool = true) {
        guard editorCanvas != nil || toolbarPanel != nil else { return }
        editorCanvas?.commitTextField()
        if commit, let baked = AnnotationRenderer.bakeExportImage(
            sampler: acquireBaseSampler(), selection: CGRect(origin: .zero, size: baseSize),
            imageScale: imageScale, annotations: annotationDoc.objects
        ) {
            currentCGImage = baked
            ToastHUD.show(message: "已更新贴图标注")
        }
        editorCanvas?.removeFromSuperview(); editorCanvas = nil
        toolbarPanel?.barView.clearHover()
        toolbarPanel?.subbarView.clearHover()
        toolbarPanel?.orderOut(nil); toolbarPanel = nil
        activeBaseSampler = nil
        pinContentView.isAnnotating = false
        if reanalyzeLiveText {
            pinContentView.liveTextView.configure(cgImage: currentCGImage, logicalSize: baseSize)
            reconcileHoverFromCurrentMouse()
        } else {
            syncHoverBarVisibility()
        }
        AnnotationRenderer.purgeCaches()
    }

    @objc func copyImage() { ClipboardAndSave.copyToClipboard(cgImage: currentCGImage, scaleFactor: imageScale) }
    @objc func copyImageWithPath() {
        ClipboardAndSave.copyToClipboard(cgImage: currentCGImage, scaleFactor: imageScale, forceIncludePath: true)
        ToastHUD.show(message: "已复制贴图与临时文件路径 · 可直接粘贴到任意终端")
    }
    @objc func openOCRPanel() { if let scr = screen ?? NSScreen.main ?? NSScreen.screens.first { onExtractOCR?(currentCGImage, imageScale, scr) } }
    @objc func openTranslatePanel() { if let scr = screen ?? NSScreen.main ?? NSScreen.screens.first { onTranslateImage?(currentCGImage, imageScale, scr) } }
    @objc func scanBarcodeInPin() {
        let img = currentCGImage
        Task { @MainActor in
            let codes = await VisionTextExtractor.detectBarcodesOffMain(cgImage: img)
            if let first = codes.first {
                OverlayView.presentBarcodeToast(first)
            } else {
                ToastHUD.show(message: "贴图中未检测到二维码或条形码")
            }
        }
    }
    @objc func toggleTextHighlights() {
        pinContentView.liveTextView.highlightBlocks.toggle()
        highlightMenuItem?.state = pinContentView.liveTextView.highlightBlocks ? .on : .off
    }
    @objc func saveImage() { onSavePNG?(currentCGImage, imageScale) }
    @objc func quickSaveImage() { onQuickSavePNG?(currentCGImage, imageScale) }
    @objc func resetZoom() { applyZoom(newZoom: 1.0); alphaValue = 1.0 }
    @objc func toggleHalfOpacity() { alphaValue = alphaValue < 0.95 ? 1.0 : 0.55 }
    @objc func rotateClockwise90() { applyImageTransform(ImageTransform.rotateClockwise90, toast: "已顺时针旋转 90°") }
    @objc func flipHorizontal() { applyImageTransform(ImageTransform.flipHorizontal, toast: "已水平镜像翻转") }

    private func applyImageTransform(_ transform: (CGImage) -> CGImage?, toast: String) {
        guard editorCanvas == nil, !isClickThrough else { return }
        guard let nextCG = transform(currentCGImage) else { return }
        baseCGImage = nextCG
        currentCGImage = nextCG
        activeBaseSampler = nil
        annotationDoc = AnnotationDocument()
        let nextBase = NSSize(
            width: max(8, CGFloat(nextCG.width) / imageScale),
            height: max(8, CGFloat(nextCG.height) / imageScale)
        )
        baseSize = nextBase
        let scr = screen ?? NSScreen.main ?? NSScreen.screens.first
        let vf = scr?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var sz = NSSize(width: round(nextBase.width * zoomFactor), height: round(nextBase.height * zoomFactor))
        if sz.width > vf.width - 24 || sz.height > vf.height - 48 {
            let fit = ImageTransform.fittedPinRect(baseSize: nextBase, visibleBounds: vf)
            zoomFactor = fit.zoom
            sz = fit.frame.size
        }
        let old = imageScreenFrame
        let nx = ((old.midX - sz.width * 0.5) * imageScale).rounded() / imageScale
        let ny = ((old.midY - sz.height * 0.5) * imageScale).rounded() / imageScale
        setImageScreenFrame(NSRect(origin: NSPoint(x: nx, y: ny), size: sz))
        pinContentView.liveTextView.configure(cgImage: nextCG, logicalSize: nextBase)
        if hoverBarPanel.isVisible { hoverBarPanel.reposition(anchoringTo: imageScreenFrame, on: screen) }
        reconcileHoverFromCurrentMouse()
        ToastHUD.show(message: toast)
    }

    @objc func closePin() {
        hideHoverWorkItem?.cancel(); hideHoverWorkItem = nil
        hoverBarPanel.hideCleanly()
        endCropEditing()
        endAnnotationEditing(commit: false, reanalyzeLiveText: false)
        activeBaseSampler = nil
        pinContentView.liveTextView.clearAll()
        pinContentView.menu = nil
        pinContentView.liveTextView.menu = nil
        orderOut(nil)
        onClose?(self)
    }

    @objc func closeAllPins() { onCloseAll?() }

    func applyZoom(newZoom: CGFloat) {
        guard abs(newZoom - zoomFactor) > 0.001 else { return }
        let mouse = NSEvent.mouseLocation, old = imageScreenFrame
        let rx = old.width > 0 ? (mouse.x - old.minX) / old.width : 0.5
        let ry = old.height > 0 ? (mouse.y - old.minY) / old.height : 0.5
        zoomFactor = newZoom
        let sz = NSSize(width: round(baseSize.width * zoomFactor), height: round(baseSize.height * zoomFactor))
        let ax = ((old.contains(mouse) ? mouse.x - sz.width * rx : old.midX - sz.width * 0.5) * imageScale).rounded() / imageScale
        let ay = ((old.contains(mouse) ? mouse.y - sz.height * ry : old.midY - sz.height * 0.5) * imageScale).rounded() / imageScale
        setImageScreenFrame(NSRect(origin: NSPoint(x: ax, y: ay), size: sz))
        toolbarPanel?.reposition(anchoringTo: imageScreenFrame, on: screen)
        if hoverBarPanel.isVisible { hoverBarPanel.reposition(anchoringTo: imageScreenFrame, on: screen) }
        reconcileHoverFromCurrentMouse()
    }

    func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "编辑 / 二次标注贴图 (E)…", action: #selector(beginAnnotationEditing), keyEquivalent: "")
        menu.addItem(withTitle: "二次裁剪贴图 (C)…", action: #selector(beginCropEditing), keyEquivalent: "")
        menu.addItem(withTitle: "开启鼠标穿透对照 (P)", action: #selector(enableClickThrough), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "提取图中文字 (T)…", action: #selector(openOCRPanel), keyEquivalent: "o")
        menu.addItem(withTitle: "翻译图中文字 (Y)…", action: #selector(openTranslatePanel), keyEquivalent: "")
        menu.addItem(withTitle: "扫描二维码 / 条形码", action: #selector(scanBarcodeInPin), keyEquivalent: "")
        let hlItem = NSMenuItem(title: "高亮图中可划选文字块", action: #selector(toggleTextHighlights), keyEquivalent: "")
        self.highlightMenuItem = hlItem
        menu.addItem(hlItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "复制贴图图像 (按住 ⌘ 可拖拽成文件)", action: #selector(copyImage), keyEquivalent: "c")
        menu.addItem(withTitle: "复制临时文件路径 (供 IDE / 终端粘贴)", action: #selector(copyImageWithPath), keyEquivalent: "")
        let quickItem = NSMenuItem(title: "一键保存到默认目录", action: #selector(quickSaveImage), keyEquivalent: "s")
        menu.addItem(quickItem)
        let saveAsItem = NSMenuItem(title: "另存为…", action: #selector(saveImage), keyEquivalent: "s")
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(saveAsItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "顺时针旋转 90° (R)", action: #selector(rotateClockwise90), keyEquivalent: "")
        menu.addItem(withTitle: "水平镜像翻转 (H)", action: #selector(flipHorizontal), keyEquivalent: "")
        menu.addItem(withTitle: "自适应屏幕大小", action: #selector(fitToScreen), keyEquivalent: "")
        menu.addItem(withTitle: "重置 100% 大小与不透明", action: #selector(resetZoom), keyEquivalent: "0")
        menu.addItem(withTitle: "切换半透明对照 (55%)", action: #selector(toggleHalfOpacity), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "关闭此贴图 (Esc / 双击空白处)", action: #selector(closePin), keyEquivalent: "")
        menu.addItem(withTitle: "关闭全部贴图", action: #selector(closeAllPins), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }
}
