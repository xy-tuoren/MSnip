import CoreGraphics
import Foundation

/// 单行一维多点像素特征签名（兼顾 O(H) 极速比对与水平多列防重名）
struct ScrollRowSig {
    var luma: Int32      // 0...1020
    var grad: Int32      // 行水平边缘梯度能量
    var c0: SIMD3<Int16> // 4 个水平检查点 RGB
    var c1: SIMD3<Int16>
    var c2: SIMD3<Int16>
    var c3: SIMD3<Int16>

    @inline(__always)
    func diff(to other: ScrollRowSig) -> Int32 {
        let dl = abs(luma - other.luma) >> 2
        let dg = abs(grad - other.grad) >> 1
        let dc0 = abs(Int32(c0.x - other.c0.x)) + abs(Int32(c0.y - other.c0.y)) + abs(Int32(c0.z - other.c0.z))
        let dc1 = abs(Int32(c1.x - other.c1.x)) + abs(Int32(c1.y - other.c1.y)) + abs(Int32(c1.z - other.c1.z))
        let dc2 = abs(Int32(c2.x - other.c2.x)) + abs(Int32(c2.y - other.c2.y)) + abs(Int32(c2.z - other.c2.z))
        let dc3 = abs(Int32(c3.x - other.c3.x)) + abs(Int32(c3.y - other.c3.y)) + abs(Int32(c3.z - other.c3.z))
        return dl + dg + ((dc0 + dc1 + dc2 + dc3) / 12)
    }
}

struct ScrollFrameDigest {
    let image: CGImage
    let sampler: PixelSampler
    let rows: [ScrollRowSig]

    static func build(for image: CGImage) -> ScrollFrameDigest {
        let sampler = PixelSampler(cgImage: image)
        let w = sampler.width, h = sampler.height
        let rightMargin = min(max(8, w / 22), 36)
        let x0 = min(4, w / 10)
        let x1 = max(x0 + 4, w - rightMargin)
        let span = max(1, x1 - x0)
        let cp0 = x0 + span * 18 / 100
        let cp1 = x0 + span * 40 / 100
        let cp2 = x0 + span * 62 / 100
        let cp3 = x0 + span * 84 / 100
        let stepX = max(2, span / 48)

        var sigs: [ScrollRowSig] = []
        sigs.reserveCapacity(h)

        for y in 0..<h {
            var lumaSum: Int32 = 0
            var gradSum: Int32 = 0
            var count: Int32 = 0
            var prevL: Int32?
            var x = x0
            while x < x1 {
                let (r, g, b) = sampler.sampleRGB(px: x, py: y)
                let l = Int32(r + (g << 1) + b)
                lumaSum += l
                if let pl = prevL { gradSum += abs(l - pl) }
                prevL = l
                count += 1
                x += stepX
            }
            let p0 = sampler.sampleRGB(px: cp0, py: y)
            let p1 = sampler.sampleRGB(px: cp1, py: y)
            let p2 = sampler.sampleRGB(px: cp2, py: y)
            let p3 = sampler.sampleRGB(px: cp3, py: y)
            sigs.append(ScrollRowSig(
                luma: count > 0 ? (lumaSum / count) : 0,
                grad: count > 1 ? (gradSum / (count - 1)) : 0,
                c0: SIMD3(Int16(p0.0), Int16(p0.1), Int16(p0.2)),
                c1: SIMD3(Int16(p1.0), Int16(p1.1), Int16(p1.2)),
                c2: SIMD3(Int16(p2.0), Int16(p2.1), Int16(p2.2)),
                c3: SIMD3(Int16(p3.0), Int16(p3.1), Int16(p3.2))
            ))
        }
        return ScrollFrameDigest(image: image, sampler: sampler, rows: sigs)
    }

    /// 识别顶/底连续未变化区：返回用于匹配排他区的 `(matchTop, matchBottom)` 及真正含固定控件的 `(stickyTop, stickyBottom)`
    static func detectStaticMargins(
        a: [ScrollRowSig],
        b: [ScrollRowSig],
        height: Int
    ) -> (matchTop: Int, matchBottom: Int, stickyTop: Int, stickyBottom: Int) {
        let limit = height * 40 / 100

        var topEnd = 0
        var hasTopTexture = false
        for y in 0..<limit {
            if a[y].diff(to: b[y]) <= 5 {
                topEnd = y + 1
                if a[y].grad >= 3 { hasTopTexture = true }
            } else {
                break
            }
        }

        var botCount = 0
        var hasBotTexture = false
        for offset in 0..<limit {
            let y = height - 1 - offset
            if a[y].diff(to: b[y]) <= 5 {
                botCount = offset + 1
                if a[y].grad >= 3 { hasBotTexture = true }
            } else {
                break
            }
        }
        if topEnd > 0, topEnd < height, abs(a[topEnd - 1].luma - a[topEnd].luma) >= 24 {
            hasTopTexture = true
        }
        let botEdgeY = height - botCount
        if botCount > 0, botEdgeY > 0, abs(a[botEdgeY].luma - a[botEdgeY - 1].luma) >= 24 {
            hasBotTexture = true
        }

        return (
            matchTop: topEnd,
            matchBottom: botCount,
            stickyTop: hasTopTexture ? topEnd : 0,
            stickyBottom: hasBotTexture ? botCount : 0
        )
    }

    static func verify2DOverlap(
        anchor: PixelSampler,
        curr: PixelSampler,
        width: Int,
        workTop: Int,
        workBottom: Int,
        dy: Int
    ) -> Bool {
        let startY = max(workTop, workTop - dy)
        let endY = min(workBottom, workBottom - dy)
        guard endY - startY >= 20 else { return false }
        let usableW = max(16, width - min(max(8, width / 22), 36))
        let xs = [usableW * 15 / 100, usableW * 32 / 100, usableW * 50 / 100, usableW * 68 / 100, usableW * 85 / 100]
        let stepY = max(2, (endY - startY) / 28)

        var errSum = 0
        var samples = 0
        var cy = startY
        while cy < endY {
            let ay = cy + dy
            for x in xs {
                let pa = anchor.sampleRGB(px: x, py: ay)
                let pc = curr.sampleRGB(px: x, py: cy)
                errSum += abs(pa.0 - pc.0) + abs(pa.1 - pc.1) + abs(pa.2 - pc.2)
                samples += 3
            }
            cy += stepY
        }
        guard samples > 0 else { return false }
        return Double(errSum) / Double(samples) <= 12.0
    }

    /// 将裁剪区域拷贝至独立内存位图，立即释放 SCStream 的底层 IOSurface 缓冲池
    static func detachCopy(_ src: CGImage, rect: CGRect) -> CGImage? {
        guard let cropped = src.cropping(to: rect), cropped.width > 0, cropped.height > 0 else { return nil }
        let w = cropped.width, h = cropped.height
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
