import AppKit
import Foundation

/// 零外边距的圆角胶囊按钮与状态签（消除原生 NSButton 隐形边距导致的错位）
final class PillControl: NSView {
    enum Style {
        case subtleButton
        case primaryButton
        case grantedBadge
    }

    var title: String { didSet { labelField.stringValue = title; refreshAppearance() } }
    var style: Style { didSet { updateTrackingAreas(); refreshAppearance() } }
    var onClick: (() -> Void)?

    private let labelField = NSTextField(labelWithString: "")
    private var isHovered = false { didSet { if oldValue != isHovered { refreshAppearance() } } }
    private var isPressed = false { didSet { if oldValue != isPressed { refreshAppearance() } } }

    init(title: String, style: Style, onClick: (() -> Void)? = nil) {
        self.title = title
        self.style = style
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        labelField.stringValue = title
        labelField.alignment = .center
        labelField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelField)

        NSLayoutConstraint.activate([
            labelField.centerXAnchor.constraint(equalTo: centerXAnchor),
            labelField.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5)
        ])
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        guard style != .grantedBadge else { isHovered = false; isPressed = false; return }
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
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    private func refreshAppearance() {
        labelField.font = .systemFont(ofSize: 12, weight: style == .primaryButton ? .semibold : .medium)
        switch style {
        case .subtleButton:
            labelField.textColor = .labelColor
        case .primaryButton:
            labelField.textColor = .white
        case .grantedBadge:
            labelField.textColor = .systemGreen
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        let bgColor: NSColor
        switch style {
        case .subtleButton:
            let alpha: CGFloat = isPressed ? 0.20 : (isHovered ? 0.14 : 0.09)
            bgColor = NSColor.labelColor.withAlphaComponent(alpha)
        case .primaryButton:
            let base = NSColor.controlAccentColor
            bgColor = isPressed ? (base.blended(withFraction: 0.18, of: .black) ?? base)
                : (isHovered ? (base.blended(withFraction: 0.10, of: .white) ?? base) : base)
        case .grantedBadge:
            bgColor = NSColor.systemGreen.withAlphaComponent(0.15)
        }
        bgColor.setFill()
        path.fill()
    }
}

/// 圆形返回 / 关闭图标小按钮（纯 Auto Layout + NSImageView 矢量着色，零上下文污染）
final class CircleIconButton: NSView {
    private let showRestingFill: Bool
    private let iconView = NSImageView()
    var onClick: (() -> Void)?

    private var isHovered = false { didSet { if oldValue != isHovered { syncTint(); needsDisplay = true } } }
    private var isPressed = false { didSet { if oldValue != isPressed { needsDisplay = true } } }

    init(symbolName: String, showRestingFill: Bool = true, toolTip: String? = nil, onClick: (() -> Void)? = nil) {
        self.showRestingFill = showRestingFill
        self.onClick = onClick
        super.init(frame: .zero)
        self.toolTip = toolTip
        translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        addSubview(iconView)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        syncTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; isPressed = false }
    override func mouseDown(with event: NSEvent) { isPressed = true }
    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    private func syncTint() {
        iconView.contentTintColor = isHovered ? .labelColor : .secondaryLabelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isPressed ? 0.18 : (isHovered ? 0.13 : (showRestingFill ? 0.08 : 0.0))
        if alpha > 0 {
            NSColor.labelColor.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
    }
}

/// 权限类型图标徽章（复刻 ChatGPT SkyPermissions 的屏幕录制取景框与辅助功能蓝圆徽章）
final class PermissionBadgeView: NSView {
    enum Kind {
        case screenRecording
        case accessibility
    }

    private let kind: Kind
    private let symbolView = NSImageView()

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        symbolView.translatesAutoresizingMaskIntoConstraints = false
        switch kind {
        case .screenRecording:
            symbolView.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
            symbolView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15.5, weight: .medium)
            symbolView.contentTintColor = .labelColor
        case .accessibility:
            symbolView.image = NSImage(systemSymbolName: "figure.arms.open", accessibilityDescription: nil)
            symbolView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
            symbolView.contentTintColor = .white
        }
        addSubview(symbolView)

        NSLayoutConstraint.activate([
            symbolView.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        switch kind {
        case .screenRecording:
            let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7.5, yRadius: 7.5)
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            bg.fill()
        case .accessibility:
            let circleRect = bounds.insetBy(dx: 1.5, dy: 1.5)
            let grad = NSGradient(
                starting: NSColor(srgbRed: 0.14, green: 0.62, blue: 1.0, alpha: 1.0),
                ending: NSColor(srgbRed: 0.0, green: 0.45, blue: 0.96, alpha: 1.0)
            )
            grad?.draw(in: NSBezierPath(ovalIn: circleRect), angle: -90)
            NSColor.white.withAlphaComponent(0.88).setStroke()
            let ring = NSBezierPath(ovalIn: circleRect.insetBy(dx: 2.0, dy: 2.0))
            ring.lineWidth = 1.1
            ring.stroke()
        }
    }
}

/// ChatGPT 风格的独立圆角权限条目卡片（左图标 + 双行说明 + 右侧胶囊按钮）
final class PermissionRowView: NSView {
    let actionPill: PillControl

    init(kind: PermissionBadgeView.Kind, title: String, subtitle: String, onAction: @escaping () -> Void) {
        self.actionPill = PillControl(title: "允许", style: .primaryButton, onClick: onAction)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let badge = PermissionBadgeView(kind: kind)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor

        let subLabel = NSTextField(labelWithString: subtitle)
        subLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subLabel.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [titleLabel, subLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1.5
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(badge)
        addSubview(textStack)
        addSubview(actionPill)

        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 30),
            badge.heightAnchor.constraint(equalToConstant: 30),

            textStack.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: actionPill.leadingAnchor, constant: -8),

            actionPill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            actionPill.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionPill.widthAnchor.constraint(equalToConstant: 66),
            actionPill.heightAnchor.constraint(equalToConstant: 25)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        (isDark ? NSColor.white.withAlphaComponent(0.05) : NSColor.black.withAlphaComponent(0.025)).setFill()
        path.fill()
        (isDark ? NSColor.white.withAlphaComponent(0.11) : NSColor.black.withAlphaComponent(0.09)).setStroke()
        path.lineWidth = 1.0
        path.stroke()
    }
}
