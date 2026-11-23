import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 管理屏幕上全部活动贴图窗口（上限 20 张，支持鼠标穿透状态统计与一键恢复，静止时零重绘）
@MainActor
final class PinManager {
    static let maxPins = 20

    var onCountChanged: ((Int) -> Void)?
    var onSaveImage: ((CGImage, CGFloat) -> Void)?
    var onQuickSaveImage: ((CGImage, CGFloat) -> Void)?
    var onExtractOCR: ((CGImage, CGFloat, NSScreen) -> Void)?

    private var windows: [PinWindow] = []
    private(set) var arePinsHidden = false

    var count: Int { windows.count }
    var clickThroughCount: Int { windows.filter(\.isClickThrough).count }

    /// 从选区渲染出的高清 `CGImage` 创建贴图并原位钉在屏幕上
    func pin(cgImage: CGImage, scaleFactor: CGFloat, topLeftOnScreen: CGPoint?, screen: NSScreen) {
        if arePinsHidden {
            arePinsHidden = false
            windows.forEach { $0.orderFrontRegardless() }
        }
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
        win.onStateChanged = { [weak self] in
            if let self { self.onCountChanged?(self.windows.count) }
        }
        win.onSavePNG = { [weak self] img, scale in
            self?.onSaveImage?(img, scale)
        }
        win.onQuickSavePNG = { [weak self] img, scale in
            self?.onQuickSaveImage?(img, scale)
        }
        win.onExtractOCR = { [weak self] img, scale, scr in
            self?.onExtractOCR?(img, scale, scr)
        }

        windows.append(win)
        win.orderFrontRegardless()
        onCountChanged?(windows.count)
    }

    /// 一键解除所有处于幽灵鼠标穿透状态的贴图，恢复正常拖拽与右键交互
    func restoreAllClickThroughPins() {
        var restored = 0
        for win in windows where win.isClickThrough {
            win.setClickThrough(false)
            restored += 1
        }
        if restored > 0 {
            ToastHUD.show(message: "已解除 \(restored) 张贴图的鼠标穿透状态")
            onCountChanged?(windows.count)
        }
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
            ToastHUD.show(message: "剪贴板暂无图片或色值 · 可先复制图片再贴图")
            return false
        }

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

    /// 一键暂藏或恢复显示桌面上的全部贴图窗口
    func toggleAllVisibility() {
        guard !windows.isEmpty else {
            ToastHUD.show(message: "当前桌面暂无贴图")
            return
        }
        if !arePinsHidden && windows.contains(where: \.isVisible) {
            arePinsHidden = true
            windows.forEach { $0.orderOut(nil) }
            ToastHUD.show(message: "已暂藏 \(windows.count) 张桌面贴图 · 再按快捷键恢复")
        } else {
            arePinsHidden = false
            windows.forEach { $0.orderFrontRegardless() }
            ToastHUD.show(message: "已恢复显示 \(windows.count) 张桌面贴图")
        }
        onCountChanged?(windows.count)
    }

    func closeAll() {
        arePinsHidden = false
        let current = windows
        windows.removeAll()
        for w in current {
            w.closePin()
        }
        onCountChanged?(0)
    }
}
