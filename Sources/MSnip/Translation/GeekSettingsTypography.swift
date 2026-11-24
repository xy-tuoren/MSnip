import AppKit
import CoreGraphics
import CoreText
import Foundation

/// 设置中心像素级光学居中排版与 Retina 矢量图标渲染引擎
extension GeekTheme {
    struct SymbolMaskEntry {
        let cg: CGImage
        let pointSize: CGSize
    }

    @MainActor private static var symbolCache: [String: SymbolMaskEntry] = [:]

    /// 按 @2x Retina 半点（1 物理像素）对齐坐标，消除 `round()` 带来的 2px 跳变
    static func snap(_ value: CGFloat, scale: CGFloat = 2.0) -> CGFloat {
        (value * scale).rounded() / scale
    }

    /// 测量单行文本精确排版宽度
    static func measureTextWidth(_ text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    /// 在 `isFlipped = true` 视图中以字体 `capHeight / 2` 为光学中轴绘制单行文本（中英文/数字/符号零下沉）
    static func drawText(
        _ text: String,
        in rect: CGRect,
        font: NSFont,
        color: NSColor,
        align: NSTextAlignment = .left
    ) {
        guard !text.isEmpty, rect.width > 1, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        var width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        if width > rect.width {
            let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))
            if let trunc = CTLineCreateTruncatedLine(line, Double(rect.width), .end, token) {
                line = trunc
                width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            }
        }
        let drawX: CGFloat
        switch align {
        case .center: drawX = snap(rect.midX - width * 0.5)
        case .right:  drawX = snap(rect.maxX - width)
        default:      drawX = snap(rect.minX)
        }
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: rect.minY + rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = CGPoint(x: drawX, y: snap(rect.midY - font.capHeight * 0.5))
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// 光栅化并裁剪 SF Symbol 的真实非透明墨迹边界（@2x 高清缓存，消除内置基线留白偏移）
    @MainActor
    static func symbolEntry(_ name: String, pointSize: CGFloat = 12.0, weight: NSFont.Weight = .semibold) -> SymbolMaskEntry? {
        let key = "\(name)@\(pointSize)-\(weight.rawValue)"
        if let hit = symbolCache[key] { return hit }
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        let img = base.withSymbolConfiguration(cfg) ?? base
        let scale: CGFloat = 2.0
        let pw = max(4, Int(ceil(img.size.width * scale)) + 8)
        let ph = max(4, Int(ceil(img.size.height * scale)) + 8)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: pw * 4, bitsPerPixel: 32
        ) else { return nil }
        rep.size = NSSize(width: CGFloat(pw) / scale, height: CGFloat(ph) / scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(
            in: NSRect(
                x: (rep.size.width - img.size.width) * 0.5,
                y: (rep.size.height - img.size.height) * 0.5,
                width: img.size.width,
                height: img.size.height
            )
        )
        NSGraphicsContext.restoreGraphicsState()
        guard let ptr = rep.bitmapData, let fullCG = rep.cgImage else { return nil }
        var minX = pw, maxX = -1, minY = ph, maxY = -1
        for y in 0..<ph {
            for x in 0..<pw where ptr[(y * pw + x) * 4 + 3] > 10 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let cw = maxX - minX + 1, ch = maxY - minY + 1
        guard let cropped = fullCG.cropping(to: CGRect(x: minX, y: minY, width: cw, height: ch)) else { return nil }
        let entry = SymbolMaskEntry(cg: cropped, pointSize: CGSize(width: CGFloat(cw) / scale, height: CGFloat(ch) / scale))
        symbolCache[key] = entry
        return entry
    }

    @MainActor
    static func drawSymbol(
        _ name: String,
        pointSize: CGFloat = 12.0,
        weight: NSFont.Weight = .semibold,
        in rect: CGRect,
        alpha: CGFloat = 1.0,
        tint: NSColor
    ) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let entry = symbolEntry(name, pointSize: pointSize, weight: weight) else { return }
        let dst = CGRect(
            x: snap(rect.midX - entry.pointSize.width * 0.5),
            y: snap(rect.midY - entry.pointSize.height * 0.5),
            width: entry.pointSize.width,
            height: entry.pointSize.height
        )
        ctx.saveGState()
        ctx.translateBy(x: 0, y: dst.minY + dst.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.clip(to: dst, mask: entry.cg)
        ctx.setFillColor(tint.withAlphaComponent(alpha).cgColor)
        ctx.fill(dst)
        ctx.restoreGState()
    }

    /// 将单行 `NSTextField` 精确垂直居中放置于指定 `centerY`
    static func placeCentered(_ field: NSTextField, x: CGFloat, width: CGFloat, centerY: CGFloat) {
        let naturalH = ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 600, height: 40)).height ?? 18)
        field.frame = NSRect(x: x, y: snap(centerY - naturalH * 0.5), width: width, height: naturalH)
    }

    /// 将主副标题双行 `NSTextField` 作为整体精确垂直居中于 `centerY`
    static func placeTwoLineStack(
        _ primary: NSTextField,
        _ secondary: NSTextField,
        x: CGFloat,
        width: CGFloat,
        centerY: CGFloat,
        gap: CGFloat = 2.0
    ) {
        let h1 = ceil(primary.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 600, height: 40)).height ?? 20)
        let h2 = ceil(secondary.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 600, height: 40)).height ?? 16)
        let total = h1 + gap + h2
        let topY = snap(centerY - total * 0.5 - 0.25)
        primary.frame = NSRect(x: x, y: topY, width: width, height: h1)
        secondary.frame = NSRect(x: x, y: snap(topY + h1 + gap), width: width, height: h2)
    }
}

/// 精确锁定于 58pt 顶栏中轴线（y = 29, 左缘对齐 x = 28 卡片栅格）的原生风交通灯关闭钮
final class GeekWindowCloseButton: NSView {
    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    nonisolated(unsafe) private var keyObservers: [NSObjectProtocol] = []
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach { NotificationCenter.default.removeObserver($0) }
        keyObservers.removeAll()
        guard let win = window else { return }
        let nc = NotificationCenter.default
        keyObservers = [
            nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: win, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.needsDisplay = true }
            },
            nc.addObserver(forName: NSWindow.didResignKeyNotification, object: win, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.needsDisplay = true }
            }
        ]
    }

    deinit { keyObservers.forEach { NotificationCenter.default.removeObserver($0) } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { window?.close() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let d: CGFloat = 12.0
        let circle = CGRect(x: GeekTheme.snap(bounds.midX - d * 0.5), y: GeekTheme.snap(bounds.midY - d * 0.5), width: d, height: d)
        let active = (window?.isKeyWindow ?? true) || hovered
        let fill = active ? NSColor(srgbRed: 1.0, green: 0.373, blue: 0.341, alpha: 1.0) : GeekTheme.inactiveDot
        ctx.saveGState()
        ctx.setFillColor(fill.cgColor)
        ctx.fillEllipse(in: circle)
        if active {
            ctx.setStrokeColor(NSColor(srgbRed: 0.878, green: 0.267, blue: 0.243, alpha: 0.65).cgColor)
            ctx.setLineWidth(0.5)
            ctx.strokeEllipse(in: circle.insetBy(dx: 0.25, dy: 0.25))
        }
        if hovered {
            ctx.setStrokeColor(NSColor(srgbRed: 0.28, green: 0.04, blue: 0.04, alpha: 0.88).cgColor)
            ctx.setLineWidth(1.35)
            ctx.setLineCap(.round)
            let r: CGFloat = 2.6, cx = circle.midX, cy = circle.midY
            ctx.move(to: CGPoint(x: cx - r, y: cy - r)); ctx.addLine(to: CGPoint(x: cx + r, y: cy + r))
            ctx.move(to: CGPoint(x: cx + r, y: cy - r)); ctx.addLine(to: CGPoint(x: cx - r, y: cy + r))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }
}

/// 顶栏左侧品牌与版本微胶囊标识（与关闭圆点及中间分段切换共享绝对中轴）
final class GeekBrandTitleView: NSView {
    private let versionText: String
    override var isFlipped: Bool { true }
    init(frame: NSRect, version: String) {
        self.versionText = version
        super.init(frame: frame)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let brandFont = NSFont.systemFont(ofSize: 15.0, weight: .bold)
        let verFont = NSFont.monospacedSystemFont(ofSize: 11.0, weight: .medium)
        let bw = GeekTheme.measureTextWidth("MSnip", font: brandFont)
        GeekTheme.drawText("MSnip", in: CGRect(x: 0, y: 0, width: bw + 2, height: bounds.height), font: brandFont, color: GeekTheme.inkPrimary)

        let vw = GeekTheme.measureTextWidth(versionText, font: verFont)
        let pillW = vw + 12, pillH: CGFloat = 20
        let pillR = CGRect(x: GeekTheme.snap(bw + 8), y: GeekTheme.snap((bounds.height - pillH) * 0.5), width: pillW, height: pillH)
        let path = CGPath(roundedRect: pillR, cornerWidth: 5.5, cornerHeight: 5.5, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(GeekTheme.pillSubtle.cgColor)
        ctx.addPath(path); ctx.fillPath()
        ctx.setStrokeColor(GeekTheme.border.cgColor)
        ctx.setLineWidth(0.75); ctx.addPath(path); ctx.strokePath()
        ctx.restoreGState()
        GeekTheme.drawText(versionText, in: pillR, font: verFont, color: GeekTheme.inkMuted, align: .center)
    }
}
