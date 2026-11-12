import AppKit
import CoreGraphics
import Foundation

/// 零拷贝底图像素快速采样器（供马赛克工具实时 O(块数) 取色，避免逐像素卷积卡顿）
public final class PixelSampler: @unchecked Sendable {
    public let cgImage: CGImage
    public let width: Int
    public let height: Int
    private let bytesPerRow: Int
    private let bytesPerPixel: Int
    private let rIdx: Int
    private let gIdx: Int
    private let bIdx: Int
    private let data: CFData?
    private let ptr: UnsafePointer<UInt8>?

    public init(cgImage: CGImage) {
        self.cgImage = cgImage
        self.width = cgImage.width
        self.height = cgImage.height
        self.bytesPerRow = cgImage.bytesPerRow
        self.bytesPerPixel = max(4, cgImage.bitsPerPixel / 8)
        let info = cgImage.bitmapInfo
        let isLittle32 = info.contains(.byteOrder32Little)
        let alpha = CGImageAlphaInfo(rawValue: info.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
        let alphaFirst = (alpha == .premultipliedFirst || alpha == .first || alpha == .noneSkipFirst)
        if isLittle32 {
            if alphaFirst { self.bIdx = 0; self.gIdx = 1; self.rIdx = 2 }
            else          { self.bIdx = 1; self.gIdx = 2; self.rIdx = 3 }
        } else {
            if alphaFirst { self.rIdx = 1; self.gIdx = 2; self.bIdx = 3 }
            else          { self.rIdx = 0; self.gIdx = 1; self.bIdx = 2 }
        }
        self.data = cgImage.dataProvider?.data
        self.ptr = self.data.flatMap { CFDataGetBytePtr($0) }
    }

    /// 零分配读取物理像素 `(px, py)`（左上角为原点）的 RGB 分量 (0...255)
    @inline(__always)
    public func sampleRGB(px: Int, py: Int) -> (Int, Int, Int) {
        guard let ptr, width > 0, height > 0 else { return (128, 128, 128) }
        let cx = min(max(0, px), width - 1)
        let cy = min(max(0, py), height - 1)
        let offset = cy * bytesPerRow + cx * bytesPerPixel
        return (Int(ptr[offset + rIdx]), Int(ptr[offset + gIdx]), Int(ptr[offset + bIdx]))
    }

    /// 按物理像素坐标 `(px, py)`（左上角为原点）读取颜色
    public func sampleColor(px: Int, py: Int) -> CGColor {
        let (r, g, b) = sampleRGB(px: px, py: py)
        return CGColor(
            srgbRed: CGFloat(r) / 255.0,
            green: CGFloat(g) / 255.0,
            blue: CGFloat(b) / 255.0,
            alpha: 1.0
        )
    }
}

/// 纯 CoreGraphics 标注渲染与高清图像烘焙器（屏幕预览与剪贴板/PNG 导出共用同一套绘制代码）
public enum AnnotationRenderer {
    /// 测量文本在给定字号下的排版尺寸（供命中框与布局缓存）
    public static func measureText(_ text: String, fontSize: CGFloat) -> CGSize {
        let attrs = textAttributes(color: RGBAColor(255, 255, 255), fontSize: fontSize)
        let size = (text as NSString).boundingRect(
            with: CGSize(width: 2000, height: 2000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        ).size
        return CGSize(width: ceil(max(12, size.width + 4)), height: ceil(max(fontSize * 1.25, size.height + 2)))
    }

    /// 在已翻转为「左上角原点」的 `CGContext` 上绘制全部标注与草稿
    public static func drawAnnotations(
        in ctx: CGContext,
        annotations: [Annotation],
        draft: Annotation?,
        skipIndex: Int? = nil,
        sampler: PixelSampler?,
        imageScale: CGFloat,
        clipRect: CGRect? = nil
    ) {
        ctx.saveGState()
        if let clipRect {
            ctx.clip(to: clipRect)
        }
        for (idx, item) in annotations.enumerated() where idx != skipIndex {
            drawSingle(item, in: ctx, sampler: sampler, imageScale: imageScale)
        }
        if let draft {
            drawSingle(draft, in: ctx, sampler: sampler, imageScale: imageScale)
        }
        ctx.restoreGState()
    }

    /// 绘制单个标注对象
    public static func drawSingle(
        _ item: Annotation,
        in ctx: CGContext,
        sampler: PixelSampler?,
        imageScale: CGFloat
    ) {
        ctx.saveGState()
        ctx.setStrokeColor(item.style.color.cgColor)
        ctx.setFillColor(item.style.color.cgColor)
        ctx.setLineWidth(item.style.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch item.payload {
        case .rect(let rect):
            let path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
            ctx.addPath(path)
            ctx.strokePath()

        case .ellipse(let rect):
            ctx.strokeEllipse(in: rect)

        case .line(let from, let to):
            ctx.move(to: from)
            ctx.addLine(to: to)
            ctx.strokePath()

        case .arrow(let from, let to):
            if let geom = Geometry.arrowGeometry(from: from, to: to, lineWidth: item.style.lineWidth) {
                ctx.setLineCap(.butt)
                ctx.move(to: from)
                ctx.addLine(to: geom.shaftEnd)
                ctx.strokePath()

                ctx.beginPath()
                ctx.move(to: geom.headPoints[0])
                ctx.addLine(to: geom.headPoints[1])
                ctx.addLine(to: geom.headPoints[2])
                ctx.closePath()
                ctx.fillPath()
            }

        case .pen(let pts):
            drawSmoothStroke(points: pts, in: ctx)

        case .mosaic(let rect):
            drawMosaic(rect: rect, blockSize: item.style.mosaicBlockSize, in: ctx, sampler: sampler, scale: imageScale)

        case .text(let origin, let content, _):
            drawText(content, at: origin, style: item.style, in: ctx)
        }
        ctx.restoreGState()
    }

    /// 将选区原图与标注合成为全分辨率 Retina `CGImage`（用于复制、贴图与另存为 PNG）
    public static func bakeExportImage(
        sampler: PixelSampler,
        selection: CGRect,
        imageScale: CGFloat,
        annotations: [Annotation]
    ) -> CGImage? {
        let pxRect = CGRect(
            x: round(selection.minX * imageScale),
            y: round(selection.minY * imageScale),
            width: max(1, round(selection.width * imageScale)),
            height: max(1, round(selection.height * imageScale))
        ).intersection(CGRect(x: 0, y: 0, width: sampler.width, height: sampler.height))

        let outW = Int(pxRect.width)
        let outH = Int(pxRect.height)
        guard outW > 0, outH > 0, let cropped = sampler.cgImage.cropping(to: pxRect) else {
            return nil
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        // 1) 在标准未翻转 CG 坐标系下绘制裁剪底图，确保原图方向正立不颠倒
        ctx.interpolationQuality = .high
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))

        // 2) 切换到与覆盖层一致的「左上角原点 + 逻辑点」坐标系绘制矢量标注
        ctx.translateBy(x: 0, y: CGFloat(outH))
        ctx.scaleBy(x: imageScale, y: -imageScale)
        ctx.translateBy(x: -selection.minX, y: -selection.minY)

        drawAnnotations(
            in: ctx,
            annotations: annotations,
            draft: nil,
            sampler: sampler,
            imageScale: imageScale,
            clipRect: selection
        )
        return ctx.makeImage()
    }

    // MARK: - Private Helpers

    private static func drawSmoothStroke(points: [CGPoint], in ctx: CGContext) {
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

    private static func drawMosaic(
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

    private static func drawText(_ text: String, at origin: CGPoint, style: AnnotationStyle, in ctx: CGContext) {
        let prev = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.current = prev }

        let attrs = textAttributes(color: style.color, fontSize: style.fontSize)
        (text as NSString).draw(at: origin, withAttributes: attrs)
    }

    private static func textAttributes(color: RGBAColor, fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let nsColor = NSColor(
            srgbRed: CGFloat(color.r) / 255.0,
            green: CGFloat(color.g) / 255.0,
            blue: CGFloat(color.b) / 255.0,
            alpha: CGFloat(color.a) / 255.0
        )
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 2.0
        return [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: nsColor,
            .shadow: shadow
        ]
    }
}
