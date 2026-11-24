import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 设置与结果面板的全局外观模式（跟随系统 / 明亮 / 暗黑）
public enum AppAppearanceMode: String, CaseIterable, Codable, Sendable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    public var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "明亮"
        case .dark:   return "暗黑"
        }
    }
}

/// 一键截取当前全屏后的默认动作
public enum FullScreenCaptureAction: String, CaseIterable, Codable, Sendable {
    case copy = "copy"
    case save = "save"
    case copyAndSave = "copyAndSave"

    public var title: String {
        switch self {
        case .copy:        return "仅复制"
        case .save:        return "仅保存"
        case .copyAndSave: return "复制并保存"
        }
    }
}

/// 延时截图秒数规范与文本解析辅助（支持 1–60 秒自定义，菜单快捷档位 3 / 5 / 10 秒）
public enum DelayedCaptureSettings {
    public static let defaultSeconds = 3
    public static let minSeconds = 1
    public static let maxSeconds = 60
    public static let quickPresets = [3, 5, 10]

    public static func clampedSeconds(_ value: Int) -> Int {
        min(maxSeconds, max(minSeconds, value))
    }

    public static func parseSeconds(_ raw: String, fallback: Int = defaultSeconds) -> Int {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "秒", with: "")
            .replacingOccurrences(of: "s", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(cleaned) else { return clampedSeconds(fallback) }
        return clampedSeconds(parsed)
    }
}

/// 截图文件保存格式（零第三方依赖，按当前 macOS `ImageIO` 能力运行时动态探测并优雅兜底，100% 兼容 macOS 12.0+）
public enum CaptureExportFormat: String, CaseIterable, Codable, Sendable {
    case png = "png"
    case jpeg = "jpg"
    case heic = "heic"
    case avif = "avif"
    case bmp = "bmp"
    case tiff = "tiff"

    private static let supportedDestinationUTIs: Set<String> = {
        let raw = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return Set(raw.map { $0.lowercased() })
    }()

    /// 当前运行系统原生 ImageIO 实际支持编码的格式列表（例如 macOS 12 自动隐藏 AVIF，macOS 13/14+ 自动显示）
    public static var supportedFormats: [CaptureExportFormat] {
        let available = allCases.filter(\.isSupportedOnCurrentOS)
        return available.isEmpty ? [.png, .jpeg] : available
    }

    public var utiIdentifier: String {
        switch self {
        case .png:  return "public.png"
        case .jpeg: return "public.jpeg"
        case .heic: return "public.heic"
        case .avif: return "public.avif"
        case .bmp:  return "com.microsoft.bmp"
        case .tiff: return "public.tiff"
        }
    }

    public var isSupportedOnCurrentOS: Bool {
        Self.supportedDestinationUTIs.contains(utiIdentifier)
    }

    /// 若配置文件同步自高版本系统且当前旧版 macOS 不支持该格式，自动回退为 PNG
    public var resolvedForCurrentOS: CaptureExportFormat {
        isSupportedOnCurrentOS ? self : .png
    }

    public var fileExtension: String { rawValue }

    public var segmentTitle: String {
        switch self {
        case .png:  return "PNG"
        case .jpeg: return "JPG"
        case .heic: return "HEIC"
        case .avif: return "AVIF"
        case .bmp:  return "BMP"
        case .tiff: return "TIFF"
        }
    }

    public var menuTitle: String {
        switch self {
        case .png:  return "PNG · 无损原图"
        case .jpeg: return "JPG · 通用高压缩"
        case .heic: return "HEIC · 苹果高压缩"
        case .avif: return "AVIF · 极致高压缩"
        case .bmp:  return "BMP · 原始位图"
        case .tiff: return "TIFF · 印刷无损"
        }
    }

    public var utType: UTType {
        UTType(utiIdentifier) ?? .png
    }

    public var lossyQuality: CGFloat? {
        switch self {
        case .png, .bmp, .tiff: return nil
        case .jpeg: return 0.90
        case .heic: return 0.86
        case .avif: return 0.84
        }
    }

    public var requiresOpaqueBackground: Bool {
        self == .jpeg || self == .bmp
    }

    public static func from(fileExtension ext: String) -> CaptureExportFormat? {
        switch ext.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "png":         return .png
        case "jpg", "jpeg": return .jpeg
        case "heic", "heif": return .heic
        case "avif":        return .avif
        case "bmp":         return .bmp
        case "tif", "tiff": return .tiff
        default:            return nil
        }
    }
}

/// 截图文件编码与可选 1× 逻辑倍率缩放管线（全程保留显示器原生 RGB ICC 色彩空间，不支持格式自动安全回退 PNG）
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

    /// 编码图像并返回实际生效的格式（若目标格式在老系统或特定硬件上编码失败，自动安全回退为 PNG）
    public static func encodeWithFallback(
        cgImage: CGImage,
        scaleFactor: CGFloat,
        format: CaptureExportFormat,
        exportAt1x: Bool = false
    ) -> (data: Data, actualFormat: CaptureExportFormat)? {
        let prepared = prepareImage(cgImage, scaleFactor: scaleFactor, exportAt1x: exportAt1x)
        let resolved = format.resolvedForCurrentOS
        if let encoded = encodePrepared(prepared.image, effectiveScale: prepared.effectiveScale, format: resolved) {
            return (encoded, resolved)
        }
        if resolved != .png, let fallback = encodePrepared(prepared.image, effectiveScale: prepared.effectiveScale, format: .png) {
            return (fallback, .png)
        }
        return nil
    }

    public static func encode(
        cgImage: CGImage,
        scaleFactor: CGFloat,
        format: CaptureExportFormat,
        exportAt1x: Bool = false
    ) -> Data? {
        encodeWithFallback(cgImage: cgImage, scaleFactor: scaleFactor, format: format, exportAt1x: exportAt1x)?.data
    }

    private static func encodePrepared(
        _ image: CGImage,
        effectiveScale: CGFloat,
        format: CaptureExportFormat
    ) -> Data? {
        let targetImage: CGImage
        if format.requiresOpaqueBackground, hasAlphaChannel(image), let flattened = flattenOntoWhite(image) {
            targetImage = flattened
        } else {
            targetImage = image
        }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, format.utiIdentifier as CFString, 1, nil) else {
            return nil
        }
        let dpi = 72.0 * max(1.0, Double(effectiveScale))
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
