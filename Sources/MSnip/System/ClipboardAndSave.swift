import AppKit
import CoreGraphics
import Foundation
import MSnipCore
import UniformTypeIdentifiers

/// 剪贴板读写与 PNG 文件导出工具
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
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = NSSize(
            width: CGFloat(cgImage.width) / max(1.0, scaleFactor),
            height: CGFloat(cgImage.height) / max(1.0, scaleFactor)
        )
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
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
