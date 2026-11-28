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
    /// 各段按文字宽度分配（多出的空间均分）；默认等宽，仅在等宽放不下较长译文时启用
    var proportional: Bool = false { didSet { needsDisplay = true } }
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
        hoveredIdx = segmentIndex(atX: convert(event.locationInWindow, from: nil).x)
    }
    override func mouseExited(with event: NSEvent) { hoveredIdx = nil }

    override func mouseDown(with event: NSEvent) {
        guard !items.isEmpty else { return }
        let idx = segmentIndex(atX: convert(event.locationInWindow, from: nil).x)
        selectedIndex = idx
        onSelect?(idx)
    }

    private static let pad: CGFloat = 2.5

    /// 单段完整显示文字（按选中态粗体）与图标所需的宽度
    private func contentWidths() -> [CGFloat] {
        let font: NSFont = monoFont
            ? .monospacedSystemFont(ofSize: 12.0, weight: .semibold)
            : .systemFont(ofSize: 12.5, weight: .semibold)
        return items.enumerated().map { i, label in
            let iconW: CGFloat = (symbols?.indices.contains(i) == true) ? 14 + 5 : 0
            return GeekTheme.measureTextWidth(label, font: font) + 2 + iconW + 12
        }
    }

    /// 各段等宽时完整显示最长一段所需的总宽度
    var fittingWidth: CGFloat {
        ceil((contentWidths().max() ?? 0) * CGFloat(items.count) + Self.pad * 2)
    }

    private func segmentRects() -> [CGRect] {
        let inner = bounds.width - Self.pad * 2
        let h = bounds.height - Self.pad * 2
        var widths = Array(repeating: inner / CGFloat(max(1, items.count)), count: items.count)
        if proportional {
            let content = contentWidths()
            let extra = max(0, inner - content.reduce(0, +)) / CGFloat(max(1, items.count))
            widths = content.map { $0 + extra }
        }
        var x = Self.pad
        return widths.map { w in
            defer { x += w }
            return CGRect(x: x, y: Self.pad, width: w, height: h)
        }
    }

    private func segmentIndex(atX x: CGFloat) -> Int {
        let rects = segmentRects()
        return rects.firstIndex { x < $0.maxX } ?? max(0, rects.count - 1)
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

        let rects = segmentRects()
        for (i, label) in items.enumerated() {
            let sr = rects[i]
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
                let innerMax = max(16, sr.width - 8)
                let clampedTextW = min(textW + 2, max(10, innerMax - entry.pointSize.width - gap))
                let totalW = entry.pointSize.width + gap + clampedTextW
                let sx = GeekTheme.snap(sr.midX - totalW * 0.5)
                let symTint = active ? GeekTheme.accent : GeekTheme.inkMuted
                GeekTheme.drawSymbol(syms[i], pointSize: 11.5, weight: active ? .semibold : .regular, in: CGRect(x: sx, y: sr.minY, width: entry.pointSize.width, height: sr.height), alpha: 0.96, tint: symTint)
                GeekTheme.drawText(label, in: CGRect(x: sx + entry.pointSize.width + gap, y: sr.minY, width: clampedTextW, height: sr.height), font: font, color: fg)
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

    private var titleFont: NSFont {
        mono ? .monospacedSystemFont(ofSize: 12.0, weight: .medium)
            : .systemFont(ofSize: 12.5, weight: (style == .subtle || style == .ghost) ? .medium : .semibold)
    }

    /// 完整显示图标与标题所需的最小宽度（英文等较长文案据此放宽固定宽度）
    var fittingWidth: CGFloat {
        let symPt: CGFloat = title.isEmpty ? 12.5 : 11.5
        let iconW = symbolName.flatMap { GeekTheme.symbolEntry($0, pointSize: symPt, weight: .semibold) }?.pointSize.width ?? 0
        let gap: CGFloat = (iconW > 0 && !title.isEmpty) ? 5.5 : 0
        return ceil(iconW + gap + GeekTheme.measureTextWidth(title, font: titleFont) + 2 + 20)
    }

    /// 在设计宽度基础上按需放宽，返回最终宽度
    func widthFitting(atLeast designWidth: CGFloat) -> CGFloat { max(designWidth, fittingWidth) }

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

        let font = titleFont
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

// MARK: - 设置页表单行与输入框组件

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
            ctx.setFillColor((isRowSelected ? GeekTheme.controlHover : GeekTheme.hoverSoft).cgColor)
            ctx.addPath(bg); ctx.fillPath()
            if isRowSelected {
                ctx.setStrokeColor(GeekTheme.borderStrong.cgColor)
                ctx.setLineWidth(1.0); ctx.addPath(bg); ctx.strokePath()
            }
        }
        MSnipUITheme.drawStatusDot(ctx: ctx, center: CGPoint(x: 14, y: bounds.midY), color: dotColor, halo: isPrimary)

        let badgeText: String = isPrimary ? L("使用中") : (isReady ? L("已就绪") : L("填 Key"))
        let badgeBg: NSColor = isPrimary ? GeekTheme.emeraldSoft : (isReady ? GeekTheme.accentSoft : GeekTheme.pillSubtle)
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
    var hintToolTip: String?
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
        if let hint = hintToolTip, !hint.isEmpty { return hint }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.backgroundColor = GeekTheme.resolvedCGColor(GeekTheme.inputBg, for: self)
        refreshBorder()
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = GeekTheme.resolvedCGColor(GeekTheme.inputBg, for: self)
        refreshBorder()
        if let ph = field.placeholderAttributedString?.string, !ph.isEmpty { field.setGeekPlaceholder(ph) }
    }

    private func refreshBorder() {
        layer?.borderWidth = focused ? 1.25 : 1.0
        let col = focused ? GeekTheme.accent.withAlphaComponent(0.80) : (hovered ? GeekTheme.borderStrong : GeekTheme.border)
        layer?.borderColor = GeekTheme.resolvedCGColor(col, for: self)
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

/// 权限状态行视图（14pt 主标题 + 右侧或紧邻清晰语义状态）
final class GeekDotLabel: NSView {
    var dotColor: NSColor = GeekTheme.emerald { didSet { needsDisplay = true } }
    var text: String = "" { didSet { needsDisplay = true } }
    var detail: String = "" { didSet { needsDisplay = true } }
    var alignDetailRight: Bool = true
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        MSnipUITheme.drawStatusDot(ctx: ctx, center: CGPoint(x: 6, y: bounds.midY), color: dotColor, halo: true)

        let titleFont = NSFont.systemFont(ofSize: 13.5, weight: .regular)
        let tW = GeekTheme.measureTextWidth(text, font: titleFont)
        GeekTheme.drawText(text, in: CGRect(x: 20, y: 0, width: max(20, bounds.width - 22), height: bounds.height), font: titleFont, color: GeekTheme.inkPrimary)

        if !detail.isEmpty {
            let detFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
            if alignDetailRight {
                GeekTheme.drawText(detail, in: CGRect(x: 20 + tW + 8, y: 0, width: max(20, bounds.width - 28 - tW), height: bounds.height), font: detFont, color: dotColor, align: .right)
            } else {
                GeekTheme.drawText(detail, in: CGRect(x: 20 + tW + 12, y: 0, width: max(20, bounds.width - 32 - tW), height: bounds.height), font: detFont, color: dotColor)
            }
        }
    }
}

/// 设置窗口暗黑/明亮/跟随系统外观切换联动与统一竖向滚动容器配置扩展
extension TranslationSettingsWindow {
    func configureVerticalScroll(_ scroll: NSScrollView) {
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
    }

    func toggleDarkLightQuick() {
        AppAppearanceCoordinator.shared.toggleDarkLight()
    }

    func applyAppearanceMode(_ mode: AppAppearanceMode, persist: Bool) {
        if !AppAppearanceCoordinator.shared.setMode(mode, persist: persist) {
            refreshSettingsWindowAppearance()
        }
    }

    func refreshSettingsWindowAppearance() {
        let mode = GeekTheme.currentMode
        HotKeyConflictPopover.shared.closeIfShown()
        ProviderAddAndPresetPopover.shared.closeIfShown()
        LanguagePickerPopover.shared.closeIfShown()
        if let win = window {
            win.appearance = GeekTheme.windowAppearance
            win.backgroundColor = GeekTheme.windowBg
            if let root = win.contentView { ResultWindowChrome.invalidateSubtree(root) }
        }
        tableView?.reloadData()
        if let idx = AppAppearanceMode.allCases.firstIndex(of: mode) {
            modeControls.appearanceSegment?.selectedIndex = idx
        }
        let dark = GeekTheme.isDark
        modeControls.themeToggleBtn?.title = dark ? L("明亮") : L("暗黑")
        modeControls.themeToggleBtn?.symbolName = dark ? "sun.max" : "moon"
        modeControls.themeToggleBtn?.toolTip = dark ? L("当前暗黑模式 · 点击一键切换明亮模式") : L("当前明亮模式 · 点击一键切换暗黑模式")
    }
}

// MARK: - 极客风格进度滑块控件

/// 极客设置页连续可拖拽进度滑条（`0%` 显示为「关闭」，支持点击/拖拽实时预览、松手提交、滚轮微调与双击复位默认）
final class GeekProgressSlider: NSView {
    var value: CGFloat = 0.45 {
        didSet {
            let c = min(1.0, max(0.0, value))
            if abs(c - value) > 0.0001 { value = c; return }
            if abs(oldValue - value) > 0.0005 { needsDisplay = true }
        }
    }
    var defaultValue: CGFloat = 0.45
    var zeroLabel: String = L("关闭")
    var onChange: ((CGFloat) -> Void)?
    var onCommit: ((CGFloat) -> Void)?

    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    private var dragging = false { didSet { if oldValue != dragging { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(value: CGFloat = 0.45, defaultValue: CGFloat = 0.45, zeroLabel: String = L("关闭")) {
        self.value = min(1.0, max(0.0, value))
        self.defaultValue = defaultValue
        self.zeroLabel = zeroLabel
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

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

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    private var trackRange: (minX: CGFloat, maxX: CGFloat) {
        let labelW: CGFloat = 44
        let left: CGFloat = 7
        let right = max(left + 40, bounds.width - labelW - 10)
        return (left, right)
    }

    private func valueFromPoint(_ pt: NSPoint) -> CGFloat {
        let r = trackRange
        let raw = (pt.x - r.minX) / max(1, r.maxX - r.minX)
        let pct = (min(1.0, max(0.0, raw)) * 100.0).rounded()
        return pct <= 1.0 ? 0.0 : pct / 100.0
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            value = defaultValue
            onChange?(value)
            onCommit?(value)
            return
        }
        dragging = true
        let next = valueFromPoint(convert(event.locationInWindow, from: nil))
        value = next
        onChange?(next)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let next = valueFromPoint(convert(event.locationInWindow, from: nil))
        if abs(next - value) > 0.001 {
            value = next
            onChange?(next)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        let next = valueFromPoint(convert(event.locationInWindow, from: nil))
        value = next
        onChange?(next)
        onCommit?(next)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        guard abs(delta) > 0.01 else { return }
        let step: CGFloat = delta > 0 ? 0.02 : -0.02
        let pct = (min(1.0, max(0.0, value + step)) * 100.0).rounded()
        let next = pct <= 1.0 ? 0.0 : pct / 100.0
        if abs(next - value) > 0.001 {
            value = next
            onChange?(next)
            onCommit?(next)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = trackRange
        let trackH: CGFloat = 4.0
        let trackY = round((bounds.height - trackH) * 0.5)
        let trackRect = CGRect(x: r.minX, y: trackY, width: r.maxX - r.minX, height: trackH)
        let trackPath = CGPath(roundedRect: trackRect, cornerWidth: 2.0, cornerHeight: 2.0, transform: nil)

        ctx.saveGState()
        // 1) 背景轨道
        ctx.setFillColor(GeekTheme.segTrackBg.cgColor)
        ctx.addPath(trackPath); ctx.fillPath()
        ctx.setStrokeColor(GeekTheme.border.cgColor)
        ctx.setLineWidth(0.75)
        ctx.addPath(trackPath); ctx.strokePath()

        // 2) 默认刻度微提示线（45%）
        let defX = round(r.minX + (r.maxX - r.minX) * defaultValue)
        ctx.setFillColor(GeekTheme.inkMuted.withAlphaComponent(0.32).cgColor)
        ctx.fill(CGRect(x: defX, y: trackY - 2, width: 1, height: trackH + 4))

        // 3) 蓝色高亮进度填充
        let fillW = max(0, (r.maxX - r.minX) * value)
        if fillW > 0.5 {
            let fillRect = CGRect(x: r.minX, y: trackY, width: fillW, height: trackH)
            let fillPath = CGPath(roundedRect: fillRect, cornerWidth: 2.0, cornerHeight: 2.0, transform: nil)
            ctx.setFillColor(GeekTheme.accent.cgColor)
            ctx.addPath(fillPath); ctx.fillPath()
        }

        // 4) 圆形滑块手柄
        let knobD: CGFloat = (dragging || hovered) ? 15.0 : 13.5
        let knobX = r.minX + fillW - knobD * 0.5
        let knobY = round((bounds.height - knobD) * 0.5)
        let knobRect = CGRect(x: knobX, y: knobY, width: knobD, height: knobD)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.0), blur: 3.0, color: NSColor.black.withAlphaComponent(dragging ? 0.28 : 0.18).cgColor)
        ctx.setFillColor(GeekTheme.segActiveBg.cgColor)
        ctx.fillEllipse(in: knobRect)
        ctx.restoreGState()
        ctx.setStrokeColor((dragging ? GeekTheme.accent : GeekTheme.borderStrong).cgColor)
        ctx.setLineWidth(dragging ? 1.4 : 0.9)
        ctx.strokeEllipse(in: knobRect.insetBy(dx: 0.45, dy: 0.45))

        // 5) 右侧等宽数值读数（0% 显示「关闭」）
        let pct = Int((value * 100.0).rounded())
        let text = pct == 0 ? zeroLabel : "\(pct)%"
        let font: NSFont = pct == 0
            ? .systemFont(ofSize: 12.0, weight: .medium)
            : .monospacedDigitSystemFont(ofSize: 12.0, weight: .semibold)
        let color: NSColor = dragging ? GeekTheme.accent : (pct == 0 ? GeekTheme.inkMuted : GeekTheme.inkPrimary)
        let labelRect = CGRect(x: r.maxX + 6, y: 0, width: bounds.width - r.maxX - 6, height: bounds.height)
        GeekTheme.drawText(text, in: labelRect, font: font, color: color, align: .right)
        ctx.restoreGState()
    }
}
