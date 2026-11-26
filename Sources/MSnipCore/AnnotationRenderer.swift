import Accelerate
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

// MARK: - 马赛克与毛玻璃 SIMD 滤镜渲染

/// 平滑贝塞尔曲线、自适应明暗底荧光笔与自增步骤序号角标渲染器
enum AnnotationEffectsRenderer {
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
        label.draw(
            at: CGPoint(x: center.x - sz.width * 0.5, y: center.y - sz.height * 0.5),
            withAttributes: attrs
        )
    }

    /// 渲染圆角胶囊底色文字标签（高对比气泡底 + 自适应黑白粗体字 + 柔和投影，杂乱背景下依旧清晰醒目）
    static func drawCapsuleText(
        _ text: String,
        at origin: CGPoint,
        measuredSize: CGSize,
        style: AnnotationStyle,
        in ctx: CGContext
    ) {
        let font = NSFont.systemFont(ofSize: style.fontSize, weight: .semibold)
        let luma = 0.299 * Double(style.color.r) + 0.587 * Double(style.color.g) + 0.114 * Double(style.color.b)
        let isLightFill = luma > 195.0
        let fgColor = isLightFill
            ? NSColor(srgbRed: 0.10, green: 0.11, blue: 0.14, alpha: 1.0)
            : NSColor.white
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fgColor
        ]

        let rawSz = (text as NSString).boundingRect(
            with: CGSize(width: 2000, height: 2000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        ).size
        let padX = max(9.0, round(style.fontSize * 0.52))
        let padY = max(5.0, round(style.fontSize * 0.28))
        let pillW = max(measuredSize.width, ceil(rawSz.width + padX * 2))
        let pillH = max(measuredSize.height, ceil(rawSz.height + padY * 2))
        let pillRect = CGRect(origin: origin, size: CGSize(width: pillW, height: pillH))
        let radius = min(12.0, pillH * 0.42)
        let pillPath = CGPath(roundedRect: pillRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -2.0),
            blur: 5.0,
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.32)
        )
        ctx.setFillColor(style.color.cgColor)
        ctx.addPath(pillPath)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        let borderColor = isLightFill
            ? CGColor(srgbRed: 0.10, green: 0.12, blue: 0.16, alpha: 0.22)
            : CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.32)
        ctx.setStrokeColor(borderColor)
        ctx.setLineWidth(1.2)
        ctx.addPath(pillPath)
        ctx.strokePath()
        ctx.restoreGState()

        let prev = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.current = prev }
        (text as NSString).draw(
            at: CGPoint(
                x: pillRect.minX + (pillW - rawSz.width) * 0.5,
                y: pillRect.minY + (pillH - rawSz.height) * 0.5
            ),
            withAttributes: attrs
        )
    }
}

private extension Array {
    subscript(safeMidIndex index: Int) -> Element? {
        indices.contains(index) ? self[index] : first
    }
}

// MARK: - 隐私敏感区域自动打码渲染

/// 高性能隐私打码渲染扩展：
/// - 方格马赛克：单次连续位图采样 + 最近邻硬件拉伸，零 `CGColor` 堆分配；
/// - 高斯毛玻璃：基于 `Accelerate / vImage` SIMD 可分离双程帐篷卷积（等价 4 阶盒滤波真高斯逼近）+ 金字塔降采样，
///   彻底消除每帧 `CoreImage` GPU 纹理上传与显存回读同步开销，拖拽帧耗时进入亚毫秒级。
extension AnnotationEffectsRenderer {
    private struct BlurCacheKey: Hashable {
        let samplerID: ObjectIdentifier
        let x: Int
        let y: Int
        let w: Int
        let h: Int
        let radius: Int
    }

    private static let sRGBSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// 与 `PixelSampler` 采样字节精确一致的色域，杜绝广色域屏偏灰及 HDR 回退栅格过饱和
    private static func effectiveColorSpace(for sampler: PixelSampler) -> CGColorSpace {
        sampler.samplingColorSpace
    }
    private static let cacheLock = NSLock()
    private static var blurCache: [BlurCacheKey: CGImage] = [:]
    private static var draftBlurEntry: (key: BlurCacheKey, image: CGImage)?

    /// 会话结束时清空全部毛玻璃切片缓存，确保菜单栏常驻期零残留内存
    static func purgeCaches() {
        cacheLock.lock()
        blurCache.removeAll(keepingCapacity: false)
        draftBlurEntry = nil
        cacheLock.unlock()
    }

    /// 方格像素马赛克打码（单次连续内存采样 + 最近邻硬件拉伸，彻底消除数千次 `CGColor` 堆分配）
    static func drawMosaic(
        rect: CGRect,
        blockSize: CGFloat,
        in ctx: CGContext,
        sampler: PixelSampler?,
        scale: CGFloat
    ) {
        guard let sampler, rect.width > 0.5, rect.height > 0.5 else { return }
        let step = max(4.0, blockSize)
        let cols = max(1, Int(ceil(rect.width / step)))
        let rows = max(1, Int(ceil(rect.height / step)))

        var rgba = [UInt8](repeating: 255, count: cols * rows * 4)
        rgba.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for r in 0..<rows {
                let y = rect.minY + CGFloat(r) * step
                let bh = min(step, rect.maxY - y)
                let sampleY = Int(((y + bh * 0.5) * scale).rounded())
                let rowOffset = r * cols * 4
                for c in 0..<cols {
                    let x = rect.minX + CGFloat(c) * step
                    let bw = min(step, rect.maxX - x)
                    let sampleX = Int(((x + bw * 0.5) * scale).rounded())
                    let (cr, cg, cb) = sampler.sampleRGB(px: sampleX, py: sampleY)
                    let idx = rowOffset + c * 4
                    base[idx] = UInt8(cr)
                    base[idx + 1] = UInt8(cg)
                    base[idx + 2] = UInt8(cb)
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let mosaicCG = CGImage(
                  width: cols, height: rows,
                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4,
                  space: effectiveColorSpace(for: sampler),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return }

        let gridRect = CGRect(x: rect.minX, y: rect.minY, width: CGFloat(cols) * step, height: CGFloat(rows) * step)
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.interpolationQuality = .none
        ctx.translateBy(x: 0, y: gridRect.minY + gridRect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(mosaicCG, in: gridRect)
        ctx.restoreGState()
    }

    /// 原生 Accelerate `vImage` SIMD 高斯毛玻璃打码（O(1) 核宽复杂度 + 边缘延展防黑边 + 草稿缓存隔离）
    static func drawGaussianBlur(
        rect: CGRect,
        blockSize: CGFloat,
        in ctx: CGContext,
        sampler: PixelSampler?,
        scale: CGFloat,
        isDraft: Bool = false
    ) {
        guard let sampler, scale > 0 else { return }
        let pxRect = CGRect(
            x: floor(rect.minX * scale),
            y: floor(rect.minY * scale),
            width: ceil(rect.width * scale),
            height: ceil(rect.height * scale)
        ).intersection(CGRect(x: 0, y: 0, width: sampler.width, height: sampler.height))

        let fullW = Int(pxRect.width)
        let fullH = Int(pxRect.height)
        guard fullW >= 2, fullH >= 2 else { return }
        let blurRadiusPx = max(6.0, blockSize * 1.45 * scale)
        let key = BlurCacheKey(
            samplerID: ObjectIdentifier(sampler),
            x: Int(pxRect.minX), y: Int(pxRect.minY),
            w: fullW, h: fullH,
            radius: Int(blurRadiusPx.rounded())
        )

        let blurredCG: CGImage? = {
            cacheLock.lock()
            if let hit = blurCache[key] {
                cacheLock.unlock()
                return hit
            }
            if isDraft, let draftHit = draftBlurEntry, draftHit.key == key {
                cacheLock.unlock()
                return draftHit.image
            }
            cacheLock.unlock()

            guard let rendered = renderSIMDGaussianPatch(
                sampler: sampler,
                originX: Int(pxRect.minX),
                originY: Int(pxRect.minY),
                fullW: fullW,
                fullH: fullH,
                blurRadiusPx: blurRadiusPx
            ) else { return nil }

            cacheLock.lock()
            if isDraft {
                draftBlurEntry = (key, rendered)
            } else {
                if blurCache.count >= 32 { blurCache.removeAll(keepingCapacity: true) }
                blurCache[key] = rendered
            }
            cacheLock.unlock()
            return rendered
        }()

        guard let blurredCG else { return }
        let dstRect = CGRect(
            x: pxRect.minX / scale, y: pxRect.minY / scale,
            width: pxRect.width / scale, height: pxRect.height / scale
        )
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.clip()
        ctx.interpolationQuality = .low
        ctx.translateBy(x: 0, y: dstRect.minY + dstRect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(blurredCG, in: dstRect)
        ctx.restoreGState()
    }

    private static func renderSIMDGaussianPatch(
        sampler: PixelSampler,
        originX: Int,
        originY: Int,
        fullW: Int,
        fullH: Int,
        blurRadiusPx: CGFloat
    ) -> CGImage? {
        let maxDS = max(1, min(fullW / 4, fullH / 4))
        let idealDS = max(1, min(4, Int(floor(blurRadiusPx / 5.0))))
        let ds = min(idealDS, maxDS)
        let sw = max(2, (fullW + ds - 1) / ds)
        let sh = max(2, (fullH + ds - 1) / ds)
        let rowBytes = sw * 4
        let byteCount = sh * rowBytes

        var bufA = [UInt8](repeating: 255, count: byteCount)
        var bufB = [UInt8](repeating: 255, count: byteCount)

        let stepX = Double(fullW) / Double(sw)
        let stepY = Double(fullH) / Double(sh)
        bufA.withUnsafeMutableBufferPointer { ptrA in
            guard let base = ptrA.baseAddress else { return }
            for y in 0..<sh {
                let sy = originY + min(fullH - 1, Int((Double(y) + 0.5) * stepY))
                let rOff = y * rowBytes
                for x in 0..<sw {
                    let sx = originX + min(fullW - 1, Int((Double(x) + 0.5) * stepX))
                    let (cr, cg, cb) = sampler.sampleRGB(px: sx, py: sy)
                    let idx = rOff + x * 4
                    base[idx] = UInt8(cr)
                    base[idx + 1] = UInt8(cg)
                    base[idx + 2] = UInt8(cb)
                }
            }
        }

        let scaledSigma = Double(blurRadiusPx) / Double(ds)
        let halfSpan = max(1, Int((sqrt(3.0 * scaledSigma * scaledSigma + 1.0)).rounded()) - 1)
        let kernel = UInt32(min(127, halfSpan * 2 + 1) | 1)
        let flags = vImage_Flags(kvImageEdgeExtend)

        bufA.withUnsafeMutableBytes { rawA in
            bufB.withUnsafeMutableBytes { rawB in
                guard let addrA = rawA.baseAddress, let addrB = rawB.baseAddress else { return }
                var vA = vImage_Buffer(data: addrA, height: vImagePixelCount(sh), width: vImagePixelCount(sw), rowBytes: rowBytes)
                var vB = vImage_Buffer(data: addrB, height: vImagePixelCount(sh), width: vImagePixelCount(sw), rowBytes: rowBytes)
                // 两趟可分离帐篷卷积 = 四阶盒式卷积，高精度逼近连续高斯核且复杂度与核半径无关 O(1)
                _ = vImageTentConvolve_ARGB8888(&vA, &vB, nil, 0, 0, kernel, kernel, nil, flags)
                _ = vImageTentConvolve_ARGB8888(&vB, &vA, nil, 0, 0, kernel, kernel, nil, flags)
            }
        }

        guard let provider = CGDataProvider(data: Data(bufA) as CFData) else { return nil }
        return CGImage(
            width: sw, height: sh,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
            space: effectiveColorSpace(for: sampler),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
