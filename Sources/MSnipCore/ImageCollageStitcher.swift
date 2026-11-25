import CoreGraphics
import Foundation

/// 多图拼接排列方向（兼容既有菜单快捷入口）
public enum CollageDirection: String, CaseIterable, Sendable {
    case horizontal
    case vertical
}

/// 拼图工作室布局模式：横向并排 / 纵向长拼 / 自适应网格
public enum CollageLayoutMode: String, CaseIterable, Sendable {
    case horizontal
    case vertical
    case grid

    public var title: String {
        switch self {
        case .horizontal: return "横向并排"
        case .vertical:   return "纵向长拼"
        case .grid:       return "网格拼图"
        }
    }
}

/// 拼图画布底色预设
public enum CollageBackgroundStyle: String, CaseIterable, Sendable {
    case lightGray
    case white
    case dark
    case transparent

    public var title: String {
        switch self {
        case .lightGray:   return "柔灰"
        case .white:       return "纯白"
        case .dark:        return "深炭"
        case .transparent: return "透明"
        }
    }

    public var rgbaColor: RGBAColor? {
        switch self {
        case .lightGray:   return RGBAColor(244, 246, 250)
        case .white:       return RGBAColor(255, 255, 255)
        case .dark:        return RGBAColor(24, 26, 32)
        case .transparent: return nil
        }
    }
}

/// 拼图工作室实时渲染与高清导出配置
public struct CollageOptions: Equatable, Sendable {
    public var layout: CollageLayoutMode
    public var gridColumns: Int
    public var gapPx: Int
    public var padPx: Int
    public var cornerRadiusPx: CGFloat
    public var background: CollageBackgroundStyle

    public init(
        layout: CollageLayoutMode = .horizontal,
        gridColumns: Int = 2,
        gapPx: Int = 24,
        padPx: Int = 32,
        cornerRadiusPx: CGFloat = 14,
        background: CollageBackgroundStyle = .lightGray
    ) {
        self.layout = layout
        self.gridColumns = min(4, max(2, gridColumns))
        self.gapPx = min(120, max(0, gapPx))
        self.padPx = min(160, max(0, padPx))
        self.cornerRadiusPx = min(64, max(0, cornerRadiusPx))
        self.background = background
    }
}

/// 纯 CoreGraphics 高清多图对比拼接与多页 PDF 合并器（零第三方依赖，支持横/纵/网格、透明底、圆角柔影与色域保留）
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
        let mode: CollageLayoutMode = (direction == .horizontal) ? .horizontal : .vertical
        return stitchCore(
            images: valid,
            layout: mode,
            gridColumns: 2,
            gapPx: gapPx,
            padPx: padPx,
            cornerRadiusPx: cornerRadiusPx,
            backgroundColor: background,
            maxRefSide: 2400
        )
    }

    public static func stitch(
        images: [CGImage],
        options: CollageOptions,
        maxRefSide: Int = 2400
    ) -> CGImage? {
        let valid = images.filter { $0.width >= 4 && $0.height >= 4 }
        guard !valid.isEmpty else { return nil }
        return stitchCore(
            images: valid,
            layout: options.layout,
            gridColumns: options.gridColumns,
            gapPx: options.gapPx,
            padPx: options.padPx,
            cornerRadiusPx: options.cornerRadiusPx,
            backgroundColor: options.background.rgbaColor,
            maxRefSide: max(120, maxRefSide)
        )
    }

    /// 将多张有序图像合成为原生多页 PDF 文档（每页保持原图宽高比并附带留白与底色，零外部依赖）
    @discardableResult
    public static func exportMultiPagePDF(
        images: [CGImage],
        padPx: Int = 24,
        background: CollageBackgroundStyle = .white,
        to url: URL
    ) -> Bool {
        let valid = images.filter { $0.width >= 4 && $0.height >= 4 }
        guard !valid.isEmpty else { return false }
        var initialBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let pdf = CGContext(url as CFURL, mediaBox: &initialBox, nil) else { return false }

        let padPt = CGFloat(max(0, padPx)) * 0.5
        let bgColor = background.rgbaColor?.cgColor
        for img in valid {
            let imgW = CGFloat(img.width) * 0.5
            let imgH = CGFloat(img.height) * 0.5
            var pageBox = CGRect(x: 0, y: 0, width: imgW + padPt * 2, height: imgH + padPt * 2)
            let boxData = Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size) as CFData
            let pageInfo: [CFString: Any] = [kCGPDFContextMediaBox: boxData]
            pdf.beginPDFPage(pageInfo as CFDictionary)
            if let bgColor {
                pdf.setFillColor(bgColor)
                pdf.fill(pageBox)
            }
            pdf.interpolationQuality = .high
            pdf.draw(img, in: CGRect(x: padPt, y: padPt, width: imgW, height: imgH))
            pdf.endPDFPage()
        }
        pdf.closePDF()
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func stitchCore(
        images valid: [CGImage],
        layout: CollageLayoutMode,
        gridColumns: Int,
        gapPx: Int,
        padPx: Int,
        cornerRadiusPx: CGFloat,
        backgroundColor: RGBAColor?,
        maxRefSide: Int
    ) -> CGImage? {
        let gap = max(0, gapPx), pad = max(0, padPx)
        let placements: (canvasW: Int, canvasH: Int, rectsTopDown: [CGRect])
        switch layout {
        case .horizontal:
            let hs = valid.map(\.height).sorted()
            let refH = min(maxRefSide, max(64, hs[hs.count / 2]))
            var curX = pad, rects: [CGRect] = []
            for img in valid {
                let w = max(16, Int((Double(img.width) * Double(refH) / Double(img.height)).rounded()))
                rects.append(CGRect(x: curX, y: pad, width: w, height: refH))
                curX += w + gap
            }
            placements = (curX - gap + pad, pad * 2 + refH, rects)

        case .vertical:
            let ws = valid.map(\.width).sorted()
            let refW = min(maxRefSide, max(64, ws[ws.count / 2]))
            var curY = pad, rects: [CGRect] = []
            for img in valid {
                let h = max(16, Int((Double(img.height) * Double(refW) / Double(img.width)).rounded()))
                rects.append(CGRect(x: pad, y: curY, width: refW, height: h))
                curY += h + gap
            }
            placements = (pad * 2 + refW, curY - gap + pad, rects)

        case .grid:
            let cols = min(max(1, valid.count), min(4, max(2, gridColumns)))
            let rows = (valid.count + cols - 1) / cols
            let cellW = min(maxRefSide / max(1, cols), max(120, valid.map(\.width).sorted()[valid.count / 2]))
            let ratios = valid.map { Double($0.height) / Double(max(1, $0.width)) }.sorted()
            let medRatio = min(1.8, max(0.45, ratios[ratios.count / 2]))
            let cellH = max(80, Int((Double(cellW) * medRatio).rounded()))
            var rects: [CGRect] = []
            for idx in 0..<valid.count {
                let r = idx / cols, c = idx % cols
                rects.append(CGRect(x: pad + c * (cellW + gap), y: pad + r * (cellH + gap), width: cellW, height: cellH))
            }
            placements = (pad * 2 + cols * cellW + (cols - 1) * gap, pad * 2 + rows * cellH + (rows - 1) * gap, rects)
        }

        let canvasW = placements.canvasW, canvasH = placements.canvasH
        guard canvasW > 0, canvasH > 0, canvasW <= 20_000, canvasH <= 24_000 else { return nil }
        let cs: CGColorSpace = (valid[0].colorSpace?.model == .rgb && valid[0].colorSpace?.supportsOutput == true)
            ? valid[0].colorSpace! : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
        guard let ctx = CGContext(
            data: nil, width: canvasW, height: canvasH, bitsPerComponent: 8, bytesPerRow: canvasW * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        if let bg = backgroundColor {
            ctx.setFillColor(bg.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
        }

        let isDarkBg = (backgroundColor?.r ?? 255) < 80
        for (idx, img) in valid.enumerated() {
            let td = placements.rectsTopDown[idx]
            let rect = CGRect(x: td.minX, y: CGFloat(canvasH) - td.maxY, width: td.width, height: td.height)
            let r = min(cornerRadiusPx, min(rect.width, rect.height) * 0.25)
            let path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)

            if backgroundColor != nil {
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 14, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: isDarkBg ? 0.36 : 0.14))
                ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                ctx.addPath(path); ctx.fillPath()
                ctx.restoreGState()
            }

            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            ctx.interpolationQuality = .high
            if layout == .grid {
                // 网格格子内采用居中裁切铺满（aspect-fill）保证视觉规整饱满
                let sx = rect.width / CGFloat(img.width), sy = rect.height / CGFloat(img.height)
                let sc = max(sx, sy), dw = CGFloat(img.width) * sc, dh = CGFloat(img.height) * sc
                ctx.draw(img, in: CGRect(x: rect.midX - dw * 0.5, y: rect.midY - dh * 0.5, width: dw, height: dh))
            } else {
                ctx.draw(img, in: rect)
            }
            ctx.restoreGState()

            ctx.saveGState()
            ctx.setStrokeColor(CGColor(srgbRed: isDarkBg ? 1 : 0, green: isDarkBg ? 1 : 0, blue: isDarkBg ? 1 : 0, alpha: isDarkBg ? 0.14 : 0.08))
            ctx.setLineWidth(1.0); ctx.addPath(path); ctx.strokePath()
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }
}
