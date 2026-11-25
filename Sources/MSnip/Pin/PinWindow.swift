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
            if pinContentView.bounds.contains(cp), !isMouseInPin { updatePinHover(true) }
            if handleResizeHover(contentPoint: cp) { return }
            super.sendEvent(event)

        case .cursorUpdate:
            let cp = pinContentView.convert(event.locationInWindow, from: nil)
            if let edge = resizeState.activeEdge ?? PinResizeEdge.hitTest(point: cp, in: pinContentView.bounds) {
                PinResizeCursorFactory.cursor(for: edge).set(); return
            }
            super.sendEvent(event)

        case .leftMouseDown:
            let cp = pinContentView.convert(event.locationInWindow, from: nil)
            guard pinContentView.bounds.contains(cp) else { return }
            if !isKeyWindow { makeKeyAndOrderFront(nil) }
            if event.modifierFlags.contains(.command) {
                pinContentView.startPNGFileDrag(with: event, cgImage: currentCGImage, scaleFactor: imageScale); return
            }
            if let edge = PinResizeEdge.hitTest(point: cp, in: pinContentView.bounds) {
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
