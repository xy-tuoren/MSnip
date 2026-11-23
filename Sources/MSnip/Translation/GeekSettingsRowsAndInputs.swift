import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 翻译服务列表行视图（38px 行高 + 悬停柔和底色 + 清晰「使用中 / 已就绪 / 填 Key」状态胶囊）
final class ProviderRowCellView: NSTableCellView {
    private let titleText: String
    private let isPrimary: Bool
    private let isReady: Bool
    private let isRowSelected: Bool
    private let dotColor: NSColor
    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    override var isFlipped: Bool { true }

    init(title: String, isPrimary: Bool, isReady: Bool, isSelected: Bool, dotColor: NSColor, fullTooltip: String? = nil) {
        self.titleText = title
        self.isPrimary = isPrimary
        self.isReady = isReady
        self.isRowSelected = isSelected
        self.dotColor = dotColor
        super.init(frame: .zero)
        self.toolTip = fullTooltip ?? title
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if isRowSelected || hovered {
            let bg = CGPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), cornerWidth: 7.5, cornerHeight: 7.5, transform: nil)
            ctx.setFillColor((isRowSelected ? GeekTheme.controlHover : NSColor(white: 1.0, alpha: 0.045)).cgColor)
            ctx.addPath(bg); ctx.fillPath()
            if isRowSelected {
                ctx.setStrokeColor(GeekTheme.borderStrong.cgColor)
                ctx.setLineWidth(1.0); ctx.addPath(bg); ctx.strokePath()
            }
        }
        MSnipUITheme.drawStatusDot(ctx: ctx, center: CGPoint(x: 14, y: bounds.midY), color: dotColor, halo: isPrimary)

        let badgeText: String = isPrimary ? "使用中" : (isReady ? "已就绪" : "填 Key")
        let badgeBg: NSColor = isPrimary ? GeekTheme.emeraldSoft : (isReady ? GeekTheme.accentSoft : NSColor(white: 1.0, alpha: 0.05))
        let badgeFg: NSColor = isPrimary ? GeekTheme.emerald : (isReady ? GeekTheme.accent : GeekTheme.inkMuted)
        let bw: CGFloat = 44, bh: CGFloat = 20
        let br = CGRect(x: bounds.width - bw - 8, y: GeekTheme.snap((bounds.height - bh) * 0.5), width: bw, height: bh)
        ctx.setFillColor(badgeBg.cgColor)
        ctx.addPath(CGPath(roundedRect: br, cornerWidth: 5.0, cornerHeight: 5.0, transform: nil)); ctx.fillPath()
        GeekTheme.drawText(badgeText, in: br, font: .systemFont(ofSize: 10.5, weight: .semibold), color: badgeFg, align: .center)

        let titleFont = NSFont.systemFont(ofSize: 13.0, weight: (isRowSelected || isPrimary) ? .semibold : .medium)
        let titleFg = (isRowSelected || hovered) ? GeekTheme.inkPrimary : GeekTheme.inkSecondary
        GeekTheme.drawText(titleText, in: CGRect(x: 24, y: 0, width: max(30, br.minX - 28), height: bounds.height), font: titleFont, color: titleFg)
    }
}

/// 极客暗色文本输入壳（即时响应 firstResponder 蓝框焦点反馈 + 悬停显示完整内容提示）
final class GeekInputBox: NSView, NSViewToolTipOwner {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    let field: NSTextField
    private var hovered = false { didSet { if oldValue != hovered { refreshBorder() } } }
    private var focused = false { didSet { if oldValue != focused { refreshBorder() } } }
    private var responderObservation: NSKeyValueObservation?
    private var tooltipTag: NSView.ToolTipTag?

    init(frame: NSRect, field: NSTextField, placeholder: String, mono: Bool) {
        self.field = field
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = GeekTheme.inputBg.cgColor
        layer?.cornerRadius = 7.5
        layer?.borderWidth = 1.0
        layer?.borderColor = GeekTheme.border.cgColor

        field.isBordered = false; field.isBezeled = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = mono ? .monospacedSystemFont(ofSize: 12.5, weight: .regular) : .systemFont(ofSize: 13.0, weight: .regular)
        field.textColor = GeekTheme.inkPrimary
        field.setGeekPlaceholder(placeholder)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true; field.cell?.wraps = false
        let fh = ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 400, height: 40)).height ?? 18)
        field.frame = NSRect(x: 10, y: GeekTheme.snap((frame.height - fh) * 0.5 - 0.25), width: frame.width - 20, height: fh)
        addSubview(field)
        refreshTooltipRect()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshTooltipRect()
    }

    private func refreshTooltipRect() {
        if let tag = tooltipTag { removeToolTip(tag) }
        tooltipTag = addToolTip(bounds, owner: self, userData: nil)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard !(field is NSSecureTextField) else { return "" }
        let val = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return val
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        responderObservation?.invalidate()
        responderObservation = nil
        guard let win = window else { focused = false; return }
        responderObservation = win.observe(\.firstResponder, options: [.initial, .new]) { [weak self] window, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let editor = window.firstResponder as? NSTextView, (editor.delegate as AnyObject?) === self.field {
                    self.focused = true
                } else {
                    self.focused = (window.firstResponder === self.field)
                }
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(field) }

    private func refreshBorder() {
        layer?.borderWidth = focused ? 1.25 : 1.0
        layer?.borderColor = focused
            ? GeekTheme.accent.withAlphaComponent(0.80).cgColor
            : (hovered ? GeekTheme.borderStrong.cgColor : GeekTheme.border.cgColor)
    }
}

extension NSTextField {
    func setGeekPlaceholder(_ text: String) {
        placeholderAttributedString = NSAttributedString(
            string: text,
            attributes: [.font: font ?? NSFont.systemFont(ofSize: 13.0), .foregroundColor: GeekTheme.inkMuted]
        )
    }

    func setTextWithTooltip(_ text: String, color: NSColor? = nil) {
        if let color { textColor = color }
        stringValue = text
        toolTip = text.isEmpty ? nil : text
    }
}
