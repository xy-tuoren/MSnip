import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 悬浮工具栏（Daylight Porcelain 清爽浅色白底风格）的按钮底色、SF Symbol 位图缓存、拖拽手柄与主操作胶囊绘制
extension ToolbarView {
    private static var symbolMaskCache: [String: (cg: CGImage, size: NSSize)] = [:]

    static let inkDark = MSnipUITheme.inkPrimary
    static let accentBlue = MSnipUITheme.accent

    static func drawButtonBg(ctx: CGContext, rect: CGRect, active: Bool, hovered: Bool, darkSurface: Bool = false) {
        guard active || hovered else { return }
        let path = CGPath(roundedRect: rect, cornerWidth: 6.5, cornerHeight: 6.5, transform: nil)
        ctx.saveGState()
        if darkSurface {
            let color = active ? accentBlue.withAlphaComponent(0.88) : NSColor.white.withAlphaComponent(0.15)
            ctx.setFillColor(color.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        } else if active {
            ctx.setFillColor(MSnipUITheme.activeSoftFill.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setStrokeColor(accentBlue.withAlphaComponent(0.32).cgColor)
            ctx.setLineWidth(1.0)
            ctx.addPath(path)
            ctx.strokePath()
        } else {
            ctx.setFillColor(MSnipUITheme.hoverFill.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    static func drawGripDots(ctx: CGContext, in rect: CGRect) {
        ctx.saveGState()
        ctx.setFillColor(MSnipUITheme.inkMuted.withAlphaComponent(0.55).cgColor)
        let cols: [CGFloat] = [round(rect.midX - 2.5), round(rect.midX + 2.5)]
        let rows: [CGFloat] = [round(rect.midY - 5.0), round(rect.midY), round(rect.midY + 5.0)]
        for cx in cols {
            for cy in rows {
                ctx.fillEllipse(in: CGRect(x: cx - 1.1, y: cy - 1.1, width: 2.2, height: 2.2))
            }
        }
        ctx.restoreGState()
    }

    static func drawSmallChevron(ctx: CGContext, x: CGFloat, centerY: CGFloat, active: Bool) {
        ctx.saveGState()
        let tint = active ? accentBlue : MSnipUITheme.inkSecondary.withAlphaComponent(0.75)
        ctx.setStrokeColor(tint.cgColor)
        ctx.setLineWidth(1.3)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: x - 2.5, y: centerY - 1.2))
        ctx.addLine(to: CGPoint(x: x, y: centerY + 1.5))
        ctx.addLine(to: CGPoint(x: x + 2.5, y: centerY - 1.2))
        ctx.strokePath()
        ctx.restoreGState()
    }

    static func drawSymbol(_ name: String, in rect: CGRect, alpha: CGFloat = 0.94, tint: NSColor = ToolbarView.inkDark) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let entry: (cg: CGImage, size: NSSize)
        if let cached = symbolMaskCache[name] {
            entry = cached
        } else {
            guard let baseImg = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
            let cfg = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .medium)
            let configured = baseImg.withSymbolConfiguration(cfg) ?? baseImg
            guard let cg = configured.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let created = (cg: cg, size: configured.size)
            symbolMaskCache[name] = created
            entry = created
        }

        let size = entry.size
        let dst = CGRect(
            x: round(rect.midX - size.width * 0.5),
            y: round(rect.midY - size.height * 0.5),
            width: size.width,
            height: size.height
        )
        ctx.saveGState()
        ctx.translateBy(x: 0, y: dst.minY + dst.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.clip(to: dst, mask: entry.cg)
        ctx.setFillColor(tint.withAlphaComponent(alpha).cgColor)
        ctx.fill(dst)
        ctx.restoreGState()
    }

    static func drawEyedropperItem(
        ctx: CGContext,
        rect: CGRect,
        active: Bool,
        customColor: RGBAColor?,
        hovered: Bool
    ) {
        drawButtonBg(ctx: ctx, rect: rect, active: active, hovered: hovered)
        let tint: NSColor = active ? accentBlue : inkDark
        drawSymbol("eyedropper", in: rect, alpha: 0.94, tint: tint)
        if let c = customColor {
            let dot = CGRect(x: rect.maxX - 8.5, y: rect.maxY - 8.5, width: 6, height: 6)
            ctx.setFillColor(c.cgColor)
            ctx.fillEllipse(in: dot)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.2)
            ctx.strokeEllipse(in: dot)
        }
    }
}
