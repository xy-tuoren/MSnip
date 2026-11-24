import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 主控制器一键全屏抓屏与最近历史多图对比拼接扩展
extension AppController {
    /// 一键抓取鼠标所在显示器整屏（菜单触发时按住 ⌥ 强制直接快存；快捷键触发按偏好设定执行）
    @objc func captureCurrentFullScreen() {
        performFullScreenCapture(fromMenu: true)
    }

    func performFullScreenCapture(fromMenu: Bool) {
        delayedCapture.cancel()
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

    /// 将最近 N 张历史截图拼成横向对比图或纵向长图（tag 编码：方向 * 10 + 张数，1=横向, 2=纵向）
    @objc func createHistoryCollage(_ sender: NSMenuItem) {
        let dirCode = sender.tag / 10
        let count = max(2, sender.tag % 10)
        let direction: CollageDirection = (dirCode == 2) ? .vertical : .horizontal
        let slice = Array(historyRing.entries.prefix(count)).reversed()
        let loaded: [(CGImage, CGFloat)] = slice.compactMap { entry in
            guard let cg = historyRing.loadCGImage(for: entry) else { return nil }
            return (cg, entry.scaleFactor)
        }
        guard loaded.count >= 2 else {
            ToastHUD.show(message: "至少需要 2 张最近截图才可拼接")
            return
        }
        let images = loaded.map(\.0)
        let refScale = loaded.last?.1 ?? 2.0
        let dirLabel = direction == .horizontal ? "横向对比拼图" : "纵向长拼图"
        Task { @MainActor [weak self] in
            let stitched = await Task.detached(priority: .userInitiated) {
                ImageCollageStitcher.stitch(images: images, direction: direction)
            }.value
            guard let self, let stitched else {
                ToastHUD.show(message: "拼图合成失败")
                return
            }
            ClipboardAndSave.copyToClipboard(cgImage: stitched, scaleFactor: refScale)
            ClipboardAndSave.playFeedbackSound(enabled: self.config.soundFeedbackEnabled)
            self.recordHistoryAndRefresh(img: stitched, scale: refScale)
            ToastHUD.show(
                message: "✓ 已生成 \(loaded.count) 图\(dirLabel)并复制",
                subtitle: "\(stitched.width) × \(stitched.height) px",
                preview: stitched,
                actionTitle: "贴到桌面 ›",
                onAction: { [weak self] in
                    if let scr = NSScreen.main ?? NSScreen.screens.first {
                        self?.pinManager.pin(cgImage: stitched, scaleFactor: refScale, topLeftOnScreen: nil, screen: scr)
                    }
                }
            )
        }
    }
}
