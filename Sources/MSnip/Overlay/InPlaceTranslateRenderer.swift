import AppKit
import CoreGraphics
import CoreText
import Foundation
import MSnipCore

/// 纯 CoreGraphics + CoreText 段落级原位翻译位图烘焙器（100% 后台线程安全，支持多行自然折行与自适应底色融合）
enum InPlaceTranslateRenderer {
    static func bakeParagraphBlocks(
        onto base: CGImage,
        blocks: [OCRParagraphBlock],
        translations: [String]
    ) -> CGImage? {
        let w = base.width, h = base.height
        let cs = (base.colorSpace?.model == .rgb && base.colorSpace?.supportsOutput == true)
            ? base.colorSpace!
            : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // 先在原生左下角坐标系绘制原图（CTFramesetter 亦原生工作于左下角坐标系，无需反复翻转 Y 轴）
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        let sampler = PixelSampler(cgImage: base)
        let isSingleShort = (blocks.count == 1 && blocks[0].lineCount == 1)

        for (i, blk) in blocks.enumerated() where translations.indices.contains(i) {
            let text = translations[i].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let lineHPx = max(12, blk.avgLineHeight * CGFloat(h))
            let padX = max(5, lineHPx * 0.22)
            let padY = max(3, lineHPx * 0.16)
            var bx = max(2, blk.box.minX * CGFloat(w) - padX)
            let by = max(2, blk.box.minY * CGFloat(h) - padY)
            var bx2 = min(CGFloat(w) - 2, blk.box.maxX * CGFloat(w) + padX)
            let by2 = min(CGFloat(h) - 2, blk.box.maxY * CGFloat(h) + padY)
            var rect = CGRect(x: bx, y: by, width: max(8, bx2 - bx), height: max(8, by2 - by))

            // 采样外沿 8 点中位底色，抗文字边缘色污染，自动决定深/浅对比字色
            let bgRGB = samplePerimeterColor(sampler: sampler, rectBottomLeft: rect, imgW: w, imgH: h)
            let luma = (bgRGB.0 * 299 + bgRGB.1 * 587 + bgRGB.2 * 114) / 1000
            let bgColor = CGColor(
                srgbRed: CGFloat(bgRGB.0) / 255.0,
                green: CGFloat(bgRGB.1) / 255.0,
                blue: CGFloat(bgRGB.2) / 255.0,
                alpha: 0.96
            )
            let fgColor = luma < 138
                ? CGColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1.0)
                : CGColor(srgbRed: 0.08, green: 0.10, blue: 0.14, alpha: 1.0)

            // 独立单行小标签优先水平适度外扩，避免字号被过度压缩
            if isSingleShort {
                let targetPt = min(max(11, lineHPx * 0.78), 44)
                let font = NSFont.systemFont(ofSize: targetPt, weight: .medium)
                let neededW = ceil(CGFloat(CTLineGetTypographicBounds(
                    CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font])),
                    nil, nil, nil
                ))) + 12
                if neededW > rect.width && CGFloat(w) - 4 > rect.width {
                    let expand = min(CGFloat(w) - 4, neededW)
                    bx = max(2, min(CGFloat(w) - 2 - expand, rect.midX - expand * 0.5))
                    bx2 = min(CGFloat(w) - 2, bx + expand)
                    rect = CGRect(x: bx, y: by, width: max(8, bx2 - bx), height: max(8, by2 - by))
                }
            }

            let radius = min(8, min(rect.width, rect.height) * 0.18)
            let bgPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.saveGState()
            ctx.setFillColor(bgColor)
            ctx.addPath(bgPath); ctx.fillPath()
            // 极淡柔和边框，防止纯白/纯黑重叠块视觉边界生硬
            let rimAlpha: CGFloat = (luma < 138) ? 0.10 : 0.06
            let rimGray: CGFloat = (luma < 138) ? 1.0 : 0.0
            ctx.setStrokeColor(CGColor(srgbRed: rimGray, green: rimGray, blue: rimGray, alpha: rimAlpha))
            ctx.setLineWidth(1.0)
            ctx.addPath(bgPath); ctx.strokePath()
            ctx.restoreGState()

            drawFittedParagraph(
                text: text,
                in: rect.insetBy(dx: 4, dy: 2),
                baseLineHeight: lineHPx,
                fgColor: fgColor,
                centered: isSingleShort,
                ctx: ctx
            )
        }
        return ctx.makeImage()
    }

    private static func drawFittedParagraph(
        text: String,
        in box: CGRect,
        baseLineHeight: CGFloat,
        fgColor: CGColor,
        centered: Bool,
        ctx: CGContext
    ) {
        guard box.width >= 6, box.height >= 6 else { return }
        let maxPt = min(max(11.0, baseLineHeight * 0.80), 44.0)
        let minPt: CGFloat = 8.5
        let fgKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)

        func makeAttr(_ pt: CGFloat) -> NSAttributedString {
            let pStyle = NSMutableParagraphStyle()
            pStyle.lineBreakMode = .byWordWrapping
            pStyle.lineSpacing = max(1.5, pt * 0.16)
            pStyle.alignment = centered ? .center : .left
            return NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: pt, weight: .medium),
                fgKey: fgColor,
                .paragraphStyle: pStyle
            ])
        }

        // 二分查找可完整容纳于段落框内的最大字号
        var lo = minPt, hi = maxPt, bestPt = minPt
        for _ in 0..<8 {
            let mid = (lo + hi) * 0.5
            let fs = CTFramesetterCreateWithAttributedString(makeAttr(mid))
            let fit = CTFramesetterSuggestFrameSizeWithConstraints(
                fs, CFRange(location: 0, length: 0), nil,
                CGSize(width: box.width, height: .greatestFiniteMagnitude), nil
            )
            if fit.height <= box.height + 1.5 {
                bestPt = mid
                lo = mid
            } else {
                hi = mid
            }
        }

        let finalAttr = makeAttr(bestPt)
        let fs = CTFramesetterCreateWithAttributedString(finalAttr)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(
            fs, CFRange(location: 0, length: 0), nil,
            CGSize(width: box.width, height: .greatestFiniteMagnitude), nil
        )
        let drawH = min(box.height, ceil(fit.height) + 2)
        let yOffset = max(0, (box.height - drawH) * 0.5)
        let frameRect = CGRect(x: box.minX, y: box.minY + yOffset, width: box.width, height: drawH)
        let framePath = CGPath(rect: frameRect, transform: nil)
        let ctFrame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), framePath, nil)

        ctx.saveGState()
        ctx.clip(to: box)
        ctx.textMatrix = .identity
        CTFrameDraw(ctFrame, ctx)
        ctx.restoreGState()
    }

    private static func samplePerimeterColor(
        sampler: PixelSampler,
        rectBottomLeft r: CGRect,
        imgW: Int,
        imgH: Int
    ) -> (Int, Int, Int) {
        // PixelSampler 使用左上角原点 Y 轴
        let topY = max(0, min(imgH - 1, imgH - 1 - Int(r.maxY.rounded())))
        let botY = max(0, min(imgH - 1, imgH - 1 - Int(r.minY.rounded())))
        let midY = (topY + botY) / 2
        let leftX = max(0, min(imgW - 1, Int(r.minX.rounded())))
        let rightX = max(0, min(imgW - 1, Int(r.maxX.rounded())))
        let midX = (leftX + rightX) / 2

        let pts = [
            (leftX, topY), (midX, topY), (rightX, topY),
            (leftX, midY), (rightX, midY),
            (leftX, botY), (midX, botY), (rightX, botY)
        ]
        var rs: [Int] = [], gs: [Int] = [], bs: [Int] = []
        for (px, py) in pts {
            let c = sampler.sampleRGB(px: px, py: py)
            rs.append(c.0); gs.append(c.1); bs.append(c.2)
        }
        rs.sort(); gs.sort(); bs.sort()
        let m = rs.count / 2
        return (rs[m], gs[m], bs[m])
    }
}
