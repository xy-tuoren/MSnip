import CoreGraphics
import Foundation

/// 单行 6 分区抗亚像素抖动特征签名：
/// - 纵向经过 `[1, 2, 1]/4` 平滑，彻底消除 `@1x` (1080p) 平滑滚动 `0.5px` 抗锯齿闪烁；
/// - 配合 `detectActiveBands` 自动剥离未滚动的左/右侧固定目录栏或 Minimap，同时保留正文区全部水平特征防跨页误配。
struct ScrollRowSig {
    var luma: Int32
    var grad: Int32
    var bands: SIMD8<Int16>  // 槽 0..5: 6 个水平分区的平滑亮度 (0..1020)
    var chroma: SIMD8<Int16> // 槽 0..5: 6 个水平分区的平滑红蓝差色度

    @inline(__always)
    func fullDiff(to other: ScrollRowSig) -> Int32 {
        maskedDiff(to: other, activeMask: 0b111111, activeCount: 6)
    }

    @inline(__always)
    func maskedDiff(to other: ScrollRowSig, activeMask: UInt8, activeCount: Int32) -> Int32 {
        var bSum: Int32 = 0
        var cSum: Int32 = 0
        for i in 0..<6 where (activeMask & (1 << i)) != 0 {
            bSum += Int32(abs(bands[i] - other.bands[i]))
            cSum += Int32(abs(chroma[i] - other.chroma[i]))
        }
        let denom = max(1, activeCount)
        let meanBand = bSum / (denom * 3)
        let meanChroma = cSum / (denom * 3)
        let dg = abs(grad - other.grad) >> 1
        return meanBand + meanChroma + dg
    }
}

struct ScrollFrameDigest {
    let image: CGImage
    let sampler: PixelSampler
    let rows: [ScrollRowSig]

    static func build(for image: CGImage, detach: Bool = false) -> ScrollFrameDigest {
        let owned = detach
            ? (detachCopy(image, rect: CGRect(x: 0, y: 0, width: image.width, height: image.height)) ?? image)
            : image
        let sampler = PixelSampler(cgImage: owned)
        let w = sampler.width, h = sampler.height
        let rightMargin = min(max(10, w / 18), 42)
        let x0 = min(4, w / 16)
        let x1 = max(x0 + 12, w - rightMargin)
        let span = max(6, x1 - x0)

        var rawBands = [[Int32]](repeating: [Int32](repeating: 0, count: 6), count: h)
        var rawChroma = [[Int32]](repeating: [Int32](repeating: 0, count: 6), count: h)
        var rawGrad = [Int32](repeating: 0, count: h)
        var rawLuma = [Int32](repeating: 0, count: h)

        for y in 0..<h {
            var gradSum: Int32 = 0
            var gradCnt: Int32 = 0
            var lumaSum: Int32 = 0
            var prevL: Int32?

            for b in 0..<6 {
                let bx0 = x0 + span * b / 6
                let bx1 = x0 + span * (b + 1) / 6
                let bSpan = max(1, bx1 - bx0)
                var bSum: Int32 = 0
                var cSum: Int32 = 0
                for s in 0..<4 {
                    let px = bx0 + bSpan * (s * 2 + 1) / 8
                    let (r, g, bl) = sampler.sampleRGB(px: px, py: y)
                    let l = Int32(r + (g << 1) + bl)
                    bSum += l
                    cSum += Int32(r - bl) + Int32(g - bl)
                    lumaSum += l
                    if let pl = prevL { gradSum += abs(l - pl); gradCnt += 1 }
                    prevL = l
                }
                rawBands[y][b] = bSum >> 2
                rawChroma[y][b] = cSum >> 2
            }
            rawLuma[y] = lumaSum / 24
            rawGrad[y] = gradCnt > 0 ? (gradSum / gradCnt) : 0
        }

        // 纵向 [1, 2, 1] / 4 平滑，抑制 @1x 屏幕亚像素抗锯齿跳变，同时保留单像素峰值定位
        var sigs: [ScrollRowSig] = []
        sigs.reserveCapacity(h)
        for y in 0..<h {
            let ym = max(0, y - 1), yp = min(h - 1, y + 1)
            var sb = SIMD8<Int16>()
            var sc = SIMD8<Int16>()
            for k in 0..<6 {
                sb[k] = Int16(clamping: (rawBands[ym][k] + (rawBands[y][k] << 1) + rawBands[yp][k]) >> 2)
                sc[k] = Int16(clamping: (rawChroma[ym][k] + (rawChroma[y][k] << 1) + rawChroma[yp][k]) >> 2)
            }
            let sl = (rawLuma[ym] + (rawLuma[y] << 1) + rawLuma[yp]) >> 2
            let sg = (rawGrad[ym] + (rawGrad[y] << 1) + rawGrad[yp]) >> 2
            sigs.append(ScrollRowSig(luma: sl, grad: sg, bands: sb, chroma: sc))
        }
        return ScrollFrameDigest(image: owned, sampler: sampler, rows: sigs)
    }

    /// 自动识别在两帧之间实际发生滚动变化的水平分区掩码（自动排除左侧固定目录栏或右侧静态边栏）
    static func detectActiveBands(
        a: [ScrollRowSig],
        b: [ScrollRowSig],
        workTop: Int,
        workBottom: Int
    ) -> (mask: UInt8, count: Int32) {
        let spanH = max(1, workBottom - workTop)
        var mask: UInt8 = 0
        var count: Int32 = 0
        for i in 0..<6 {
            var changedRows = 0
            for y in workTop..<workBottom {
                let db = abs(Int32(a[y].bands[i] - b[y].bands[i]))
                let dc = abs(Int32(a[y].chroma[i] - b[y].chroma[i]))
                if db > 10 || dc > 10 { changedRows += 1 }
            }
            // 若该纵向条带有 >= 6% 的行发生变化，则属于正在滚动的正文列；否则为静态侧边栏
            if changedRows * 100 >= spanH * 6 {
                mask |= (1 << i)
                count += 1
            }
        }
        if count == 0 { return (0b111111, 6) }
        return (mask, count)
    }

    /// 识别顶/底连续未变化区：仅当静态带内部具备足够 UI 纹理行时才认定为 Sticky 固定栏（防止将段落留白误锁为导航栏）
    static func detectStaticMargins(
        a: [ScrollRowSig],
        b: [ScrollRowSig],
        height: Int
    ) -> (matchTop: Int, matchBottom: Int, stickyTop: Int, stickyBottom: Int) {
        let limit = height * 28 / 100

        var topEnd = 0
        var topTexturedRows = 0
        for y in 0..<limit {
            if a[y].fullDiff(to: b[y]) <= 6 {
                topEnd = y + 1
                if a[y].grad >= 4 { topTexturedRows += 1 }
            } else { break }
        }

        var botCount = 0
        var botTexturedRows = 0
        for offset in 0..<limit {
            let y = height - 1 - offset
            if a[y].fullDiff(to: b[y]) <= 6 {
                botCount = offset + 1
                if a[y].grad >= 4 { botTexturedRows += 1 }
            } else { break }
        }

        let isTrueStickyTop = topEnd >= 10 && topTexturedRows >= max(3, topEnd / 10)
        let isTrueStickyBot = botCount >= 10 && botTexturedRows >= max(3, botCount / 10)

        return (
            matchTop: topEnd,
            matchBottom: botCount,
            stickyTop: isTrueStickyTop ? topEnd : 0,
            stickyBottom: isTrueStickyBot ? botCount : 0
        )
    }

    /// 二维像素验证：仅在活跃滚动列内抽检，支持 `±1px` 亚像素插值容差，确保跨页空白不会误匹配
    static func verify2DOverlap(
        anchor: PixelSampler,
        curr: PixelSampler,
        width: Int,
        height: Int,
        workTop: Int,
        workBottom: Int,
        dy: Int,
        activeMask: UInt8
    ) -> Bool {
        let startY = max(workTop, workTop - dy)
        let endY = min(workBottom, workBottom - dy)
        guard endY - startY >= 16 else { return false }

        let rightMargin = min(max(10, width / 18), 42)
        let x0 = min(4, width / 16)
        let span = max(12, max(x0 + 12, width - rightMargin) - x0)

        var xs: [Int] = []
        for b in 0..<6 where (activeMask & (1 << b)) != 0 {
            xs.append(x0 + span * (b * 2 + 1) / 12)
            xs.append(x0 + span * (b * 2 + 1) / 12 + max(2, span / 24))
        }
        if xs.isEmpty { xs = [width * 30 / 100, width * 50 / 100, width * 70 / 100] }

        let stepY = max(1, (endY - startY) / 36)
        var totalErr: Double = 0
        var samples = 0
        var cy = startY
        while cy < endY {
            let ay = cy + dy
            let ayPrev = max(0, ay - 1)
            let ayNext = min(height - 1, ay + 1)
            for x in xs {
                let pc = curr.sampleRGB(px: x, py: cy)
                let p0 = anchor.sampleRGB(px: x, py: ay)
                let e0 = abs(p0.0 - pc.0) + abs(p0.1 - pc.1) + abs(p0.2 - pc.2)
                if e0 <= 9 {
                    totalErr += Double(e0)
                } else {
                    let pPrev = anchor.sampleRGB(px: x, py: ayPrev)
                    let pNext = anchor.sampleRGB(px: x, py: ayNext)
                    let ePrev = abs(pPrev.0 - pc.0) + abs(pPrev.1 - pc.1) + abs(pPrev.2 - pc.2) + 3
                    let eNext = abs(pNext.0 - pc.0) + abs(pNext.1 - pc.1) + abs(pNext.2 - pc.2) + 3
                    let eMid = abs(((p0.0 + pNext.0) >> 1) - pc.0)
                        + abs(((p0.1 + pNext.1) >> 1) - pc.1)
                        + abs(((p0.2 + pNext.2) >> 1) - pc.2) + 2
                    totalErr += Double(min(min(e0, eMid), min(ePrev, eNext)))
                }
                samples += 3
            }
            cy += stepY
        }
        guard samples > 0 else { return false }
        return (totalErr / Double(samples)) <= 16.0
    }

    private static func resolvedColorSpace(for image: CGImage?) -> CGColorSpace {
        if let cs = image?.colorSpace, cs.model == .rgb { return cs }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    static func detachCopy(_ src: CGImage, rect: CGRect) -> CGImage? {
        guard let cropped = src.cropping(to: rect), cropped.width > 0, cropped.height > 0 else { return nil }
        let w = cropped.width, h = cropped.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: resolvedColorSpace(for: src), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func makePreviewSlice(_ src: CGImage, maxWidthPx: Int = 340) -> CGImage {
        guard src.width > maxWidthPx else { return src }
        let ratio = CGFloat(maxWidthPx) / CGFloat(src.width)
        let ph = max(1, Int((CGFloat(src.height) * ratio).rounded()))
        guard let ctx = CGContext(
            data: nil, width: maxWidthPx, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
            space: resolvedColorSpace(for: src), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return src }
        ctx.interpolationQuality = .medium
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: maxWidthPx, height: ph))
        return ctx.makeImage() ?? src
    }

    static func composeStrips(
        widthPx fullW: Int,
        totalHeightPx fullH: Int,
        strips: [CGImage],
        previewStrips: [CGImage],
        footer: CGImage?,
        previewFooter: CGImage?,
        scaleDownToMaxSide: Int?,
        usePreviewSlices: Bool
    ) -> CGImage? {
        guard fullW > 0, fullH > 0 else { return nil }
        var scale: CGFloat = 1.0
        if let maxSide = scaleDownToMaxSide, max(fullW, fullH) > maxSide {
            scale = CGFloat(maxSide) / CGFloat(max(fullW, fullH))
        }
        let outW = max(1, Int((CGFloat(fullW) * scale).rounded()))
        let outH = max(1, Int((CGFloat(fullH) * scale).rounded()))
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
            space: resolvedColorSpace(for: strips.first ?? footer), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = scale < 1.0 ? .medium : .none
        var cursorTopPx = 0
        for i in strips.indices {
            let ph = strips[i].height
            let tex = (usePreviewSlices && previewStrips.indices.contains(i)) ? previewStrips[i] : strips[i]
            let dstY = CGFloat(fullH - cursorTopPx - ph) * scale
            ctx.draw(tex, in: CGRect(x: 0, y: dstY, width: CGFloat(outW), height: CGFloat(ph) * scale))
            cursorTopPx += ph
        }
        if let footer {
            let ph = footer.height
            let tex = (usePreviewSlices ? previewFooter : nil) ?? footer
            let dstY = CGFloat(fullH - cursorTopPx - ph) * scale
            ctx.draw(tex, in: CGRect(x: 0, y: dstY, width: CGFloat(outW), height: CGFloat(ph) * scale))
        }
        return ctx.makeImage()
    }
}
