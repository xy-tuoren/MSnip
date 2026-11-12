import AppKit
import CoreGraphics
import Foundation

/// 应用主控制器：管理菜单栏常驻图标、全局快捷键路由、截图会话与贴图池
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var axMenuItem: NSMenuItem?
    private var config = AppConfig.load()
    private let hotKeyManager = HotKeyManager()
    private let pinManager = PinManager()
    private var activeSession: OverlaySession?
    private var isCapturing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()
        setupCallbacks()
        hotKeyManager.apply(preset: config.hotKeyPreset, enabled: config.hotKeysEnabled)
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
            button.toolTip = "MSnip（麦截）— 轻量截图与贴图"
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
        pinManager.onCountChanged = { [weak self] _ in
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
    }

    // MARK: - Core Actions

    @objc func startCapture() {
        guard activeSession == nil, !isCapturing else { return }
        guard ScreenCapturer.ensurePermission() else {
            showPermissionAlert()
            return
        }

        isCapturing = true
        // 在创建全屏覆盖层之前，先抓取当前所有可见窗口的真实 Z 序与几何边界
        let regionDetector = RegionDetector.captureBeforeOverlay()
        Task { @MainActor [weak self] in
            let snapshots = await ScreenCapturer.captureAllScreens()
            guard let self else { return }
            self.isCapturing = false
            guard !snapshots.isEmpty else {
                self.showPermissionAlert()
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
                case .cancelled:
                    break
                }
            }

            session.start(
                snapshots: snapshots,
                regionDetector: regionDetector,
                colorIndex: self.config.defaultColorIndex,
                lineWidth: self.config.defaultLineWidth,
                pinHint: self.config.hotKeyPreset.pinBadgeLabel
            )
        }
    }

    @objc func handlePinHotKey() {
        // 若当前正在截图中，按 ⌘2 直接将当前选区贴到桌面；否则从剪贴板贴图
        if let session = activeSession, session.pinCurrentSelectionIfPossible() {
            return
        }
        guard activeSession == nil else { return }
        pinManager.pinFromClipboard()
    }

    @objc private func closeAllPins() {
        pinManager.closeAll()
    }

    @objc private func selectHotKeyPreset(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preset = HotKeyPreset(rawValue: raw) else { return }
        config.hotKeyPreset = preset
        config.hotKeysEnabled = true
        config.save()
        hotKeyManager.apply(preset: preset, enabled: true)
        rebuildMenu()
    }

    @objc private func toggleHotKeysEnabled() {
        config.hotKeysEnabled.toggle()
        config.save()
        hotKeyManager.apply(preset: config.hotKeyPreset, enabled: config.hotKeysEnabled)
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        let target = !LaunchAtLoginManager.isEnabled
        _ = LaunchAtLoginManager.setEnabled(target)
        rebuildMenu()
    }

    @objc private func requestDeepControlSnap() {
        _ = RegionDetector.checkAccessibilityPermission(prompt: true)
        rebuildMenu()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "MSnip（麦截）v0.2.0"
        alert.informativeText = """
        超轻量原生 macOS 截图、智能选区识别、圈记与贴图工具
        • 纯 Swift + AppKit + CoreGraphics，零第三方依赖
        • 移动镜头自动吸附窗口与多层控件，滚轮切换矩阵大小，单击锁定
        • 数字键 1–7 切换圈记工具，双击或回车复制，⌘2 贴图，⌘S 保存
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - Menu Construction

    private func rebuildMenu() {
        let menu = NSMenu()
        let capKey = config.hotKeyPreset.captureShortcut
        let pinKey = config.hotKeyPreset.pinShortcut

        let shotItem = NSMenuItem(title: "区域截图", action: #selector(startCapture), keyEquivalent: capKey.keyEquivalent)
        shotItem.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: capKey.mask)
        shotItem.target = self
        menu.addItem(shotItem)

        let pinItem = NSMenuItem(title: "从剪贴板贴图", action: #selector(handlePinHotKey), keyEquivalent: pinKey.keyEquivalent)
        pinItem.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: pinKey.mask)
        pinItem.target = self
        menu.addItem(pinItem)

        if pinManager.count > 0 {
            let clearItem = NSMenuItem(
                title: "关闭全部贴图 (\(pinManager.count))",
                action: #selector(closeAllPins),
                keyEquivalent: ""
            )
            clearItem.target = self
            menu.addItem(clearItem)
        }

        menu.addItem(.separator())

        // 快捷键子菜单
        let hkSubmenu = NSMenu()
        let enableItem = NSMenuItem(title: "启用全局快捷键", action: #selector(toggleHotKeysEnabled), keyEquivalent: "")
        enableItem.state = config.hotKeysEnabled ? .on : .off
        enableItem.target = self
        hkSubmenu.addItem(enableItem)
        hkSubmenu.addItem(.separator())

        for preset in HotKeyPreset.allCases {
            let item = NSMenuItem(title: preset.menuTitle, action: #selector(selectHotKeyPreset(_:)), keyEquivalent: "")
            item.representedObject = preset.rawValue
            item.state = (config.hotKeyPreset == preset) ? .on : .off
            item.target = self
            hkSubmenu.addItem(item)
        }
        let hkRoot = NSMenuItem(title: "全局快捷键", action: nil, keyEquivalent: "")
        hkRoot.submenu = hkSubmenu
        menu.addItem(hkRoot)

        let axItem = NSMenuItem(
            title: "增强子控件识别（辅助功能权限）",
            action: #selector(requestDeepControlSnap),
            keyEquivalent: ""
        )
        axItem.state = RegionDetector.checkAccessibilityPermission(prompt: false) ? .on : .off
        axItem.target = self
        axMenuItem = axItem
        menu.addItem(axItem)

        let loginItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.state = LaunchAtLoginManager.isEnabled ? .on : .off
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "关于 MSnip", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(title: "退出 MSnip", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        axMenuItem?.state = RegionDetector.checkAccessibilityPermission(prompt: false) ? .on : .off
    }

    private func showPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "需要「屏幕录制」权限才能截图"
        alert.informativeText = "请前往「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」，勾选允许 MSnip，然后重试。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
