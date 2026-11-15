import Accelerate
import CoreGraphics
import Foundation

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
                  space: sRGBSpace,
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
            space: sRGBSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
