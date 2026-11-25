import AppKit
import CoreGraphics
import Foundation

/// 贴图窗口外发光柔和容器：
/// - 静置态呈现淡淡发光白边（兼顾浅色壁纸环境分离），鼠标悬浮/选中/标注时平滑点亮柔和蓝色外光晕；
/// - 采用 even-odd 外环裁切，仅向图像外围渲染光晕，绝不向透明圆角图像内部填底色。
final class PinGlowContainerView: NSView {
    static let glowPadding: CGFloat = 14.0

    let contentHost: PinContentView
    var glowStrength: CGFloat = 0.45 { didSet { if abs(oldValue - glowStrength) > 0.001 { needsDisplay = true } } }
    var isHoveredOrFocused: Bool = false { didSet { if oldValue != isHoveredOrFocused { needsDisplay = true } } }
    var isAnnotating: Bool = false { didSet { if oldValue != isAnnotating { needsDisplay = true } } }
    var isGhostMode: Bool = false { didSet { if oldValue != isGhostMode { needsDisplay = true } } }

    init(contentView: PinContentView, glowStrength: CGFloat) {
        self.contentHost = contentView
        self.glowStrength = min(1.0, max(0.0, glowStrength))
        let pad = Self.glowPadding
        let fullSize = NSSize(width: contentView.frame.width + pad * 2, height: contentView.frame.height + pad * 2)
        super.init(frame: NSRect(origin: .zero, size: fullSize))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        contentView.frame = NSRect(x: pad, y: pad, width: contentView.frame.width, height: contentView.frame.height)
        contentView.autoresizingMask = [.width, .height]
        addSubview(contentView)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard contentHost.frame.contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let imgRect = contentHost.frame
        guard imgRect.width >= 4, imgRect.height >= 4 else { return }

        let activeBlue = isHoveredOrFocused || isAnnotating
        let s = min(1.0, max(0.0, glowStrength))
        if !activeBlue && !isGhostMode && s <= 0.005 { return }

        ctx.saveGState()
        // 外环 even-odd 裁切：确保光晕严格扩散在贴图外部，不污染透明圆角内部
        ctx.addRect(bounds)
        ctx.addRect(imgRect)
        ctx.clip(using: .evenOdd)

        if activeBlue {
            let eff = max(0.35, s)
            let outerBlur = 3.5 + 8.5 * eff
            let coreBlur = max(2.0, outerBlur * 0.42)
            // 1) 宽柔蓝色外光晕
            ctx.setShadow(
                offset: .zero,
                blur: outerBlur,
                color: NSColor(srgbRed: 0.14, green: 0.50, blue: 1.0, alpha: 0.58 + 0.34 * eff).cgColor
            )
            ctx.setFillColor(NSColor(srgbRed: 0.18, green: 0.54, blue: 1.0, alpha: 1.0).cgColor)
            ctx.fill(imgRect)
            // 2) 贴边高亮蓝光核心层
            ctx.setShadow(
                offset: .zero,
                blur: coreBlur,
                color: NSColor(srgbRed: 0.28, green: 0.62, blue: 1.0, alpha: 0.78 + 0.18 * eff).cgColor
            )
            ctx.fill(imgRect)
            ctx.restoreGState()

            // 3) 精致 1pt 亮蓝外描边
            ctx.saveGState()
            ctx.setStrokeColor(NSColor(srgbRed: 0.32, green: 0.66, blue: 1.0, alpha: 0.92).cgColor)
            ctx.setLineWidth(1.0)
            ctx.stroke(imgRect.insetBy(dx: -0.5, dy: -0.5))
            ctx.restoreGState()
            return
        }

        if isGhostMode {
            let blur = max(3.5, 2.5 + 6.0 * s)
            ctx.setShadow(
                offset: .zero,
                blur: blur,
                color: NSColor(srgbRed: 0.20, green: 0.54, blue: 1.0, alpha: 0.45).cgColor
            )
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(imgRect)
            ctx.restoreGState()
            ctx.saveGState()
            ctx.setStrokeColor(NSColor(srgbRed: 0.30, green: 0.62, blue: 1.0, alpha: 0.55).cgColor)
            ctx.setLineWidth(1.0)
            ctx.stroke(imgRect.insetBy(dx: -0.5, dy: -0.5))
            ctx.restoreGState()
            return
        }

        // 默认静置态：淡淡发光白边 + 柔和环境分离影（深色桌面通透微光、纯白浅色网页下边界同样清晰常亮）
        let blur = 3.0 + 8.6 * s
        ctx.setShadow(
            offset: .zero,
            blur: blur * 0.85,
            color: NSColor.black.withAlphaComponent(0.20 + 0.16 * s).cgColor
        )
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(imgRect)

        ctx.setShadow(
            offset: .zero,
            blur: blur,
            color: NSColor.white.withAlphaComponent(0.46 + 0.44 * s).cgColor
        )
        ctx.fill(imgRect)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.32 + 0.36 * s).cgColor)
        ctx.setLineWidth(0.85)
        ctx.stroke(imgRect.insetBy(dx: -0.45, dy: -0.45))
        ctx.restoreGState()
    }
}
