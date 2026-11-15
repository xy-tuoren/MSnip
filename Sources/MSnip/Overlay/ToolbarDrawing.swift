import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 悬浮标注工具栏的纯矢量按钮底色、SF Symbol 位图掩码缓存与取色吸管渲染方法
extension ToolbarView {
    private static var symbolMaskCache: [String: (cg: CGImage, size: NSSize)] = [:]

    static func drawButtonBg(ctx: CGContext, rect: CGRect, active: Bool, hovered: Bool) {
        guard active || hovered else { return }
        let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        let color = active
            ? NSColor.controlAccentColor.withAlphaComponent(0.85)
            : NSColor.white.withAlphaComponent(0.14)
        ctx.setFillColor(color.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
    }

    static func drawSymbol(_ name: String, in rect: CGRect, alpha: CGFloat, tint: NSColor = .white) {
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
        let tint: NSColor
        if let c = customColor {
            tint = NSColor(srgbRed: CGFloat(c.r) / 255.0, green: CGFloat(c.g) / 255.0, blue: CGFloat(c.b) / 255.0, alpha: 1.0)
        } else {
            tint = .white
        }
        drawSymbol("eyedropper", in: rect, alpha: 0.95, tint: tint)
        if let c = customColor, !active {
            let dot = CGRect(x: rect.maxX - 8, y: rect.maxY - 8, width: 5, height: 5)
            ctx.setFillColor(c.cgColor)
            ctx.fillEllipse(in: dot)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(0.8)
            ctx.strokeEllipse(in: dot)
        }
    }
}
