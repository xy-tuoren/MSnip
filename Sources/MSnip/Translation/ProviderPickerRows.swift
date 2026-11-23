import AppKit
import CoreGraphics
import Foundation

/// 服务添加 / 预设选择浮窗内的辅助视图（搜索图标、分组头、带悬停完整提示的双行富选项卡片）
final class ProviderSearchIconView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        GeekTheme.drawSymbol("magnifyingglass", pointSize: 12.5, weight: .semibold, in: bounds, alpha: 0.9, tint: GeekTheme.inkSecondary)
    }
}

final class ClickableProviderTableView: NSTableView {
    var onRowClicked: ((Int) -> Void)?
    override func mouseDown(with event: NSEvent) {
        let r = row(at: convert(event.locationInWindow, from: nil))
        if r >= 0 { onRowClicked?(r) }
    }
}

final class ProviderPickerHeaderView: NSView {
    let title: String
    override var isFlipped: Bool { true }
    init(title: String) { self.title = title; super.init(frame: .zero) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        GeekTheme.drawText(title, in: CGRect(x: 12, y: 4, width: max(40, bounds.width - 24), height: bounds.height - 4), font: .systemFont(ofSize: 11.0, weight: .semibold), color: GeekTheme.inkMuted)
    }
}

final class ProviderPickerRowView: NSView {
    let title: String
    let subtitle: String
    let symbol: String
    let badge: String
    let badgeColor: NSColor
    let selected: Bool
    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    override var isFlipped: Bool { true }

    init(title: String, subtitle: String, symbol: String, badge: String, badgeColor: NSColor, selected: Bool) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol
        self.badge = badge; self.badgeColor = badgeColor; self.selected = selected
        super.init(frame: .zero)
        self.toolTip = "\(title)\n\(subtitle)"
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 6, dy: 1.5)
        if selected || hovered {
            let p = CGPath(roundedRect: r, cornerWidth: 8.0, cornerHeight: 8.0, transform: nil)
            ctx.setFillColor((selected ? GeekTheme.accentSoft : GeekTheme.controlHover).cgColor)
            ctx.addPath(p); ctx.fillPath()
        }
        let iconBox = CGRect(x: 14, y: GeekTheme.snap((bounds.height - 28) * 0.5), width: 28, height: 28)
        let ip = CGPath(roundedRect: iconBox, cornerWidth: 7.0, cornerHeight: 7.0, transform: nil)
        ctx.setFillColor(GeekTheme.controlBg.cgColor); ctx.addPath(ip); ctx.fillPath()
        ctx.setStrokeColor(GeekTheme.border.cgColor); ctx.setLineWidth(1.0); ctx.addPath(ip); ctx.strokePath()
        GeekTheme.drawSymbol(symbol, pointSize: 12.0, weight: .medium, in: iconBox, alpha: 0.94, tint: selected ? GeekTheme.accent : GeekTheme.inkPrimary)

        let badgeFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        let bw = max(46, ceil(GeekTheme.measureTextWidth(badge, font: badgeFont) + 12))
        let br = CGRect(x: bounds.width - bw - 14, y: GeekTheme.snap((bounds.height - 20) * 0.5), width: bw, height: 20)
        ctx.setFillColor(badgeColor.withAlphaComponent(0.14).cgColor)
        ctx.addPath(CGPath(roundedRect: br, cornerWidth: 5.0, cornerHeight: 5.0, transform: nil)); ctx.fillPath()
        GeekTheme.drawText(badge, in: br, font: badgeFont, color: badgeColor, align: .center)

        let textW = max(60, br.minX - 58)
        GeekTheme.drawText(title, in: CGRect(x: 50, y: 6, width: textW, height: 18), font: .systemFont(ofSize: 13.0, weight: .semibold), color: GeekTheme.inkPrimary)
        GeekTheme.drawText(subtitle, in: CGRect(x: 50, y: 24, width: textW, height: 15), font: .systemFont(ofSize: 11.0, weight: .regular), color: GeekTheme.inkSecondary)
    }
}
