import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 主控制器快存导出、独立窗口抓拍与截图翻译快捷入口扩展
extension AppController {
    @objc func startQuickTranslate() {
        beginCaptureSession(quickOCR: false, quickTranslate: true)
    }

    @objc func openTranslationSettings() {
        translationSettings.show(tab: .translation)
    }

    @objc func openGeneralPreferences() {
        translationSettings.show(tab: .general)
    }

    func performQuickSave(img: CGImage, scale: CGFloat) {
        let dir = ClipboardAndSave.resolveQuickSaveDirectory(preferred: config.lastSaveDirectory)
        performSaveToDirectory(img: img, scale: scale, directoryPath: dir.path, rememberDirectory: false)
    }

    func performSaveToDirectory(img: CGImage, scale: CGFloat, directoryPath: String, rememberDirectory: Bool = true) {
        let dirURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
        guard let url = ClipboardAndSave.quickSavePNG(cgImage: img, scaleFactor: scale, intoDirectory: dirURL) else {
            ToastHUD.show(message: "保存图片失败")
            return
        }
        if rememberDirectory {
            config.recordSaveDirectory(directoryPath)
            config.save()
            rebuildMenu()
        }
        let folderName = dirURL.lastPathComponent
        ToastHUD.show(
            message: "已保存到 \(folderName)/\(url.lastPathComponent)",
            actionTitle: "在 Finder 显示 ›",
            onAction: { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        )
    }

    func performPickDirectorySave(img: CGImage, scale: CGFloat) {
        guard let res = ClipboardAndSave.pickDirectoryAndQuickSave(
            cgImage: img,
            scaleFactor: scale,
            initialDirectory: config.lastSaveDirectory
        ) else { return }
        config.recordSaveDirectory(res.dir)
        config.save()
        rebuildMenu()
        let folderName = URL(fileURLWithPath: res.dir).lastPathComponent
        ToastHUD.show(
            message: "已保存到 \(folderName)/\(res.url.lastPathComponent)",
            actionTitle: "在 Finder 显示 ›",
            onAction: { NSWorkspace.shared.activateFileViewerSelecting([res.url]) }
        )
    }

    func performInteractiveSave(img: CGImage, scale: CGFloat) {
        if let newDir = ClipboardAndSave.savePNGInteractive(
            cgImage: img,
            scaleFactor: scale,
            initialDirectory: config.lastSaveDirectory
        ) {
            config.recordSaveDirectory(newDir)
            config.save()
            rebuildMenu()
        }
    }

    func captureAndExportIsolatedWindow(
        windowID: CGWindowID,
        scale: CGFloat,
        backdrop: BackdropStyle,
        pin: Bool,
        origin: CGPoint,
        screen: NSScreen
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let winImg = await ScreenCapturer.captureIsolatedWindow(
                windowID: windowID,
                scaleFactor: scale,
                backdropStyle: backdrop
            ) else {
                ToastHUD.show(message: "抓取独立窗口失败，请确认屏幕录制权限已开启")
                return
            }
            self.recordHistoryAndRefresh(img: winImg, scale: scale)
            if pin {
                self.pinManager.pin(cgImage: winImg, scaleFactor: scale, topLeftOnScreen: origin, screen: screen)
                ToastHUD.show(message: "已将纯净独立窗口贴到桌面")
            } else {
                ClipboardAndSave.copyToClipboard(cgImage: winImg, scaleFactor: scale)
                ToastHUD.show(message: "纯净独立窗口（含悬浮阴影）已复制到剪贴板")
            }
        }
    }

    func startRecordingSession(screen: NSScreen, rect: CGRect, initialFrame: CGImage?) {
        let rec = RegionRecordingSession()
        self.activeRecording = rec
        rec.onFormatChanged = { [weak self] fmt in
            guard let self else { return }
            self.config.preferredRecordingFormat = fmt
            self.config.save()
        }
        rec.onHUDPrefChanged = { [weak self] enabled in
            guard let self else { return }
            self.config.recordInteractionHUD = enabled
            self.config.save()
        }
        rec.onComplete = { [weak self] outcome in
            guard let self else { return }
            self.activeRecording = nil
            switch outcome {
            case .copiedFile(let url, let fmt):
                let kb = ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) / 1024
                ToastHUD.show(message: "\(fmt.badgeTitle) 已复制到剪贴板 (\(max(1, kb)) KB) · 可直接粘贴发送")
            case .savedFile(let url, let fmt, let dir):
                self.config.lastSaveDirectory = dir
                self.config.save()
                ToastHUD.show(message: "已保存 \(fmt.badgeTitle)：\(url.lastPathComponent)")
            case .cancelled:
                break
            }
        }
        rec.start(
            screen: screen,
            selectionLocalTopLeft: rect,
            initialCroppedFrame: initialFrame,
            defaultFormat: config.preferredRecordingFormat,
            interactionHUD: config.recordInteractionHUD,
            initialSaveDirectory: config.lastSaveDirectory,
            autoStartCountdown: true
        )
    }
}
