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
        let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        let opts: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, srcOpts as CFDictionary),
              let rawCG = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        let cg = ImageTransform.detachedCopy(rawCG)
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

/// 晾衣架卡片装配、复制/贴图/识字/拖拽分发与屏幕定位扩展
extension ShelfPanelController {
    func buildCardView(for item: ShelfCardItem, timeFormatter: DateFormatter) -> ShelfCardView {
        let thumb: NSImage?, title: String, sub: String, sym: String?, snippet: String?, canOCR: Bool
        switch item {
        case .history(let e):
            thumb = historyRing.shelfThumbnail(for: e)
            title = e.isCollage ? "并排对比" : timeFormatter.string(from: e.createdAt)
            sub = "\(e.pixelWidth)×\(e.pixelHeight)"; sym = "photo"; snippet = nil; canOCR = true
        case .custom(let c):
            if c.kind == .file, let p = c.filePath {
                let u = URL(fileURLWithPath: p), ext = u.pathExtension.lowercased()
                let isImg = ["png", "jpg", "jpeg", "webp", "heic", "gif", "tiff", "bmp"].contains(ext)
                thumb = isImg ? ShelfStore.loadCardThumbnail(fileURL: u) : nil
                title = c.title; sub = ext.isEmpty ? "文件" : ext.uppercased()
                sym = isImg ? "photo" : (["mp4", "mov"].contains(ext) ? "film" : "doc.fill")
                snippet = nil; canOCR = isImg
            } else {
                thumb = nil; title = c.title; sub = "\((c.textContent ?? "").count) 字"
                sym = nil; snippet = c.textContent; canOCR = false
            }
        }
        let card = ShelfCardView(item: item, thumbnail: thumb, title: title, subtitle: sub, symbol: sym, textSnippet: snippet, canOCR: canOCR)
        card.onCopy = { [weak self] it in self?.handleCopy(it) }
        card.onEdit = { [weak self] it in self?.handleEdit(it) }
        card.onPin = { [weak self] it in self?.handlePin(it) }
        card.onOCR = { [weak self] it in self?.handleOCR(it) }
        card.onRemove = { [weak self] it in self?.handleRemove(it) }
        card.dragWriterProvider = { [weak self] it in self?.pasteboardWriter(for: it) }
        return card
    }

    private func handleCopy(_ item: ShelfCardItem) {
        switch item {
        case .history(let e): onCopyHistory?(e)
        case .custom(let c):
            if c.kind == .file, let p = c.filePath {
                let pb = NSPasteboard.general; pb.clearContents(); pb.writeObjects([URL(fileURLWithPath: p) as NSURL])
                ToastHUD.show(message: "已复制文件：\(c.title)")
            } else if let txt = c.textContent { ClipboardAndSave.copyText(txt); ToastHUD.show(message: "已复制暂存文本 (\(txt.count) 字)") }
        }
    }

    private func handleEdit(_ item: ShelfCardItem) {
        switch item {
        case .history(let e): onEditHistory?(e)
        case .custom(let c):
            if c.kind == .file, let p = c.filePath, let cg = loadImage(at: p) {
                onEditImage?(cg, NSScreen.main?.backingScaleFactor ?? 2.0)
            }
        }
    }

    private func handlePin(_ item: ShelfCardItem) {
        switch item {
        case .history(let e): onPinHistory?(e)
        case .custom(let c):
            if c.kind == .text, let txt = c.textContent { onPinText?(txt) }
            else if c.kind == .file, let p = c.filePath, let cg = loadImage(at: p) {
                onPinImage?(cg, NSScreen.main?.backingScaleFactor ?? 2.0)
            }
        }
    }

    private func handleOCR(_ item: ShelfCardItem) {
        switch item {
        case .history(let e): onOCRHistory?(e)
        case .custom(let c):
            if c.kind == .file, let p = c.filePath, let cg = loadImage(at: p) {
                onOCRImage?(cg, NSScreen.main?.backingScaleFactor ?? 2.0)
            }
        }
    }

    private func handleRemove(_ item: ShelfCardItem) {
        switch item {
        case .custom(let c):
            store.removeCustom(id: c.id)
            reloadCards()
        case .history(let e):
            historyRing.remove(id: e.id)
            onHistoryMutated?()
            reloadCards()
        }
    }

    private func pasteboardWriter(for item: ShelfCardItem) -> NSPasteboardWriting? {
        switch item {
        case .history(let e): return historyRing.fileURL(for: e) as NSURL?
        case .custom(let c): return c.kind == .file ? c.filePath.map { URL(fileURLWithPath: $0) as NSURL } : c.textContent as NSString?
        }
    }

    private func loadImage(at path: String) -> CGImage? {
        let opts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, opts as CFDictionary) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary)
    }

    func screenUnderCursor() -> NSScreen {
        let pt = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { ShelfTriggerGeometry.containsInclusive($0.frame, point: pt) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// 将当前 ⌘ 勾选的条目（或默认最近 2 张截图）送入多图拼接与合并 PDF 工作室
    func triggerCollageStudio() {
        let allItems = store.mergedItems(historyRing: historyRing)
        let byID = Dictionary(uniqueKeysWithValues: allItems.map { ($0.id, $0) })
        let chosen = selectedItemIDs.compactMap { byID[$0] }
        selectedItemIDs.removeAll()
        hide(manual: true)

        if chosen.isEmpty {
            onOpenCollageStudio?([], [])
            return
        }
        var imgs: [(String, CGImage, CGFloat)] = []
        let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss"
        for it in chosen {
            switch it {
            case .history(let e):
                if let cg = historyRing.loadCGImage(for: e) { imgs.append(("截图 \(tf.string(from: e.createdAt))", cg, e.scaleFactor)) }
            case .custom(let c):
                if c.kind == .file, let p = c.filePath, let cg = loadImage(at: p) {
                    imgs.append((c.title, cg, 2.0))
                } else if c.kind == .text, let txt = c.textContent, let cg = TextPinCardRenderer.render(text: txt, scale: 2.0) {
                    imgs.append((c.title, cg, 2.0))
                }
            }
        }
        onOpenCollageStudio?([], imgs)
    }
}
