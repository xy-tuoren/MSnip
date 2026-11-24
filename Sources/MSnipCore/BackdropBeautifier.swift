import AppKit
import CoreGraphics
import CoreText
import Foundation

/// 一键美观背景衬底主题（类似 CleanShot X / PixPin 的渐变画布留白 + 圆角 + 悬浮柔影）
public enum BackdropStyle: Int, CaseIterable, Codable, Sendable {
    case none = 0
    case oceanAurora = 1
    case warmSunset = 2
    case emeraldMist = 3
    case cleanStudio = 4
    case noirCarbon = 5

    public var title: String {
        switch self {
        case .none:        return "无衬底"
        case .oceanAurora: return "极光蓝紫"
        case .warmSunset:  return "落日暖橙"
        case .emeraldMist: return "森系青翠"
        case .cleanStudio: return "极简银灰"
        case .noirCarbon:  return "暗夜深空"
        }
    }

    public var next: BackdropStyle {
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self) else { return .oceanAurora }
        return all[(idx + 1) % all.count]
    }

    public var isLightBackdrop: Bool { self == .cleanStudio }

    /// 供渐变画布与覆盖层预览边框使用的起止色组
    public var gradientStops: [RGBAColor] {
        switch self {
        case .none:        return []
        case .oceanAurora: return [RGBAColor(67, 56, 202), RGBAColor(126, 34, 206), RGBAColor(14, 165, 233)]
        case .warmSunset:  return [RGBAColor(244, 63, 94), RGBAColor(249, 115, 22), RGBAColor(251, 191, 36)]
        case .emeraldMist: return [RGBAColor(13, 148, 136), RGBAColor(16, 185, 129), RGBAColor(110, 231, 183)]
        case .cleanStudio: return [RGBAColor(236, 240, 246), RGBAColor(214, 222, 235), RGBAColor(201, 211, 227)]
        case .noirCarbon:  return [RGBAColor(34, 39, 52), RGBAColor(20, 23, 32), RGBAColor(13, 15, 22)]
        }
    }
}

/// 美化衬底卡片输出画幅比例（适配 PPT / 文档 / 社媒封面卡片）
public enum BackdropAspectRatio: String, CaseIterable, Codable, Sendable {
    case auto
    case ratio16x9
    case ratio4x3
    case ratio1x1

    public var title: String {
        switch self {
        case .auto:      return "自动"
        case .ratio16x9: return "16:9"
        case .ratio4x3:  return "4:3"
        case .ratio1x1:  return "1:1"
        }
    }

    public var numericRatio: CGFloat? {
        switch self {
        case .auto:      return nil
        case .ratio16x9: return 16.0 / 9.0
        case .ratio4x3:  return 4.0 / 3.0
        case .ratio1x1:  return 1.0
        }
    }
}

/// 纯 CoreGraphics 高清卡片美化合成器（支持渐变留白、16:9 / 4:3 / 1:1 比例画幅与轻水印）
public enum BackdropBeautifier {
    /// 计算给定逻辑尺寸截图对应的均衡留白边距（单位：逻辑 pt）
    public static func paddingPoints(forLogicalSize size: CGSize) -> CGFloat {
        round(min(68.0, max(32.0, min(size.width, size.height) * 0.12)))
    }

    /// 为已烘焙好标注的原分辨率截图套上渐变衬底、圆角裁切、画幅比例扩展、立体悬浮阴影与可选轻水印
    public static func apply(
        to cardImage: CGImage,
        style: BackdropStyle,
        imageScale: CGFloat,
        innerCornerRadiusPt: CGFloat = 0,
        aspectRatio: BackdropAspectRatio = .auto,
        watermarkText: String = ""
    ) -> CGImage? {
        guard style != .none else { return cardImage }
        let stops = style.gradientStops
        guard stops.count >= 2 else { return cardImage }

        let scale = max(1.0, imageScale)
        let logicalSize = CGSize(width: CGFloat(cardImage.width) / scale, height: CGFloat(cardImage.height) / scale)
        let padPx = max(16, Int((paddingPoints(forLogicalSize: logicalSize) * scale).rounded()))
        var canvasW = cardImage.width + padPx * 2
        var canvasH = cardImage.height + padPx * 2

        if let targetRatio = aspectRatio.numericRatio {
            let curRatio = CGFloat(canvasW) / max(1, CGFloat(canvasH))
            if curRatio < targetRatio {
                canvasW = Int((CGFloat(canvasH) * targetRatio).rounded())
            } else if curRatio > targetRatio {
                canvasH = Int((CGFloat(canvasW) / targetRatio).rounded())
            }
        }

        let cs: CGColorSpace = (cardImage.colorSpace?.model == .rgb && cardImage.colorSpace?.supportsOutput == true)
            ? cardImage.colorSpace!
            : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
        guard let ctx = CGContext(
            data: nil, width: canvasW, height: canvasH, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return cardImage }

        // 1) 对角线性渐变衬底（左上 → 右下）
        let cgColors = stops.map(\.cgColor) as CFArray
        let locations: [CGFloat] = stops.enumerated().map { CGFloat($0.offset) / CGFloat(max(1, stops.count - 1)) }
        if let gradient = CGGradient(colorsSpace: cs, colors: cgColors, locations: locations) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: CGFloat(canvasH)),
                end: CGPoint(x: CGFloat(canvasW), y: 0),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }

        let cardX = (canvasW - cardImage.width) / 2
        let cardY = (canvasH - cardImage.height) / 2
        let cardRect = CGRect(x: cardX, y: cardY, width: cardImage.width, height: cardImage.height)
        let effectiveCornerPt = innerCornerRadiusPt > 0.5 ? innerCornerRadiusPt : 12.0
        let rPx = min(effectiveCornerPt * scale, CGFloat(min(cardImage.width, cardImage.height)) * 0.5)
        let cardPath = CGPath(roundedRect: cardRect, cornerWidth: rPx, cornerHeight: rPx, transform: nil)

        // 2) 双层柔和窗口级悬浮阴影
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -10.0 * scale),
            blur: 28.0 * scale,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.36)
        )
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1.0))
        ctx.addPath(cardPath); ctx.fillPath()
        ctx.restoreGState()

        // 3) 圆角裁切并正立绘制内容卡片
        ctx.saveGState()
        ctx.addPath(cardPath); ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(cardImage, in: cardRect)
        ctx.restoreGState()

        // 4) 细微高光玻璃描边
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.24))
        ctx.setLineWidth(max(1.0, 0.85 * scale))
        ctx.addPath(cardPath); ctx.strokePath()
        ctx.restoreGState()

        // 5) 可选右下角轻量文字水印
        let wm = watermarkText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !wm.isEmpty {
            drawWatermark(wm, in: ctx, canvasW: CGFloat(canvasW), scale: scale, lightBg: style.isLightBackdrop)
        }
        return ctx.makeImage() ?? cardImage
    }

    private static func drawWatermark(_ text: String, in ctx: CGContext, canvasW: CGFloat, scale: CGFloat, lightBg: Bool) {
        let fontPt = max(11.0, 11.5 * scale)
        let fgColor = lightBg
            ? CGColor(srgbRed: 0.12, green: 0.16, blue: 0.24, alpha: 0.56)
            : CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.68)
        let fgKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontPt, weight: .semibold),
            fgKey: fgColor
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        var asc: CGFloat = 0, desc: CGFloat = 0
        let lw = CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, nil))
        let marginX = max(14.0, 14.0 * scale)
        let marginY = max(10.0, 10.0 * scale)
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: max(marginX, canvasW - lw - marginX), y: marginY + desc)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// 为独立窗口截图套上原生 macOS 风格透明悬浮柔和阴影（四周全透明 Alpha 通道，无桌面杂物）
    public static func applyTransparentWindowShadow(to windowImage: CGImage, imageScale: CGFloat) -> CGImage? {
        let scale = max(1.0, imageScale)
        let padSidePx = max(20, Int((34.0 * scale).rounded()))
        let padTopPx = max(16, Int((24.0 * scale).rounded()))
        let padBottomPx = max(24, Int((44.0 * scale).rounded()))
        let canvasW = windowImage.width + padSidePx * 2
        let canvasH = windowImage.height + padTopPx + padBottomPx

        let cs: CGColorSpace = (windowImage.colorSpace?.model == .rgb && windowImage.colorSpace?.supportsOutput == true)
            ? windowImage.colorSpace!
            : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
        guard let ctx = CGContext(
            data: nil, width: canvasW, height: canvasH, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return windowImage }

        ctx.clear(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
        let winRect = CGRect(x: padSidePx, y: padBottomPx, width: windowImage.width, height: windowImage.height)
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -10.0 * scale),
            blur: 26.0 * scale,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.36)
        )
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.interpolationQuality = .high
        ctx.draw(windowImage, in: winRect)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        return ctx.makeImage() ?? windowImage
    }
}
