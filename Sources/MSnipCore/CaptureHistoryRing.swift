import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 单条最近截图历史元数据（原图按需从磁盘缓存读取，闲置时零原图内存常驻）
public struct CaptureHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let scaleFactor: CGFloat
    public let fileName: String

    var thumbFileName: String { "thumb-\(id.uuidString).png" }

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        pixelWidth: Int,
        pixelHeight: Int,
        scaleFactor: CGFloat,
        fileName: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scaleFactor = scaleFactor
        self.fileName = fileName
    }
}

/// 磁盘持久化的有界最近截图环形历史库：
/// - 异步后台编码落盘，主线程 `record()` 亚毫秒返回；
/// - 菜单仅持有预烘焙的 `56 × 36 px` 极小位图缩略图（15 条总计 ~120 KB），绝不常驻全尺寸 Retina 原图。
public final class CaptureHistoryRing {
    private static let ioQueue = DispatchQueue(label: "top.xy.msnip.history.io", qos: .utility)

    public let maxCount: Int
    public let directoryURL: URL
    private let indexURL: URL
    public private(set) var entries: [CaptureHistoryEntry] = []

    private let stateLock = NSLock()
    private var inFlightImages: [UUID: CGImage] = [:]
    private var thumbCache: [UUID: NSImage] = [:]

    public init(directoryURL: URL? = nil, maxCount: Int = 15) {
        self.maxCount = max(1, maxCount)
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.directoryURL = caches
                .appendingPathComponent("top.xy.msnip", isDirectory: true)
                .appendingPathComponent("History", isDirectory: true)
        }
        self.indexURL = self.directoryURL.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: self.directoryURL, withIntermediateDirectories: true)
        Self.ioQueue.sync {}
        loadIndex()
    }

    /// 记录一张新完成的截图：主线程仅生成 `56×36` 微缩略图（`<0.3ms`），高清 PNG 压缩与落盘全部交由后台串行队列执行
    @discardableResult
    public func record(cgImage: CGImage, scaleFactor: CGFloat, date: Date = Date()) -> CaptureHistoryEntry? {
        guard cgImage.width > 0, cgImage.height > 0 else { return nil }
        let id = UUID()
        let normScale = max(1.0, scaleFactor)
        let entry = CaptureHistoryEntry(
            id: id,
            createdAt: date,
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height,
            scaleFactor: normScale,
            fileName: "shot-\(id.uuidString).png"
        )

        let thumbCG = Self.makeThumbnailCGImage(from: cgImage)
        stateLock.lock()
        inFlightImages[id] = cgImage
        if let thumbCG {
            thumbCache[id] = NSImage(cgImage: thumbCG, size: NSSize(width: 28, height: 18))
        }
        stateLock.unlock()

        entries.insert(entry, at: 0)
        var evictedList: [CaptureHistoryEntry] = []
        while entries.count > maxCount {
            let evicted = entries.removeLast()
            evictedList.append(evicted)
            stateLock.lock()
            inFlightImages.removeValue(forKey: evicted.id)
            thumbCache.removeValue(forKey: evicted.id)
            stateLock.unlock()
        }

        let snapshotEntries = entries
        let dirURL = directoryURL
        let idxURL = indexURL

        Self.ioQueue.async { [weak self] in
            let fm = FileManager.default
            for evicted in evictedList {
                try? fm.removeItem(at: dirURL.appendingPathComponent(evicted.fileName))
                try? fm.removeItem(at: dirURL.appendingPathComponent(evicted.thumbFileName))
            }

            let shouldWrite: Bool = {
                guard let self else { return true }
                self.stateLock.lock()
                defer { self.stateLock.unlock() }
                return self.inFlightImages[id] != nil
            }()

            if shouldWrite {
                try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
                let shotURL = dirURL.appendingPathComponent(entry.fileName)
                Self.writePNG(cgImage: cgImage, scaleFactor: normScale, to: shotURL)
                if let thumbCG {
                    let thumbURL = dirURL.appendingPathComponent(entry.thumbFileName)
                    Self.writePNG(cgImage: thumbCG, scaleFactor: 2.0, to: thumbURL)
                }
            }

            if let data = try? JSONEncoder().encode(snapshotEntries) {
                try? data.write(to: idxURL, options: .atomic)
            }

            if let self {
                self.stateLock.lock()
                self.inFlightImages.removeValue(forKey: id)
                self.stateLock.unlock()
            }
        }
        return entry
    }

    /// 等待所有后台历史 PNG 写入任务落盘完成
    public func flushPendingWrites() {
        Self.ioQueue.sync {}
    }

    /// 按条目按需解码原分辨率 `CGImage`（禁用 ImageIO 全局缓存，用完即释）
    public func loadCGImage(for entry: CaptureHistoryEntry) -> CGImage? {
        stateLock.lock()
        if let pending = inFlightImages[entry.id] {
            stateLock.unlock()
            return pending
        }
        stateLock.unlock()

        let url = directoryURL.appendingPathComponent(entry.fileName)
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts as CFDictionary) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary)
    }

    /// 确保后台写盘完成后返回该条历史截图在缓存目录中的 PNG 文件路径
    public func fileURL(for entry: CaptureHistoryEntry) -> URL? {
        Self.ioQueue.sync {}
        let url = directoryURL.appendingPathComponent(entry.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 返回顶部菜单栏轻量缩略图图标（`28 × 18 pt` 独立小位图，绝不捕获原尺寸 `CGImage`）
    public func menuThumbnail(for entry: CaptureHistoryEntry) -> NSImage? {
        stateLock.lock()
        if let cached = thumbCache[entry.id] {
            stateLock.unlock()
            return cached
        }
        stateLock.unlock()

        let thumbURL = directoryURL.appendingPathComponent(entry.thumbFileName)
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let src = CGImageSourceCreateWithURL(thumbURL as CFURL, opts as CFDictionary),
           let thumbCG = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary) {
            let img = NSImage(cgImage: thumbCG, size: NSSize(width: 28, height: 18))
            stateLock.lock()
            thumbCache[entry.id] = img
            stateLock.unlock()
            return img
        }

        // 兼容旧版未生成独立微缩略图的条目：一次性按需烘焙并异步补存磁盘
        guard let fullCG = loadCGImage(for: entry),
              let bakedCG = Self.makeThumbnailCGImage(from: fullCG) else {
            return nil
        }
        let img = NSImage(cgImage: bakedCG, size: NSSize(width: 28, height: 18))
        stateLock.lock()
        thumbCache[entry.id] = img
        stateLock.unlock()
        Self.ioQueue.async {
            Self.writePNG(cgImage: bakedCG, scaleFactor: 2.0, to: thumbURL)
        }
        return img
    }

    public func clearAll() {
        let dirURL = directoryURL
        let idxURL = indexURL
        let toDelete = entries
        entries.removeAll()
        stateLock.lock()
        inFlightImages.removeAll()
        thumbCache.removeAll()
        stateLock.unlock()

        Self.ioQueue.sync {
            let fm = FileManager.default
            for item in toDelete {
                try? fm.removeItem(at: dirURL.appendingPathComponent(item.fileName))
                try? fm.removeItem(at: dirURL.appendingPathComponent(item.thumbFileName))
            }
            try? fm.removeItem(at: idxURL)
        }
    }

    // MARK: - Helpers

    private static func makeThumbnailCGImage(from src: CGImage) -> CGImage? {
        let w = 56, h = 36
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let dst = CGRect(x: 0, y: 0, width: w, height: h)
        let clip = CGPath(roundedRect: dst, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.addPath(clip)
        ctx.clip()

        let srcRatio = CGFloat(src.width) / max(1.0, CGFloat(src.height))
        let dstRatio = dst.width / dst.height
        let drawRect: CGRect
        if srcRatio > dstRatio {
            let dw = dst.height * srcRatio
            drawRect = CGRect(x: (dst.width - dw) * 0.5, y: 0, width: dw, height: dst.height)
        } else {
            let dh = dst.width / srcRatio
            drawRect = CGRect(x: 0, y: (dst.height - dh) * 0.5, width: dst.width, height: dh)
        }
        ctx.interpolationQuality = .medium
        ctx.draw(src, in: drawRect)

        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28))
        ctx.setLineWidth(2.0)
        ctx.addPath(clip)
        ctx.strokePath()
        return ctx.makeImage()
    }

    private static func writePNG(cgImage: CGImage, scaleFactor: CGFloat, to url: URL) {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return
        }
        let dpi = 72.0 * max(1.0, Double(scaleFactor))
        let props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi
        ]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        if CGImageDestinationFinalize(dest) {
            try? (data as Data).write(to: url, options: .atomic)
        }
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([CaptureHistoryEntry].self, from: data) else {
            return
        }
        entries = decoded.filter {
            FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent($0.fileName).path)
        }
    }
}
