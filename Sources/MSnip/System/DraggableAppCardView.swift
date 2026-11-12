import AppKit
import Foundation

/// 极简居中的应用图标拖拽台：
/// 鼠标悬停浮现轻盈虚线托盘，支持未激活状态下（`acceptsFirstMouse`）一把按住直接拖进「系统设置」。
final class DraggableAppCardView: NSView, NSDraggingSource {
    var onRevealInFinder: (() -> Void)?

    private var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }
    private var isPressing = false {
        didSet { if oldValue != isPressing { needsDisplay = true } }
    }
    private var mouseDownEvent: NSEvent?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let menu = NSMenu()
        let item = NSMenuItem(title: "在访达中显示", action: #selector(revealClicked), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        self.menu = menu
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func revealClicked() {
        onRevealInFinder?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        (isPressing ? NSCursor.closedHand : NSCursor.openHand).set()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        NSCursor.openHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressing = false
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        isPressing = true
        mouseDownEvent = event
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startEvent = mouseDownEvent else { return }
        let p0 = convert(startEvent.locationInWindow, from: nil)
        let p1 = convert(event.locationInWindow, from: nil)
        guard hypot(p1.x - p0.x, p1.y - p0.y) >= 2.0 else { return }

        mouseDownEvent = nil
        let appURL = Bundle.main.bundleURL as NSURL
        let item = NSDraggingItem(pasteboardWriter: appURL)

        let iconSize = NSSize(width: 58, height: 58)
        let dragImage = appIconImage(size: iconSize)
        let origin = NSPoint(x: p1.x - iconSize.width * 0.5, y: p1.y - iconSize.height * 0.5)
        item.setDraggingFrame(NSRect(origin: origin, size: iconSize), contents: dragImage)

        let session = beginDraggingSession(with: [item], event: startEvent, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        isPressing = false
        mouseDownEvent = nil
        if isHovered { NSCursor.openHand.set() }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        isPressing = false
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let podSize: CGFloat = 70
        let podRect = NSRect(x: (bounds.width - podSize) * 0.5, y: 2, width: podSize, height: podSize)
        let podPath = CGPath(roundedRect: podRect, cornerWidth: 18, cornerHeight: 18, transform: nil)

        ctx.saveGState()
        let fillAlpha: CGFloat = isPressing ? 0.16 : (isHovered ? 0.10 : 0.05)
        ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(fillAlpha).cgColor)
        ctx.addPath(podPath)
        ctx.fillPath()

        let strokeAlpha: CGFloat = (isHovered || isPressing) ? 0.80 : 0.35
        ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(strokeAlpha).cgColor)
        ctx.setLineWidth(1.25)
        ctx.setLineDash(phase: 0, lengths: [5, 3.5])
        ctx.addPath(podPath)
        ctx.strokePath()
        ctx.restoreGState()

        let iconSide: CGFloat = isPressing ? 52 : 56
        let iconRect = NSRect(
            x: (bounds.width - iconSide) * 0.5,
            y: podRect.midY - iconSide * 0.5,
            width: iconSide,
            height: iconSide
        )
        let icon = appIconImage(size: NSSize(width: iconSide, height: iconSide))
        icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)

        let hint = "按住图标拖入系统设置" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: isHovered ? NSColor.labelColor : NSColor.secondaryLabelColor
        ]
        let sz = hint.size(withAttributes: attrs)
        hint.draw(at: NSPoint(x: (bounds.width - sz.width) * 0.5, y: podRect.maxY + 7), withAttributes: attrs)
    }

    private func appIconImage(size: NSSize) -> NSImage {
        let icon = (NSApp.applicationIconImage?.copy() as? NSImage)
            ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        icon.size = size
        return icon
    }
}
