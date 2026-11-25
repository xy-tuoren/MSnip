import AppKit
import CoreGraphics
import Foundation
import ImageIO
import MSnipCore

/// 顶部暂存架统一卡片条目（无缝融合最近截图历史与用户主动拖入/挂架的文件与文本）
enum ShelfCardItem: Identifiable {
    case history(CaptureHistoryEntry)
    case custom(ShelfCustomItem)

    var id: UUID {
        switch self {
        case .history(let e): return e.id
        case .custom(let c):  return c.id
        }
    }

    var createdAt: Date {
        switch self {
        case .history(let e): return e.createdAt
        case .custom(let c):  return c.createdAt
        }
    }
}

/// 顶部暂存架（MSnip Shelf）数据仓库：
/// 截图直接复用 `CaptureHistoryRing` 磁盘缓存（零重复落盘），额外仅轻量持久化用户拖入的文件路径与文本片段。
@MainActor
final class ShelfStore {
    private static let maxCustomCount = 16
    private static let storeURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("MSnip", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("shelf.json")
    }()

    private(set) var customItems: [ShelfCustomItem] = []

    init() {
        load()
    }

    /// 合并最近截图与自定义挂架项（按创建时间倒序，最新在前）
    func mergedItems(historyRing: CaptureHistoryRing) -> [ShelfCardItem] {
        pruneInvalidFiles()
        var list: [ShelfCardItem] = historyRing.entries.map { .history($0) }
        list.append(contentsOf: customItems.map { .custom($0) })
        list.sort { $0.createdAt > $1.createdAt }
        return Array(list.prefix(24))
    }

    @discardableResult
    func addFileURLs(_ urls: [URL]) -> Int {
        var added = 0
        for url in urls where url.isFileURL {
            let stdPath = url.standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: stdPath) else { continue }
            customItems.removeAll { $0.kind == .file && $0.filePath == stdPath }
            let item = ShelfCustomItem(kind: .file, title: url.lastPathComponent, filePath: stdPath)
            customItems.insert(item, at: 0)
            added += 1
        }
        trimAndSave()
        return added
    }

    @discardableResult
    func addText(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let previewTitle = trimmed.split(whereSeparator: \.isNewline).first.map { String($0.prefix(26)) } ?? "文本片段"
        customItems.removeAll { $0.kind == .text && $0.textContent == trimmed }
        customItems.insert(ShelfCustomItem(kind: .text, title: previewTitle, textContent: trimmed), at: 0)
        trimAndSave()
        return true
    }

    /// 将当前系统剪贴板内容（文件 / 图片 / 文本）一键挂上暂存架
    func addFromClipboard(historyRing: CaptureHistoryRing) -> String? {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let n = addFileURLs(urls)
            return n > 0 ? "已挂架 \(n) 个剪贴板文件" : nil
        }
        if let nsImg = ClipboardAndSave.readImageFromClipboard(),
           let cg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let scale = NSScreen.main?.backingScaleFactor ?? 2.0
            _ = historyRing.record(cgImage: cg, scaleFactor: scale)
            return "已将剪贴板图片挂上暂存架"
        }
        if let str = pb.string(forType: .string), addText(str) {
            return "已将剪贴板文本挂上暂存架"
        }
        return nil
    }

    func removeCustom(id: UUID) {
        customItems.removeAll { $0.id == id }
        save()
    }

    func clearCustom() {
        guard !customItems.isEmpty else { return }
        customItems.removeAll()
        save()
    }

    static func loadCardThumbnail(fileURL: URL, maxPixelSize: Int = 224) -> NSImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) * 0.5, height: CGFloat(cg.height) * 0.5))
    }

    private func pruneInvalidFiles() {
        let before = customItems.count
        customItems.removeAll { !$0.isValidOnDisk }
        if customItems.count != before { save() }
    }

    private func trimAndSave() {
        if customItems.count > Self.maxCustomCount {
            customItems = Array(customItems.prefix(Self.maxCustomCount))
        }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let decoded = try? JSONDecoder().decode([ShelfCustomItem].self, from: data) else { return }
        customItems = decoded.filter(\.isValidOnDisk)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(customItems) {
            try? data.write(to: Self.storeURL, options: .atomic)
        }
    }
}
