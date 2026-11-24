import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 极客单色分段切换控件（支持图文图标混排、等宽模式及半点光学居中）
final class GeekSegmentControl: NSView {
    var items: [String] { didSet { needsDisplay = true } }
    var symbols: [String]? { didSet { needsDisplay = true } }
    var selectedIndex: Int = 0 { didSet { needsDisplay = true } }
    var monoFont: Bool = false
    var onSelect: ((Int) -> Void)?
    private var hoveredIdx: Int? { didSet { if oldValue != hoveredIdx { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(items: [String], symbols: [String]? = nil, selectedIndex: Int = 0, mono: Bool = false) {
        self.items = items
        self.symbols = symbols
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
        selectedIndex = idx
        onSelect?(idx)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !items.isEmpty else { return }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let bg = CGPath(roundedRect: r, cornerWidth: 8.0, cornerHeight: 8.0, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(GeekTheme.segTrackBg.cgColor)
        ctx.addPath(bg); ctx.fillPath()
        ctx.setStrokeColor(GeekTheme.border.cgColor)
        ctx.setLineWidth(1.0); ctx.addPath(bg); ctx.strokePath()

        let pad: CGFloat = 2.5
        let segW = (bounds.width - pad * 2) / CGFloat(items.count)
        for (i, label) in items.enumerated() {
            let sr = CGRect(x: pad + CGFloat(i) * segW, y: pad, width: segW, height: bounds.height - pad * 2)
            let active = (i == selectedIndex)
            if active || hoveredIdx == i {
                let p = CGPath(roundedRect: sr, cornerWidth: 6.0, cornerHeight: 6.0, transform: nil)
                ctx.saveGState()
                if active {
                    ctx.setShadow(offset: CGSize(width: 0, height: 0.8), blur: 2.2, color: GeekTheme.softShadow.cgColor)
                }
                ctx.setFillColor((active ? GeekTheme.segActiveBg : GeekTheme.hoverSoft).cgColor)
                ctx.addPath(p); ctx.fillPath()
                ctx.restoreGState()
                if active {
                    ctx.setStrokeColor(GeekTheme.border.cgColor)
                    ctx.setLineWidth(0.75); ctx.addPath(p); ctx.strokePath()
                }
            }
            let font: NSFont = monoFont
                ? .monospacedSystemFont(ofSize: 12.0, weight: active ? .semibold : .regular)
                : .systemFont(ofSize: 12.5, weight: active ? .semibold : .regular)
            let fg = active ? GeekTheme.inkPrimary : GeekTheme.inkSecondary
            if let syms = symbols, syms.indices.contains(i),
               let entry = GeekTheme.symbolEntry(syms[i], pointSize: 11.5, weight: active ? .semibold : .regular) {
                let textW = GeekTheme.measureTextWidth(label, font: font)
                let gap: CGFloat = 5.0
                let totalW = entry.pointSize.width + gap + textW
                let sx = GeekTheme.snap(sr.midX - totalW * 0.5)
                let symTint = active ? GeekTheme.accent : GeekTheme.inkMuted
                GeekTheme.drawSymbol(syms[i], pointSize: 11.5, weight: active ? .semibold : .regular, in: CGRect(x: sx, y: sr.minY, width: entry.pointSize.width, height: sr.height), alpha: 0.96, tint: symTint)
                GeekTheme.drawText(label, in: CGRect(x: sx + entry.pointSize.width + gap, y: sr.minY, width: textW + 2, height: sr.height), font: font, color: fg)
            } else {
                GeekTheme.drawText(label, in: sr.insetBy(dx: 4, dy: 0), font: font, color: fg, align: .center)
            }
        }
        ctx.restoreGState()
    }
}

/// 极客微按钮（13pt 清晰字号，图标真实墨迹宽度与文字整体光学居中）
final class GeekButton: NSView {
    enum Style { case ghost, subtle, accent, emeraldSoft, amberSoft, dangerSoft }
    var title: String { didSet { needsDisplay = true } }
    var symbolName: String? { didSet { needsDisplay = true } }
    var style: Style { didSet { needsDisplay = true } }
    var mono: Bool = false
    var contentAlignment: NSTextAlignment = .center { didSet { needsDisplay = true } }
    var isEnabled: Bool = true { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

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
        let p = CGPath(roundedRect: r, cornerWidth: 7.0, cornerHeight: 7.0, transform: nil)
        let alpha: CGFloat = isEnabled ? 1.0 : 0.45
        ctx.saveGState()
        let fg: NSColor
        switch style {
        case .emeraldSoft:
            ctx.setFillColor((hovered ? GeekTheme.emerald.withAlphaComponent(0.24) : GeekTheme.emeraldSoft).cgColor)
            ctx.addPath(p); ctx.fillPath()
            ctx.setStrokeColor(GeekTheme.emerald.withAlphaComponent(0.38).cgColor)
            ctx.setLineWidth(1.0); ctx.addPath(p); ctx.strokePath()
            fg = GeekTheme.emerald
        case .amberSoft:
            ctx.setFillColor(GeekTheme.amber.withAlphaComponent(hovered ? 0.24 : 0.14).cgColor)
            ctx.addPath(p); ctx.fillPath()
            ctx.setStrokeColor(GeekTheme.amber.withAlphaComponent(0.45).cgColor)
            ctx.setLineWidth(1.0); ctx.addPath(p); ctx.strokePath()
            fg = GeekTheme.amber
        case .dangerSoft:
            ctx.setFillColor(GeekTheme.danger.withAlphaComponent(hovered ? 0.24 : 0.14).cgColor)
            ctx.addPath(p); ctx.fillPath()
            ctx.setStrokeColor(GeekTheme.danger.withAlphaComponent(0.50).cgColor)
            ctx.setLineWidth(1.0); ctx.addPath(p); ctx.strokePath()
            fg = GeekTheme.danger
        case .accent:
            ctx.setFillColor((hovered ? GeekTheme.accent.withAlphaComponent(0.26) : GeekTheme.accentSoft).cgColor)
            ctx.addPath(p); ctx.fillPath()
            ctx.setStrokeColor(GeekTheme.accent.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(1.0); ctx.addPath(p); ctx.strokePath()
            fg = GeekTheme.accent
        case .subtle:
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 0.6), blur: 1.6, color: GeekTheme.softShadow.cgColor)
            ctx.setFillColor((hovered ? GeekTheme.controlHover : GeekTheme.controlBg).cgColor)
            ctx.addPath(p); ctx.fillPath()
            ctx.restoreGState()
            ctx.setStrokeColor((hovered ? GeekTheme.borderStrong : GeekTheme.border).cgColor)
            ctx.setLineWidth(1.0); ctx.addPath(p); ctx.strokePath()
            fg = GeekTheme.inkPrimary
        case .ghost:
            if hovered && isEnabled {
                ctx.setFillColor(GeekTheme.pillSubtle.cgColor)
                ctx.addPath(p); ctx.fillPath()
            }
            fg = (hovered && isEnabled) ? GeekTheme.inkPrimary : GeekTheme.inkSecondary
        }

        let font: NSFont = mono
            ? .monospacedSystemFont(ofSize: 12.0, weight: .medium)
            : .systemFont(ofSize: 12.5, weight: (style == .subtle || style == .ghost) ? .medium : .semibold)
        let symPt: CGFloat = title.isEmpty ? 12.5 : 11.5
        let symEntry = symbolName.flatMap { GeekTheme.symbolEntry($0, pointSize: symPt, weight: .semibold) }
        let iconW = symEntry?.pointSize.width ?? 0
        let textW = GeekTheme.measureTextWidth(title, font: font)
        let gap: CGFloat = (symEntry != nil && !title.isEmpty) ? 5.5 : 0
        let totalW = iconW + gap + textW
        var sx: CGFloat = (contentAlignment == .left) ? 8.0 : GeekTheme.snap((bounds.width - totalW) * 0.5)
        if let sym = symbolName, symEntry != nil {
            GeekTheme.drawSymbol(sym, pointSize: symPt, weight: .semibold, in: CGRect(x: sx, y: 0, width: iconW, height: bounds.height), alpha: alpha * 0.96, tint: fg)
            sx += iconW + gap
        }
        if !title.isEmpty {
            let maxTextW = max(16, bounds.width - sx - 6)
            GeekTheme.drawText(title, in: CGRect(x: sx, y: 0, width: min(textW + 2, maxTextW), height: bounds.height), font: font, color: fg.withAlphaComponent(alpha))
        }
        ctx.restoreGState()
    }
}

/// 极客暗色下拉选择器（13pt 清晰字号 + 中性灰前缀图标，严格中轴对齐）
final class GeekDropdownPill: NSView {
    var items: [String] = [] { didSet { syncTooltip(); needsDisplay = true } }
    var selectedIndex: Int = 0 { didSet { syncTooltip(); needsDisplay = true } }
    var customDisplayTitle: String? { didSet { syncTooltip(); needsDisplay = true } }
    var symbolName: String? { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?
    var onCustomClick: ((NSView) -> Void)?
    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(symbol: String? = nil, items: [String] = [], selectedIndex: Int = 0) {
        self.symbolName = symbol; self.items = items; self.selectedIndex = selectedIndex
        super.init(frame: .zero)
        syncTooltip()
    }
    private func syncTooltip() {
        let txt = customDisplayTitle ?? (items.indices.contains(selectedIndex) ? items[selectedIndex] : nil)
        toolTip = txt
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
        if let custom = onCustomClick {
            custom(self)
            return
        }
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
        let path = CGPath(roundedRect: r, cornerWidth: 7.0, cornerHeight: 7.0, transform: nil)
        ctx.saveGState()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 0.6), blur: 1.6, color: GeekTheme.softShadow.cgColor)
        ctx.setFillColor((hovered ? GeekTheme.controlHover : GeekTheme.controlBg).cgColor)
        ctx.addPath(path); ctx.fillPath()
        ctx.restoreGState()
        ctx.setStrokeColor((hovered ? GeekTheme.borderStrong : GeekTheme.border).cgColor)
        ctx.setLineWidth(1.0); ctx.addPath(path); ctx.strokePath()

        var leftX: CGFloat = 11
        if let sym = symbolName {
            let w = max(14, GeekTheme.symbolEntry(sym, pointSize: 12.0, weight: .medium)?.pointSize.width ?? 14)
            GeekTheme.drawSymbol(sym, pointSize: 12.0, weight: .medium, in: CGRect(x: leftX, y: 0, width: w, height: bounds.height), alpha: 0.86, tint: GeekTheme.inkSecondary)
            leftX += w + 7
        }
        let text = customDisplayTitle ?? (items.indices.contains(selectedIndex) ? items[selectedIndex] : "—")
        GeekTheme.drawText(
            text,
            in: CGRect(x: leftX, y: 0, width: max(20, bounds.width - leftX - 24), height: bounds.height),
            font: .systemFont(ofSize: 12.5, weight: .medium),
            color: GeekTheme.inkPrimary
        )
        let chevronTint = hovered ? GeekTheme.inkPrimary : GeekTheme.inkSecondary
        ctx.setStrokeColor(chevronTint.cgColor)
        ctx.setLineWidth(1.35); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        let cx = bounds.width - 13.5, cy = bounds.midY
        ctx.move(to: CGPoint(x: cx - 3.2, y: cy - 1.6))
        ctx.addLine(to: CGPoint(x: cx, y: cy + 1.6))
        ctx.addLine(to: CGPoint(x: cx + 3.2, y: cy - 1.6))
        ctx.strokePath()
        ctx.restoreGState()
    }
}
