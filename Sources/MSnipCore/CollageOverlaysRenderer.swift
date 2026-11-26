import CoreGraphics
import CoreText
import Foundation

/// 拼图多图尺寸缩放与对齐策略
public enum CollageScaleAlignment: Int, CaseIterable, Codable, Sendable {
    case uniformFill = 0    // 等比齐平（横向等高 / 纵向等宽 / 网格铺满）
    case originalCenter = 1 // 原寸居中（保留原始比例不强拉小图，居中对齐）
    case originalStart = 2  // 原寸顶齐（保留原始比例，横向顶对齐 / 纵向左对齐）
}

/// 拼图输出画幅比例预设
public enum CollageAspectPreset: Int, CaseIterable, Codable, Sendable {
    case auto = 0       // 自适应紧包
    case widescreen = 1 // 16:9 演示/封面
    case standard = 2   // 4:3 文档/卡片
    case square = 3     // 1:1 正方形

    public var targetRatio: Double? {
        switch self {
        case .auto:       return nil
        case .widescreen: return 16.0 / 9.0
        case .standard:   return 4.0 / 3.0
        case .square:     return 1.0
        }
    }
}

/// 拼图每张卡片左上角标签模式（步骤序号 / Before-After 对比）
public enum CollageBadgeStyle: Int, CaseIterable, Codable, Sendable {
    case none = 0, numbered = 1, beforeAfter = 2
}

/// 拼图与多页 PDF 水印模式（关闭 / 右下角微标 / 全图防盗斜向平铺）
public enum CollageWatermarkStyle: Int, CaseIterable, Codable, Sendable {
    case none = 0, corner = 1, tiled = 2
}

/// 多页 PDF 底部矢量页码样式
public enum CollagePDFPageNumberStyle: Int, CaseIterable, Codable, Sendable {
    case none = 0, fraction = 1, chinese = 2

    public func label(index: Int, total: Int) -> String? {
        switch self {
        case .none:     return nil
        case .fraction: return "\(index + 1) / \(total)"
        case .chinese:  return "第 \(index + 1) 页"
        }
    }
}

/// 拼图与多页 PDF 的 5 款精选工作室渐变衬底
public enum CollageGradientPreset: Int, CaseIterable, Codable, Sendable {
    case aurora = 0
    case sunset = 1
    case mint = 2
    case dawn = 3
    case obsidian = 4

    public var title: String {
        switch self {
        case .aurora:   return "极光渐变"
        case .sunset:   return "落日珊瑚"
        case .mint:     return "薄荷青空"
        case .dawn:     return "破晓微光"
        case .obsidian: return "暗曜深空"
        }
    }

    public var isDarkVisual: Bool {
        self != .dawn
    }

    public var srgbStops: [(CGFloat, CGFloat, CGFloat)] {
        switch self {
        case .aurora:
            return [(0.34, 0.33, 0.88), (0.16, 0.62, 0.94), (0.60, 0.45, 0.95)]
        case .sunset:
            return [(0.95, 0.36, 0.46), (0.98, 0.54, 0.32), (0.96, 0.74, 0.34)]
        case .mint:
            return [(0.06, 0.66, 0.56), (0.10, 0.64, 0.84), (0.28, 0.46, 0.92)]
        case .dawn:
            return [(0.98, 0.88, 0.86), (0.89, 0.87, 0.98), (0.84, 0.93, 0.99)]
        case .obsidian:
            return [(0.08, 0.10, 0.15), (0.13, 0.19, 0.30), (0.18, 0.15, 0.28)]
        }
    }
}

/// 拼图与多页 PDF 的纯 CoreGraphics + CoreText 特效绘制器（纯色/任意自定义色/多款渐变、步骤/对比角标、防盗水印、PDF 矢量页码）
public enum CollageOverlaysRenderer {
    /// 绘制画布或 PDF 单页背景（支持透明、任意自定义 `RGBAColor` 与 5 款渐变衬底）
    public static func drawBackground(
        style: CollageBackgroundStyle,
        customColor: RGBAColor? = nil,
        gradientPreset: CollageGradientPreset = .aurora,
        in rect: CGRect,
        ctx: CGContext
    ) {
        switch style {
        case .transparent:
            return
        case .gradient:
            drawGradient(gradientPreset, in: rect, ctx: ctx, topLeftToBottomRightInBottomUpCG: true)
        default:
            if let rgba = customColor ?? style.rgbaColor {
                ctx.setFillColor(rgba.cgColor)
                ctx.fill(rect)
            }
        }
    }

    public static func drawGradient(
        _ preset: CollageGradientPreset,
        in rect: CGRect,
        ctx: CGContext,
        topLeftToBottomRightInBottomUpCG: Bool
    ) {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let cgColors = preset.srgbStops.map { CGColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1.0) }
        let locs: [CGFloat] = [0.0, 0.52, 1.0]
        guard let grad = CGGradient(colorsSpace: cs, colors: cgColors as CFArray, locations: locs) else { return }
        ctx.saveGState()
        ctx.clip(to: rect)
        let start = topLeftToBottomRightInBottomUpCG ? CGPoint(x: rect.minX, y: rect.maxY) : CGPoint(x: rect.minX, y: rect.minY)
        let end   = topLeftToBottomRightInBottomUpCG ? CGPoint(x: rect.maxX, y: rect.minY) : CGPoint(x: rect.maxX, y: rect.maxY)
        ctx.drawLinearGradient(grad, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    /// 在单张拼接图左上角绘制序号或对比标签（CoreGraphics 左下角坐标系）
    static func drawCardBadge(index: Int, total: Int, style: CollageBadgeStyle, cardRect: CGRect, ctx: CGContext) {
        guard style != .none else { return }
        let label: String
        let isAccentPill: Bool
        switch style {
        case .none: return
        case .numbered:
            label = "\(index + 1)"; isAccentPill = true
        case .beforeAfter:
            if index == 0 { label = "Before"; isAccentPill = false }
            else if index == total - 1 { label = "After"; isAccentPill = true }
            else { label = "\(index + 1)"; isAccentPill = false }
        }

        let shortSide = min(cardRect.width, cardRect.height)
        let fontSize = min(22, max(10, round(shortSide * 0.055)))
        let line = makeCTLine(label, fontSize: fontSize, bold: true, color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.98))
        var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
        let tw = CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, &lead))
        let padX = style == .numbered ? max(8, fontSize * 0.55) : max(10, fontSize * 0.68)
        let pillH = max(20, round(asc + desc + fontSize * 0.58))
        let pillW = max(pillH, round(tw + padX * 2))
        let margin = max(8, round(shortSide * 0.032))
        let pill = CGRect(x: cardRect.minX + margin, y: cardRect.maxY - margin - pillH, width: pillW, height: pillH)
        let path = CGPath(roundedRect: pill, cornerWidth: pillH * 0.5, cornerHeight: pillH * 0.5, transform: nil)

        ctx.saveGState()
        let fill = isAccentPill
            ? CGColor(srgbRed: 0.08, green: 0.46, blue: 0.96, alpha: 0.90)
            : CGColor(srgbRed: 0.08, green: 0.10, blue: 0.14, alpha: 0.80)
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28))
        ctx.setFillColor(fill); ctx.addPath(path); ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28))
        ctx.setLineWidth(1.0); ctx.addPath(path); ctx.strokePath()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: pill.midX - tw * 0.5, y: pill.midY - (asc - desc) * 0.5)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// 绘制自定义水印（角标模式：右下角双层对比微标；平铺模式：全图 -24° 防盗斜纹水印）
    static func drawWatermark(text rawText: String, style: CollageWatermarkStyle, canvasRect: CGRect, isDarkBg: Bool, ctx: CGContext) {
        guard style != .none else { return }
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = trimmed.isEmpty ? "MSnip" : trimmed
        let ref = min(canvasRect.width, canvasRect.height)

        switch style {
        case .none: return
        case .corner:
            let fontSize = min(24, max(10, round(ref * 0.030)))
            let line = makeCTLine(text, fontSize: fontSize, bold: true, color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92))
            var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
            let tw = CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, &lead))
            let padX = max(9, round(fontSize * 0.6))
            let pillH = max(20, round(asc + desc + fontSize * 0.52)), pillW = round(tw + padX * 2)
            let margin = max(10, round(ref * 0.028))
            let pill = CGRect(x: canvasRect.maxX - margin - pillW, y: canvasRect.minY + margin, width: pillW, height: pillH)
            let path = CGPath(roundedRect: pill, cornerWidth: pillH * 0.48, cornerHeight: pillH * 0.48, transform: nil)
            ctx.saveGState()
            ctx.setFillColor(CGColor(srgbRed: 0.06, green: 0.08, blue: 0.12, alpha: isDarkBg ? 0.58 : 0.48))
            ctx.addPath(path); ctx.fillPath()
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22))
            ctx.setLineWidth(0.8); ctx.addPath(path); ctx.strokePath()
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: pill.midX - tw * 0.5, y: pill.midY - (asc - desc) * 0.5)
            CTLineDraw(line, ctx)
            ctx.restoreGState()

        case .tiled:
            let fontSize = min(28, max(12, round(ref * 0.042)))
            let fg = isDarkBg
                ? CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.19)
                : CGColor(srgbRed: 0.10, green: 0.12, blue: 0.18, alpha: 0.16)
            let line = makeCTLine(text, fontSize: fontSize, bold: true, color: fg)
            var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
            let tw = max(32, CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, &lead)))
            let stepX = max(tw + fontSize * 3.0, fontSize * 7.5), stepY = max(fontSize * 4.4, 72)
            let diag = hypot(canvasRect.width, canvasRect.height)
            ctx.saveGState()
            ctx.clip(to: canvasRect)
            ctx.translateBy(x: canvasRect.midX, y: canvasRect.midY)
            ctx.rotate(by: -24.0 * .pi / 180.0)
            ctx.textMatrix = .identity
            var row = 0, y = -diag * 0.65
            while y <= diag * 0.65 {
                var x = -diag * 0.65 + (row % 2 == 0 ? 0 : stepX * 0.5)
                while x <= diag * 0.65 {
                    ctx.textPosition = CGPoint(x: x, y: y); CTLineDraw(line, ctx); x += stepX
                }
                y += stepY; row += 1
            }
            ctx.restoreGState()
        }
    }

    static func drawPDFPageNumber(index: Int, total: Int, style: CollagePDFPageNumberStyle, pageRect: CGRect, isDarkBg: Bool, ctx: CGContext) {
        guard let label = style.label(index: index, total: total) else { return }
        let fontSize = min(13, max(9.5, round(min(pageRect.width, pageRect.height) * 0.018)))
        let fg = isDarkBg
            ? CGColor(srgbRed: 0.92, green: 0.94, blue: 0.98, alpha: 0.78)
            : CGColor(srgbRed: 0.24, green: 0.28, blue: 0.36, alpha: 0.76)
        let line = makeCTLine(label, fontSize: fontSize, bold: false, color: fg)
        var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
        let tw = CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, &lead))
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: pageRect.midX - tw * 0.5, y: pageRect.minY + max(5, fontSize * 0.55))
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func makeCTLine(_ text: String, fontSize: CGFloat, bold: Bool, color: CGColor) -> CTLine {
        let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, fontSize, nil)
            ?? CTFontCreateWithName("HelveticaNeue" as CFString, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }
}
