import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 截图文件保存格式（零第三方依赖，全部使用 macOS ImageIO 原生硬件编解码器）
public enum CaptureExportFormat: String, CaseIterable, Codable, Sendable {
    case png = "png"
    case jpeg = "jpg"
    case heic = "heic"

    public var fileExtension: String { rawValue }

    public var segmentTitle: String {
        switch self {
        case .png:  return "PNG"
        case .jpeg: return "JPG"
        case .heic: return "HEIC"
        }
    }

    public var utType: UTType {
        switch self {
        case .png:  return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        }
    }

    public var lossyQuality: CGFloat? {
        switch self {
        case .png:  return nil
        case .jpeg: return 0.90
        case .heic: return 0.86
        }
    }
}

/// 截图文件编码与可选 1× 逻辑倍率缩放管线（全程保留显示器原生 RGB ICC 色彩空间）
public enum CaptureImageExporter {
    /// 当开启 `exportAt1x` 且原图倍率 > 1× 时，按高质量采样缩至逻辑点尺寸（72 DPI），否则零拷贝直通原图
    public static func prepareImage(
        _ cgImage: CGImage,
        scaleFactor: CGFloat,
        exportAt1x: Bool
    ) -> (image: CGImage, effectiveScale: CGFloat) {
        let s = max(1.0, scaleFactor)
        guard exportAt1x, s > 1.05 else { return (cgImage, s) }
        let outW = max(1, Int((CGFloat(cgImage.width) / s).rounded()))
        let outH = max(1, Int((CGFloat(cgImage.height) / s).rounded()))
        guard outW < cgImage.width || outH < cgImage.height else { return (cgImage, s) }
        let cs = resolvedRGBColorSpace(from: cgImage)
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (cgImage, s) }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        guard let scaled = ctx.makeImage() else { return (cgImage, s) }
        return (scaled, 1.0)
    }

    /// 按指定格式编码图像数据（保留原生色域与逻辑 DPI；导出 JPEG 时自动为带透明通道的图片铺白底防黑边）
    public static func encode(
        cgImage: CGImage,
        scaleFactor: CGFloat,
        format: CaptureExportFormat,
        exportAt1x: Bool = false
    ) -> Data? {
        let prepared = prepareImage(cgImage, scaleFactor: scaleFactor, exportAt1x: exportAt1x)
        let targetImage: CGImage
        if format == .jpeg, hasAlphaChannel(prepared.image), let flattened = flattenOntoWhite(prepared.image) {
            targetImage = flattened
        } else {
            targetImage = prepared.image
        }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, format.utType.identifier as CFString, 1, nil) else {
            return nil
        }
        let dpi = 72.0 * max(1.0, Double(prepared.effectiveScale))
        var props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi
        ]
        if let q = format.lossyQuality {
            props[kCGImageDestinationLossyCompressionQuality] = q
        }
        CGImageDestinationAddImage(dest, targetImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    private static func resolvedRGBColorSpace(from image: CGImage) -> CGColorSpace {
        if let cs = image.colorSpace, cs.model == .rgb { return cs }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    private static func hasAlphaChannel(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .premultipliedFirst, .premultipliedLast, .first, .last: return true
        default: return false
        }
    }

    private static func flattenOntoWhite(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        let cs = resolvedRGBColorSpace(from: image)
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(colorSpace: cs, components: [1, 1, 1, 1]) ?? CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
