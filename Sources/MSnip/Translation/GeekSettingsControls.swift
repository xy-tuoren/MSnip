import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 极客单色分段切换控件（支持普通标题与等宽字号）
final class GeekSegmentControl: NSView {
    var items: [String] { didSet { needsDisplay = true } }
    var selectedIndex: Int = 0 { didSet { needsDisplay = true } }
    var monoFont: Bool = false
    var onSelect: ((Int) -> Void)?
    private var hoveredIdx: Int? { didSet { if oldValue != hoveredIdx { needsDisplay = true } } }
    override var isFlipped: Bool { true }

    init(items: [String], selectedIndex: Int = 0, mono: Bool = false) {
        self.items = items
        self.selectedIndex = selectedIndex
        self.monoFont = mono
        super.init(frame: .zero)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard !items.isEmpty else { return }
        let x = convert(event.locationInWindow, from: nil).x
        hoveredIdx = min(items.count - 1, max(0, Int(x / (bounds.width / CGFloat(items.count)))))
    }
    override func mouseExited(with event: NSEvent) { hoveredIdx = nil }

    override func mouseDown(with event: NSEvent) {
        guard !items.isEmpty else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let idx = min(items.count - 1, max(0, Int(x / (bounds.width / CGFloat(items.count)))))
        if idx != selectedIndex {
            selectedIndex = idx
            onSelect?(idx)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !items.isEmpty else { return }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let bg = CGPath(roundedRect: r, cornerWidth: 7.0, cornerHeight: 7.0, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(GeekTheme.inputBg.cgColor)
        ctx.addPath(bg); ctx.fillPath()
        ctx.setStrokeColor(GeekTheme.border.cgColor)
        ctx.setLineWidth(1.0); ctx.addPath(bg); ctx.strokePath()

        let segW = (bounds.width - 4) / CGFloat(items.count)
        for (i, label) in items.enumerated() {
            let sr = CGRect(x: 2 + CGFloat(i) * segW, y: 2, width: segW, height: bounds.height - 4)
            let active = (i == selectedIndex)
            if active || hoveredIdx == i {
                let p = CGPath(roundedRect: sr, cornerWidth: 5.5, cornerHeight: 5.5, transform: nil)
                ctx.setFillColor((active ? GeekTheme.controlHover : NSColor(white: 1.0, alpha: 0.04)).cgColor)
                ctx.addPath(p); ctx.fillPath()
                if active {
                    ctx.setStrokeColor(GeekTheme.borderStrong.cgColor)
                    ctx.setLineWidth(1.0); ctx.addPath(p); ctx.strokePath()
                }
            }
            let font: NSFont = monoFont
                ? .monospacedSystemFont(ofSize: 10.5, weight: active ? .semibold : .medium)
                : .systemFont(ofSize: 12.0, weight: active ? .semibold : .medium)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: active ? GeekTheme.inkPrimary : GeekTheme.inkSecondary
            ]
            let ns = label as NSString
            let sz = ns.size(withAttributes: attrs)
            ns.draw(at: CGPoint(x: round(sr.midX - sz.width * 0.5), y: round(sr.midY - sz.height * 0.5)), withAttributes: attrs)
        }
        ctx.restoreGState()
    }
}

/// 极客微按钮（支持 ghost / subtle / accent / primaryLight 四种克制态）
final class GeekButton: NSView {
    enum Style { case ghost, subtle, accent, primaryLight }
    var title: String { didSet { needsDisplay = true } }
    var symbolName: String? { didSet { needsDisplay = true } }
    var style: Style { didSet { needsDisplay = true } }
    var mono: Bool = false
    var isEnabled: Bool = true { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    override var isFlipped: Bool { true }

    init(title: String, symbol: String? = nil, style: Style = .subtle, mono: Bool = false) {
        self.title = title; self.symbolName = symbol; self.style = style; self.mono = mono
        super.init(frame: .zero)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: isEnabled ? .pointingHand : .arrow) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { if isEnabled { onClick?() } }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = CGPath(roundedRect: r, cornerWidth: 6.0, cornerHeight: 6.0, transform: nil)
        let alpha: CGFloat = isEnabled ? 1.0 : 0.40
        ctx.saveGState()
        let fg: NSColor
        switch style {
        case .primaryLight:
            ctx.setFillColor((hovered ? NSColor.white : GeekTheme.inkPrimary).withAlphaComponent(alpha).cgColor)
            ctx.addPath(p); ctx.fillPath()
            fg = GeekTheme.windowBg
        case .accent:
            ctx.setFillColor((hovered ? GeekTheme.accent.withAlphaComponent(0.24) : GeekTheme.accentSoft).cgColor)
            ctx.addPath(p); ctx.fillPath()
            ctx.setStrokeColor(GeekTheme.accent.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(1.0); ctx.addPath(p); ctx.strokePath()
            fg = GeekTheme.accent
        case .subtle:
            ctx.setFillColor((hovered ? GeekTheme.controlHover : GeekTheme.controlBg).cgColor)
            ctx.addPath(p); ctx.fillPath()
            ctx.setStrokeColor((hovered ? GeekTheme.borderStrong : GeekTheme.border).cgColor)
            ctx.setLineWidth(1.0); ctx.addPath(p); ctx.strokePath()
            fg = GeekTheme.inkPrimary
        case .ghost:
            if hovered {
                ctx.setFillColor(NSColor(white: 1.0, alpha: 0.06).cgColor)
                ctx.addPath(p); ctx.fillPath()
            }
            fg = hovered ? GeekTheme.inkPrimary : GeekTheme.inkSecondary
        }

        let font: NSFont = mono
            ? .monospacedSystemFont(ofSize: 11.0, weight: .medium)
            : .systemFont(ofSize: 11.5, weight: style == .primaryLight ? .semibold : .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg.withAlphaComponent(alpha)]
        let tSz = title.isEmpty ? .zero : (title as NSString).size(withAttributes: attrs)
        let iconSpan: CGFloat = symbolName != nil ? (title.isEmpty ? 14 : 16) : 0
        var sx = (bounds.width - tSz.width - iconSpan) * 0.5
        if let sym = symbolName {
            ToolbarView.drawSymbol(sym, in: CGRect(x: round(sx), y: 0, width: 14, height: bounds.height), alpha: alpha * 0.95, tint: fg)
            sx += iconSpan
        }
        if !title.isEmpty {
            (title as NSString).draw(at: CGPoint(x: round(sx), y: round((bounds.height - tSz.height) * 0.5)), withAttributes: attrs)
        }
        ctx.restoreGState()
    }
}

/// 极客暗色下拉选择器（替代系统默认弹框）
final class GeekDropdownPill: NSView {
    var items: [String] = [] { didSet { needsDisplay = true } }
    var selectedIndex: Int = 0 { didSet { needsDisplay = true } }
    var symbolName: String? { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?
    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    override var isFlipped: Bool { true }

    init(symbol: String? = nil, items: [String] = [], selectedIndex: Int = 0) {
        self.symbolName = symbol; self.items = items; self.selectedIndex = selectedIndex
        super.init(frame: .zero)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseDown(with event: NSEvent) {
        guard !items.isEmpty else { return }
        let menu = NSMenu()
        for (idx, title) in items.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(handlePick(_:)), keyEquivalent: "")
            item.tag = idx
            item.state = (idx == selectedIndex) ? .on : .off
            item.target = self
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 3), in: self)
    }

    @objc private func handlePick(_ sender: NSMenuItem) {
        guard items.indices.contains(sender.tag) else { return }
        selectedIndex = sender.tag
        onSelect?(sender.tag)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: r, cornerWidth: 6.0, cornerHeight: 6.0, transform: nil)
        ctx.saveGState()
        ctx.setFillColor((hovered ? GeekTheme.controlHover : GeekTheme.controlBg).cgColor)
        ctx.addPath(path); ctx.fillPath()
        ctx.setStrokeColor((hovered ? GeekTheme.accent.withAlphaComponent(0.50) : GeekTheme.border).cgColor)
        ctx.setLineWidth(1.0); ctx.addPath(path); ctx.strokePath()

        var leftX: CGFloat = 8
        if let sym = symbolName {
            ToolbarView.drawSymbol(sym, in: CGRect(x: leftX, y: 0, width: 13, height: bounds.height), alpha: 0.90, tint: GeekTheme.accent)
            leftX += 17
        }
        let text = items.indices.contains(selectedIndex) ? items[selectedIndex] : "—"
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: GeekTheme.inkPrimary,
            .paragraphStyle: para
        ]
        let sz = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(
            in: CGRect(x: round(leftX), y: round((bounds.height - sz.height) * 0.5), width: max(20, bounds.width - leftX - 18), height: sz.height + 2),
            withAttributes: attrs
        )
        let chevronTint = hovered ? GeekTheme.inkPrimary : GeekTheme.inkSecondary
        ctx.setStrokeColor(chevronTint.cgColor)
        ctx.setLineWidth(1.2); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        let cx = bounds.width - 9.5, cy = bounds.midY + 0.5
        ctx.move(to: CGPoint(x: cx - 2.5, y: cy - 1.2))
        ctx.addLine(to: CGPoint(x: cx, y: cy + 1.5))
        ctx.addLine(to: CGPoint(x: cx + 2.5, y: cy - 1.2))
        ctx.strokePath()
        ctx.restoreGState()
    }
}
