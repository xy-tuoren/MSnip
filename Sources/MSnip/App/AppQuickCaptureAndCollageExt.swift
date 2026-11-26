import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 主控制器一键全屏抓屏扩展
extension AppController {
    /// 一键抓取鼠标所在显示器整屏（菜单触发时按住 ⌥ 强制直接快存；快捷键触发按偏好设定执行）
    @objc func captureCurrentFullScreen() {
        performFullScreenCapture(fromMenu: true)
    }

    func performFullScreenCapture(fromMenu: Bool) {
        if isStatusMenuOpen {
            runAfterStatusMenuDismissed(fromMenuClick: fromMenu) { [weak self] in
                self?.performFullScreenCapture(fromMenu: false)
            }
            return
        }
        if hasDelayedCapture { delayedCapture.cancel() }
        guard activeSession == nil, activeLongShot == nil, activeRecording == nil, !isCapturing else { return }
        let effectiveAction: FullScreenCaptureAction = (fromMenu && NSEvent.modifierFlags.contains(.option))
            ? .save
            : config.fullScreenCaptureAction
        let mouse = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen = targetScreen,
              let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map({ CGDirectDisplayID($0.uint32Value) }) else {
            return
        }
        ToastHUD.dismissImmediate()
        isCapturing = true
        Task { @MainActor [weak self] in
            // 仅菜单点击触发时稍等 40ms 待顶部菜单收起，全局快捷键触发零延迟直抓
            if fromMenu { try? await Task.sleep(nanoseconds: 40_000_000) }
            let snap = await ScreenCapturer.captureScreen(displayID: displayID)
            guard let self else { return }
            self.isCapturing = false
            guard let snap else {
                ScreenCapturer.runtimeVerifiedAccess = false
                self.permissionGuide.show(opening: .screenRecording)
                return
            }
            let img = snap.cgImage
            let scale = snap.scaleFactor
            self.recordHistoryAndRefresh(img: img, scale: scale)
            switch effectiveAction {
            case .copy:
                ClipboardAndSave.copyToClipboard(cgImage: img, scaleFactor: scale)
                ClipboardAndSave.playFeedbackSound(enabled: self.config.soundFeedbackEnabled)
                ToastHUD.show(
                    message: "✓ 已截取当前全屏并复制",
                    subtitle: "\(img.width) × \(img.height) px",
                    preview: img,
                    actionTitle: "保存到默认目录 ›",
                    onAction: { [weak self] in self?.performQuickSave(img: img, scale: scale) }
                )
            case .save:
                self.performQuickSave(img: img, scale: scale)
            case .copyAndSave:
                ClipboardAndSave.copyToClipboard(cgImage: img, scaleFactor: scale)
                let dir = ClipboardAndSave.resolveQuickSaveDirectory(preferred: self.config.lastSaveDirectory)
                let savedURL = ClipboardAndSave.quickSavePNG(
                    cgImage: img, scaleFactor: scale, intoDirectory: dir,
                    format: self.config.exportImageFormat, exportAt1x: self.config.exportAt1xScale,
                    filenameTemplate: self.config.filenameTemplate
                )
                ClipboardAndSave.playFeedbackSound(enabled: self.config.soundFeedbackEnabled)
                if let url = savedURL {
                    let shortPath = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
                    ToastHUD.show(
                        message: "✓ 已截取当前全屏（已复制并保存）",
                        subtitle: shortPath,
                        preview: img,
                        actionTitle: "在访达中显示",
                        onAction: { ClipboardAndSave.revealInFinder(url) }
                    )
                } else {
                    ToastHUD.show(message: "✓ 已复制当前全屏（保存文件失败）", preview: img)
                }
            }
        }
    }
}
