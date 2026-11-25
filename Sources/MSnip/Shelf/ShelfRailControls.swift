import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 暂存条左右边缘极简透明翻页控件（静止时仅呈现优雅 SF Symbol 箭头，悬停才浮出柔光微胶囊，告别笨重白条）
final class ShelfEdgeArrowButton: NSView {
    let symbolName: String
    var isNavEnabled: Bool = true { didSet { if oldValue != isNavEnabled { needsDisplay = true } } }
    var onClick: (() -> Void)?

    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    private var pressed = false { didSet { if oldValue != pressed { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(symbolName: String, toolTip: String) {
        self.symbolName = symbolName
        super.init(frame: .zero)
        self.toolTip = toolTip
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isNavEnabled ? .pointingHand : .arrow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false }
    override func mouseDown(with event: NSEvent) { guard isNavEnabled else { return }; pressed = true }
    override func mouseUp(with event: NSEvent) {
        let fire = pressed && isNavEnabled && bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if fire { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let isDark = GeekTheme.isDark
        let pill = CGRect(x: round(bounds.midX - 9.5), y: round(bounds.midY - 19), width: 19, height: 38)

        if isNavEnabled && (hovered || pressed) {
            let p = CGPath(roundedRect: pill, cornerWidth: 7, cornerHeight: 7, transform: nil)
            let fill = isDark
                ? NSColor.white.withAlphaComponent(pressed ? 0.18 : 0.11)
                : NSColor.black.withAlphaComponent(pressed ? 0.13 : 0.07)
            ctx.setFillColor(fill.cgColor)
            ctx.addPath(p); ctx.fillPath()
        }

        let alpha: CGFloat = !isNavEnabled ? 0.22 : (hovered ? 0.95 : 0.68)
        let tint = isDark ? NSColor.white : NSColor(white: 0.16, alpha: 1)
        GeekTheme.drawSymbol(symbolName, pointSize: 11.0, weight: .semibold, in: pill, alpha: alpha, tint: tint)
    }
}

/// 顶部暂存条右侧精炼控制列（原生毛玻璃调和色调 + SF Symbols 图标，彻底取代刺眼白底按钮块）
final class ShelfActionRailView: NSView {
    var itemCount: Int = 0 { didSet { if oldValue != itemCount { needsDisplay = true } } }
    var selectedCount: Int = 0 { didSet { if oldValue != selectedCount { needsDisplay = true } } }
    var isPinned: Bool = false { didSet { if oldValue != isPinned { needsDisplay = true } } }

    var onTogglePin: (() -> Void)?
    var onClose: (() -> Void)?
    var onAddClipboard: (() -> Void)?
    var onOpenCollage: (() -> Void)?

    private enum Slot: Int, CaseIterable { case pin, close, clipboard, collage }
    private var hoveredSlot: Slot? { didSet { if oldValue != hoveredSlot { needsDisplay = true; syncToolTip() } } }
    private var pressedSlot: Slot? { didSet { if oldValue != pressedSlot { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func rect(for slot: Slot) -> CGRect {
        let w = bounds.width
        switch slot {
        case .close:     return CGRect(x: w - 21, y: 0, width: 21, height: 21)
        case .pin:       return CGRect(x: w - 45, y: 0, width: 21, height: 21)
        case .clipboard: return CGRect(x: 0, y: 27, width: w, height: 25)
        case .collage:   return CGRect(x: 0, y: 57, width: w, height: 25)
        }
    }

    private func hitSlot(at pt: CGPoint) -> Slot? {
        Slot.allCases.first { rect(for: $0).contains(pt) }
    }

    override func resetCursorRects() {
        for s in Slot.allCases { addCursorRect(rect(for: s), cursor: .pointingHand) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        hoveredSlot = hitSlot(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) { hoveredSlot = nil; pressedSlot = nil }

    override func mouseDown(with event: NSEvent) {
        pressedSlot = hitSlot(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let up = hitSlot(at: convert(event.locationInWindow, from: nil))
        let fire = (up != nil && up == pressedSlot) ? up : nil
        pressedSlot = nil
        switch fire {
        case .pin:       onTogglePin?()
        case .close:     onClose?()
        case .clipboard: onAddClipboard?()
        case .collage:   onOpenCollage?()
        case nil:        break
        }
    }

    private func syncToolTip() {
        switch hoveredSlot {
        case .pin:       toolTip = isPinned ? "取消钉住（离开后自动收起）" : "钉住暂存架保持展开"
        case .close:     toolTip = "收起暂存架 (Esc)"
        case .clipboard: toolTip = "将当前剪贴板图片、文件或文本加入暂存架"
        case .collage:   toolTip = "打开多图拼接与合并 PDF 窗口（⌘+点击卡片可先自选顺序）"
        case nil:        toolTip = nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let isDark = GeekTheme.isDark

        // Row 1 左侧：精炼计数标签
        let countRect = CGRect(x: 1, y: 1, width: max(20, bounds.width - 50), height: 19)
        GeekTheme.drawText(
            "\(itemCount) 项",
            in: countRect,
            font: .monospacedDigitSystemFont(ofSize: 11.2, weight: .semibold),
            color: isDark ? NSColor.white.withAlphaComponent(0.76) : NSColor(white: 0.24, alpha: 0.88)
        )

        // Row 1 右侧：原生 SF Symbol 幽灵图标按钮（钉住 / 关闭）
        drawIconButton(
            in: ctx, rect: rect(for: .pin),
            symbol: isPinned ? "pin.fill" : "pin",
            active: isPinned, hovered: hoveredSlot == .pin, pressed: pressedSlot == .pin,
            danger: false, isDark: isDark
        )
        drawIconButton(
            in: ctx, rect: rect(for: .close),
            symbol: "xmark",
            active: false, hovered: hoveredSlot == .close, pressed: pressedSlot == .close,
            danger: true, isDark: isDark
        )

        // Row 2：剪贴板入架（半透明融背景质感）
        drawRowButton(
            in: ctx, rect: rect(for: .clipboard),
            symbol: "plus.square.on.square", title: "剪贴板",
            accented: false, hovered: hoveredSlot == .clipboard, pressed: pressedSlot == .clipboard,
            isDark: isDark
        )

        // Row 3：拼图 / PDF（多选 ≥ 2 张时优雅点亮强调色）
        let collageTitle = selectedCount > 0 ? "拼图 (\(selectedCount))" : "拼图 / PDF"
        drawRowButton(
            in: ctx, rect: rect(for: .collage),
            symbol: "rectangle.split.2x2", title: collageTitle,
            accented: selectedCount >= 2, hovered: hoveredSlot == .collage, pressed: pressedSlot == .collage,
            isDark: isDark
        )
    }

    private func drawIconButton(
        in ctx: CGContext, rect r: CGRect, symbol: String,
        active: Bool, hovered: Bool, pressed: Bool, danger: Bool, isDark: Bool
    ) {
        let path = CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil)
        if active || hovered || pressed {
            let fill: NSColor
            if active {
                fill = GeekTheme.accent.withAlphaComponent(pressed ? 0.95 : 0.88)
            } else if danger && hovered {
                fill = NSColor.systemRed.withAlphaComponent(pressed ? 0.24 : 0.14)
            } else {
                fill = isDark
                    ? NSColor.white.withAlphaComponent(pressed ? 0.18 : 0.11)
                    : NSColor.black.withAlphaComponent(pressed ? 0.12 : 0.065)
            }
            ctx.setFillColor(fill.cgColor)
            ctx.addPath(path); ctx.fillPath()
        }
        let tint: NSColor = active
            ? .white
            : (danger && hovered ? .systemRed : (isDark ? NSColor.white.withAlphaComponent(0.80) : NSColor(white: 0.22, alpha: 0.86)))
        GeekTheme.drawSymbol(symbol, pointSize: 10.5, weight: .semibold, in: r, alpha: 0.96, tint: tint)
    }

    private func drawRowButton(
        in ctx: CGContext, rect r: CGRect, symbol: String, title: String,
        accented: Bool, hovered: Bool, pressed: Bool, isDark: Bool
    ) {
        let p = CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 7, cornerHeight: 7, transform: nil)
        let fill: NSColor
        let stroke: NSColor
        let fg: NSColor
        if accented {
            fill = GeekTheme.accent.withAlphaComponent(pressed ? 0.96 : (hovered ? 0.92 : 0.86))
            stroke = GeekTheme.accent.withAlphaComponent(0.95)
            fg = .white
        } else {
            fill = isDark
                ? NSColor.white.withAlphaComponent(pressed ? 0.16 : (hovered ? 0.12 : 0.07))
                : NSColor.black.withAlphaComponent(pressed ? 0.11 : (hovered ? 0.075 : 0.045))
            stroke = isDark
                ? NSColor.white.withAlphaComponent(hovered ? 0.18 : 0.10)
                : NSColor.black.withAlphaComponent(hovered ? 0.14 : 0.08)
            fg = isDark ? NSColor.white.withAlphaComponent(0.92) : NSColor(white: 0.14, alpha: 0.94)
        }

        ctx.saveGState()
        ctx.setFillColor(fill.cgColor); ctx.addPath(p); ctx.fillPath()
        ctx.setStrokeColor(stroke.cgColor); ctx.setLineWidth(0.75); ctx.addPath(p); ctx.strokePath()
        ctx.restoreGState()

        let iconR = CGRect(x: r.minX + 7, y: r.minY, width: 13, height: r.height)
        GeekTheme.drawSymbol(symbol, pointSize: 10.8, weight: .medium, in: iconR, alpha: accented ? 0.96 : 0.82, tint: fg)
        let textR = CGRect(x: iconR.maxX + 5, y: r.minY, width: r.maxX - iconR.maxX - 9, height: r.height)
        GeekTheme.drawText(title, in: textR, font: .systemFont(ofSize: 11.2, weight: .medium), color: fg)
    }
}
