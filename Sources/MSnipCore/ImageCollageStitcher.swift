import CoreGraphics
import CoreText
import Foundation

/// 多图拼接排列方向（兼容既有菜单快捷入口）
public enum CollageDirection: String, CaseIterable, Sendable {
    case horizontal, vertical
}

/// 拼图工作室布局模式：横向并排 / 纵向长拼 / 自适应网格
public enum CollageLayoutMode: String, CaseIterable, Codable, Sendable {
    case horizontal, vertical, grid
    public var title: String {
        switch self { case .horizontal: return L("横向并排"); case .vertical: return L("纵向长拼"); case .grid: return L("网格拼图") }
    }
}

/// 拼图画布底色预设
public enum CollageBackgroundStyle: String, CaseIterable, Codable, Sendable {
    case lightGray, white, dark, gradient, transparent
    public var title: String {
        switch self {
        case .lightGray: return L("柔灰"); case .white: return L("纯白"); case .dark: return L("深炭")
        case .gradient: return L("极光渐变"); case .transparent: return L("透明")
        }
    }
    public var rgbaColor: RGBAColor? {
        switch self {
        case .lightGray: return RGBAColor(244, 246, 250)
        case .white:     return RGBAColor(255, 255, 255)
        case .dark:      return RGBAColor(24, 26, 32)
        case .gradient, .transparent: return nil
        }
    }
    public var isDarkVisual: Bool { self == .dark || self == .gradient }
}

/// 拼图工作室实时渲染与高清导出配置
public struct CollageOptions: Equatable, Codable, Sendable {
    public var layout: CollageLayoutMode
    public var gridColumns: Int
    public var gapPx: Int
    public var padPx: Int
    public var cornerRadiusPx: CGFloat
    public var background: CollageBackgroundStyle
    public var customBackgroundColor: RGBAColor?
    public var gradientPreset: CollageGradientPreset
    public var scaleAlignment: CollageScaleAlignment
    public var aspectPreset: CollageAspectPreset
    public var cardShadow: Bool
    public var badge: CollageBadgeStyle
    public var watermark: CollageWatermarkStyle
    public var watermarkText: String
    public var pdfPageNumber: CollagePDFPageNumberStyle

    public var effectiveSolidColor: RGBAColor? {
        (background == .transparent || background == .gradient) ? nil : (customBackgroundColor ?? background.rgbaColor)
    }

    public var effectiveIsDarkBackground: Bool {
        switch background {
        case .transparent: return false
        case .gradient:    return gradientPreset.isDarkVisual
        default:           return (effectiveSolidColor?.relativeLuminance ?? 1.0) < 0.42
        }
    }

    public init(
        layout: CollageLayoutMode = .horizontal, gridColumns: Int = 2,
        gapPx: Int = 24, padPx: Int = 32, cornerRadiusPx: CGFloat = 14,
        background: CollageBackgroundStyle = .lightGray, customBackgroundColor: RGBAColor? = nil,
        gradientPreset: CollageGradientPreset = .aurora, scaleAlignment: CollageScaleAlignment = .uniformFill,
        aspectPreset: CollageAspectPreset = .auto, cardShadow: Bool = true, badge: CollageBadgeStyle = .none,
        watermark: CollageWatermarkStyle = .none, watermarkText: String = "", pdfPageNumber: CollagePDFPageNumberStyle = .chinese
    ) {
        self.layout = layout; self.gridColumns = min(4, max(2, gridColumns))
        self.gapPx = min(120, max(0, gapPx)); self.padPx = min(160, max(0, padPx))
        self.cornerRadiusPx = min(64, max(0, cornerRadiusPx))
        self.background = background; self.customBackgroundColor = customBackgroundColor; self.gradientPreset = gradientPreset
        self.scaleAlignment = scaleAlignment; self.aspectPreset = aspectPreset; self.cardShadow = cardShadow
        self.badge = badge; self.watermark = watermark; self.watermarkText = watermarkText; self.pdfPageNumber = pdfPageNumber
    }
}

/// 纯 CoreGraphics 高清多图对比拼接与多页 PDF 合并器
public enum ImageCollageStitcher {
    public static func stitch(
        images: [CGImage],
        direction: CollageDirection,
        gapPx: Int = 24,
        padPx: Int = 32,
        cornerRadiusPx: CGFloat = 14,
        background: RGBAColor = RGBAColor(244, 246, 250)
    ) -> CGImage? {
        let valid = images.filter { $0.width >= 4 && $0.height >= 4 }
        guard valid.count >= 2 else { return valid.first }
        let opts = CollageOptions(
            layout: direction == .horizontal ? .horizontal : .vertical,
            gapPx: gapPx, padPx: padPx, cornerRadiusPx: cornerRadiusPx,
            background: .lightGray, customBackgroundColor: background
        )
        return stitch(images: valid, options: opts, maxRefSide: 2400)
    }

    public static func stitch(images: [CGImage], options: CollageOptions, maxRefSide: Int = 2400) -> CGImage? {
        let valid = images.filter { $0.width >= 4 && $0.height >= 4 }
        guard !valid.isEmpty else { return nil }
        return stitchCore(images: valid, options: options, maxRefSide: max(120, maxRefSide))
    }

    /// 零像素分配快速估算最终导出尺寸（供工作室顶栏准确展示实际导出像素，而非预览缩放尺寸）
    public static func estimatedCanvasSize(images: [CGImage], options: CollageOptions, maxRefSide: Int = 2400) -> (width: Int, height: Int)? {
        let valid = images.filter { $0.width >= 4 && $0.height >= 4 }
        guard !valid.isEmpty else { return nil }
        let p = computePlacements(valid: valid, options: options, maxRefSide: max(120, maxRefSide))
        return (p.canvasW, p.canvasH)
    }

    @discardableResult
    public static func exportMultiPagePDF(
        images: [CGImage],
        padPx: Int = 24,
        background: CollageBackgroundStyle = .white,
        customBackgroundColor: RGBAColor? = nil,
        gradientPreset: CollageGradientPreset = .aurora,
        watermark: CollageWatermarkStyle = .none,
        watermarkText: String = "",
        pageNumber: CollagePDFPageNumberStyle = .none,
        to url: URL
    ) -> Bool {
        let valid = images.filter { $0.width >= 4 && $0.height >= 4 }
        guard !valid.isEmpty else { return false }
        var initialBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let pdf = CGContext(url as CFURL, mediaBox: &initialBox, nil) else { return false }

        let padPt = CGFloat(max(0, padPx)) * 0.5
        let footerExtra: CGFloat = (pageNumber == .none) ? 0 : max(0, 18 - padPt)
        let effectiveBg: CollageBackgroundStyle = (background == .transparent) ? .white : background
        let isDark: Bool = (effectiveBg == .gradient)
            ? gradientPreset.isDarkVisual
            : ((customBackgroundColor ?? effectiveBg.rgbaColor)?.relativeLuminance ?? 1.0) < 0.42

        // 统一按中位页宽归一化各页视觉宽度（595..1120pt），彻底消除 1x/2x/手机原图混排时 PDF 页宽忽大忽小
        let sortedRawW = valid.map { CGFloat($0.width) * 0.5 }.sorted()
        let uniformImgW = min(1120.0, max(595.0, sortedRawW[sortedRawW.count / 2]))
        for (idx, img) in valid.enumerated() {
            let imgW = valid.count > 1 ? uniformImgW : min(1200.0, max(320.0, CGFloat(img.width) * 0.5))
            let drawH = max(1.0, round(imgW * CGFloat(img.height) / max(1.0, CGFloat(img.width))))
            let pageContentH = max(120.0, drawH)
            let drawY = padPt + footerExtra + round((pageContentH - drawH) * 0.5)
            var pageBox = CGRect(x: 0, y: 0, width: imgW + padPt * 2, height: pageContentH + padPt * 2 + footerExtra)
            let boxData = Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size) as CFData
            pdf.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            CollageOverlaysRenderer.drawBackground(style: effectiveBg, customColor: customBackgroundColor, gradientPreset: gradientPreset, in: pageBox, ctx: pdf)
            pdf.interpolationQuality = .high
            pdf.draw(img, in: CGRect(x: padPt, y: drawY, width: imgW, height: drawH))
            CollageOverlaysRenderer.drawPDFPageNumber(index: idx, total: valid.count, style: pageNumber, pageRect: pageBox, isDarkBg: isDark, ctx: pdf)
            CollageOverlaysRenderer.drawWatermark(text: watermarkText, style: watermark, canvasRect: pageBox, isDarkBg: isDark, ctx: pdf)
            pdf.endPDFPage()
        }
        pdf.closePDF()
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func stitchCore(images valid: [CGImage], options: CollageOptions, maxRefSide: Int) -> CGImage? {
        let placements = computePlacements(valid: valid, options: options, maxRefSide: maxRefSide)
        let canvasW = placements.canvasW, canvasH = placements.canvasH
        guard canvasW > 0, canvasH > 0, canvasW <= 20_000, canvasH <= 24_000 else { return nil }

        let cs: CGColorSpace = (valid[0].colorSpace?.model == .rgb && valid[0].colorSpace?.supportsOutput == true)
            ? valid[0].colorSpace! : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
        guard let ctx = CGContext(
            data: nil, width: canvasW, height: canvasH, bitsPerComponent: 8, bytesPerRow: canvasW * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let canvasRect = CGRect(x: 0, y: 0, width: canvasW, height: canvasH)
        CollageOverlaysRenderer.drawBackground(style: options.background, customColor: options.customBackgroundColor, gradientPreset: options.gradientPreset, in: canvasRect, ctx: ctx)

        let isDarkBg = options.effectiveIsDarkBackground
        let hasOpaqueBg = (options.background != .transparent)
        for (idx, img) in valid.enumerated() {
            let td = placements.rectsTopDown[idx]
            let cell = CGRect(x: td.minX, y: CGFloat(canvasH) - td.maxY, width: td.width, height: td.height)
            let drawBox: CGRect
            if options.layout == .grid && options.scaleAlignment != .uniformFill {
                let sc = min(cell.width / CGFloat(img.width), cell.height / CGFloat(img.height))
                let dw = round(CGFloat(img.width) * sc), dh = round(CGFloat(img.height) * sc)
                let dy = (options.scaleAlignment == .originalCenter) ? round((cell.height - dh) * 0.5) : (cell.height - dh)
                drawBox = CGRect(x: round(cell.midX - dw * 0.5), y: cell.minY + dy, width: dw, height: dh)
            } else {
                drawBox = cell
            }

            let r = min(options.cornerRadiusPx, min(drawBox.width, drawBox.height) * 0.25)
            let path = CGPath(roundedRect: drawBox, cornerWidth: r, cornerHeight: r, transform: nil)
            if hasOpaqueBg && options.cardShadow {
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 16, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: isDarkBg ? 0.36 : 0.14))
                ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                ctx.addPath(path); ctx.fillPath()
                ctx.restoreGState()
            }

            ctx.saveGState()
            ctx.addPath(path); ctx.clip(); ctx.interpolationQuality = .high
            if options.layout == .grid && options.scaleAlignment == .uniformFill {
                let sc = max(drawBox.width / CGFloat(img.width), drawBox.height / CGFloat(img.height))
                let dw = CGFloat(img.width) * sc, dh = CGFloat(img.height) * sc
                ctx.draw(img, in: CGRect(x: drawBox.midX - dw * 0.5, y: drawBox.midY - dh * 0.5, width: dw, height: dh))
            } else {
                ctx.draw(img, in: drawBox)
            }
            ctx.restoreGState()

            ctx.saveGState()
            ctx.setStrokeColor(CGColor(srgbRed: isDarkBg ? 1 : 0, green: isDarkBg ? 1 : 0, blue: isDarkBg ? 1 : 0, alpha: isDarkBg ? 0.16 : 0.08))
            ctx.setLineWidth(1.0); ctx.addPath(path); ctx.strokePath()
            ctx.restoreGState()
            CollageOverlaysRenderer.drawCardBadge(index: idx, total: valid.count, style: options.badge, cardRect: drawBox, ctx: ctx)
        }

        CollageOverlaysRenderer.drawWatermark(text: options.watermarkText, style: options.watermark, canvasRect: canvasRect, isDarkBg: isDarkBg, ctx: ctx)
        return ctx.makeImage()
    }

    private static func computePlacements(valid: [CGImage], options: CollageOptions, maxRefSide: Int) -> (canvasW: Int, canvasH: Int, rectsTopDown: [CGRect]) {
        let gap = max(0, options.gapPx), pad = max(0, options.padPx), align = options.scaleAlignment
        let maxRawDim = max(1, valid.map { max($0.width, $0.height) }.max() ?? 1)
        let capS = min(1.0, Double(maxRefSide) / Double(maxRawDim))
        var rawW: Int, rawH: Int, rects: [CGRect] = []

        switch options.layout {
        case .horizontal:
            if align == .uniformFill {
                let refH = min(maxRefSide, max(64, valid.map(\.height).sorted()[valid.count / 2]))
                var curX = pad
                for img in valid {
                    let w = max(16, Int((Double(img.width) * Double(refH) / Double(img.height)).rounded()))
                    rects.append(CGRect(x: curX, y: pad, width: w, height: refH)); curX += w + gap
                }
                rawW = curX - gap + pad; rawH = pad * 2 + refH
            } else {
                let sizes = valid.map { (w: max(16, Int((Double($0.width) * capS).rounded())), h: max(16, Int((Double($0.height) * capS).rounded()))) }
                let rowH = sizes.map(\.h).max() ?? 64
                var curX = pad
                for sz in sizes {
                    let y = pad + (align == .originalCenter ? (rowH - sz.h) / 2 : 0)
                    rects.append(CGRect(x: curX, y: y, width: sz.w, height: sz.h)); curX += sz.w + gap
                }
                rawW = curX - gap + pad; rawH = pad * 2 + rowH
            }
        case .vertical:
            if align == .uniformFill {
                let refW = min(maxRefSide, max(64, valid.map(\.width).sorted()[valid.count / 2]))
                var curY = pad
                for img in valid {
                    let h = max(16, Int((Double(img.height) * Double(refW) / Double(img.width)).rounded()))
                    rects.append(CGRect(x: pad, y: curY, width: refW, height: h)); curY += h + gap
                }
                rawW = pad * 2 + refW; rawH = curY - gap + pad
            } else {
                let sizes = valid.map { (w: max(16, Int((Double($0.width) * capS).rounded())), h: max(16, Int((Double($0.height) * capS).rounded()))) }
                let colW = sizes.map(\.w).max() ?? 64
                var curY = pad
                for sz in sizes {
                    let x = pad + (align == .originalCenter ? (colW - sz.w) / 2 : 0)
                    rects.append(CGRect(x: x, y: curY, width: sz.w, height: sz.h)); curY += sz.h + gap
                }
                rawW = pad * 2 + colW; rawH = curY - gap + pad
            }
        case .grid:
            let cols = min(max(1, valid.count), min(4, max(2, options.gridColumns)))
            let rows = (valid.count + cols - 1) / cols
            let cellW = min(maxRefSide / max(1, cols), max(120, valid.map(\.width).sorted()[valid.count / 2]))
            let medRatio = min(1.8, max(0.45, valid.map { Double($0.height) / Double(max(1, $0.width)) }.sorted()[valid.count / 2]))
            let cellH = max(80, Int((Double(cellW) * medRatio).rounded()))
            rects = (0..<valid.count).map { CGRect(x: pad + ($0 % cols) * (cellW + gap), y: pad + ($0 / cols) * (cellH + gap), width: cellW, height: cellH) }
            rawW = pad * 2 + cols * cellW + (cols - 1) * gap; rawH = pad * 2 + rows * cellH + (rows - 1) * gap
        }

        if let ratio = options.aspectPreset.targetRatio, rawW > 0, rawH > 0 {
            let cur = Double(rawW) / Double(rawH)
            if cur > ratio + 0.01 {
                let targetH = min(24_000, max(rawH, Int((Double(rawW) / ratio).rounded())))
                let dy = CGFloat(targetH - rawH) * 0.5
                rects = rects.map { $0.offsetBy(dx: 0, dy: round(dy)) }
                rawH = targetH
            } else if cur < ratio - 0.01 {
                let targetW = min(20_000, max(rawW, Int((Double(rawH) * ratio).rounded())))
                let dx = CGFloat(targetW - rawW) * 0.5
                rects = rects.map { $0.offsetBy(dx: round(dx), dy: 0) }
                rawW = targetW
            }
        }
        return (rawW, rawH, rects)
    }
}

// MARK: - 拼图序号徽章、水印与圆角合成

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
        case .chinese:  return L("第 %@ 页", index + 1)
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
        case .aurora:   return L("极光渐变")
        case .sunset:   return L("落日珊瑚")
        case .mint:     return L("薄荷青空")
        case .dawn:     return L("破晓微光")
        case .obsidian: return L("暗曜深空")
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
