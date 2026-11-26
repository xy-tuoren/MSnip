import CoreGraphics
import Foundation

/// 多图拼接排列方向（兼容既有菜单快捷入口）
public enum CollageDirection: String, CaseIterable, Sendable {
    case horizontal, vertical
}

/// 拼图工作室布局模式：横向并排 / 纵向长拼 / 自适应网格
public enum CollageLayoutMode: String, CaseIterable, Codable, Sendable {
    case horizontal, vertical, grid
    public var title: String {
        switch self { case .horizontal: return "横向并排"; case .vertical: return "纵向长拼"; case .grid: return "网格拼图" }
    }
}

/// 拼图画布底色预设
public enum CollageBackgroundStyle: String, CaseIterable, Codable, Sendable {
    case lightGray, white, dark, gradient, transparent
    public var title: String {
        switch self {
        case .lightGray: return "柔灰"; case .white: return "纯白"; case .dark: return "深炭"
        case .gradient: return "极光渐变"; case .transparent: return "透明"
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

        for (idx, img) in valid.enumerated() {
            let imgW = CGFloat(img.width) * 0.5, imgH = CGFloat(img.height) * 0.5
            var pageBox = CGRect(x: 0, y: 0, width: imgW + padPt * 2, height: imgH + padPt * 2 + footerExtra)
            let boxData = Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size) as CFData
            pdf.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            CollageOverlaysRenderer.drawBackground(style: effectiveBg, customColor: customBackgroundColor, gradientPreset: gradientPreset, in: pageBox, ctx: pdf)
            pdf.interpolationQuality = .high
            pdf.draw(img, in: CGRect(x: padPt, y: padPt + footerExtra, width: imgW, height: imgH))
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
