import AppKit
import CoreGraphics
import Foundation

/// 单条最近截图历史元数据（原图按需从磁盘缓存读取，闲置时零内存常驻）
public struct CaptureHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let scaleFactor: CGFloat
    public let fileName: String

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

/// 磁盘持久化的有界最近截图环形历史库（默认最多保留最近 15 张，超出自动淘汰并清理旧 PNG）
public final class CaptureHistoryRing {
    public let maxCount: Int
    public let directoryURL: URL
    private let indexURL: URL
    public private(set) var entries: [CaptureHistoryEntry] = []

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
        loadIndex()
    }

    /// 记录一张新完成（复制/贴图/保存）的截图，置于队首并自动淘汰超出 `maxCount` 的旧文件
    @discardableResult
    public func record(cgImage: CGImage, scaleFactor: CGFloat, date: Date = Date()) -> CaptureHistoryEntry? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = NSSize(
            width: CGFloat(cgImage.width) / max(1.0, scaleFactor),
            height: CGFloat(cgImage.height) / max(1.0, scaleFactor)
        )
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return nil }

        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let id = UUID()
        let fileName = "shot-\(id.uuidString).png"
        let fileURL = directoryURL.appendingPathComponent(fileName)
        do {
            try pngData.write(to: fileURL, options: .atomic)
        } catch {
            return nil
        }

        let entry = CaptureHistoryEntry(
            id: id,
            createdAt: date,
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height,
            scaleFactor: max(1.0, scaleFactor),
            fileName: fileName
        )
        entries.insert(entry, at: 0)

        while entries.count > maxCount {
            let evicted = entries.removeLast()
            try? FileManager.default.removeItem(at: directoryURL.appendingPathComponent(evicted.fileName))
        }
        saveIndex()
        return entry
    }

    /// 按条目按需加载原分辨率 `CGImage`
    public func loadCGImage(for entry: CaptureHistoryEntry) -> CGImage? {
        let url = directoryURL.appendingPathComponent(entry.fileName)
        guard let data = try? Data(contentsOf: url),
              let rep = NSBitmapImageRep(data: data) else {
            return nil
        }
        return rep.cgImage
    }

    /// 生成供顶部菜单栏展示的轻量缩略图图标（`28 × 18 pt`）
    public func menuThumbnail(for entry: CaptureHistoryEntry) -> NSImage? {
        guard let cg = loadCGImage(for: entry) else { return nil }
        let target = NSSize(width: 28, height: 18)
        let img = NSImage(size: target, flipped: false) { dst in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let clip = CGPath(roundedRect: dst, cornerWidth: 3, cornerHeight: 3, transform: nil)
            ctx.addPath(clip)
            ctx.clip()
            let srcRatio = CGFloat(cg.width) / max(1.0, CGFloat(cg.height))
            let dstRatio = dst.width / dst.height
            let drawRect: CGRect
            if srcRatio > dstRatio {
                let w = dst.height * srcRatio
                drawRect = CGRect(x: (dst.width - w) * 0.5, y: 0, width: w, height: dst.height)
            } else {
                let h = dst.width / srcRatio
                drawRect = CGRect(x: 0, y: (dst.height - h) * 0.5, width: dst.width, height: h)
            }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: drawRect)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
            ctx.setLineWidth(1.0)
            ctx.addPath(clip)
            ctx.strokePath()
            return true
        }
        return img
    }

    public func clearAll() {
        for item in entries {
            try? FileManager.default.removeItem(at: directoryURL.appendingPathComponent(item.fileName))
        }
        entries.removeAll()
        try? FileManager.default.removeItem(at: indexURL)
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

    private func saveIndex() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}
