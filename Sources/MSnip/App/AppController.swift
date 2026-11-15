import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 应用主控制器：管理菜单栏常驻图标、全局快捷键路由、截图会话、滚动长截图、对照识字与贴图池
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var axMenuItem: NSMenuItem?
    var config = AppConfig.load()
    private let hotKeyManager = HotKeyManager()
    let pinManager = PinManager()
    private let ocrController = OCRResultController()
    private let permissionGuide = PermissionGuideController()
    private var activeSession: OverlaySession?
    private var activeLongShot: LongShotSession?
    private var isCapturing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        setupCallbacks()
        hotKeyManager.apply(preset: config.hotKeyPreset, enabled: config.hotKeysEnabled)
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
            button.toolTip = "MSnip（麦截）— 轻量截图、长截图、实况识字与贴图"
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
        pinManager.onExtractOCR = { [weak self] img, scale, scr in
            self?.ocrController.present(cgImage: img, scaleFactor: scale, screen: scr)
        }
        ocrController.onPinImage = { [weak self] img, scale, scr in
            self?.pinManager.pin(cgImage: img, scaleFactor: scale, topLeftOnScreen: nil, screen: scr)
        }
    }

    // MARK: - Core Actions

    @objc func startCapture() {
        beginCaptureSession(quickOCR: false)
    }

    @objc func startQuickOCR() {
        beginCaptureSession(quickOCR: true)
    }

    private func beginCaptureSession(quickOCR: Bool) {
        guard activeSession == nil, activeLongShot == nil, !isCapturing else { return }
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

            session.onPrefsUpdated = { [weak self] fmt, showTips in
                guard let self else { return }
                self.config.colorCopyFormat = fmt
                self.config.showShortcutTips = showTips
                self.config.save()
            }

            session.onComplete = { [weak self] outcome in
                guard let self else { return }
                self.activeSession = nil
                switch outcome {
                case .copied(let img, let scale):
                    ClipboardAndSave.copyToClipboard(cgImage: img, scaleFactor: scale)
                case .saved(let img, let scale):
                    if let newDir = ClipboardAndSave.savePNGInteractive(
                        cgImage: img,
                        scaleFactor: scale,
                        initialDirectory: self.config.lastSaveDirectory
                    ) {
                        self.config.lastSaveDirectory = newDir
                        self.config.save()
                    }
                case .pinned(let img, let scale, let origin, let screen):
                    self.pinManager.pin(cgImage: img, scaleFactor: scale, topLeftOnScreen: origin, screen: screen)
                case .copiedColor(let value, let swatch, let pt):
                    ClipboardAndSave.copyText(value)
                    ToastHUD.show(message: "\(value) 已复制  ·  \(self.config.hotKeyPreset.pinBadgeLabel) 贴色卡", swatch: swatch, near: pt)
                case .copiedCoordinate(let value, let pt):
                    ClipboardAndSave.copyText(value)
                    ToastHUD.show(message: "坐标 \(value) 已复制", near: pt)
                case .extractText(let img, let scale, let scr):
                    self.ocrController.present(cgImage: img, scaleFactor: scale, screen: scr)
                case .startLongShot(let screen, let rect, let initialImg):
                    self.startLongShotSession(screen: screen, rect: rect, initialFrame: initialImg)
                case .cancelled:
                    break
                }
            }

            session.start(
                snapshots: snapshots,
                regionDetector: regionDetector,
                colorIndex: self.config.defaultColorIndex,
                lineWidth: self.config.defaultLineWidth,
                colorCopyFormat: self.config.colorCopyFormat,
                showShortcutTips: self.config.showShortcutTips,
                pinHint: self.config.hotKeyPreset.pinBadgeLabel,
                quickOCRMode: quickOCR
            )
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
                ToastHUD.show(message: "长截图已复制 · \(img.width) × \(img.height) px")
            case .saved(let img, let scale):
                if let newDir = ClipboardAndSave.savePNGInteractive(
                    cgImage: img,
                    scaleFactor: scale,
                    initialDirectory: self.config.lastSaveDirectory
                ) {
                    self.config.lastSaveDirectory = newDir
                    self.config.save()
                }
            case .pinned(let img, let scale, let origin, let targetScreen):
                self.pinManager.pin(cgImage: img, scaleFactor: scale, topLeftOnScreen: origin, screen: targetScreen)
            case .cancelled:
                break
            }
        }
        longShot.start(
            screen: screen,
            selectionLocalTopLeft: rect,
            initialCroppedFrame: initialFrame,
            pinHint: config.hotKeyPreset.pinBadgeLabel
        )
    }

    @objc func handlePinHotKey() {
        if let ls = activeLongShot, ls.pinCurrentIfPossible() { return }
        if let session = activeSession, session.pinCurrentSelectionIfPossible() { return }
        guard activeSession == nil, activeLongShot == nil else { return }
        pinManager.pinFromClipboard()
    }

    @objc func closeAllPins() { pinManager.closeAll() }

    @objc func selectHotKeyPreset(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preset = HotKeyPreset(rawValue: raw) else { return }
        config.hotKeyPreset = preset
        config.hotKeysEnabled = true
        config.save()
        hotKeyManager.apply(preset: preset, enabled: true)
        rebuildMenu()
    }

    @objc func toggleHotKeysEnabled() {
        config.hotKeysEnabled.toggle()
        config.save()
        hotKeyManager.apply(preset: config.hotKeyPreset, enabled: config.hotKeysEnabled)
        rebuildMenu()
    }

    @objc func toggleLaunchAtLogin() {
        let target = !LaunchAtLoginManager.isEnabled
        _ = LaunchAtLoginManager.setEnabled(target)
        rebuildMenu()
    }

    @objc func openPermissionGuide() {
        let pane: PermissionPane? = !CGPreflightScreenCaptureAccess()
            ? .screenRecording
            : (!RegionDetector.checkAccessibilityPermission(prompt: false) ? .accessibility : nil)
        permissionGuide.show(opening: pane)
    }

    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "MSnip（麦截）v0.9.0"
        alert.informativeText = """
        超轻量原生 macOS 截图、滚动长截图、实况识字与贴图工具
        • 纯 Swift + AppKit + CoreGraphics + ScreenCaptureKit + VisionKit，零第三方依赖
        • ⌘3 框选即识字 / 截图中按 T：弹出「左图实况划词 + 右侧可编辑/合并段落」对照窗
        • 桌面贴图内置 Live Text：鼠标移到贴图文字上直接变 I 光标划词复制
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc func quitApp() { NSApp.terminate(nil) }
}
