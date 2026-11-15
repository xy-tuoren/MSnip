import AppKit
import CoreGraphics
import Foundation
import MSnipCore
import UniformTypeIdentifiers

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

    /// 将 `CGImage` 编码为保留逻辑 DPI 尺寸的 PNG 数据
    static func encodePNG(cgImage: CGImage, scaleFactor: CGFloat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = NSSize(
            width: CGFloat(cgImage.width) / max(1.0, scaleFactor),
            height: CGFloat(cgImage.height) / max(1.0, scaleFactor)
        )
        return rep.representation(using: .png, properties: [:])
    }

    /// 将 Retina 高清 `CGImage` 写入系统剪贴板（保留物理像素分辨率与逻辑点尺寸）
    static func copyToClipboard(cgImage: CGImage, scaleFactor: CGFloat) {
        let logicalSize = NSSize(
            width: CGFloat(cgImage.width) / max(1.0, scaleFactor),
            height: CGFloat(cgImage.height) / max(1.0, scaleFactor)
        )
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = logicalSize

        let nsImage = NSImage(size: logicalSize)
        nsImage.addRepresentation(rep)

        let pb = NSPasteboard.general
        pb.clearContents()
        if let pngData = rep.representation(using: .png, properties: [:]) {
            pb.setData(pngData, forType: .png)
        }
        pb.writeObjects([nsImage])
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

    /// 弹出原生保存对话框导出 PNG，返回用户选定的新目录以便配置记忆
    @MainActor
    static func savePNGInteractive(
        cgImage: CGImage,
        scaleFactor: CGFloat,
        initialDirectory: String?
    ) -> String? {
        guard let pngData = encodePNG(cgImage: cgImage, scaleFactor: scaleFactor) else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let defaultName = "MSnip-\(formatter.string(from: Date())).png"

        let panel = NSSavePanel()
        panel.title = "保存截图"
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.level = .modalPanel

        if let dir = initialDirectory, FileManager.default.fileExists(atPath: dir) {
            panel.directoryURL = URL(fileURLWithPath: dir, isDirectory: true)
        } else if let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first {
            panel.directoryURL = pictures
        }

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }
        do {
            try pngData.write(to: url, options: .atomic)
            return url.deletingLastPathComponent().path
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
