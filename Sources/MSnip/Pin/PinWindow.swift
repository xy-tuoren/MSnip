import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 单个置顶贴图窗口：支持实况划词复制、鼠标穿透对照、`⌘+拖拽`（或右上角按钮）直投 PNG 文件与无损二次圈记标注
final class PinWindow: NSPanel {
    var onClose: ((PinWindow) -> Void)?
    var onCloseAll: (() -> Void)?
    var onStateChanged: (() -> Void)?
    var onSavePNG: ((CGImage, CGFloat) -> Void)?
    var onExtractOCR: ((CGImage, CGFloat, NSScreen) -> Void)?

    let baseCGImage: CGImage
    let baseSampler: PixelSampler
    var currentCGImage: CGImage
    let imageScale: CGFloat
    let baseSize: NSSize
    var zoomFactor: CGFloat = 1.0
    var preGhostAlpha: CGFloat = 1.0
    var isClickThrough: Bool = false

    var annotationDoc = AnnotationDocument()
    var editorCanvas: PinAnnotationCanvasView?
    var toolbarPanel: PinToolbarPanel?

    private var isDraggingWindow = false
    private var dragMouseStart: NSPoint = .zero
    private var dragOriginStart: NSPoint = .zero
    let pinContentView: PinContentView
    var highlightMenuItem: NSMenuItem?

    init(cgImage: CGImage, scaleFactor: CGFloat, screenOriginTopLeft: CGPoint?, on screen: NSScreen) {
        self.baseCGImage = cgImage
        self.baseSampler = PixelSampler(cgImage: cgImage)
        self.currentCGImage = cgImage
        self.imageScale = max(1.0, scaleFactor)
        self.baseSize = NSSize(
            width: max(24, CGFloat(cgImage.width) / self.imageScale),
            height: max(24, CGFloat(cgImage.height) / self.imageScale)
        )
        self.pinContentView = PinContentView(cgImage: cgImage, baseSize: baseSize)

        let frameOrigin: NSPoint
        if let topLeft = screenOriginTopLeft {
            let yBottom = screen.frame.maxY - topLeft.y - baseSize.height
            frameOrigin = NSPoint(x: screen.frame.minX + topLeft.x, y: yBottom)
        } else {
            let visible = screen.visibleFrame
            frameOrigin = NSPoint(x: visible.midX - baseSize.width * 0.5, y: visible.midY - baseSize.height * 0.5)
        }

        super.init(
            contentRect: NSRect(origin: frameOrigin, size: baseSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isFloatingPanel = true
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.contentView = pinContentView

        pinContentView.onRequestAnnotate = { [weak self] in self?.beginAnnotationEditing() }
        pinContentView.onRequestFileDrag = { [weak self] ev in
            guard let self else { return }
            self.pinContentView.startPNGFileDrag(with: ev, cgImage: self.currentCGImage, scaleFactor: self.imageScale)
        }

        let menu = buildContextMenu()
        pinContentView.menu = menu
        pinContentView.liveTextView.menu = menu
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Event Routing (Annotation / File Drag / Live Text / Window Move)

    override func sendEvent(_ event: NSEvent) {
        if editorCanvas != nil {
            super.sendEvent(event)
            return
        }
        switch event.type {
        case .leftMouseDown:
            if pinContentView.hitHoverControl(atWindowPoint: event.locationInWindow) {
                super.sendEvent(event)
                return
            }
            if event.modifierFlags.contains(.command) {
                pinContentView.startPNGFileDrag(with: event, cgImage: currentCGImage, scaleFactor: imageScale)
                return
            }
            let forceDrag = event.modifierFlags.contains(.option)
            let hitLiveText = !forceDrag && pinContentView.liveTextView.hasInteractiveItem(atWindowPoint: event.locationInWindow)
            if hitLiveText {
                isDraggingWindow = false
                if !isKeyWindow { makeKey() }
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
                    x: dragOriginStart.x + (now.x - dragMouseStart.x),
                    y: dragOriginStart.y + (now.y - dragMouseStart.y)
                ))
                return
            }
            super.sendEvent(event)

        case .leftMouseUp:
            if isDraggingWindow {
                isDraggingWindow = false
                return
            }
            super.sendEvent(event)

        default:
            super.sendEvent(event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if editorCanvas != nil { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command && chars == "c" {
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
            let d: CGFloat = delta > 0 ? 0.5 : -0.5
            let nextW = min(18.0, max(1.0, canvas.style.lineWidth + d))
            canvas.style.mosaicBlockSize = min(32.0, max(5.0, canvas.style.mosaicBlockSize + d * 1.5))
            canvas.applyStrokeWidth(nextW)
            toolbarPanel?.barView.lineWidth = nextW
            return
        }
        let step: CGFloat = event.hasPreciseScrollingDeltas ? delta * 0.004 : (delta > 0 ? 0.08 : -0.08)
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            alphaValue = min(1.0, max(0.2, alphaValue + step))
        } else {
            applyZoom(newZoom: min(4.0, max(0.25, zoomFactor * (1.0 + step))))
        }
    }

    override func keyDown(with event: NSEvent) {
        if editorCanvas != nil { super.keyDown(with: event); return }
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.keyCode == 53 {
            if pinContentView.liveTextView.hasSelection {
                pinContentView.liveTextView.clearSelection()
            } else {
                closePin()
            }
        } else if event.modifierFlags.contains(.command), chars == "s" {
            saveImage()
        } else if chars == "e", !event.modifierFlags.contains(.command) {
            beginAnnotationEditing()
        } else if chars == "p", !event.modifierFlags.contains(.command) {
            enableClickThrough()
        } else if chars == "t", !event.modifierFlags.contains(.command) {
            openOCRPanel()
        } else {
            super.keyDown(with: event)
        }
    }
}
