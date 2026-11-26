import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 命令行/URL Scheme 直达路由、按需懒加载窗口工厂、顶部暂存架联动与后台静默 OCR 直拷扩展
extension AppController {
    func makeOCRController() -> OCRResultController {
        let c = OCRResultController()
        c.ocrAutoCopyProvider = { [weak self] in self?.config.ocrAutoCopy ?? true }
        c.onPinImage = { [weak self] img, scale, scr in self?.pinManager.pin(cgImage: img, scaleFactor: scale, topLeftOnScreen: nil, screen: scr) }
        c.onRecognizeLatex = { [weak self] img, scale, scr in self?.latexController.present(cgImage: img, scaleFactor: scale, screen: scr) }
        c.onOpenOCRSettings = { [weak self] in self?.translationSettings.show(tab: .ocrAndLatex) }
        c.onOpenSettings = { [weak self] in self?.translationSettings.show(tab: .translation) }
        return c
    }

    func makeLatexController() -> LatexResultController {
        let c = LatexResultController()
        c.onPinImage = { [weak self] img, scale, scr in self?.pinManager.pin(cgImage: img, scaleFactor: scale, topLeftOnScreen: nil, screen: scr) }
        c.onOpenLatexSettings = { [weak self] in self?.translationSettings.show(tab: .ocrAndLatex) }
        return c
    }

    func makePermissionGuide() -> PermissionGuideController {
        let g = PermissionGuideController()
        g.onPermissionChanged = { [weak self] in
            guard let self else { return }
            self.hotKeyManager.apply(config: self.config); self.rebuildMenu()
        }
        return g
    }

    func makeTranslationSettings() -> TranslationSettingsWindow {
        hasSettingsInitialized = true
        let w = TranslationSettingsWindow()
        w.appConfigProvider = { [weak self] in self?.config ?? AppConfig() }
        w.isPriorityTapActiveProvider = { [weak self] in self?.hotKeyManager.isPriorityTapActive ?? false }
        w.shortcutAudit.failedHotKeyActionsProvider = { [weak self] in self?.hotKeyManager.failedActions ?? [] }
        w.onReapplyHotKeys = { [weak self] in guard let self else { return }; self.hotKeyManager.apply(config: self.config) }
        w.onPreviewPinGlow = { [weak self] g in self?.pinManager.applyGlowStrengthToAll(g) }
        w.onAppConfigMutated = { [weak self] mutate in
            guard let self else { return }
            let oldGlow = self.config.pinGlowStrength
            mutate(&self.config)
            self.config.save()
            SmartClipboardProjectionManager.shared.isAdaptiveEnabled = self.config.terminalPasteAdaptEnabled
            if abs(self.config.pinGlowStrength - oldGlow) > 0.001 {
                self.pinManager.applyGlowStrengthToAll(self.config.pinGlowStrength)
            }
            if self.hasShelfInitialized || self.config.topShelfTriggerMode != .manualOnly {
                self.shelfController.triggerMode = self.config.topShelfTriggerMode
                self.shelfController.applyTheme()
                self.shelfController.refreshIfVisible()
            }
            self.hotKeyManager.apply(config: self.config)
            self.rebuildMenu()
        }
        w.onBeginHotKeyRecording = { [weak self] in self?.hotKeyManager.unregisterAll() }
        w.onEndHotKeyRecording = { [weak self] in guard let self else { return }; self.hotKeyManager.apply(config: self.config) }
        w.onOpenPermissionGuide = { [weak self] in self?.openPermissionGuide() }
        return w
    }

    func makeCollageStudio() -> CollageStudioController {
        let c = CollageStudioController()
        c.options = config.collageOptions
        c.historyRingProvider = { [weak self] in self?.historyRing }
        c.onOptionsChanged = { [weak self] opts in
            guard let self else { return }
            self.config.collageOptions = opts
            self.scheduleConfigSave()
        }
        c.onCopyCollage = { [weak self] img, scale in
            guard let self else { return }
            ClipboardAndSave.copyToClipboard(cgImage: img, scaleFactor: scale)
            ClipboardAndSave.playFeedbackSound(enabled: self.config.soundFeedbackEnabled)
            self.recordHistoryAndRefresh(img: img, scale: scale, isCollage: true)
            ToastHUD.show(message: "✓ 已复制高清拼图到剪贴板 · \(img.width) × \(img.height) px", preview: img)
        }
        c.onPinCollage = { [weak self] img, scale in
            guard let self else { return }
            self.recordHistoryAndRefresh(img: img, scale: scale, isCollage: true)
            let mouse = NSEvent.mouseLocation
            if let scr = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens.first {
                self.pinManager.pin(cgImage: img, scaleFactor: scale, topLeftOnScreen: nil, screen: scr)
            }
        }
        c.onSaveCollage = { [weak self] img, scale in self?.performInteractiveSave(img: img, scale: scale) }
        return c
    }

    func makeShelfController() -> ShelfPanelController {
        hasShelfInitialized = true
        let s = ShelfPanelController(historyRing: historyRing)
        s.triggerMode = config.topShelfTriggerMode
        s.isSuppressed = { [weak self] in
            guard let self else { return true }
            return self.activeSession != nil || self.activeLongShot != nil
                || self.activeRecording != nil || self.isCapturing || self.isStatusMenuOpen
        }
        s.onCopyHistory = { [weak self] entry in
            guard let self, let cg = self.historyRing.loadCGImage(for: entry) else { NSSound.beep(); return }
            ClipboardAndSave.copyToClipboard(cgImage: cg, scaleFactor: entry.scaleFactor)
            ClipboardAndSave.playFeedbackSound(enabled: self.config.soundFeedbackEnabled)
            ToastHUD.show(message: "已复制暂存截图 · \(entry.pixelWidth) × \(entry.pixelHeight)")
        }
        s.onEditHistory = { [weak self] entry in
            guard let self, let cg = self.historyRing.loadCGImage(for: entry),
                  let scr = NSScreen.main ?? NSScreen.screens.first else { NSSound.beep(); return }
            s.hide()
            let win = self.pinManager.pin(cgImage: cg, scaleFactor: entry.scaleFactor, topLeftOnScreen: nil, screen: scr)
            win.beginAnnotationEditing()
        }
        s.onEditImage = { [weak self] cg, scale in
            guard let self, let scr = NSScreen.main ?? NSScreen.screens.first else { return }
            s.hide()
            let win = self.pinManager.pin(cgImage: cg, scaleFactor: scale, topLeftOnScreen: nil, screen: scr)
            win.beginAnnotationEditing()
        }
        s.onPinHistory = { [weak self] entry in
            guard let self, let cg = self.historyRing.loadCGImage(for: entry),
                  let scr = NSScreen.main ?? NSScreen.screens.first else { NSSound.beep(); return }
            s.hide()
            self.pinManager.pin(cgImage: cg, scaleFactor: entry.scaleFactor, topLeftOnScreen: nil, screen: scr)
        }
        s.onOCRHistory = { [weak self] entry in
            guard let self, let cg = self.historyRing.loadCGImage(for: entry),
                  let scr = NSScreen.main ?? NSScreen.screens.first else { NSSound.beep(); return }
            s.hide()
            self.ocrController.present(cgImage: cg, scaleFactor: entry.scaleFactor, screen: scr, autoTranslate: false)
        }
        s.onPinImage = { [weak self] cg, scale in
            guard let self, let scr = NSScreen.main ?? NSScreen.screens.first else { return }
            s.hide(); self.pinManager.pin(cgImage: cg, scaleFactor: scale, topLeftOnScreen: nil, screen: scr)
        }
        s.onOCRImage = { [weak self] cg, scale in
            guard let self, let scr = NSScreen.main ?? NSScreen.screens.first else { return }
            s.hide(); self.ocrController.present(cgImage: cg, scaleFactor: scale, screen: scr, autoTranslate: false)
        }
        s.onPinText = { [weak self] text in
            guard let self, let scr = NSScreen.main ?? NSScreen.screens.first else { return }
            let scale = max(1.0, scr.backingScaleFactor)
            guard let img = TextPinCardRenderer.render(text: text, scale: scale) else { return }
            s.hide(); self.pinManager.pin(cgImage: img, scaleFactor: scale, topLeftOnScreen: nil, screen: scr)
        }
        s.onOpenCollageStudio = { [weak self] entries, imgs in self?.collageStudio.present(initialEntries: entries, initialImages: imgs) }
        s.onOpenSettings = { [weak self] in self?.openGeneralPreferences() }
        s.onHistoryMutated = { [weak self] in self?.rebuildMenu() }
        return s
    }

    func setupShelfAndRemoteIPC() {
        if config.topShelfTriggerMode != .manualOnly {
            _ = shelfController
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                MainActor.assumeIsolated { self?.shelfController.presentInitiallyIfNeeded() }
            }
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleRemoteIPCNotification(_:)),
            name: Notification.Name(MSnipLaunchCommand.ipcNotificationName), object: nil
        )
        if let initialCmd = MSnipLaunchCommand.parse(arguments: CommandLine.arguments), initialCmd != .tray {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
                MainActor.assumeIsolated { self?.executeLaunchCommand(initialCmd) }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openGeneralPreferences(); return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let cmd = MSnipLaunchCommand.parse(url: url) { executeLaunchCommand(cmd); break }
        }
    }

    @objc private func handleRemoteIPCNotification(_ note: Notification) {
        guard let raw = note.object as? String, let cmd = MSnipLaunchCommand(rawValue: raw) else { return }
        Task { @MainActor [weak self] in self?.executeLaunchCommand(cmd) }
    }

    func executeLaunchCommand(_ cmd: MSnipLaunchCommand) {
        switch cmd {
        case .capture:    startCapture()
        case .fullscreen: performFullScreenCapture(fromMenu: false)
        case .delay:      startDefaultDelayedCapture()
        case .pin:        handlePinHotKey()
        case .ocr:        startQuickOCR()
        case .silentOCR:  beginCaptureSession(mode: .quickSilentOCR)
        case .translate:  startQuickTranslate()
        case .long:       startQuickLongShot()
        case .record:     startQuickRecord()
        case .latex:      startQuickLatex()
        case .shelf:      toggleTopShelf()
        case .settings:   openGeneralPreferences()
        case .tray:       break
        }
    }

    @objc func toggleTopShelf() { shelfController.toggle() }
    @objc func openCollageStudioWindow() { collageStudio.present() }

    /// 为纯代码 `.accessory` 菜单栏应用安装标准「编辑」主菜单，使全应用所有输入框（含 API 密钥密文框、文字标注与保存面板）原生支持 `⌘V / ⌘C / ⌘X / ⌘A / ⌘Z / ⌘⇧Z`
    func setupMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem(); appItem.submenu = NSMenu(title: "MSnip"); mainMenu.addItem(appItem)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]; editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu; mainMenu.addItem(editItem); NSApp.mainMenu = mainMenu
    }

    /// 在 `NSStatusBarWindow` 分发鼠标按下事件前动态挂载 `statusItem.menu`：
    /// 彻底摒弃 `performClick(nil)` 合成点击与 `NSDragEventTracker` 嵌套模态循环，100% 走系统原生状态栏菜单通道
    func installStatusBarMenuPreHook() {
        guard statusBarMouseMonitor == nil else { return }
        statusBarMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] ev in
            guard let self, let btn = self.statusItem?.button, ev.window === btn.window else { return ev }
            let wantsMenu = (ev.type == .rightMouseDown) || (ev.type == .leftMouseDown && ev.modifierFlags.contains(.control))
            if wantsMenu {
                self.beginMenuInteractiveActivity()
                self.prepareStatusMenuBeforeOpen()
                self.statusItem.menu = self.statusMenu
            } else {
                self.statusItem.menu = nil
            }
            return ev
        }
    }

    @objc func handleStatusBarClick(_ sender: Any?) {
        let ev = NSApp.currentEvent
        if ev?.modifierFlags.contains(.option) == true { toggleTopShelf(); return }
        openGeneralPreferences()
    }

    func performSilentOCRCopy(img: CGImage, scale: CGFloat, screen: NSScreen) {
        let ocrCfg = OCRRecognitionConfig.load()
        if ocrCfg.engineKind != .appleVision {
            let engine = ocrCfg.engineKind
            let activeID = TranslationService.shared.settings.activeProfileID
            let profiles = VisionLLMOCRService.availableVisionLLMProfiles()
            ToastHUD.show(message: "正在用「\(engine.shortName)」识字…")
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let out = try await CloudOCRService.recognizeText(
                        image: img, engine: engine, config: ocrCfg, activeProfileID: activeID, profiles: profiles
                    )
                    ClipboardAndSave.copyText(out.text); ClipboardAndSave.playFeedbackSound(enabled: self.config.soundFeedbackEnabled)
                    ToastHUD.show(message: "✓ 已用「\(out.providerName)」识别 \(out.text.count) 字并复制", actionTitle: "双栏查看 ›") { [weak self] in
                        self?.ocrController.present(cgImage: img, scaleFactor: scale, screen: screen, autoTranslate: false)
                    }
                } catch { self.performAppleVisionSilentOCR(img: img, scale: scale, screen: screen) }
            }
            return
        }
        performAppleVisionSilentOCR(img: img, scale: scale, screen: screen)
    }

    private func performAppleVisionSilentOCR(img: CGImage, scale: CGFloat, screen: NSScreen) {
        ToastHUD.show(message: "正在离线识字…")
        VisionTextExtractor.recognizeAsync(from: img) { [weak self] output in
            guard let self else { return }
            if let qr = output.qrPayloads.first, output.preservedText.isEmpty {
                ClipboardAndSave.copyText(qr)
                ClipboardAndSave.playFeedbackSound(enabled: self.config.soundFeedbackEnabled)
                let lower = qr.lowercased()
                let isURL = (lower.hasPrefix("http://") || lower.hasPrefix("https://")), parsed = URL(string: qr)
                ToastHUD.show(
                    message: "✓ 已静默识别二维码并复制", subtitle: qr,
                    actionTitle: isURL && parsed != nil ? "打开链接 ›" : nil,
                    onAction: (isURL && parsed != nil) ? { NSWorkspace.shared.open(parsed!) } : nil
                )
                return
            }
            let text = output.initialClipboardText
            guard !text.isEmpty else { ToastHUD.show(message: "选区内未检测到可识别文字或二维码"); return }
            ClipboardAndSave.copyText(text)
            ClipboardAndSave.playFeedbackSound(enabled: self.config.soundFeedbackEnabled)
            ToastHUD.show(
                message: "✓ 已静默识别 \(text.count) 字并复制", actionTitle: "双栏查看 ›",
                onAction: { [weak self] in self?.ocrController.present(cgImage: img, scaleFactor: scale, screen: screen, autoTranslate: false) }
            )
        }
    }
}
