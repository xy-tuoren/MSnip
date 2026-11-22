import Accelerate
import CoreGraphics
import Foundation

/// OCR 识别图像预处理结果：包含自适应超分放大、同色延展留白后的高清图，以及用于将归一化框精确还原回原图的映射参数
public struct OCRPreprocessedImage: @unchecked Sendable {
    public let cgImage: CGImage
    public let upscaleFactor: CGFloat
    /// 原图内容区在增强图中的归一化矩形（Vision 左下角原点 `0..1`）
    public let contentNormalizedRect: CGRect

    /// 将 Vision 在增强图上返回的归一化边界框精确映射回原始截图坐标系（左下角原点 `0..1`）
    public func mapBoxBack(_ box: CGRect) -> CGRect {
        let cw = max(0.0001, contentNormalizedRect.width)
        let ch = max(0.0001, contentNormalizedRect.height)
        let x0 = (box.minX - contentNormalizedRect.minX) / cw
        let y0 = (box.minY - contentNormalizedRect.minY) / ch
        let x1 = (box.maxX - contentNormalizedRect.minX) / cw
        let y1 = (box.maxY - contentNormalizedRect.minY) / ch
        let cx0 = min(1.0, max(0.0, x0))
        let cy0 = min(1.0, max(0.0, y0))
        let cx1 = min(1.0, max(cx0, x1))
        let cy1 = min(1.0, max(cy0, y1))
        return CGRect(x: cx0, y: cy0, width: max(0.001, cx1 - cx0), height: max(0.001, cy1 - cy0))
    }
}

/// 纯原生零依赖 OCR 图像增强管线：
/// 1. 对 @1x 低分屏与小选区执行自适应 1.5×~2.5× 高质量双三次超分放大（上限 2400px 兼顾速度与内存）；
/// 2. 采样四边主底色并向外补足 20~28px 同色安全留白，彻底消除贴边字符漏识与首尾截断；
/// 3. 放大后执行硬件 SIMD (`vImageConvolve_ARGB8888`) 轻微边缘锐化，显著改善 `1/l/I`、`0/O` 与密集小号汉字识别率。
public enum OCRImagePreprocessor {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    public static func prepare(_ source: CGImage) -> OCRPreprocessedImage {
        let srcW = source.width
        let srcH = source.height
        guard srcW >= 4, srcH >= 4 else {
            return OCRPreprocessedImage(cgImage: source, upscaleFactor: 1.0, contentNormalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        }

        let longSide = max(srcW, srcH)
        let shortSide = min(srcW, srcH)
        let rawScale: CGFloat
        if shortSide < 90 || longSide < 420 {
            rawScale = 2.5
        } else if shortSide < 280 || longSide < 1100 {
            rawScale = 2.0
        } else if longSide < 1700 {
            rawScale = 1.5
        } else {
            rawScale = 1.0
        }
        let maxOutDim: CGFloat = 2400.0
        let cappedScale = min(rawScale, max(1.0, maxOutDim / CGFloat(longSide)))
        let scaledW = max(srcW, Int((CGFloat(srcW) * cappedScale).rounded()))
        let scaledH = max(srcH, Int((CGFloat(srcH) * cappedScale).rounded()))
        let pad = min(32, max(16, Int((CGFloat(min(scaledW, scaledH)) * 0.08).rounded())))

        let outW = scaledW + pad * 2
        let outH = scaledH + pad * 2
        let bg = sampleBorderBackground(source)

        guard let ctx = CGContext(
            data: nil,
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bytesPerRow: outW * 4,
            space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return OCRPreprocessedImage(cgImage: source, upscaleFactor: 1.0, contentNormalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        }

        ctx.setFillColor(CGColor(srgbRed: bg.r, green: bg.g, blue: bg.b, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
        ctx.interpolationQuality = .high
        ctx.draw(source, in: CGRect(x: pad, y: pad, width: scaledW, height: scaledH))

        let normRect = CGRect(
            x: CGFloat(pad) / CGFloat(outW),
            y: CGFloat(pad) / CGFloat(outH),
            width: CGFloat(scaledW) / CGFloat(outW),
            height: CGFloat(scaledH) / CGFloat(outH)
        )

        if cappedScale > 1.05, let sharpened = applyGentleSharpen(in: ctx, width: outW, height: outH) {
            return OCRPreprocessedImage(cgImage: sharpened, upscaleFactor: cappedScale, contentNormalizedRect: normRect)
        }
        guard let img = ctx.makeImage() else {
            return OCRPreprocessedImage(cgImage: source, upscaleFactor: 1.0, contentNormalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return OCRPreprocessedImage(cgImage: img, upscaleFactor: cappedScale, contentNormalizedRect: normRect)
    }

    /// 采样原图四边均匀 32 个边界点取中位色，保证暗色终端补深灰、白底文档补纯白
    private static func sampleBorderBackground(_ image: CGImage) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let sampler = PixelSampler(cgImage: image)
        let w = sampler.width, h = sampler.height
        guard w > 1, h > 1 else { return (1, 1, 1) }

        var rs: [Int] = []; var gs: [Int] = []; var bs: [Int] = []
        rs.reserveCapacity(32); gs.reserveCapacity(32); bs.reserveCapacity(32)
        let steps = 8
        for i in 0..<steps {
            let x = (w - 1) * i / max(1, steps - 1)
            let y = (h - 1) * i / max(1, steps - 1)
            for pt in [(x, 0), (x, h - 1), (0, y), (w - 1, y)] {
                let (r, g, b) = sampler.sampleRGB(px: pt.0, py: pt.1)
                rs.append(r); gs.append(g); bs.append(b)
            }
        }
        rs.sort(); gs.sort(); bs.sort()
        let mid = rs.count / 2
        return (CGFloat(rs[mid]) / 255.0, CGFloat(gs[mid]) / 255.0, CGFloat(bs[mid]) / 255.0)
    }

    /// 硬件 SIMD 温和 3×3 拉普拉斯锐化（强度 0.25，避免过锐白边同时增强细小笔画对比度）
    private static func applyGentleSharpen(in ctx: CGContext, width: Int, height: Int) -> CGImage? {
        guard let srcBase = ctx.data else { return nil }
        let rowBytes = ctx.bytesPerRow
        let total = rowBytes * height
        var outBuf = [UInt8](repeating: 255, count: total)

        var kernel: [Int16] = [
             0, -1,  0,
            -1, 12, -1,
             0, -1,  0
        ]
        let divisor: Int32 = 8

        let err: vImage_Error = outBuf.withUnsafeMutableBytes { dstRaw in
            guard let dstBase = dstRaw.baseAddress else { return kvImageNullPointerArgument }
            var srcV = vImage_Buffer(data: srcBase, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
            var dstV = vImage_Buffer(data: dstBase, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rowBytes)
            return vImageConvolve_ARGB8888(&srcV, &dstV, nil, 0, 0, &kernel, 3, 3, divisor, nil, vImage_Flags(kvImageEdgeExtend))
        }
        guard err == kvImageNoError else { return nil }

        // 还原不透明 Alpha（卷积通道对全 255 保持不变，但显式锁死避免浮点边角误差）
        let pixelCount = width * height
        outBuf.withUnsafeMutableBufferPointer { buf in
            guard let p = buf.baseAddress else { return }
            for i in 0..<pixelCount { p[i * 4 + 3] = 255 }
        }

        guard let provider = CGDataProvider(data: Data(outBuf) as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
            space: sRGB,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
