import AppKit
import CoreGraphics
import Foundation

/// 纯 CoreGraphics 标注渲染与高清图像烘焙器（屏幕预览与剪贴板/PNG 导出共用同一套绘制代码）
public enum AnnotationRenderer {
    /// 释放渲染器内部瞬态图像缓存（如毛玻璃切片缓存），保证会话关闭后零闲置内存占用
    public static func purgeCaches() {
        AnnotationEffectsRenderer.purgeCaches()
    }

    /// 测量文本在给定字号与样式（纯字/胶囊底色块）下的排版尺寸（供命中框与布局缓存）
    public static func measureText(_ text: String, fontSize: CGFloat, capsule: Bool = false) -> CGSize {
        let attrs = textAttributes(color: RGBAColor(255, 255, 255), fontSize: fontSize)
        let size = (text as NSString).boundingRect(
            with: CGSize(width: 2000, height: 2000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        ).size
        if capsule {
            let padX = max(9.0, round(fontSize * 0.52))
            let padY = max(5.0, round(fontSize * 0.28))
            return CGSize(width: ceil(max(24, size.width + padX * 2)), height: ceil(max(fontSize * 1.5, size.height + padY * 2)))
        }
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
        // 优先渲染聚光灯压暗遮罩（多块聚光灯同时照亮各自焦点区域，其余标注叠加在其上方保持清晰）
        var spotlightRects: [CGRect] = []
        for (idx, item) in annotations.enumerated() where idx != skipIndex {
            if case .spotlight(let r) = item.payload, r.width >= 3, r.height >= 3 { spotlightRects.append(r) }
        }
        if let draft, case .spotlight(let r) = draft.payload, r.width >= 3, r.height >= 3 {
            spotlightRects.append(r)
        }
        if !spotlightRects.isEmpty, let area = clipRect {
            drawSpotlightMask(in: ctx, area: area, cutouts: spotlightRects)
        }
        for (idx, item) in annotations.enumerated() where idx != skipIndex {
            drawSingle(item, in: ctx, sampler: sampler, imageScale: imageScale, isDraft: false)
        }
        if let draft {
            drawSingle(draft, in: ctx, sampler: sampler, imageScale: imageScale, isDraft: true)
        }
        ctx.restoreGState()
    }

    private static func drawSpotlightMask(in ctx: CGContext, area: CGRect, cutouts: [CGRect]) {
        ctx.saveGState()
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.48))
        ctx.addRect(area.insetBy(dx: -2, dy: -2))
        for r in cutouts {
            let cr = min(6.0, min(r.width, r.height) * 0.2)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: cr, cornerHeight: cr, transform: nil))
        }
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    /// 绘制单个标注对象
    public static func drawSingle(
        _ item: Annotation,
        in ctx: CGContext,
        sampler: PixelSampler?,
        imageScale: CGFloat,
        isDraft: Bool = false
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
            AnnotationEffectsRenderer.drawSmoothStroke(points: pts, in: ctx)

        case .highlighter(let pts):
            AnnotationEffectsRenderer.drawHighlighter(points: pts, style: item.style, in: ctx, sampler: sampler, scale: imageScale)
        case .step(let center, let tail, let num):
            AnnotationEffectsRenderer.drawStepBadge(center: center, tail: tail, number: num, style: item.style, in: ctx)
        case .mosaic(let rect):
            AnnotationEffectsRenderer.drawMosaic(rect: rect, blockSize: item.style.mosaicBlockSize, in: ctx, sampler: sampler, scale: imageScale)
        case .gaussianBlur(let rect):
            AnnotationEffectsRenderer.drawGaussianBlur(rect: rect, blockSize: item.style.mosaicBlockSize, in: ctx, sampler: sampler, scale: imageScale, isDraft: isDraft)
        case .spotlight(let rect):
            let cr = min(6.0, min(rect.width, rect.height) * 0.2)
            ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
            ctx.setLineWidth(1.5)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: cr, cornerHeight: cr, transform: nil)); ctx.strokePath()

        case .text(let origin, let content, let measured):
            if item.style.textCapsule {
                AnnotationEffectsRenderer.drawCapsuleText(content, at: origin, measuredSize: measured, style: item.style, in: ctx)
            } else {
                drawText(content, at: origin, style: item.style, in: ctx)
            }
        }
        ctx.restoreGState()
    }

    /// 将选区原图与标注合成为全分辨率 Retina `CGImage`（支持圆角裁切与一键美观渐变衬底）
    public static func bakeExportImage(
        sampler: PixelSampler,
        selection: CGRect,
        imageScale: CGFloat,
        annotations: [Annotation],
        cornerRadiusPt: CGFloat = 0,
        backdropStyle: BackdropStyle = .none,
        backdropAspectRatio: BackdropAspectRatio = .auto,
        watermarkText: String = ""
    ) -> CGImage? {
        let pxRect = CGRect(
            x: round(selection.minX * imageScale),
            y: round(selection.minY * imageScale),
            width: max(1, round(selection.width * imageScale)),
            height: max(1, round(selection.height * imageScale))
        ).intersection(CGRect(x: 0, y: 0, width: sampler.width, height: sampler.height))

        let outW = Int(pxRect.width), outH = Int(pxRect.height)
        guard outW > 0, outH > 0, let cropped = sampler.cgImage.cropping(to: pxRect) else { return nil }

        // 无标注/无圆角/无衬底时：局部选区拷贝为独立紧致缓冲以彻底释放 5K 全屏 CGDataProvider，全屏抓图则直接零重绘返回
        if annotations.isEmpty && cornerRadiusPt <= 0.5 && backdropStyle == .none {
            let isSubRegion = outW * outH < (sampler.width * sampler.height * 3) / 4
            return isSubRegion ? ImageTransform.detachedCopy(cropped) : cropped
        }

        let colorSpace: CGColorSpace = (sampler.cgImage.colorSpace?.model == .rgb && sampler.cgImage.colorSpace?.supportsOutput == true)
            ? sampler.cgImage.colorSpace!
            : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        if backdropStyle == .none, cornerRadiusPt > 0.5 {
            let rPx = min(cornerRadiusPt * imageScale, CGFloat(min(outW, outH)) * 0.5)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: outW, height: outH), cornerWidth: rPx, cornerHeight: rPx, transform: nil))
            ctx.clip()
        }

        // 1) 在标准未翻转 CG 坐标系下 1:1 无插值绘制裁剪底图，确保原图方向正立、像素零模糊
        ctx.interpolationQuality = .none
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))

        // 2) 切换到与覆盖层一致的「左上角原点 + 逻辑点」坐标系绘制矢量标注
        ctx.translateBy(x: 0, y: CGFloat(outH))
        ctx.scaleBy(x: imageScale, y: -imageScale)
        ctx.translateBy(x: -selection.minX, y: -selection.minY)
        drawAnnotations(in: ctx, annotations: annotations, draft: nil, sampler: sampler, imageScale: imageScale, clipRect: selection)
        guard let rawCard = ctx.makeImage() else { return nil }
        return BackdropBeautifier.apply(
            to: rawCard, style: backdropStyle, imageScale: imageScale,
            innerCornerRadiusPt: cornerRadiusPt, aspectRatio: backdropAspectRatio, watermarkText: watermarkText
        )
    }

    // MARK: - Private Text Helpers

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
