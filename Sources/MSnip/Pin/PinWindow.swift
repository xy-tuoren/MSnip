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

    let baseCGImage: CGImage
    lazy var baseSampler: PixelSampler = PixelSampler(cgImage: baseCGImage)
    var currentCGImage: CGImage
    let imageScale: CGFloat
    let baseSize: NSSize
    var zoomFactor: CGFloat = 1.0
    var preGhostAlpha: CGFloat = 1.0
    var isClickThrough: Bool = false

    var annotationDoc = AnnotationDocument()
    var editorCanvas: PinAnnotationCanvasView?
    var toolbarPanel: PinToolbarPanel?
    let hoverBarPanel = PinHoverBarPanel()

    var isMouseInPin = false
    var isMouseInHoverBar = false
    var isDraggingFromBar = false
    var hideHoverWorkItem: DispatchWorkItem?

    private var isDraggingWindow = false
    private var dragMouseStart: NSPoint = .zero
    private var dragOriginStart: NSPoint = .zero
    let pinContentView: PinContentView
    var highlightMenuItem: NSMenuItem?

    init(cgImage: CGImage, scaleFactor: CGFloat, screenOriginTopLeft: CGPoint?, on screen: NSScreen) {
        self.baseCGImage = cgImage
        self.currentCGImage = cgImage
        let s = max(1.0, scaleFactor)
        self.imageScale = s
        self.baseSize = NSSize(
            width: max(8, CGFloat(cgImage.width) / s),
            height: max(8, CGFloat(cgImage.height) / s)
        )
        self.pinContentView = PinContentView(cgImage: cgImage, baseSize: baseSize)

        let snapPx: (CGFloat) -> CGFloat = { v in (v * s).rounded() / s }
        let frameOrigin: NSPoint
        if let topLeft = screenOriginTopLeft {
            let yBottom = screen.frame.maxY - topLeft.y - baseSize.height
            frameOrigin = NSPoint(x: snapPx(screen.frame.minX + topLeft.x), y: snapPx(yBottom))
        } else {
            let visible = screen.visibleFrame
            frameOrigin = NSPoint(x: snapPx(visible.midX - baseSize.width * 0.5), y: snapPx(visible.midY - baseSize.height * 0.5))
        }

        super.init(
            contentRect: NSRect(origin: frameOrigin, size: baseSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.animationBehavior = .none
        self.becomesKeyOnlyIfNeeded = false
        self.isFloatingPanel = true
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.contentView = pinContentView

        pinContentView.onHoverChanged = { [weak self] inside in
            self?.isMouseInPin = inside
            self?.syncHoverBarVisibility()
        }
        hoverBarPanel.barView.onHoverChanged = { [weak self] inside in
            self?.isMouseInHoverBar = inside
            self?.syncHoverBarVisibility()
        }
        hoverBarPanel.barView.onAction = { [weak self] act in
            guard let self else { return }
            switch act {
            case .annotate: self.beginAnnotationEditing()
            case .ocr:      self.openOCRPanel()
            case .close:    self.closePin()
            }
        }
        hoverBarPanel.barView.onDragStart = { [weak self] in
            guard let self else { return }
            self.makeKeyAndOrderFront(nil)
            self.isDraggingFromBar = true
            self.dragMouseStart = NSEvent.mouseLocation
            self.dragOriginStart = self.frame.origin
        }
        hoverBarPanel.barView.onDragMove = { [weak self] in
            guard let self, self.isDraggingFromBar else { return }
            let now = NSEvent.mouseLocation
            let s = self.imageScale
            self.setFrameOrigin(NSPoint(
                x: ((self.dragOriginStart.x + (now.x - self.dragMouseStart.x)) * s).rounded() / s,
                y: ((self.dragOriginStart.y + (now.y - self.dragMouseStart.y)) * s).rounded() / s
            ))
            self.hoverBarPanel.reposition(anchoringTo: self.frame, on: self.screen)
        }
        hoverBarPanel.barView.onDragEnd = { [weak self] in
            guard let self else { return }
            self.isDraggingFromBar = false
            self.syncHoverBarVisibility()
        }

        let menu = buildContextMenu()
        pinContentView.menu = menu
        pinContentView.liveTextView.menu = menu
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func becomeKey() { super.becomeKey(); pinContentView.isSelectedKey = true }
    override func resignKey() { super.resignKey(); pinContentView.isSelectedKey = false }

    // MARK: - Event Routing (Direct Text Selection + Blank/Handle Drag + Guaranteed Esc)

    override func sendEvent(_ event: NSEvent) {
        if editorCanvas != nil {
            super.sendEvent(event)
            return
        }
        switch event.type {
        case .leftMouseDown:
            if !isKeyWindow { makeKeyAndOrderFront(nil) }
            if event.modifierFlags.contains(.command) {
                pinContentView.startPNGFileDrag(with: event, cgImage: currentCGImage, scaleFactor: imageScale)
                return
            }
            let forceDrag = event.modifierFlags.contains(.option)
            let hitLiveText = !forceDrag && pinContentView.liveTextView.hasInteractiveItem(atWindowPoint: event.locationInWindow)
            if hitLiveText {
                isDraggingWindow = false
                super.sendEvent(event)
                return
            }
            pinContentView.liveTextView.clearSelection()
            if event.clickCount == 2 {
                closePin()
                return
            }
            isDraggingWindow = true
            dragMouseStart = NSEvent.mouseLocation
            dragOriginStart = frame.origin

        case .leftMouseDragged:
            if isDraggingWindow {
                let now = NSEvent.mouseLocation
                setFrameOrigin(NSPoint(
                    x: ((dragOriginStart.x + (now.x - dragMouseStart.x)) * imageScale).rounded() / imageScale,
                    y: ((dragOriginStart.y + (now.y - dragMouseStart.y)) * imageScale).rounded() / imageScale
                ))
                if hoverBarPanel.isVisible {
                    hoverBarPanel.reposition(anchoringTo: frame, on: screen)
                }
                return
            }
            super.sendEvent(event)

        case .leftMouseUp:
            if isDraggingWindow {
                isDraggingWindow = false
                return
            }
            super.sendEvent(event)

        case .keyDown:
            // 在窗口分发入口直接拦截 Esc 与单键快捷操作，防止 VisionKit 子视图吞噬按键导致 Esc 不响应
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
            if pinContentView.liveTextView.copySelectionIfActive() {
                ToastHUD.show(message: "已复制贴图划选文字")
                return true
            }
            copyImage()
            ToastHUD.show(message: "已复制贴图图像")
            return true
        }
        if flags == .command && chars == "o" {
            openOCRPanel()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }
        if let canvas = editorCanvas {
            let d: CGFloat = delta > 0 ? 1.0 : -1.0
            let nextW = min(ToolbarSubbarView.maxStroke, max(ToolbarSubbarView.minStroke, (canvas.style.lineWidth + d).rounded()))
            canvas.applyStrokeWidth(nextW)
            toolbarPanel?.barView.lineWidth = nextW
            toolbarPanel?.subbarView.lineWidth = nextW
            return
        }
        let step: CGFloat = event.hasPreciseScrollingDeltas ? delta * 0.004 : (delta > 0 ? 0.08 : -0.08)
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            alphaValue = min(1.0, max(0.2, alphaValue + step))
        } else {
            applyZoom(newZoom: min(4.0, max(0.25, zoomFactor * (1.0 + step))))
        }
    }

    private func handlePinKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.keyCode == 53 {
            closePin()
            return true
        }
        if flags.contains(.command), chars == "s" {
            if flags.contains(.shift) { quickSaveImage() } else { saveImage() }
            return true
        }
        if flags.isEmpty {
            switch chars {
            case "e": beginAnnotationEditing(); return true
            case "p": enableClickThrough(); return true
            case "t": openOCRPanel(); return true
            default: break
            }
        }
        return false
    }
}
