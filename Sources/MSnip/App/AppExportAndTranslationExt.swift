import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 主控制器快存导出、独立窗口抓拍与截图翻译快捷入口扩展
extension AppController {
    func handleGlobalHotKey(_ action: GlobalHotKeyAction) {
        switch action {
        case .capture:           startCapture()
        case .pin:               handlePinHotKey()
        case .ocr:               startQuickOCR()
        case .translate:         startQuickTranslate()
        case .longShot:          startQuickLongShot()
        case .record:            startQuickRecord()
        case .delayedCapture:    startDefaultDelayedCapture()
        case .fullScreenCapture: performFullScreenCapture(fromMenu: false)
        case .latex:             startQuickLatex()
        case .togglePins:        togglePinsVisibility()
        case .repeatCapture:     repeatLastCapture()
        case .toggleShelf:       toggleTopShelf()
        }
    }

    @objc func startDefaultDelayedCapture() {
        if isStatusMenuOpen {
            statusItem.menu?.cancelTrackingWithoutAnimation()
            isStatusMenuOpen = false
        }
        if delayedCapture.isRunning {
            delayedCapture.cancel(showToast: true)
            return
        }
        let secs = DelayedCaptureSettings.clampedSeconds(config.delayedCaptureSeconds)
        delayedCapture.start(seconds: secs) { [weak self] in self?.beginCaptureSession(mode: .standard) }
    }

    @objc func startQuickTranslate(_ sender: Any? = nil) { beginCaptureSession(mode: .quickTranslate, fromMenuClick: sender is NSMenuItem) }
    @objc func startQuickLongShot(_ sender: Any? = nil) { beginCaptureSession(mode: .quickLongShot, fromMenuClick: sender is NSMenuItem) }
    @objc func startQuickRecord(_ sender: Any? = nil) { beginCaptureSession(mode: .quickRecord, fromMenuClick: sender is NSMenuItem) }
    @objc func startQuickLatex(_ sender: Any? = nil) { beginCaptureSession(mode: .quickLatex, fromMenuClick: sender is NSMenuItem) }
    @objc func togglePinsVisibility() { pinManager.toggleAllVisibility() }

    @objc func repeatLastCapture() {
        guard activeSession == nil, activeLongShot == nil, activeRecording == nil, !isCapturing else { return }
        guard let target = OverlaySession.lastCaptureTarget else {
            startCapture()
            return
        }
        isCapturing = true
        Task { @MainActor [weak self] in
            let snap = await ScreenCapturer.captureScreen(displayID: target.displayID)
            guard let self else { return }
            self.isCapturing = false
            guard let snap else {
                self.permissionGuide.show(opening: .screenRecording)
                return
            }
            let s = snap.scaleFactor
            let clamped = target.rect.intersection(CGRect(origin: .zero, size: snap.screen.frame.size))
            let pxRect = CGRect(
                x: round(clamped.minX * s), y: round(clamped.minY * s),
                width: max(2, round(clamped.width * s)), height: max(2, round(clamped.height * s))
            )
            guard let cropped = snap.cgImage.cropping(to: pxRect) else { return }
            ClipboardAndSave.copyToClipboard(cgImage: cropped, scaleFactor: s)
            self.recordHistoryAndRefresh(img: cropped, scale: s)
            ToastHUD.show(message: "✓ 已重截上次区域并复制", subtitle: "\(cropped.width) × \(cropped.height) px", preview: cropped)
        }
    }

    @objc func openTranslationSettings() {
        translationSettings.show(tab: .translation)
    }

    @objc func openShortcutsSettings() {
        translationSettings.show(tab: .shortcuts)
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
        guard let url = ClipboardAndSave.quickSavePNG(
            cgImage: img, scaleFactor: scale, intoDirectory: dirURL,
            format: config.exportImageFormat, exportAt1x: config.exportAt1xScale,
            filenameTemplate: config.filenameTemplate
        ) else {
            ToastHUD.show(message: "保存图片失败")
            return
        }
        ClipboardAndSave.playFeedbackSound(enabled: config.soundFeedbackEnabled)
        if rememberDirectory {
            config.recordSaveDirectory(directoryPath)
            config.save()
            rebuildMenu()
        }
        let shortDir = dirURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        ToastHUD.show(
            message: "✓ 已保存截图至「\(dirURL.lastPathComponent)」",
            subtitle: "\(shortDir)/\(url.lastPathComponent)",
            preview: img,
            actionTitle: "在访达中显示",
            onAction: { [weak self] in
                self?.activeSession?.cancel()
                ClipboardAndSave.revealInFinder(url)
            }
        )
    }

    func performInteractiveSave(img: CGImage, scale: CGFloat) {
        guard let res = ClipboardAndSave.savePNGInteractive(
            cgImage: img,
            scaleFactor: scale,
            initialDirectory: config.recentSaveDirectories.first ?? config.lastSaveDirectory,
            format: config.exportImageFormat,
            exportAt1x: config.exportAt1xScale,
            filenameTemplate: config.filenameTemplate
        ) else { return }
        ClipboardAndSave.playFeedbackSound(enabled: config.soundFeedbackEnabled)
        config.recordSaveDirectory(res.dir)
        config.save()
        rebuildMenu()
        let folderName = URL(fileURLWithPath: res.dir).lastPathComponent
        let shortPath = res.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        ToastHUD.show(
            message: "✓ 已保存截图至「\(folderName)」",
            subtitle: shortPath,
            preview: img,
            actionTitle: "在访达中显示",
            onAction: { [weak self] in
                self?.activeSession?.cancel()
                ClipboardAndSave.revealInFinder(res.url)
            }
        )
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
        updateMenuBarRecordingState(true)
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
            self.updateMenuBarRecordingState(false)
            switch outcome {
            case .copiedFile(let url, let fmt):
                let kb = ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) / 1024
                ToastHUD.show(message: "\(fmt.badgeTitle) 已复制到剪贴板 (\(max(1, kb)) KB) · 可直接粘贴发送")
            case .savedFile(let url, let fmt, let dir):
                self.config.recordSaveDirectory(dir)
                self.config.save()
                ToastHUD.show(
                    message: "✓ 已保存 \(fmt.badgeTitle) 录屏文件",
                    subtitle: url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                    actionTitle: "在访达中显示 ›",
                    onAction: { ClipboardAndSave.revealInFinder(url) }
                )
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
            recordingOptions: config.recordingOptions,
            initialSaveDirectory: config.lastSaveDirectory,
            autoStartCountdown: true
        )
    }

    func startLongShotSession(screen: NSScreen, rect: CGRect, initialFrame: CGImage?) {
        let longShot = LongShotSession()
        self.activeLongShot = longShot
        longShot.onComplete = { [weak self] outcome in
            guard let self else { return }
            self.activeLongShot = nil
            switch outcome {
            case .copied(let img, let scale):
                ClipboardAndSave.copyToClipboard(cgImage: img, scaleFactor: scale)
                self.recordHistoryAndRefresh(img: img, scale: scale)
                ToastHUD.show(message: "长截图已复制 · \(img.width) × \(img.height) px")
            case .quickSaved(let img, let scale):
                self.recordHistoryAndRefresh(img: img, scale: scale)
                self.performQuickSave(img: img, scale: scale)
            case .saved(let img, let scale):
                self.recordHistoryAndRefresh(img: img, scale: scale)
                self.performInteractiveSave(img: img, scale: scale)
            case .pinned(let img, let scale, let origin, let targetScreen):
                self.recordHistoryAndRefresh(img: img, scale: scale)
                self.pinManager.pin(cgImage: img, scaleFactor: scale, topLeftOnScreen: origin, screen: targetScreen)
            case .pinAndAnnotate(let img, let scale, let origin, let targetScreen):
                self.recordHistoryAndRefresh(img: img, scale: scale)
                let pinWin = self.pinManager.pin(cgImage: img, scaleFactor: scale, topLeftOnScreen: origin, screen: targetScreen)
                pinWin.beginAnnotationEditing()
            case .extractText(let img, let scale, let targetScreen):
                self.recordHistoryAndRefresh(img: img, scale: scale)
                self.ocrController.present(cgImage: img, scaleFactor: scale, screen: targetScreen, autoTranslate: false)
            case .translateText(let img, let scale, let targetScreen):
                self.recordHistoryAndRefresh(img: img, scale: scale)
                self.ocrController.present(cgImage: img, scaleFactor: scale, screen: targetScreen, autoTranslate: true)
            case .cancelled:
                break
            }
        }
        longShot.start(
            screen: screen,
            selectionLocalTopLeft: rect,
            initialCroppedFrame: initialFrame,
            pinHint: config.activeCombo(for: .pin)?.displayString ?? "P"
        )
    }

    @objc func handlePinHotKey() {
        if let ls = activeLongShot, ls.pinCurrentIfPossible() { return }
        if let session = activeSession, session.pinCurrentSelectionIfPossible() { return }
        guard activeSession == nil, activeLongShot == nil, activeRecording == nil else { return }
        pinManager.pinFromClipboard()
    }
}
