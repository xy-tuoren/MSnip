import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 应用主控制器：管理菜单栏常驻图标、全局快捷键路由、截图历史环、长截图、对照识字与贴图池
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var axMenuItem: NSMenuItem?
    var permWarnSepItem: NSMenuItem?
    var loginMenuItem: NSMenuItem?
    var historyRootItem: NSMenuItem?
    var historySubmenu: NSMenu?
    var config = AppConfig.load()
    let hotKeyManager = HotKeyManager()
    let historyRing = CaptureHistoryRing(maxCount: 15)
    let pinManager = PinManager()
    let ocrController = OCRResultController()
    let latexController = LatexResultController()
    let translationSettings = TranslationSettingsWindow()
    let permissionGuide = PermissionGuideController()
    let delayedCapture = DelayedCaptureController()
    var activeSession: OverlaySession?
    var activeLongShot: LongShotSession?
    var activeRecording: RegionRecordingSession?
    var isCapturing = false
    var isStatusMenuOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        GeekTheme.currentMode = config.appearanceMode
        ResultWindowChrome.prefersDarkAppearance = GeekTheme.isDark
        SmartClipboardProjectionManager.shared.isAdaptiveEnabled = config.terminalPasteAdaptEnabled
        pinManager.defaultGlowStrength = config.pinGlowStrength
        setupStatusBar()
        setupCallbacks()
        hotKeyManager.apply(config: config)
        // 启动期仅做轻量权限探测，不在空载时提前拉起 ScreenCaptureKit / Metal 图形池以压低常驻内存
        Task { @MainActor [weak self] in
            let ok = await ScreenCapturer.hasScreenCapturePermission()
            guard let self else { return }
            self.rebuildMenu()
            if !ok {
                self.permissionGuide.show(opening: .screenRecording)
            }
        }
    }

    // MARK: - Setup

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = MSnipUITheme.menuBarIcon(recording: false)
            button.imagePosition = .imageOnly
            button.toolTip = "MSnip（麦截）— 轻量截图、长截图、动图录制、识字与贴图"
        }
        rebuildMenu()
    }

    func updateMenuBarRecordingState(_ recording: Bool) {
        statusItem?.button?.image = MSnipUITheme.menuBarIcon(recording: recording)
    }

    private func setupCallbacks() {
        hotKeyManager.onTrigger = { [weak self] action in
            Task { @MainActor in self?.handleGlobalHotKey(action) }
        }
        pinManager.onCountChanged = { [weak self] _ in
            self?.rebuildMenu()
        }
        permissionGuide.onPermissionChanged = { [weak self] in
            guard let self else { return }
            self.hotKeyManager.apply(config: self.config)
            self.rebuildMenu()
        }
        pinManager.onSaveImage = { [weak self] img, scale in self?.performInteractiveSave(img: img, scale: scale) }
        pinManager.onQuickSaveImage = { [weak self] img, scale in self?.performQuickSave(img: img, scale: scale) }
        pinManager.onExtractOCR = { [weak self] img, scale, scr in self?.ocrController.present(cgImage: img, scaleFactor: scale, screen: scr) }
        pinManager.onTranslateImage = { [weak self] img, scale, scr in self?.ocrController.present(cgImage: img, scaleFactor: scale, screen: scr, autoTranslate: true) }
        pinManager.onGlowStrengthChanged = { [weak self] g in guard let self else { return }; self.config.pinGlowStrength = g; self.config.save() }
        ocrController.ocrAutoCopyProvider = { [weak self] in
            self?.config.ocrAutoCopy ?? true
        }
        ocrController.onPinImage = { [weak self] img, scale, scr in
            self?.pinManager.pin(cgImage: img, scaleFactor: scale, topLeftOnScreen: nil, screen: scr)
        }
        ocrController.onRecognizeLatex = { [weak self] img, scale, scr in
            self?.latexController.present(cgImage: img, scaleFactor: scale, screen: scr)
        }
        ocrController.onOpenSettings = { [weak self] in
            self?.translationSettings.show(tab: .translation)
        }
        latexController.onPinImage = { [weak self] img, scale, scr in
            self?.pinManager.pin(cgImage: img, scaleFactor: scale, topLeftOnScreen: nil, screen: scr)
        }
        latexController.onOpenMainAISettings = { [weak self] in
            self?.translationSettings.show(tab: .translation)
        }
        translationSettings.appConfigProvider = { [weak self] in
            self?.config ?? AppConfig()
        }
        translationSettings.isPriorityTapActiveProvider = { [weak self] in
            self?.hotKeyManager.isPriorityTapActive ?? false
        }
        translationSettings.shortcutAudit.failedHotKeyActionsProvider = { [weak self] in
            self?.hotKeyManager.failedActions ?? []
        }
        translationSettings.onReapplyHotKeys = { [weak self] in
            guard let self else { return }
            self.hotKeyManager.apply(config: self.config)
        }
        translationSettings.onAppConfigMutated = { [weak self] mutate in
            guard let self else { return }
            mutate(&self.config)
            self.config.save()
            SmartClipboardProjectionManager.shared.isAdaptiveEnabled = self.config.terminalPasteAdaptEnabled
            self.hotKeyManager.apply(config: self.config)
            self.rebuildMenu()
        }
        translationSettings.onBeginHotKeyRecording = { [weak self] in
            self?.hotKeyManager.unregisterAll()
        }
        translationSettings.onEndHotKeyRecording = { [weak self] in
            guard let self else { return }
            self.hotKeyManager.apply(config: self.config)
        }
        translationSettings.onOpenPermissionGuide = { [weak self] in
            self?.openPermissionGuide()
        }
    }

    // MARK: - Core Capture & LongShot Actions

    @objc func startCapture(_ sender: Any? = nil) { beginCaptureSession(mode: .standard, fromMenuClick: sender is NSMenuItem) }
    @objc func startQuickOCR(_ sender: Any? = nil) { beginCaptureSession(mode: .quickOCR, fromMenuClick: sender is NSMenuItem) }

    func beginCaptureSession(mode: OverlayQuickLaunchMode = .standard, fromMenuClick: Bool = false) {
        if isStatusMenuOpen || fromMenuClick {
            runAfterStatusMenuDismissed(fromMenuClick: fromMenuClick) { [weak self] in
                self?.beginCaptureSession(mode: mode, fromMenuClick: false)
            }
            return
        }
        delayedCapture.cancel()
        guard activeSession == nil, activeLongShot == nil, activeRecording == nil, !isCapturing else { return }
        ToastHUD.dismissImmediate()

        isCapturing = true
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        Task { @MainActor [weak self] in
            async let detectorTask = Task.detached(priority: .userInitiated) {
                RegionDetector.captureBeforeOverlay(primaryScreenHeight: primaryH, frontmostPID: frontPID)
            }.value
            async let snapshotsTask = ScreenCapturer.captureAllScreens()
            let (regionDetector, snapshots) = await (detectorTask, snapshotsTask)
            guard let self else { return }
            self.isCapturing = false
            guard !snapshots.isEmpty else {
                ScreenCapturer.runtimeVerifiedAccess = false
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
            session.onRecordingPrefsUpdated = { [weak self] fmt, hud in
                guard let self else { return }
                self.config.preferredRecordingFormat = fmt; self.config.recordInteractionHUD = hud; self.config.save()
            }
            session.onGlowStrengthUpdated = { [weak self] g in
                guard let self else { return }
                self.config.pinGlowStrength = g; self.pinManager.defaultGlowStrength = g; self.config.save()
            }
            session.onQuickSaveInPlace = { [weak self] img, scale in
                guard let self else { return }
                self.recordHistoryAndRefresh(img: img, scale: scale)
                self.performQuickSave(img: img, scale: scale)
            }
            session.onComplete = { [weak self] outcome in
                self?.handleOverlayOutcome(outcome)
            }

            let pinCombo = self.config.activeCombo(for: .pin)
            session.start(
                snapshots: snapshots,
                regionDetector: regionDetector,
                colorIndex: self.config.defaultColorIndex,
                lineWidth: self.config.defaultLineWidth,
                colorCopyFormat: self.config.colorCopyFormat,
                showShortcutTips: self.config.showShortcutTips,
                textCapsule: self.config.defaultTextCapsule,
                pinHint: pinCombo?.displayString ?? "",
                saveFolderOptions: ClipboardAndSave.quickSaveFolders(
                    preferred: self.config.lastSaveDirectory,
                    recent: self.config.recentSaveDirectories
                ),
                recordingFormat: self.config.preferredRecordingFormat,
                recordingHUDEnabled: self.config.recordInteractionHUD,
                launchMode: mode,
                canvasKeyMap: self.config.resolvedCanvasKeyMap,
                activePinCombo: pinCombo,
                ocrAutoOpenDualPane: self.config.ocrAutoOpenDualPane,
                translateAutoOpenDualPane: self.config.translateAutoOpenDualPane,
                ocrAutoCopy: self.config.ocrAutoCopy,
                backdropAspectRatio: self.config.backdropAspectRatio,
                backdropWatermark: self.config.backdropWatermark,
                pinGlowStrength: self.config.pinGlowStrength
            )
        }
    }

    private func handleOverlayOutcome(_ outcome: OverlaySession.Outcome) {
        activeSession = nil
        switch outcome {
        case .copied(let img, let scale):
            ClipboardAndSave.copyToClipboard(cgImage: img, scaleFactor: scale)
            ClipboardAndSave.playFeedbackSound(enabled: config.soundFeedbackEnabled)
            recordHistoryAndRefresh(img: img, scale: scale)
        case .copiedWithPath(let img, let scale):
            ClipboardAndSave.copyToClipboard(cgImage: img, scaleFactor: scale, forceIncludePath: true)
            ClipboardAndSave.playFeedbackSound(enabled: config.soundFeedbackEnabled)
            recordHistoryAndRefresh(img: img, scale: scale)
            ToastHUD.show(message: "已复制截图与临时 PNG 路径")
        case .saved(let img, let scale):
            recordHistoryAndRefresh(img: img, scale: scale)
            performInteractiveSave(img: img, scale: scale)
        case .quickSaved(let img, let scale):
            recordHistoryAndRefresh(img: img, scale: scale)
            performQuickSave(img: img, scale: scale)
        case .savedToFolder(let img, let scale, let dir):
            recordHistoryAndRefresh(img: img, scale: scale)
            performSaveToDirectory(img: img, scale: scale, directoryPath: dir)
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
            let pLabel = config.activeCombo(for: .pin)?.displayString
            let msg = pLabel.map { "\(value) 已复制  ·  \($0) 贴色卡" } ?? "\(value) 已复制"
            ToastHUD.show(message: msg, swatch: swatch, near: pt)
        case .copiedCoordinate(let value, let pt):
            ClipboardAndSave.copyText(value)
            ToastHUD.show(message: "坐标 \(value) 已复制", near: pt)
        case .extractText(let img, let scale, let scr):
            ocrController.present(cgImage: img, scaleFactor: scale, screen: scr, autoTranslate: false)
        case .recognizeLatex(let img, let scale, let scr):
            latexController.present(cgImage: img, scaleFactor: scale, screen: scr)
        case .translateText(let img, let scale, let scr):
            ocrController.present(cgImage: img, scaleFactor: scale, screen: scr, autoTranslate: true)
        case .openTranslationSettings:
            translationSettings.show(tab: .translation)
        case .startLongShot(let screen, let rect, let initialImg):
            startLongShotSession(screen: screen, rect: rect, initialFrame: initialImg)
        case .startRecording(let screen, let rect, let initialImg):
            startRecordingSession(screen: screen, rect: rect, initialFrame: initialImg)
        case .cancelled:
            break
        }
    }

    func recordHistoryAndRefresh(img: CGImage, scale: CGFloat, isCollage: Bool = false) {
        historyRing.record(cgImage: img, scaleFactor: scale, isCollage: isCollage)
        rebuildMenu()
    }
}
