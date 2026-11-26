import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import MSnipCore
import UniformTypeIdentifiers

/// 常用快捷保存目录描述符
struct QuickSaveFolder: Equatable {
    let title: String
    let path: String
    let symbol: String
    let isDefault: Bool
}

/// 剪贴板读写、临时拖拽文件生成与 PNG / 动图导出工具
enum ClipboardAndSave {
    /// 将纯文本（如色值、坐标、OCR 识别结果）写入系统剪贴板
    static func copyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// 从剪贴板文本尝试解析颜色值（支持 `#RRGGBB` / `#RGB` / `rgb(r, g, b)`）
    static func readColorFromClipboard() -> RGBAColor? {
        guard let str = NSPasteboard.general.string(forType: .string) else { return nil }
        return RGBAColor.parseColorString(str)
    }

    /// 从剪贴板读取非空纯文本（供贴图快捷键直接生成置顶文本便签卡）
    static func readTextFromClipboard() -> String? {
        guard let str = NSPasteboard.general.string(forType: .string) else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : str
    }

    /// 将 `CGImage` 编码为保留逻辑 DPI 尺寸的 PNG 数据
    static func encodePNG(cgImage: CGImage, scaleFactor: CGFloat) -> Data? {
        ClipboardImagePromise.encodePNG(cgImage: cgImage, scaleFactor: scaleFactor)
    }

    /// 将 Retina 高清 `CGImage` 零阻塞写入系统剪贴板（切到终端/访达时自动动态适配路径与文件 URL，切回普通应用保持纯净图像）
    @MainActor
    static func copyToClipboard(cgImage: CGImage, scaleFactor: CGFloat, forceIncludePath: Bool = false) {
        SmartClipboardProjectionManager.shared.writeImage(cgImage, scaleFactor: scaleFactor, forceIncludePath: forceIncludePath)
    }

    /// 在访达中打开并高亮定位目标文件（先在点击事件上下文内激活应用，再显式置顶 Finder 突破 macOS 14+ 后台焦点拦截）
    @MainActor
    static func revealInFinder(_ fileURL: URL) {
        NSApp.activate(ignoringOtherApps: true)
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        let bringFinderFront: @MainActor @Sendable () -> Void = {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder") {
                _ = app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            }
        }
        bringFinderFront()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: bringFinderFront)
    }

    /// 将本地媒体文件（如录制的 `.gif` / `.mp4`）写入剪贴板，支持直接粘贴到微信/飞书/Slack/Finder
    static func copyMediaFileToClipboard(fileURL: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([fileURL as NSURL])
    }

    /// 生成供贴图拖拽直投外部应用（微信/飞书/浏览器/Finder）的临时高清 PNG 文件（自动清理超过 2 小时的旧临时项）
    static func writeTempPNGFile(cgImage: CGImage, scaleFactor: CGFloat, prefix: String = "MSnip-Pin") -> URL? {
        guard let pngData = encodePNG(cgImage: cgImage, scaleFactor: scaleFactor) else { return nil }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("MSnipDrag", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        if let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let cutoff = Date().addingTimeInterval(-7200)
            for u in urls {
                if let mtime = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                   mtime < cutoff {
                    try? fm.removeItem(at: u)
                }
            }
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss-SSS"
        let outURL = dir.appendingPathComponent("\(prefix)-\(formatter.string(from: Date())).png")
        do {
            try pngData.write(to: outURL, options: .atomic)
            return outURL
        } catch {
            return nil
        }
    }

    /// 从剪贴板读取图片（用于桌面按 `⌘2` 触发剪贴板贴图）
    static func readImageFromClipboard() -> NSImage? {
        let pb = NSPasteboard.general
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let first = images.first, first.isValid {
            return first
        }
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
           let img = NSImage(data: data), img.isValid {
            return img
        }
        return nil
    }

    /// 解析免弹窗快存目录（优先使用已配置的保存目录，否则默认归档至 `~/Pictures/MSnip`）
    static func resolveQuickSaveDirectory(preferred: String?) -> URL {
        let fm = FileManager.default
        if let dir = preferred, !dir.isEmpty, fm.fileExists(atPath: dir) {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        let pictures = fm.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures", isDirectory: true)
        let target = pictures.appendingPathComponent("MSnip", isDirectory: true)
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    /// 组装去重后的常用快捷保存目录（默认目录 + 桌面/下载/图片/文稿 + 最近选过的自定义目录）
    static func quickSaveFolders(preferred: String?, recent: [String]) -> [QuickSaveFolder] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [QuickSaveFolder] = []

        func appendIfValid(title: String, url: URL, symbol: String, isDefault: Bool = false) {
            let std = url.standardizedFileURL.path
            guard !seen.contains(std) else { return }
            if !isDefault && !fm.fileExists(atPath: std) { return }
            seen.insert(std)
            result.append(QuickSaveFolder(title: title, path: std, symbol: symbol, isDefault: isDefault))
        }

        let defURL = resolveQuickSaveDirectory(preferred: preferred)
        appendIfValid(title: "默认 · \(defURL.lastPathComponent)", url: defURL, symbol: "star.fill", isDefault: true)

        let stdSpecs: [(FileManager.SearchPathDirectory, String, String)] = [
            (.desktopDirectory, "桌面", "menubar.dock.rectangle"),
            (.downloadsDirectory, "下载", "arrow.down.circle"),
            (.picturesDirectory, "图片", "photo"),
            (.documentDirectory, "文稿", "doc")
        ]
        for (dir, label, sym) in stdSpecs {
            if let u = fm.urls(for: dir, in: .userDomainMask).first {
                appendIfValid(title: label, url: u, symbol: sym)
            }
        }
        var extraAdded = 0
        for p in recent where extraAdded < 3 {
            let u = URL(fileURLWithPath: p, isDirectory: true)
            let before = result.count
            appendIfValid(title: u.lastPathComponent, url: u, symbol: "folder")
            if result.count > before { extraAdded += 1 }
        }
        return result
    }

    /// 播放 macOS 系统内置轻量提示音（零外部音频资源文件）
    @MainActor
    static func playFeedbackSound(enabled: Bool) {
        guard enabled else { return }
        if let snd = NSSound(named: NSSound.Name("Tink")) ?? NSSound(named: NSSound.Name("Pop")) {
            snd.volume = 0.45
            snd.play()
        }
    }

    /// 免弹窗一键快存高清图片至指定目录（按配置导出 PNG / JPG / HEIC / AVIF / BMP / TIFF、自定义文件名模板及可选 1× 倍率）
    static func quickSavePNG(
        cgImage: CGImage,
        scaleFactor: CGFloat,
        preferredDirectory: String?,
        format: CaptureExportFormat = .png,
        exportAt1x: Bool = false,
        filenameTemplate: String = SaveFilenameTemplate.defaultTemplate
    ) -> URL? {
        let dirURL = resolveQuickSaveDirectory(preferred: preferredDirectory)
        return quickSavePNG(
            cgImage: cgImage, scaleFactor: scaleFactor, intoDirectory: dirURL,
            format: format, exportAt1x: exportAt1x, filenameTemplate: filenameTemplate
        )
    }

    static func quickSavePNG(
        cgImage: CGImage,
        scaleFactor: CGFloat,
        intoDirectory dirURL: URL,
        format: CaptureExportFormat = .png,
        exportAt1x: Bool = false,
        filenameTemplate: String = SaveFilenameTemplate.defaultTemplate
    ) -> URL? {
        guard let result = CaptureImageExporter.encodeWithFallback(
            cgImage: cgImage, scaleFactor: scaleFactor, format: format, exportAt1x: exportAt1x
        ) else { return nil }
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        let fileName = SaveFilenameTemplate.render(
            template: filenameTemplate,
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height,
            fileExtension: result.actualFormat.fileExtension,
            appendMillisIfNoMillis: true
        )
        let outURL = dirURL.appendingPathComponent(fileName)
        do {
            try result.data.write(to: outURL, options: .atomic)
            return outURL
        } catch {
            return nil
        }
    }

    /// 弹出原生保存对话框（支持切换任意目录、修改后缀格式 PNG/JPG/HEIC/AVIF/BMP/TIFF 或文件名），成功返回保存后的文件 `URL` 与所在目录路径
    @MainActor
    static func savePNGInteractive(
        cgImage: CGImage,
        scaleFactor: CGFloat,
        initialDirectory: String?,
        format: CaptureExportFormat = .png,
        exportAt1x: Bool = false,
        filenameTemplate: String = SaveFilenameTemplate.defaultTemplate
    ) -> (url: URL, dir: String)? {
        let effectiveDefault = format.resolvedForCurrentOS
        let defaultName = SaveFilenameTemplate.render(
            template: filenameTemplate,
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height,
            fileExtension: effectiveDefault.fileExtension,
            appendMillisIfNoMillis: false
        )

        let panel = NSSavePanel()
        panel.title = "保存截图"
        panel.nameFieldStringValue = defaultName
        let supported = CaptureExportFormat.supportedFormats
        panel.allowedContentTypes = [effectiveDefault.utType] + supported.filter { $0 != effectiveDefault }.map(\.utType)
        panel.canCreateDirectories = true
        panel.level = .modalPanel
        panel.directoryURL = resolveQuickSaveDirectory(preferred: initialDirectory)

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }
        let requestedFmt = CaptureExportFormat.from(fileExtension: url.pathExtension) ?? effectiveDefault
        guard let result = CaptureImageExporter.encodeWithFallback(
            cgImage: cgImage, scaleFactor: scaleFactor, format: requestedFmt, exportAt1x: exportAt1x
        ) else { return nil }
        let finalURL: URL = (result.actualFormat != requestedFmt)
            ? url.deletingPathExtension().appendingPathExtension(result.actualFormat.fileExtension)
            : url
        do {
            try result.data.write(to: finalURL, options: .atomic)
            return (finalURL, finalURL.deletingLastPathComponent().standardizedFileURL.path)
        } catch {
            let alert = NSAlert()
            alert.messageText = "保存图片失败"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
            return nil
        }
    }
}

// MARK: - 录屏媒体异步微缩略图加载器

/// 视频（MP4/MOV）与动图/静图异步离主线程首帧缩略图加载器（有界正/负缓存，零阻塞主线程，杜绝坏文件死循环）
@MainActor
enum MediaThumbnailLoader {
    private static let maxCached = 16
    private static let maxFailed = 32
    private static let retryCooldown: TimeInterval = 30.0
    private static let decodeMaxPixel = 480

    private static var cache: [String: NSImage] = [:]
    private static var cacheOrder: [String] = []
    private static var failedAt: [String: TimeInterval] = [:]
    private static var inFlight: [String: [@MainActor (NSImage?) -> Void]] = [:]

    static func cachedThumbnail(for url: URL) -> NSImage? {
        cache[url.standardizedFileURL.path]
    }

    static func invalidate(url: URL) {
        let key = url.standardizedFileURL.path
        cache.removeValue(forKey: key)
        cacheOrder.removeAll { $0 == key }
        failedAt.removeValue(forKey: key)
    }

    static func loadThumbnail(
        for url: URL,
        completion: @escaping @MainActor (NSImage?) -> Void
    ) {
        let key = url.standardizedFileURL.path
        if let hit = cache[key] { completion(hit); return }
        let now = ProcessInfo.processInfo.systemUptime
        if let failTime = failedAt[key], now - failTime < retryCooldown {
            completion(nil); return
        }
        if inFlight[key] != nil {
            inFlight[key]?.append(completion)
            return
        }
        inFlight[key] = [completion]
        let fileURL = url.standardizedFileURL
        Task.detached(priority: .utility) {
            let cg = await extractFirstFrame(url: fileURL, maxPixelSize: decodeMaxPixel)
            let img: NSImage? = cg.map {
                let detached = ImageTransform.detachedCopy($0)
                return NSImage(cgImage: detached, size: NSSize(width: CGFloat(detached.width) * 0.5, height: CGFloat(detached.height) * 0.5))
            }
            await MainActor.run {
                if let img {
                    failedAt.removeValue(forKey: key)
                    store(img, forKey: key)
                } else {
                    recordFailure(forKey: key)
                }
                let callbacks = inFlight.removeValue(forKey: key) ?? []
                callbacks.forEach { $0(img) }
            }
        }
    }

    private static func store(_ img: NSImage, forKey key: String) {
        cache[key] = img
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        while cacheOrder.count > maxCached {
            let evicted = cacheOrder.removeFirst()
            cache.removeValue(forKey: evicted)
        }
    }

    private static func recordFailure(forKey key: String) {
        failedAt[key] = ProcessInfo.processInfo.systemUptime
        if failedAt.count > maxFailed, let oldest = failedAt.min(by: { $0.value < $1.value })?.key {
            failedAt.removeValue(forKey: oldest)
        }
    }

    nonisolated private static func extractFirstFrame(url: URL, maxPixelSize: Int) async -> CGImage? {
        let ext = url.pathExtension.lowercased()
        if ["mp4", "mov", "m4v"].contains(ext) {
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
            if #available(macOS 13.0, *) {
                return try? await gen.image(at: .zero).image
            }
            return await extractVideoFrameLegacy(generator: gen)
        }
        let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOpts as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary)
    }

    nonisolated private static func extractVideoFrameLegacy(generator: AVAssetImageGenerator) async -> CGImage? {
        await withCheckedContinuation { cont in
            let lock = NSLock()
            var resumed = false
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, cg, _, _, _ in
                lock.lock()
                let shouldResume = !resumed
                resumed = true
                lock.unlock()
                if shouldResume { cont.resume(returning: cg) }
            }
        }
    }
}
