import AppKit
import Foundation

/// 零外边距的圆角胶囊按钮与状态签：消除原生 NSButton 隐形阴影边距导致的上下错位
final class PillControl: NSView {
    enum Style {
        case subtleButton
        case primaryButton
        case grantedBadge
    }

    var title: String { didSet { needsDisplay = true } }
    var style: Style { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    private var isHovered = false { didSet { if oldValue != isHovered { needsDisplay = true } } }
    private var isPressed = false { didSet { if oldValue != isPressed { needsDisplay = true } } }

    init(title: String, style: Style, onClick: (() -> Void)? = nil) {
        self.title = title
        self.style = style
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        guard style != .grantedBadge else { return }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; isPressed = false }
    override func mouseDown(with event: NSEvent) {
        guard style != .grantedBadge else { return }
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        let pt = convert(event.locationInWindow, from: nil)
        if bounds.contains(pt) { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6.5, yRadius: 6.5)

        let bgColor: NSColor
        let fgColor: NSColor
        switch style {
        case .subtleButton:
            let alpha: CGFloat = isPressed ? 0.24 : (isHovered ? 0.18 : 0.12)
            bgColor = NSColor.labelColor.withAlphaComponent(alpha)
            fgColor = .labelColor
        case .primaryButton:
            let base = NSColor.controlAccentColor
            bgColor = isPressed ? (base.blended(withFraction: 0.2, of: .black) ?? base)
                : (isHovered ? (base.blended(withFraction: 0.1, of: .white) ?? base) : base)
            fgColor = .white
        case .grantedBadge:
            bgColor = NSColor.systemGreen.withAlphaComponent(0.14)
            fgColor = .systemGreen
        }

        bgColor.setFill()
        path.fill()

        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fgColor]
        let nsTitle = title as NSString
        let sz = nsTitle.size(withAttributes: attrs)
        let x = (bounds.width - sz.width) * 0.5
        let y = (bounds.height - sz.height) * 0.5
        nsTitle.draw(at: NSPoint(x: round(x * 2) * 0.5, y: round(y * 2) * 0.5), withAttributes: attrs)
    }
}

/// 状态指示圆点
final class StatusDotView: NSView {
    var color: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
}

/// 零默认内边距的分组圆角卡片容器
final class CardContainerView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }
}
