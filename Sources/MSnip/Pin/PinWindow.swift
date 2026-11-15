import AppKit
import CoreGraphics
import Foundation

/// 单个置顶贴图窗口：不抢占焦点（`.nonactivatingPanel`），内置 macOS 实况文本支持原图直接划词复制，
/// 空白处拖拽移动、滚轮缩放、`⌘`+滚轮调透明度、双击空白处关闭与右键 OCR 菜单。
final class PinWindow: NSPanel {
    var onClose: ((PinWindow) -> Void)?
    var onCloseAll: (() -> Void)?
    var onSavePNG: ((CGImage, CGFloat) -> Void)?
    var onExtractOCR: ((CGImage, CGFloat, NSScreen) -> Void)?

    private let cgImage: CGImage
    private let imageScale: CGFloat
    private let baseSize: NSSize
    private var zoomFactor: CGFloat = 1.0
    private var isDraggingWindow = false
    private var dragMouseStart: NSPoint = .zero
    private var dragOriginStart: NSPoint = .zero
    private let pinContentView: PinContentView
    private var highlightMenuItem: NSMenuItem?

    init(cgImage: CGImage, scaleFactor: CGFloat, screenOriginTopLeft: CGPoint?, on screen: NSScreen) {
        self.cgImage = cgImage
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
            frameOrigin = NSPoint(
                x: visible.midX - baseSize.width * 0.5,
                y: visible.midY - baseSize.height * 0.5
            )
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

        let menu = buildContextMenu()
        pinContentView.menu = menu
        pinContentView.liveTextView.menu = menu
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Event Routing (Live Text Selection vs Window Drag)

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
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
        let step: CGFloat = event.hasPreciseScrollingDeltas ? delta * 0.004 : (delta > 0 ? 0.08 : -0.08)

        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            alphaValue = min(1.0, max(0.2, alphaValue + step))
        } else {
            applyZoom(newZoom: min(4.0, max(0.25, zoomFactor * (1.0 + step))))
        }
    }

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.keyCode == 53 {
            if pinContentView.liveTextView.hasSelection {
                pinContentView.liveTextView.clearSelection()
            } else {
                closePin()
            }
        } else if event.modifierFlags.contains(.command), chars == "s" {
            saveImage()
        } else if chars == "t", !event.modifierFlags.contains(.command) {
            openOCRPanel()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Actions

    @objc private func copyImage() {
        ClipboardAndSave.copyToClipboard(cgImage: cgImage, scaleFactor: imageScale)
    }

    @objc private func openOCRPanel() {
        let scr = screen ?? NSScreen.main ?? NSScreen.screens.first
        if let scr { onExtractOCR?(cgImage, imageScale, scr) }
    }

    @objc private func toggleTextHighlights() {
        pinContentView.liveTextView.highlightBlocks.toggle()
        highlightMenuItem?.state = pinContentView.liveTextView.highlightBlocks ? .on : .off
    }

    @objc private func saveImage() { onSavePNG?(cgImage, imageScale) }
    @objc private func resetZoom() { applyZoom(newZoom: 1.0); alphaValue = 1.0 }
    @objc private func toggleHalfOpacity() { alphaValue = alphaValue < 0.95 ? 1.0 : 0.55 }
    @objc func closePin() { orderOut(nil); onClose?(self) }
    @objc private func closeAllPins() { onCloseAll?() }

    private func applyZoom(newZoom: CGFloat) {
        guard abs(newZoom - zoomFactor) > 0.001 else { return }
        let mouseScreen = NSEvent.mouseLocation
        let oldFrame = frame
        let relX = oldFrame.width > 0 ? (mouseScreen.x - oldFrame.minX) / oldFrame.width : 0.5
        let relY = oldFrame.height > 0 ? (mouseScreen.y - oldFrame.minY) / oldFrame.height : 0.5

        zoomFactor = newZoom
        let newSize = NSSize(width: round(baseSize.width * zoomFactor), height: round(baseSize.height * zoomFactor))
        let anchorX = oldFrame.contains(mouseScreen) ? mouseScreen.x - newSize.width * relX : oldFrame.midX - newSize.width * 0.5
        let anchorY = oldFrame.contains(mouseScreen) ? mouseScreen.y - newSize.height * relY : oldFrame.midY - newSize.height * 0.5
        setFrame(NSRect(origin: NSPoint(x: anchorX, y: anchorY), size: newSize), display: true)
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "提取图中文字 (OCR 对照窗)…", action: #selector(openOCRPanel), keyEquivalent: "o")
        let hlItem = NSMenuItem(title: "高亮图中可划选文字块", action: #selector(toggleTextHighlights), keyEquivalent: "")
        self.highlightMenuItem = hlItem
        menu.addItem(hlItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "复制贴图图像", action: #selector(copyImage), keyEquivalent: "c")
        menu.addItem(withTitle: "另存为 PNG...", action: #selector(saveImage), keyEquivalent: "s")
        menu.addItem(.separator())
        menu.addItem(withTitle: "重置 100% 大小与不透明", action: #selector(resetZoom), keyEquivalent: "0")
        menu.addItem(withTitle: "切换半透明对照 (55%)", action: #selector(toggleHalfOpacity), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "关闭此贴图 (双击空白处)", action: #selector(closePin), keyEquivalent: "")
        menu.addItem(withTitle: "关闭全部贴图", action: #selector(closeAllPins), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }
}

/// 贴图内容容器（承载实况文本图层与 1pt 精致描边）
private final class PinContentView: NSView {
    let liveTextView = LiveTextImageView(scaling: .scaleAxesIndependently)

    init(cgImage: CGImage, baseSize: NSSize) {
        super.init(frame: NSRect(origin: .zero, size: baseSize))
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        layer?.borderWidth = 1.0
        layer?.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor

        liveTextView.frame = bounds
        liveTextView.autoresizingMask = [.width, .height]
        liveTextView.configure(cgImage: cgImage, logicalSize: baseSize)
        addSubview(liveTextView)
        updateTrackingAreas()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor
    }
}
