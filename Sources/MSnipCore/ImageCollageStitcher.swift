import CoreGraphics
import Foundation

/// 多图拼接排列方向
public enum CollageDirection: String, CaseIterable, Sendable {
    case horizontal
    case vertical
}

/// 纯 CoreGraphics 高清多图对比拼接合成器（支持横向并排对比与纵向长图拼接，自动等比对齐、圆角柔影与色域保留）
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

        let gap = max(0, gapPx)
        let pad = max(0, padPx)
        let maxRefSide = 2400

        // 按拼接方向统一垂直高度（横向）或水平宽度（纵向），取各图中位基准尺寸并限制单边上限防止内存暴涨
        let refDim: Int
        if direction == .horizontal {
            let hs = valid.map(\.height).sorted()
            refDim = min(maxRefSide, max(64, hs[hs.count / 2]))
        } else {
            let ws = valid.map(\.width).sorted()
            refDim = min(maxRefSide, max(64, ws[ws.count / 2]))
        }

        var itemSizes: [(w: Int, h: Int)] = []
        for img in valid {
            if direction == .horizontal {
                let scale = Double(refDim) / Double(img.height)
                let w = max(16, Int((Double(img.width) * scale).rounded()))
                itemSizes.append((w, refDim))
            } else {
                let scale = Double(refDim) / Double(img.width)
                let h = max(16, Int((Double(img.height) * scale).rounded()))
                itemSizes.append((refDim, h))
            }
        }

        let canvasW: Int
        let canvasH: Int
        if direction == .horizontal {
            canvasW = pad * 2 + itemSizes.reduce(0) { $0 + $1.w } + gap * (valid.count - 1)
            canvasH = pad * 2 + refDim
        } else {
            canvasW = pad * 2 + refDim
            canvasH = pad * 2 + itemSizes.reduce(0) { $0 + $1.h } + gap * (valid.count - 1)
        }
        guard canvasW > 0, canvasH > 0, canvasW <= 20_000, canvasH <= 24_000 else { return nil }

        let cs: CGColorSpace = (valid[0].colorSpace?.model == .rgb && valid[0].colorSpace?.supportsOutput == true)
            ? valid[0].colorSpace!
            : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
        guard let ctx = CGContext(
            data: nil, width: canvasW, height: canvasH, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setFillColor(background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))

        var cursorX = pad
        var cursorTopY = pad // 逻辑从上往下累加，再换算到 CG 左下角坐标系
        for (idx, img) in valid.enumerated() {
            let sz = itemSizes[idx]
            let cgY = canvasH - cursorTopY - sz.h
            let rect = CGRect(x: cursorX, y: cgY, width: sz.w, height: sz.h)
            let r = min(cornerRadiusPx, CGFloat(min(sz.w, sz.h)) * 0.25)
            let path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)

            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 14, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.14))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.addPath(path); ctx.fillPath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(path); ctx.clip()
            ctx.interpolationQuality = .high
            ctx.draw(img, in: rect)
            ctx.restoreGState()

            ctx.saveGState()
            ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.08))
            ctx.setLineWidth(1.0)
            ctx.addPath(path); ctx.strokePath()
            ctx.restoreGState()

            if direction == .horizontal { cursorX += sz.w + gap } else { cursorTopY += sz.h + gap }
        }
        return ctx.makeImage()
    }
}
