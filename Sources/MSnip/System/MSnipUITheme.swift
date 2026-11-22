import AppKit
import CoreGraphics
import Foundation

/// MSnip 统一「清爽浅色磨砂白底（Daylight Porcelain）」设计系统令牌与通用矢量控件
enum MSnipUITheme {
    // MARK: - Core Palette Tokens
    static let canvasBg       = NSColor(srgbRed: 0.961, green: 0.965, blue: 0.978, alpha: 1.0) // #F5F6FA
    static let sidebarBg      = NSColor(srgbRed: 0.929, green: 0.938, blue: 0.957, alpha: 1.0) // #EDEFF4
    static let cardBg         = NSColor(srgbRed: 0.992, green: 0.994, blue: 1.000, alpha: 0.97)
    static let cardSolid      = NSColor.white
    static let subtleFill     = NSColor(srgbRed: 0.945, green: 0.955, blue: 0.973, alpha: 1.0) // #F1F4F8
    static let transWellFill  = NSColor(srgbRed: 0.953, green: 0.973, blue: 1.000, alpha: 1.0) // #F3F8FF
    static let hoverFill      = NSColor(srgbRed: 0.060, green: 0.110, blue: 0.220, alpha: 0.065)
    static let activeSoftFill = NSColor(srgbRed: 0.047, green: 0.431, blue: 0.953, alpha: 0.13)

    static let borderHairline = NSColor(srgbRed: 0.080, green: 0.120, blue: 0.200, alpha: 0.11)
    static let borderStrong   = NSColor(srgbRed: 0.080, green: 0.120, blue: 0.200, alpha: 0.18)

    static let inkPrimary     = NSColor(srgbRed: 0.078, green: 0.098, blue: 0.137, alpha: 1.0) // #141923
    static let inkSecondary   = NSColor(srgbRed: 0.318, green: 0.357, blue: 0.427, alpha: 1.0) // #515B6D
    static let inkMuted       = NSColor(srgbRed: 0.475, green: 0.514, blue: 0.584, alpha: 1.0) // #798395
    static let inkTrans       = NSColor(srgbRed: 0.055, green: 0.180, blue: 0.360, alpha: 1.0)

    static let accent         = NSColor(srgbRed: 0.047, green: 0.431, blue: 0.953, alpha: 1.0) // #0C6EF3
    static let accentHover    = NSColor(srgbRed: 0.035, green: 0.365, blue: 0.835, alpha: 1.0)
    static let success        = NSColor(srgbRed: 0.051, green: 0.580, blue: 0.408, alpha: 1.0) // #0D9468
    static let warning        = NSColor(srgbRed: 0.847, green: 0.467, blue: 0.024, alpha: 1.0) // #D87706
    static let danger         = NSColor(srgbRed: 0.863, green: 0.149, blue: 0.149, alpha: 1.0) // #DC2626

    // MARK: - CoreGraphics Primitives

    static func drawPorcelainBar(ctx: CGContext, bounds: CGRect, radius: CGFloat = 9.5) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(cardBg.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setStrokeColor(borderStrong.cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    static func drawPrimaryCTA(ctx: CGContext, rect: CGRect, radius: CGFloat = 6.5, color: NSColor = accent, hovered: Bool) {
        let top = (color == danger)
            ? NSColor(srgbRed: 0.96, green: 0.27, blue: 0.36, alpha: 1.0)
            : (color == accent ? NSColor(srgbRed: 0.14, green: 0.53, blue: 1.0, alpha: 1.0) : color)
        let bot = (color == danger)
            ? NSColor(srgbRed: 0.84, green: 0.14, blue: 0.24, alpha: 1.0)
            : (color == accent ? NSColor(srgbRed: 0.04, green: 0.39, blue: 0.92, alpha: 1.0) : color)
        drawGradientCTA(ctx: ctx, rect: rect, radius: radius, topColor: top, bottomColor: bot, hovered: hovered)
    }

    static func drawGradientCTA(ctx: CGContext, rect: CGRect, radius: CGFloat, topColor: NSColor, bottomColor: NSColor, hovered: Bool) {
        let t = hovered ? (topColor.blended(withFraction: 0.10, of: .black) ?? topColor) : topColor
        let b = hovered ? (bottomColor.blended(withFraction: 0.10, of: .black) ?? bottomColor) : bottomColor
        let p = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        ctx.saveGState()
        ctx.addPath(p)
        ctx.clip()
        if let g = CGGradient(colorsSpace: cs, colors: [t.cgColor, b.cgColor] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
        }
        ctx.restoreGState()
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: max(1, radius - 0.5), cornerHeight: max(1, radius - 0.5), transform: nil))
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// 商业级定制菜单栏矢量图标（与 AppIcon 保持一致的「四角取景框 + 光学圆孔快门」轮廓，原生自适应 @1x/@2x 与浅色/深色菜单栏）
    static func menuBarIcon(recording: Bool = false) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let box = CGRect(x: 2.25, y: 2.25, width: 13.5, height: 13.5)
            let arm: CGFloat = 3.6, arcR: CGFloat = 2.3
            let path = CGMutablePath()
            path.move(to: CGPoint(x: box.minX, y: box.maxY - arm))
            path.addArc(tangent1End: CGPoint(x: box.minX, y: box.maxY), tangent2End: CGPoint(x: box.minX + arm, y: box.maxY), radius: arcR)
            path.addLine(to: CGPoint(x: box.minX + arm, y: box.maxY))
            path.move(to: CGPoint(x: box.maxX - arm, y: box.maxY))
            path.addArc(tangent1End: CGPoint(x: box.maxX, y: box.maxY), tangent2End: CGPoint(x: box.maxX, y: box.maxY - arm), radius: arcR)
            path.addLine(to: CGPoint(x: box.maxX, y: box.maxY - arm))
            path.move(to: CGPoint(x: box.maxX, y: box.minY + arm))
            path.addArc(tangent1End: CGPoint(x: box.maxX, y: box.minY), tangent2End: CGPoint(x: box.maxX - arm, y: box.minY), radius: arcR)
            path.addLine(to: CGPoint(x: box.maxX - arm, y: box.minY))
            path.move(to: CGPoint(x: box.minX + arm, y: box.minY))
            path.addArc(tangent1End: CGPoint(x: box.minX, y: box.minY), tangent2End: CGPoint(x: box.minX, y: box.minY + arm), radius: arcR)
            path.addLine(to: CGPoint(x: box.minX, y: box.minY + arm))

            let ink = recording ? NSColor.labelColor : NSColor.black
            ctx.setStrokeColor(ink.cgColor)
            ctx.setLineWidth(1.6)
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            ctx.addPath(path); ctx.strokePath()

            if recording {
                ctx.setFillColor(NSColor(srgbRed: 0.96, green: 0.23, blue: 0.34, alpha: 1.0).cgColor)
                ctx.fillEllipse(in: CGRect(x: 5.5, y: 5.5, width: 7.0, height: 7.0))
            } else {
                let tile = CGPath(roundedRect: CGRect(x: 5.2, y: 5.2, width: 7.6, height: 7.6), cornerWidth: 2.1, cornerHeight: 2.1, transform: nil)
                let hole = CGPath(ellipseIn: CGRect(x: 7.1, y: 7.1, width: 3.8, height: 3.8), transform: nil)
                ctx.setFillColor(ink.cgColor)
                ctx.addPath(tile); ctx.addPath(hole)
                ctx.fillPath(using: .evenOdd)
            }
            return true
        }
        img.isTemplate = !recording
        return img
    }

    static func drawStatusDot(ctx: CGContext, center: CGPoint, color: NSColor, halo: Bool = false) {
        ctx.saveGState()
        if halo {
            ctx.setFillColor(color.withAlphaComponent(0.18).cgColor)
            ctx.fillEllipse(in: CGRect(x: center.x - 6, y: center.y - 6, width: 12, height: 12))
        }
        ctx.setFillColor(color.cgColor)
        ctx.fillEllipse(in: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))
        ctx.restoreGState()
    }

    static func menuSymbol(_ name: String, pt: CGFloat = 13) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: .medium)
        let img = base.withSymbolConfiguration(cfg) ?? base
        img.isTemplate = true
        return img
    }
}

/// 清爽浅色白底自定义下拉胶囊选择器（替代生硬的系统旧式 `NSPopUpButton`）
final class LightDropdownPill: NSView {
    var items: [String] = [] { didSet { needsDisplay = true } }
    var selectedIndex: Int = 0 { didSet { needsDisplay = true } }
    var symbolName: String? { didSet { needsDisplay = true } }
    var onSelect: ((Int) -> Void)?

    private var hovered = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    init(symbol: String? = nil, items: [String] = [], selectedIndex: Int = 0) {
        self.symbolName = symbol
        self.items = items
        self.selectedIndex = selectedIndex
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
        let idx = sender.tag
        guard items.indices.contains(idx) else { return }
        selectedIndex = idx
        onSelect?(idx)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: r, cornerWidth: 6.5, cornerHeight: 6.5, transform: nil)
        ctx.saveGState()
        ctx.setFillColor((hovered ? MSnipUITheme.subtleFill : MSnipUITheme.cardSolid).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setStrokeColor((hovered ? MSnipUITheme.accent.withAlphaComponent(0.45) : MSnipUITheme.borderStrong).cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(path)
        ctx.strokePath()

        var leftX: CGFloat = 9
        if let sym = symbolName {
            let iconRect = CGRect(x: leftX, y: 0, width: 14, height: bounds.height)
            ToolbarView.drawSymbol(sym, in: iconRect, alpha: 0.92, tint: MSnipUITheme.accent)
            leftX += 18
        }

        let currentTitle = items.indices.contains(selectedIndex) ? items[selectedIndex] : "未选择"
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: MSnipUITheme.inkPrimary,
            .paragraphStyle: para
        ]
        let textMaxW = max(24, bounds.width - leftX - 20)
        let sz = (currentTitle as NSString).size(withAttributes: attrs)
        let textRect = CGRect(
            x: round(leftX),
            y: round((bounds.height - sz.height) * 0.5),
            width: textMaxW,
            height: sz.height + 2
        )
        (currentTitle as NSString).draw(in: textRect, withAttributes: attrs)

        ToolbarView.drawSmallChevron(ctx: ctx, x: bounds.width - 10, centerY: bounds.midY + 0.5, active: hovered)
        ctx.restoreGState()
    }
}
