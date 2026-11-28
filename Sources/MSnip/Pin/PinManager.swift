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
    var onTranslateImage: ((CGImage, CGFloat, NSScreen) -> Void)?
    var onGlowStrengthChanged: ((CGFloat) -> Void)?
    var defaultGlowStrength: CGFloat = 0.45

    private var windows: [PinWindow] = []
    private let hoverCoordinator = PinHoverCoordinator()
    private(set) var arePinsHidden = false

    init() {
        hoverCoordinator.windowsProvider = { [weak self] in self?.windows ?? [] }
    }

    var count: Int { windows.count }
    var clickThroughCount: Int { windows.filter(\.isClickThrough).count }

    /// 从选区渲染出的高清 `CGImage` 创建贴图并原位钉在屏幕上（超宽/超高大图自动适配屏幕可见区域不溢出）
    @discardableResult
    func pin(
        cgImage: CGImage,
        scaleFactor: CGFloat,
        topLeftOnScreen: CGPoint?,
        screen: NSScreen,
        cascadeOffset: CGPoint = .zero,
        glowStrength: CGFloat? = nil
    ) -> PinWindow {
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
            on: screen,
            cascadeOffset: cascadeOffset,
            glowStrength: glowStrength ?? defaultGlowStrength
        )
        win.onGlowStrengthChanged = { [weak self] g in
            self?.defaultGlowStrength = g
            self?.onGlowStrengthChanged?(g)
        }
        win.onClose = { [weak self] closed in
            self?.windows.removeAll { $0 === closed }
            self?.hoverCoordinator.syncMonitors()
            if let self { self.onCountChanged?(self.windows.count) }
        }
        win.onCloseAll = { [weak self] in
            self?.closeAll()
        }
        win.onStateChanged = { [weak self] in
            self?.hoverCoordinator.syncMonitors()
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
        win.onTranslateImage = { [weak self] img, scale, scr in
            self?.onTranslateImage?(img, scale, scr)
        }
        win.onSnapOrigin = { [weak self] raw, size, movingWin in
            guard let self else { return raw }
            let sibFrames = self.windows.filter { $0 !== movingWin && $0.isVisible }.map(\.imageScreenFrame)
            let vf = (movingWin.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            return ImageTransform.snapPinOrigin(raw, size: size, siblingFrames: sibFrames, visibleBounds: vf, threshold: 8.0)
        }

        windows.append(win)
        win.orderFrontRegardless()
        hoverCoordinator.syncMonitors()
        hoverCoordinator.reconcileSoon(delay: 0.05)
        onCountChanged?(windows.count)
        return win
    }

    /// 一键解除所有处于幽灵鼠标穿透状态的贴图，恢复正常拖拽与右键交互
    func restoreAllClickThroughPins() {
        var restored = 0
        for win in windows where win.isClickThrough {
            win.setClickThrough(false)
            restored += 1
        }
        if restored > 0 {
            ToastHUD.show(message: L("已解除 %@ 张贴图的鼠标穿透状态", restored))
            onCountChanged?(windows.count)
        }
    }

    /// 从剪贴板读取图片、色值（如 `#3388FF`）或纯文本便签，居中贴在鼠标当前所在的显示器上
    @discardableResult
    func pinFromClipboard() -> Bool {
        let mouse = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen = targetScreen else { return false }

        let cgImage: CGImage
        let scale: CGFloat
        var toastNote: String?
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
        } else if let text = ClipboardAndSave.readTextFromClipboard(),
                  let card = TextPinCardRenderer.render(text: text, scale: screen.backingScaleFactor) {
            cgImage = card
            scale = max(1.0, screen.backingScaleFactor)
            toastNote = L("已将剪贴板文本贴为桌面便签")
        } else {
            NSSound.beep()
            ToastHUD.show(message: L("剪贴板暂无图片、色值或文本 · 复制后再按快捷键贴图"))
            return false
        }

        let cascade = CGFloat((windows.count % 6) * 22)
        pin(cgImage: cgImage, scaleFactor: scale, topLeftOnScreen: nil, screen: screen, cascadeOffset: CGPoint(x: cascade, y: -cascade))
        if let toastNote { ToastHUD.show(message: toastNote) }
        return true
    }

    /// 一键暂藏或恢复显示桌面上的全部贴图窗口
    func toggleAllVisibility() {
        guard !windows.isEmpty else {
            ToastHUD.show(message: L("当前桌面暂无贴图"))
            return
        }
        if !arePinsHidden && windows.contains(where: \.isVisible) {
            arePinsHidden = true
            windows.forEach { $0.hideForToggle() }
            hoverCoordinator.syncMonitors()
            ToastHUD.show(message: L("已暂藏 %@ 张桌面贴图 · 再按快捷键恢复", windows.count))
        } else {
            arePinsHidden = false
            windows.forEach { $0.orderFrontRegardless() }
            hoverCoordinator.syncMonitors()
            hoverCoordinator.reconcileSoon(delay: 0.05)
            ToastHUD.show(message: L("已恢复显示 %@ 张桌面贴图", windows.count))
        }
        onCountChanged?(windows.count)
    }

    func applyGlowStrengthToAll(_ strength: CGFloat) {
        let clamped = min(1.0, max(0.0, strength))
        defaultGlowStrength = clamped
        for w in windows { w.glowStrength = clamped; w.syncGlowState() }
    }

    func closeAll() {
        arePinsHidden = false
        let current = windows
        windows.removeAll()
        hoverCoordinator.stop()
        for w in current {
            w.closePin()
        }
        onCountChanged?(0)
    }
}
