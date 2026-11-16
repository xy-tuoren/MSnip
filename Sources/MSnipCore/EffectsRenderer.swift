import AppKit
import CoreGraphics
import Foundation

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
            offset: CGSize(width: 0, height: 2.0),
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
