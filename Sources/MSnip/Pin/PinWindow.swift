import AppKit
import CoreGraphics
import Foundation

/// 单个置顶贴图窗口：不抢占当前工作焦点（`.nonactivatingPanel`），
/// 支持拖拽移动、滚轮缩放、`⌘`+滚轮调透明度、双击/Esc 关闭与右键菜单。
final class PinWindow: NSPanel {
    var onClose: ((PinWindow) -> Void)?
    var onCloseAll: (() -> Void)?
    var onSavePNG: ((CGImage, CGFloat) -> Void)?

    private let cgImage: CGImage
    private let imageScale: CGFloat
    private let baseSize: NSSize
    private var zoomFactor: CGFloat = 1.0
    private var dragMouseStart: NSPoint = .zero
    private var dragOriginStart: NSPoint = .zero
    private let pinContentView: PinContentView

    init(cgImage: CGImage, scaleFactor: CGFloat, screenOriginTopLeft: CGPoint?, on screen: NSScreen) {
        self.cgImage = cgImage
        self.imageScale = max(1.0, scaleFactor)
        self.baseSize = NSSize(
            width: max(24, CGFloat(cgImage.width) / self.imageScale),
            height: max(24, CGFloat(cgImage.height) / self.imageScale)
        )

        let nsImage = NSImage(cgImage: cgImage, size: baseSize)
        self.pinContentView = PinContentView(image: nsImage)

        let frameOrigin: NSPoint
        if let topLeft = screenOriginTopLeft {
            // 将屏幕左上角逻辑点坐标转换为 AppKit 左下角窗口坐标
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

        pinContentView.menu = buildContextMenu()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // MARK: - Mouse & Keyboard

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            closePin()
            return
        }
        dragMouseStart = NSEvent.mouseLocation
        dragOriginStart = frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        let newOrigin = NSPoint(
            x: dragOriginStart.x + (now.x - dragMouseStart.x),
            y: dragOriginStart.y + (now.y - dragMouseStart.y)
        )
        setFrameOrigin(newOrigin)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.01 else { return }
        let step: CGFloat = event.hasPreciseScrollingDeltas ? delta * 0.004 : (delta > 0 ? 0.08 : -0.08)

        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            // ⌘ / ⌃ + 滚轮：调节贴图透明度
            alphaValue = min(1.0, max(0.2, alphaValue + step))
        } else {
            // 普通滚轮：以鼠标所在位置为锚点平滑缩放
            applyZoom(newZoom: min(4.0, max(0.25, zoomFactor * (1.0 + step))))
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Esc
            closePin()
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
            copyImage()
        } else if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "s" {
            saveImage()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Actions

    @objc private func copyImage() {
        ClipboardAndSave.copyToClipboard(cgImage: cgImage, scaleFactor: imageScale)
    }

    @objc private func saveImage() {
        onSavePNG?(cgImage, imageScale)
    }

    @objc private func resetZoom() {
        applyZoom(newZoom: 1.0)
        alphaValue = 1.0
    }

    @objc private func toggleHalfOpacity() {
        alphaValue = alphaValue < 0.95 ? 1.0 : 0.55
    }

    @objc func closePin() {
        orderOut(nil)
        onClose?(self)
    }

    @objc private func closeAllPins() {
        onCloseAll?()
    }

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
        pinContentView.needsDisplay = true
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "复制贴图", action: #selector(copyImage), keyEquivalent: "c")
        menu.addItem(withTitle: "另存为 PNG...", action: #selector(saveImage), keyEquivalent: "s")
        menu.addItem(.separator())
        menu.addItem(withTitle: "重置 100% 大小与不透明", action: #selector(resetZoom), keyEquivalent: "0")
        menu.addItem(withTitle: "切换半透明对照 (55%)", action: #selector(toggleHalfOpacity), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "关闭此贴图 (双击)", action: #selector(closePin), keyEquivalent: "")
        menu.addItem(withTitle: "关闭全部贴图", action: #selector(closeAllPins), keyEquivalent: "")
        for item in menu.items {
            item.target = self
        }
        return menu
    }
}

/// 贴图内容绘制视图（含 1pt 精致描边，防止纯白截图融入浅色桌面）
private final class PinContentView: NSView {
    private let image: NSImage
    private var hovered = false

    init(image: NSImage) {
        self.image = image
        super.init(frame: NSRect(origin: .zero, size: image.size))
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
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()

        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        border.lineWidth = 1.0
        (hovered ? NSColor.controlAccentColor.withAlphaComponent(0.9) : NSColor.white.withAlphaComponent(0.45)).setStroke()
        border.stroke()
    }
}
