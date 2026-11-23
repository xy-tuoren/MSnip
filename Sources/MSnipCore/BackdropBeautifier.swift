import CoreGraphics
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

    /// 供渐变画布与覆盖层预览边框使用的起止色组
    public var gradientStops: [RGBAColor] {
        switch self {
        case .none:
            return []
        case .oceanAurora:
            return [RGBAColor(67, 56, 202), RGBAColor(126, 34, 206), RGBAColor(14, 165, 233)]
        case .warmSunset:
            return [RGBAColor(244, 63, 94), RGBAColor(249, 115, 22), RGBAColor(251, 191, 36)]
        case .emeraldMist:
            return [RGBAColor(13, 148, 136), RGBAColor(16, 185, 129), RGBAColor(110, 231, 183)]
        case .cleanStudio:
            return [RGBAColor(236, 240, 246), RGBAColor(214, 222, 235), RGBAColor(201, 211, 227)]
        case .noirCarbon:
            return [RGBAColor(34, 39, 52), RGBAColor(20, 23, 32), RGBAColor(13, 15, 22)]
        }
    }
}

/// 纯 CoreGraphics 高清卡片美化合成器
public enum BackdropBeautifier {
    /// 计算给定逻辑尺寸截图对应的均衡留白边距（单位：逻辑 pt）
    public static func paddingPoints(forLogicalSize size: CGSize) -> CGFloat {
        round(min(68.0, max(32.0, min(size.width, size.height) * 0.12)))
    }

    /// 为已烘焙好标注的原分辨率截图套上渐变衬底、圆角裁切、立体悬浮阴影与高光内描边
    public static func apply(
        to cardImage: CGImage,
        style: BackdropStyle,
        imageScale: CGFloat,
        innerCornerRadiusPt: CGFloat = 0
    ) -> CGImage? {
        guard style != .none else { return cardImage }
        let stops = style.gradientStops
        guard stops.count >= 2 else { return cardImage }

        let scale = max(1.0, imageScale)
        let logicalSize = CGSize(
            width: CGFloat(cardImage.width) / scale,
            height: CGFloat(cardImage.height) / scale
        )
        let padPt = paddingPoints(forLogicalSize: logicalSize)
        let padPx = max(16, Int((padPt * scale).rounded()))
        let canvasW = cardImage.width + padPx * 2
        let canvasH = cardImage.height + padPx * 2

        let cs: CGColorSpace = (cardImage.colorSpace?.model == .rgb && cardImage.colorSpace?.supportsOutput == true)
            ? cardImage.colorSpace!
            : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
        guard let ctx = CGContext(
            data: nil,
            width: canvasW,
            height: canvasH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return cardImage }

        // 1) 绘制平滑对角线性渐变衬底（左上 → 右下）
        let cgColors = stops.map(\.cgColor) as CFArray
        let locations: [CGFloat] = stops.enumerated().map { idx, _ in
            CGFloat(idx) / CGFloat(max(1, stops.count - 1))
        }
        if let gradient = CGGradient(colorsSpace: cs, colors: cgColors, locations: locations) {
            ctx.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: CGFloat(canvasH)),
                end: CGPoint(x: CGFloat(canvasW), y: 0),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }

        let cardRect = CGRect(x: padPx, y: padPx, width: cardImage.width, height: cardImage.height)
        let effectiveCornerPt = innerCornerRadiusPt > 0.5 ? innerCornerRadiusPt : 12.0
        let rPx = min(effectiveCornerPt * scale, CGFloat(min(cardImage.width, cardImage.height)) * 0.5)
        let cardPath = CGPath(roundedRect: cardRect, cornerWidth: rPx, cornerHeight: rPx, transform: nil)

        // 2) 绘制双层柔和窗口级悬浮阴影
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -10.0 * scale),
            blur: 28.0 * scale,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.36)
        )
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1.0))
        ctx.addPath(cardPath)
        ctx.fillPath()
        ctx.restoreGState()

        // 3) 圆角裁切并正立绘制内容卡片
        ctx.saveGState()
        ctx.addPath(cardPath)
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(cardImage, in: cardRect)
        ctx.restoreGState()

        // 4) 细微高光玻璃描边，令暗色窗口在深色衬底上层次分明
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.24))
        ctx.setLineWidth(max(1.0, 0.85 * scale))
        ctx.addPath(cardPath)
        ctx.strokePath()
        ctx.restoreGState()

        return ctx.makeImage() ?? cardImage
    }

    /// 为独立窗口截图套上原生 macOS 风格透明悬浮柔和阴影（四周全透明 Alpha 通道，无桌面杂物）
    public static func applyTransparentWindowShadow(
        to windowImage: CGImage,
        imageScale: CGFloat
    ) -> CGImage? {
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
            data: nil,
            width: canvasW,
            height: canvasH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return windowImage }

        ctx.clear(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
        let winRect = CGRect(
            x: padSidePx,
            y: padBottomPx,
            width: windowImage.width,
            height: windowImage.height
        )

        // 基于窗口自身 Alpha 轮廓投射柔和环境阴影，完美贴合圆角窗口与悬浮面板
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
