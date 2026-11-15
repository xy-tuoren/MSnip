import AppKit
import CoreGraphics
import CoreImage
import Foundation

/// 荧光笔、自增步骤序号角标、像素马赛克与高斯毛玻璃模糊的专用渲染引擎
enum AnnotationEffectsRenderer {
    private struct BlurCacheKey: Hashable {
        let samplerID: ObjectIdentifier
        let x: Int
        let y: Int
        let w: Int
        let h: Int
        let radius: Int
    }

    private static let ciContext = CIContext(options: [
        .useSoftwareRenderer: false,
        .cacheIntermediates: false
    ])
    private static let cacheLock = NSLock()
    private static var blurCache: [BlurCacheKey: CGImage] = [:]

    /// 二阶贝塞尔中点平滑曲线绘制（供画笔与荧光笔共用）
    static func drawSmoothStroke(points: [CGPoint], in ctx: CGContext) {
        guard points.count >= 2 else { return }
        ctx.beginPath()
        ctx.move(to: points[0])
        if points.count == 2 {
            ctx.addLine(to: points[1])
        } else {
            for i in 1..<(points.count - 1) {
                let mid = CGPoint(
                    x: (points[i].x + points[i + 1].x) * 0.5,
                    y: (points[i].y + points[i + 1].y) * 0.5
                )
                ctx.addQuadCurve(to: mid, control: points[i])
            }
            if let last = points.last {
                ctx.addLine(to: last)
            }
        }
        ctx.strokePath()
    }

    /// 半透明荧光马克笔：亮底自动采用 `.multiply` 正片叠底令黑字保持 100% 纯黑锐利，暗底自动切回透明柔光防隐形
    static func drawHighlighter(
        points: [CGPoint],
        style: AnnotationStyle,
        in ctx: CGContext,
        sampler: PixelSampler? = nil,
        scale: CGFloat = 1.0
    ) {
        guard points.count >= 2 else { return }
        var isLightBg = true
        if let sampler, let midPt = points[safeMidIndex: points.count / 2] {
            let (r, g, b) = sampler.sampleRGB(
                px: Int((midPt.x * scale).rounded()),
                py: Int((midPt.y * scale).rounded())
            )
            let luma = 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
            isLightBg = luma > 135.0
        }

        ctx.saveGState()
        if isLightBg {
            ctx.setBlendMode(.multiply)
            ctx.setAlpha(0.42)
        } else {
            ctx.setBlendMode(.normal)
            ctx.setAlpha(0.38)
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        let vivid = RGBAColor(style.color.r, style.color.g, style.color.b, 255)
        ctx.setStrokeColor(vivid.cgColor)
        ctx.setLineWidth(style.highlighterWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        drawSmoothStroke(points: points, in: ctx)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    /// 自增步骤序号角标 `① ② ③`（支持单圆点落标，或拖拽拉出带阴影的指示箭头）
    static func drawStepBadge(
        center: CGPoint,
        tail: CGPoint?,
        number: Int,
        style: AnnotationStyle,
        in ctx: CGContext
    ) {
        let r = style.stepBadgeRadius
        let badgeRect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        let luma = 0.299 * Double(style.color.r) + 0.587 * Double(style.color.g) + 0.114 * Double(style.color.b)
        let isLightBadge = luma > 200.0

        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -1.5),
            blur: 3.5,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.34)
        )
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        // 1) 若拖拽出了足够长的指示尾部，绘制从圆周出发指向目标的箭头
        if let tail {
            let dx = tail.x - center.x
            let dy = tail.y - center.y
            let dist = hypot(dx, dy)
            if dist > r + 5.0 {
                let startPt = CGPoint(
                    x: center.x + (dx / dist) * (r - 1.0),
                    y: center.y + (dy / dist) * (r - 1.0)
                )
                let shaftWidth = max(2.5, style.lineWidth)
                if let geom = Geometry.arrowGeometry(from: startPt, to: tail, lineWidth: shaftWidth) {
                    ctx.setStrokeColor(style.color.cgColor)
                    ctx.setFillColor(style.color.cgColor)
                    ctx.setLineWidth(shaftWidth)
                    ctx.setLineCap(.butt)
                    ctx.move(to: startPt)
                    ctx.addLine(to: geom.shaftEnd)
                    ctx.strokePath()

                    ctx.beginPath()
                    ctx.move(to: geom.headPoints[0])
                    ctx.addLine(to: geom.headPoints[1])
                    ctx.addLine(to: geom.headPoints[2])
                    ctx.closePath()
                    ctx.fillPath()
                }
            }
        }

        // 2) 绘制实心徽章圆底与高对比度描边环
        ctx.setFillColor(style.color.cgColor)
        ctx.fillEllipse(in: badgeRect)

        let ringColor = isLightBadge
            ? CGColor(srgbRed: 0.12, green: 0.14, blue: 0.18, alpha: 0.35)
            : CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.94)
        ctx.setStrokeColor(ringColor)
        ctx.setLineWidth(1.8)
        ctx.strokeEllipse(in: badgeRect.insetBy(dx: 0.5, dy: 0.5))

        ctx.endTransparencyLayer()
        ctx.restoreGState()

        // 3) 居中绘制等宽粗体数字
        let label = "\(max(1, number))" as NSString
        let digitScale: CGFloat = number >= 100 ? 0.82 : (number >= 10 ? 0.94 : 1.08)
        let fontPt = max(11.0, r * digitScale)
        let fgColor = isLightBadge
            ? NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 1.0)
            : NSColor.white
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontPt, weight: .bold),
            .foregroundColor: fgColor
        ]

        let prev = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.current = prev }

        let sz = label.size(withAttributes: attrs)
        let textOrigin = CGPoint(
            x: center.x - sz.width * 0.5,
            y: center.y - sz.height * 0.5
        )
        label.draw(at: textOrigin, withAttributes: attrs)
    }

    /// 方格像素马赛克打码
    static func drawMosaic(
        rect: CGRect,
        blockSize: CGFloat,
        in ctx: CGContext,
        sampler: PixelSampler?,
        scale: CGFloat
    ) {
        guard let sampler else { return }
        let step = max(4.0, blockSize)
        var y = rect.minY
        while y < rect.maxY {
            let bh = min(step, rect.maxY - y)
            var x = rect.minX
            while x < rect.maxX {
                let bw = min(step, rect.maxX - x)
                let sampleX = Int(((x + bw * 0.5) * scale).rounded())
                let sampleY = Int(((y + bh * 0.5) * scale).rounded())
                ctx.setFillColor(sampler.sampleColor(px: sampleX, py: sampleY))
                ctx.fill(CGRect(x: x, y: y, width: bw + 0.4, height: bh + 0.4))
                x += step
            }
            y += step
        }
    }

    /// 原生 CoreImage 高斯毛玻璃柔化打码（边缘延展防透明黑边 + 局部切片缓存保证 60fps 丝滑）
    static func drawGaussianBlur(
        rect: CGRect,
        blockSize: CGFloat,
        in ctx: CGContext,
        sampler: PixelSampler?,
        scale: CGFloat
    ) {
        guard let sampler, scale > 0 else { return }
        let pxRect = CGRect(
            x: floor(rect.minX * scale),
            y: floor(rect.minY * scale),
            width: ceil(rect.width * scale),
            height: ceil(rect.height * scale)
        ).intersection(CGRect(x: 0, y: 0, width: sampler.width, height: sampler.height))

        guard pxRect.width >= 2, pxRect.height >= 2 else { return }
        let blurRadiusPx = max(6.0, blockSize * 1.45 * scale)
        let key = BlurCacheKey(
            samplerID: ObjectIdentifier(sampler),
            x: Int(pxRect.minX),
            y: Int(pxRect.minY),
            w: Int(pxRect.width),
            h: Int(pxRect.height),
            radius: Int(blurRadiusPx.rounded())
        )

        let blurredCG: CGImage? = {
            cacheLock.lock()
            if let hit = blurCache[key] {
                cacheLock.unlock()
                return hit
            }
            cacheLock.unlock()

            guard let cropped = sampler.cgImage.cropping(to: pxRect) else { return nil }
            let ciInput = CIImage(cgImage: cropped)
            let clamped = ciInput.clampedToExtent()
            guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
            filter.setValue(clamped, forKey: kCIInputImageKey)
            filter.setValue(blurRadiusPx, forKey: kCIInputRadiusKey)
            guard let output = filter.outputImage?.cropped(to: ciInput.extent),
                  let rendered = ciContext.createCGImage(output, from: ciInput.extent) else {
                return nil
            }

            cacheLock.lock()
            if blurCache.count >= 24 { blurCache.removeAll(keepingCapacity: true) }
            blurCache[key] = rendered
            cacheLock.unlock()
            return rendered
        }()

        guard let blurredCG else { return }
        let dstRect = CGRect(
            x: pxRect.minX / scale,
            y: pxRect.minY / scale,
            width: pxRect.width / scale,
            height: pxRect.height / scale
        )
        ctx.saveGState()
        let clipPath = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.addPath(clipPath)
        ctx.clip()
        ctx.translateBy(x: 0, y: dstRect.minY + dstRect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(blurredCG, in: dstRect)
        ctx.restoreGState()
    }
}

private extension Array {
    subscript(safeMidIndex index: Int) -> Element? {
        indices.contains(index) ? self[index] : first
    }
}
