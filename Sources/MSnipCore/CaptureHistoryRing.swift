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
    public let isCollage: Bool

    var thumbFileName: String { "thumb-\(id.uuidString).png" }

    public init(id: UUID = UUID(), createdAt: Date = Date(), pixelWidth: Int, pixelHeight: Int, scaleFactor: CGFloat, fileName: String, isCollage: Bool = false) {
        self.id = id; self.createdAt = createdAt; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.scaleFactor = scaleFactor; self.fileName = fileName; self.isCollage = isCollage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); createdAt = try c.decode(Date.self, forKey: .createdAt)
        pixelWidth = try c.decode(Int.self, forKey: .pixelWidth); pixelHeight = try c.decode(Int.self, forKey: .pixelHeight)
        scaleFactor = try c.decode(CGFloat.self, forKey: .scaleFactor); fileName = try c.decode(String.self, forKey: .fileName)
        isCollage = try c.decodeIfPresent(Bool.self, forKey: .isCollage) ?? false
    }
}

/// 磁盘持久化的线程安全最近截图环形历史库：
/// - 异步后台编码落盘，主线程 `record()` 亚毫秒返回；
/// - 预烘焙 `212×124 px` 紧凑卡片缩略图供菜单栏与顶部暂存架零阻塞共用（不常驻全尺寸原图、不阻塞主线程等待 PNG 落盘）。
public final class CaptureHistoryRing: @unchecked Sendable {
    private static let ioQueue = DispatchQueue(label: "top.xy.msnip.history.io", qos: .utility)

    public let maxCount: Int
    public let directoryURL: URL
    private let indexURL: URL

    private let stateLock = NSLock()
    private var _entries: [CaptureHistoryEntry] = []
    private var inFlightImages: [UUID: CGImage] = [:]
    private var thumbCache: [UUID: CGImage] = [:]
    private var menuIconCache: [UUID: NSImage] = [:]

    public var entries: [CaptureHistoryEntry] {
        stateLock.lock(); defer { stateLock.unlock() }
        return _entries
    }

    public var originalEntries: [CaptureHistoryEntry] {
        entries.filter { !$0.isCollage }
    }

    public init(directoryURL: URL? = nil, maxCount: Int = 15) {
        self.maxCount = max(1, maxCount)
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        self.directoryURL = directoryURL ?? base.appendingPathComponent("top.xy.msnip/History", isDirectory: true)
        self.indexURL = self.directoryURL.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: self.directoryURL, withIntermediateDirectories: true)
        loadIndex(); prewarmMenuIconsAsync()
    }

    private func prewarmMenuIconsAsync() {
        let initial = entries
        guard !initial.isEmpty else { return }
        Self.ioQueue.async { [weak self] in
            guard let self else { return }
            for e in initial { _ = self.menuThumbnail(for: e) }
        }
    }

    @discardableResult
    public func record(cgImage: CGImage, scaleFactor: CGFloat, date: Date = Date(), isCollage: Bool = false) -> CaptureHistoryEntry? {
        guard cgImage.width > 0, cgImage.height > 0 else { return nil }
        let id = UUID(), normScale = max(1.0, scaleFactor)
        let entry = CaptureHistoryEntry(
            id: id, createdAt: date, pixelWidth: cgImage.width, pixelHeight: cgImage.height,
            scaleFactor: normScale, fileName: "shot-\(id.uuidString).png", isCollage: isCollage
        )

        let thumbCG = Self.makeThumbnailCGImage(from: cgImage)
        let menuNS = thumbCG.flatMap { Self.makeMenuNSImage(from: $0) }
        var evictedList: [CaptureHistoryEntry] = []
        let snapshotEntries: [CaptureHistoryEntry]

        stateLock.lock()
        inFlightImages[id] = cgImage
        if let thumbCG { thumbCache[id] = thumbCG }
        if let menuNS { menuIconCache[id] = menuNS }
        _entries.insert(entry, at: 0)
        while _entries.count > maxCount {
            let evicted = _entries.removeLast()
            evictedList.append(evicted)
            inFlightImages.removeValue(forKey: evicted.id)
            thumbCache.removeValue(forKey: evicted.id)
            menuIconCache.removeValue(forKey: evicted.id)
        }
        snapshotEntries = _entries
        stateLock.unlock()

        let dirURL = directoryURL, idxURL = indexURL
        Self.ioQueue.async { [weak self] in
            let fm = FileManager.default
            for evicted in evictedList {
                try? fm.removeItem(at: dirURL.appendingPathComponent(evicted.fileName))
                try? fm.removeItem(at: dirURL.appendingPathComponent(evicted.thumbFileName))
            }
            let shouldWrite: Bool = {
                guard let self else { return true }
                self.stateLock.lock(); defer { self.stateLock.unlock() }
                return self.inFlightImages[id] != nil
            }()
            if shouldWrite {
                try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
                Self.writePNG(cgImage: cgImage, scaleFactor: normScale, to: dirURL.appendingPathComponent(entry.fileName))
                if let thumbCG { Self.writePNG(cgImage: thumbCG, scaleFactor: 2.0, to: dirURL.appendingPathComponent(entry.thumbFileName)) }
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

    public func flushPendingWrites() { Self.ioQueue.sync {} }

    public func loadCGImage(for entry: CaptureHistoryEntry) -> CGImage? {
        stateLock.lock()
        if let pending = inFlightImages[entry.id] { stateLock.unlock(); return pending }
        stateLock.unlock()

        let url = directoryURL.appendingPathComponent(entry.fileName)
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts as CFDictionary) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary)
    }

    /// 仅当该条目仍在后台落盘队列中时才等待写盘完成，已落盘条目零阻塞立即返回路径
    public func fileURL(for entry: CaptureHistoryEntry) -> URL? {
        let isPending: Bool = {
            stateLock.lock(); defer { stateLock.unlock() }
            return inFlightImages[entry.id] != nil
        }()
        if isPending { Self.ioQueue.sync {} }
        let url = directoryURL.appendingPathComponent(entry.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 返回顶部暂存架清晰卡片缩略图（零阻塞优先命中内存微缓存或小尺寸 thumb 文件，绝不等待 5K 原图写盘）
    public func shelfThumbnail(for entry: CaptureHistoryEntry) -> NSImage? {
        guard let cg = resolveThumbCG(for: entry) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) * 0.5, height: CGFloat(cg.height) * 0.5))
    }

    /// 返回菜单栏轻量预解码 `@2x` 位图图标（`28 × 18 pt` / `56 × 36 px`，消除菜单高亮移动时的实时重采样与 PNG 反复解码卡顿）
    public func menuThumbnail(for entry: CaptureHistoryEntry) -> NSImage? {
        stateLock.lock()
        if let cached = menuIconCache[entry.id] { stateLock.unlock(); return cached }
        stateLock.unlock()
        guard let cg = resolveThumbCG(for: entry), let icon = Self.makeMenuNSImage(from: cg) else { return nil }
        stateLock.lock(); menuIconCache[entry.id] = icon; stateLock.unlock()
        return icon
    }

    private func resolveThumbCG(for entry: CaptureHistoryEntry) -> CGImage? {
        stateLock.lock()
        if let cached = thumbCache[entry.id] { stateLock.unlock(); return cached }
        let pendingFull = inFlightImages[entry.id]
        stateLock.unlock()

        if let pendingFull, let baked = Self.makeThumbnailCGImage(from: pendingFull) {
            stateLock.lock(); thumbCache[entry.id] = baked; stateLock.unlock()
            return baked
        }

        let thumbURL = directoryURL.appendingPathComponent(entry.thumbFileName)
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let src = CGImageSourceCreateWithURL(thumbURL as CFURL, opts as CFDictionary),
           let rawThumb = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary),
           let decoded = Self.makeAspectFillCGImage(from: rawThumb, width: max(1, rawThumb.width), height: max(1, rawThumb.height)) {
            stateLock.lock(); thumbCache[entry.id] = decoded; stateLock.unlock()
            return decoded
        }

        let shotURL = directoryURL.appendingPathComponent(entry.fileName)
        let downOpts: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 224
        ]
        guard let src = CGImageSourceCreateWithURL(shotURL as CFURL, opts as CFDictionary),
              let downCG = CGImageSourceCreateThumbnailAtIndex(src, 0, downOpts as CFDictionary),
              let bakedCG = Self.makeThumbnailCGImage(from: downCG) else { return nil }
        stateLock.lock(); thumbCache[entry.id] = bakedCG; stateLock.unlock()
        Self.ioQueue.async { Self.writePNG(cgImage: bakedCG, scaleFactor: 2.0, to: thumbURL) }
        return bakedCG
    }

    public func remove(id: UUID) {
        stateLock.lock()
        guard let idx = _entries.firstIndex(where: { $0.id == id }) else { stateLock.unlock(); return }
        let removed = _entries.remove(at: idx)
        let snapshot = _entries
        inFlightImages.removeValue(forKey: id); thumbCache.removeValue(forKey: id); menuIconCache.removeValue(forKey: id)
        stateLock.unlock()

        let dirURL = directoryURL, idxURL = indexURL
        Self.ioQueue.async {
            let fm = FileManager.default
            try? fm.removeItem(at: dirURL.appendingPathComponent(removed.fileName))
            try? fm.removeItem(at: dirURL.appendingPathComponent(removed.thumbFileName))
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: idxURL, options: .atomic) }
        }
    }

    public func clearAll() {
        let dirURL = directoryURL, idxURL = indexURL
        stateLock.lock()
        let toDelete = _entries
        _entries.removeAll(); inFlightImages.removeAll(); thumbCache.removeAll(); menuIconCache.removeAll()
        stateLock.unlock()

        Self.ioQueue.async {
            let fm = FileManager.default
            for item in toDelete {
                try? fm.removeItem(at: dirURL.appendingPathComponent(item.fileName))
                try? fm.removeItem(at: dirURL.appendingPathComponent(item.thumbFileName))
            }
            try? fm.removeItem(at: idxURL)
        }
    }

    private static func makeThumbnailCGImage(from src: CGImage) -> CGImage? {
        makeAspectFillCGImage(from: src, width: 212, height: 124)
    }

    private static func makeMenuNSImage(from src: CGImage) -> NSImage? {
        guard let cg = makeAspectFillCGImage(from: src, width: 56, height: 36, cornerRadius: 5.0, framed: true) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: 28, height: 18)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep); img.cacheMode = .always
        return img
    }

    private static func makeAspectFillCGImage(from src: CGImage, width w: Int, height h: Int, cornerRadius: CGFloat = 0, framed: Bool = false) -> CGImage? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let dst = CGRect(x: 0, y: 0, width: w, height: h)
        if cornerRadius > 0 {
            ctx.addPath(CGPath(roundedRect: dst, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
            ctx.clip()
        }
        let srcRatio = CGFloat(src.width) / max(1.0, CGFloat(src.height)), dstRatio = dst.width / dst.height
        let drawRect = srcRatio > dstRatio
            ? CGRect(x: (dst.width - dst.height * srcRatio) * 0.5, y: 0, width: dst.height * srcRatio, height: dst.height)
            : CGRect(x: 0, y: (dst.height - dst.width / srcRatio) * 0.5, width: dst.width, height: dst.width / srcRatio)
        ctx.interpolationQuality = .medium
        ctx.draw(src, in: drawRect)
        if framed {
            ctx.setStrokeColor(CGColor(srgbRed: 0.52, green: 0.56, blue: 0.64, alpha: 0.34))
            ctx.setLineWidth(1.0)
            ctx.addPath(CGPath(roundedRect: dst.insetBy(dx: 0.5, dy: 0.5), cornerWidth: max(1, cornerRadius - 0.5), cornerHeight: max(1, cornerRadius - 0.5), transform: nil))
            ctx.strokePath()
        }
        return ctx.makeImage()
    }

    private static func writePNG(cgImage: CGImage, scaleFactor: CGFloat, to url: URL) {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return }
        let dpi = 72.0 * max(1.0, Double(scaleFactor))
        let props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        if CGImageDestinationFinalize(dest) { try? (data as Data).write(to: url, options: .atomic) }
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([CaptureHistoryEntry].self, from: data) else { return }
        let valid = decoded.filter { FileManager.default.fileExists(atPath: directoryURL.appendingPathComponent($0.fileName).path) }
        stateLock.lock(); _entries = valid; stateLock.unlock()
    }
}
