import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 管理屏幕上全部活动贴图窗口（上限 20 张，静止时零重绘）
@MainActor
final class PinManager {
    static let maxPins = 20

    var onCountChanged: ((Int) -> Void)?
    var onSaveImage: ((CGImage, CGFloat) -> Void)?

    private var windows: [PinWindow] = []

    var count: Int { windows.count }

    /// 从选区渲染出的高清 `CGImage` 创建贴图并原位钉在屏幕上
    func pin(cgImage: CGImage, scaleFactor: CGFloat, topLeftOnScreen: CGPoint?, screen: NSScreen) {
        if windows.count >= Self.maxPins, let oldest = windows.first {
            oldest.closePin()
        }

        let win = PinWindow(
            cgImage: cgImage,
            scaleFactor: scaleFactor,
            screenOriginTopLeft: topLeftOnScreen,
            on: screen
        )
        win.onClose = { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
            if let self { self.onCountChanged?(self.windows.count) }
        }
        win.onCloseAll = { [weak self] in
            self?.closeAll()
        }
        win.onSavePNG = { [weak self] img, scale in
            self?.onSaveImage?(img, scale)
        }

        windows.append(win)
        win.orderFrontRegardless()
        onCountChanged?(windows.count)
    }

    /// 从剪贴板读取图片或色值文本（如 `#3388FF`）并居中贴在鼠标当前所在的显示器上
    @discardableResult
    func pinFromClipboard() -> Bool {
        let mouse = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen = targetScreen else { return false }

        let cgImage: CGImage
        let scale: CGFloat
        if let nsImage = ClipboardAndSave.readImageFromClipboard() {
            var proposedRect = NSRect(origin: .zero, size: nsImage.size)
            guard let img = nsImage.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
                NSSound.beep()
                return false
            }
            cgImage = img
            scale = nsImage.size.width > 0 ? CGFloat(img.width) / nsImage.size.width : 2.0
        } else if let color = ClipboardAndSave.readColorFromClipboard(),
                  let card = RGBAColor.renderColorPinCard(color, scale: screen.backingScaleFactor) {
            cgImage = card
            scale = max(1.0, screen.backingScaleFactor)
        } else {
            NSSound.beep()
            return false
        }

        // 连续从剪贴板贴多张时轻微错开偏移，避免完全重叠
        let cascade = CGFloat((windows.count % 6) * 22)
        let visible = screen.visibleFrame
        let w = CGFloat(cgImage.width) / max(1.0, scale)
        let h = CGFloat(cgImage.height) / max(1.0, scale)
        let topLeft = CGPoint(
            x: (visible.width - w) * 0.5 + (visible.minX - screen.frame.minX) + cascade,
            y: (screen.frame.maxY - visible.midY) - h * 0.5 + cascade
        )
        pin(cgImage: cgImage, scaleFactor: scale, topLeftOnScreen: topLeft, screen: screen)
        return true
    }

    func closeAll() {
        let current = windows
        windows.removeAll()
        for w in current {
            w.orderOut(nil)
        }
        onCountChanged?(0)
    }
}
