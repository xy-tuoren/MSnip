import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 应用主控制器：管理菜单栏常驻图标、全局快捷键路由、截图历史环、长截图、对照识字与贴图池
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var axMenuItem: NSMenuItem?
    var config = AppConfig.load()
    let hotKeyManager = HotKeyManager()
    let hotKeyRecorder = HotKeyRecorderController()
    let historyRing = CaptureHistoryRing(maxCount: 15)
    let pinManager = PinManager()
    let ocrController = OCRResultController()
    let permissionGuide = PermissionGuideController()
    var activeSession: OverlaySession?
    var activeLongShot: LongShotSession?
    var activeRecording: RegionRecordingSession?
    var isCapturing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        setupCallbacks()
        hotKeyManager.apply(config: config)
        if !CGPreflightScreenCaptureAccess() {
            permissionGuide.show(opening: .screenRecording)
        }
    }

    // MARK: - Setup

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "MSnip") {
                img.isTemplate = true
                button.image = img
            } else {
                button.title = "✂︎"
            }
            button.toolTip = "MSnip（麦截）— 轻量截图、长截图、动图录制、识字与贴图"
        }
        rebuildMenu()
    }

    private func setupCallbacks() {
        hotKeyManager.onCapture = { [weak self] in
            Task { @MainActor in self?.startCapture() }
        }
        hotKeyManager.onPin = { [weak self] in
            Task { @MainActor in self?.handlePinHotKey() }
        }
        hotKeyManager.onOCR = { [weak self] in
            Task { @MainActor in self?.startQuickOCR() }
        }
        hotKeyRecorder.onBeginRecording = { [weak self] in
            self?.hotKeyManager.unregisterAll()
        }
        hotKeyRecorder.onConfigUpdated = { [weak self] updated in
            guard let self else { return }
            self.config = updated
            self.config.save()
            self.hotKeyManager.apply(config: updated)
            self.rebuildMenu()
        }
        pinManager.onCountChanged = { [weak self] _ in
            self?.rebuildMenu()
        }
        permissionGuide.onPermissionChanged = { [weak self] in
            self?.rebuildMenu()
        }
        pinManager.onSaveImage = { [weak self] img, scale in
            guard let self else { return }
            if let dir = ClipboardAndSave.savePNGInteractive(
                cgImage: img,
                scaleFactor: scale,
                initialDirectory: self.config.lastSaveDirectory
            ) {
                self.config.lastSaveDirectory = dir
                self.config.save()
            }
        }
        pinManager.onQuickSaveImage = { [weak self] img, scale in
            self?.performQuickSave(img: img, scale: scale)
        }
        pinManager.onExtractOCR = { [weak self] img, scale, scr in
            self?.ocrController.present(cgImage: img, scaleFactor: scale, screen: scr)
        }
        ocrController.onPinImage = { [weak self] img, scale, scr in
            self?.pinManager.pin(cgImage: img, scaleFactor: scale, topLeftOnScreen: nil, screen: scr)
        }
    }

    // MARK: - Core Capture & LongShot Actions

    @objc func startCapture() { beginCaptureSession(quickOCR: false) }
    @objc func startQuickOCR() { beginCaptureSession(quickOCR: true) }

    private func beginCaptureSession(quickOCR: Bool) {
        guard activeSession == nil, activeLongShot == nil, activeRecording == nil, !isCapturing else { return }
        guard CGPreflightScreenCaptureAccess() else {
            permissionGuide.show(opening: .screenRecording)
            return
        }

        isCapturing = true
        let regionDetector = RegionDetector.captureBeforeOverlay()
        Task { @MainActor [weak self] in
            let snapshots = await ScreenCapturer.captureAllScreens()
            guard let self else { return }
            self.isCapturing = false
            guard !snapshots.isEmpty else {
                self.permissionGuide.show(opening: .screenRecording)
                return
            }

            let session = OverlaySession()
            self.activeSession = session

            session.onStyleUpdated = { [weak self] cIdx, width in
                guard let self else { return }
                self.config.defaultColorIndex = cIdx
                self.config.defaultLineWidth = width
                self.config.save()
            }
            session.onCapsuleUpdated = { [weak self] cap in
                guard let self else { return }
                self.config.defaultTextCapsule = cap
                self.config.save()
            }
            session.onPrefsUpdated = { [weak self] fmt, showTips in
                guard let self else { return }
                self.config.colorCopyFormat = fmt
                self.config.showShortcutTips = showTips
                self.config.save()
            }
            session.onQuickSaveInPlace = { [weak self] img, scale in
                guard let self else { return }
                self.recordHistoryAndRefresh(img: img, scale: scale)
                self.performQuickSave(img: img, scale: scale)
            }
            session.onComplete = { [weak self] outcome in
                self?.handleOverlayOutcome(outcome)
            }

            session.start(
                snapshots: snapshots,
                regionDetector: regionDetector,
                colorIndex: self.config.defaultColorIndex,
                lineWidth: self.config.defaultLineWidth,
                colorCopyFormat: self.config.colorCopyFormat,
                showShortcutTips: self.config.showShortcutTips,
                textCapsule: self.config.defaultTextCapsule,
                pinHint: self.config.activePinCombo.displayString,
                quickOCRMode: quickOCR
            )
        }
    }

    private func handleOverlayOutcome(_ outcome: OverlaySession.Outcome) {
        activeSession = nil
        switch outcome {
        case .copied(let img, let scale):
            ClipboardAndSave.copyToClipboard(cgImage: img, scaleFactor: scale)
            recordHistoryAndRefresh(img: img, scale: scale)
        case .saved(let img, let scale):
            recordHistoryAndRefresh(img: img, scale: scale)
            if let newDir = ClipboardAndSave.savePNGInteractive(
                cgImage: img,
                scaleFactor: scale,
                initialDirectory: config.lastSaveDirectory
            ) {
                config.lastSaveDirectory = newDir
                config.save()
            }
        case .quickSaved(let img, let scale):
            recordHistoryAndRefresh(img: img, scale: scale)
            performQuickSave(img: img, scale: scale)
        case .pinned(let img, let scale, let origin, let screen):
            recordHistoryAndRefresh(img: img, scale: scale)
            pinManager.pin(cgImage: img, scaleFactor: scale, topLeftOnScreen: origin, screen: screen)
        case .isolatedWindow(let winID, let scale, let backdrop, let shouldPin, let origin, let screen):
            captureAndExportIsolatedWindow(
                windowID: winID, scale: scale, backdrop: backdrop,
                pin: shouldPin, origin: origin, screen: screen
            )
        case .copiedColor(let value, let swatch, let pt):
            ClipboardAndSave.copyText(value)
            ToastHUD.show(message: "\(value) 已复制  ·  \(config.activePinCombo.displayString) 贴色卡", swatch: swatch, near: pt)
        case .copiedCoordinate(let value, let pt):
            ClipboardAndSave.copyText(value)
            ToastHUD.show(message: "坐标 \(value) 已复制", near: pt)
        case .extractText(let img, let scale, let scr):
            ocrController.present(cgImage: img, scaleFactor: scale, screen: scr)
        case .startLongShot(let screen, let rect, let initialImg):
            startLongShotSession(screen: screen, rect: rect, initialFrame: initialImg)
        case .startRecording(let screen, let rect, let initialImg):
            startRecordingSession(screen: screen, rect: rect, initialFrame: initialImg)
        case .cancelled:
            break
        }
    }

    private func startLongShotSession(screen: NSScreen, rect: CGRect, initialFrame: CGImage?) {
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
            case .saved(let img, let scale):
                self.recordHistoryAndRefresh(img: img, scale: scale)
                if let newDir = ClipboardAndSave.savePNGInteractive(
                    cgImage: img,
                    scaleFactor: scale,
                    initialDirectory: self.config.lastSaveDirectory
                ) {
                    self.config.lastSaveDirectory = newDir
                    self.config.save()
                }
            case .pinned(let img, let scale, let origin, let targetScreen):
                self.recordHistoryAndRefresh(img: img, scale: scale)
                self.pinManager.pin(cgImage: img, scaleFactor: scale, topLeftOnScreen: origin, screen: targetScreen)
            case .cancelled:
                break
            }
        }
        longShot.start(
            screen: screen,
            selectionLocalTopLeft: rect,
            initialCroppedFrame: initialFrame,
            pinHint: config.activePinCombo.displayString
        )
    }

    func recordHistoryAndRefresh(img: CGImage, scale: CGFloat) {
        historyRing.record(cgImage: img, scaleFactor: scale)
        rebuildMenu()
    }

    private func startRecordingSession(screen: NSScreen, rect: CGRect, initialFrame: CGImage?) {
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
            initialSaveDirectory: config.lastSaveDirectory
        )
    }

    @objc func handlePinHotKey() {
        if let ls = activeLongShot, ls.pinCurrentIfPossible() { return }
        if let session = activeSession, session.pinCurrentSelectionIfPossible() { return }
        guard activeSession == nil, activeLongShot == nil, activeRecording == nil else { return }
        pinManager.pinFromClipboard()
    }
}
