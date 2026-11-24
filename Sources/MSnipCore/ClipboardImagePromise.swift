import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 剪贴板零阻塞延迟图像提供器（`NSPasteboardItemDataProvider`）：
/// 按下回车/双击复制截图时主线程 `<0.3ms` 瞬时返回，仅当目标应用真正执行粘贴 (`⌘V`) 时才按需编码 PNG / TIFF。
public enum ClipboardImagePromise {
    private static let lock = NSLock()
    private static var activeProviders: [ObjectIdentifier: Provider] = [:]

    /// 将高清 `CGImage` 以延迟承诺（Promise）方式写入指定剪贴板（默认系统通用剪贴板）
    @discardableResult
    public static func write(
        cgImage: CGImage,
        scaleFactor: CGFloat,
        to pasteboard: NSPasteboard = .general
    ) -> Int {
        let provider = Provider(cgImage: cgImage, scaleFactor: max(1.0, scaleFactor))
        let id = ObjectIdentifier(provider)
        lock.lock()
        activeProviders[id] = provider
        lock.unlock()

        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.png, .tiff])
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        return pasteboard.changeCount
    }

    /// 使用原生 `ImageIO` 将 `CGImage` 编码为保留 Retina 逻辑 DPI 的标准 PNG 数据
    public static func encodePNG(cgImage: CGImage, scaleFactor: CGFloat) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        let dpi = 72.0 * max(1.0, Double(scaleFactor))
        let props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi
        ]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// 使用 `NSBitmapImageRep` 生成保留逻辑点尺寸的 TIFF 数据（供 Keynote / Pages / 预览等原生应用粘贴）
    public static func encodeTIFF(cgImage: CGImage, scaleFactor: CGFloat) -> Data? {
        let s = max(1.0, scaleFactor)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = NSSize(
            width: CGFloat(cgImage.width) / s,
            height: CGFloat(cgImage.height) / s
        )
        return rep.tiffRepresentation
    }

    private final class Provider: NSObject, NSPasteboardItemDataProvider {
        let cgImage: CGImage
        let scaleFactor: CGFloat

        init(cgImage: CGImage, scaleFactor: CGFloat) {
            self.cgImage = cgImage
            self.scaleFactor = scaleFactor
        }

        func pasteboard(
            _ pasteboard: NSPasteboard?,
            item: NSPasteboardItem,
            provideDataForType type: NSPasteboard.PasteboardType
        ) {
            // AppKit 将 setData 数据交给系统剪贴板服务托管且每种类型至多回调一次，无需在进程堆内双份驻留 PNG/TIFF 字节
            if type == .png {
                if let data = ClipboardImagePromise.encodePNG(cgImage: cgImage, scaleFactor: scaleFactor) {
                    item.setData(data, forType: .png)
                }
            } else if type == .tiff {
                if let data = ClipboardImagePromise.encodeTIFF(cgImage: cgImage, scaleFactor: scaleFactor) {
                    item.setData(data, forType: .tiff)
                }
            }
        }

        func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
            let id = ObjectIdentifier(self)
            ClipboardImagePromise.lock.lock()
            ClipboardImagePromise.activeProviders.removeValue(forKey: id)
            ClipboardImagePromise.lock.unlock()
        }
    }
}
