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
            if self.hasCollageInitialized { self.collageStudio.options = self.config.collageOptions }
            self.hotKeyManager.apply(config: self.config)
            self.rebuildMenu()
        }
        w.onBeginHotKeyRecording = { [weak self] in self?.hotKeyManager.unregisterAll() }
        w.onEndHotKeyRecording = { [weak self] in guard let self else { return }; self.hotKeyManager.apply(config: self.config) }
        w.onOpenPermissionGuide = { [weak self] pane in self?.showPermissionGuide(pane: pane) }
        return w
    }

    func makeCollageStudio() -> CollageStudioController {
        hasCollageInitialized = true
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
            guard let self, NSApp.modalWindow == nil, let btn = self.statusItem?.button, ev.window === btn.window else { return ev }
            let isOptionLeft = (ev.type == .leftMouseDown) && ev.modifierFlags.contains(.option)
            self.statusItem.menu = isOptionLeft ? nil : self.statusMenu
            return ev
        }
    }

    @objc func handleStatusBarClick(_ sender: Any?) {
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true { toggleTopShelf(); return }
        if NSApp.currentEvent?.type != .leftMouseUp, let menu = statusMenu {
            statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
        }
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
                        self?.ocrController.present(cgImage: img, scaleFactor: scale, screen: screen, autoTranslate: false, preRecognized: out)
                    }
                } catch {
                    self.performAppleVisionSilentOCR(img: img, scale: scale, screen: screen, fallbackNote: "⚠ \(engine.shortName)失败，已回退离线：\(error.localizedDescription)")
                }
            }
            return
        }
        performAppleVisionSilentOCR(img: img, scale: scale, screen: screen, fallbackNote: nil)
    }

    private func performAppleVisionSilentOCR(img: CGImage, scale: CGFloat, screen: NSScreen, fallbackNote: String?) {
        if fallbackNote == nil { ToastHUD.show(message: "正在离线识字…") }
        Task { @MainActor [weak self] in
            let output = await VisionTextExtractor.recognizeTextOnlyOffMain(cgImage: img)
            guard let self else { return }
            if let qr = output.qrPayloads.first, output.preservedText.isEmpty {
                ClipboardAndSave.copyText(qr); ClipboardAndSave.playFeedbackSound(enabled: self.config.soundFeedbackEnabled)
                let lower = qr.lowercased(), isURL = (lower.hasPrefix("http://") || lower.hasPrefix("https://")), parsed = URL(string: qr)
                ToastHUD.show(message: "✓ 已静默识别二维码并复制", subtitle: fallbackNote ?? qr, actionTitle: isURL && parsed != nil ? "打开链接 ›" : nil, onAction: (isURL && parsed != nil) ? { NSWorkspace.shared.open(parsed!) } : nil)
                return
            }
            let text = output.initialClipboardText
            guard !text.isEmpty else { ToastHUD.show(message: "选区内未检测到可识别文字或二维码", subtitle: fallbackNote); return }
            ClipboardAndSave.copyText(text); ClipboardAndSave.playFeedbackSound(enabled: self.config.soundFeedbackEnabled)
            ToastHUD.show(message: "✓ 已静默识别 \(text.count) 字并复制", subtitle: fallbackNote, actionTitle: "双栏查看 ›") { [weak self] in
                self?.ocrController.present(cgImage: img, scaleFactor: scale, screen: screen, autoTranslate: false)
            }
        }
    }
}

// MARK: - 导出保存、历史回溯与原位翻译

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

    @objc func repeatLastCapture(_ sender: Any? = nil) {
        let fromMenu = (sender is NSMenuItem)
        if isStatusMenuOpen || fromMenu {
            runAfterStatusMenuDismissed(fromMenuClick: fromMenu) { [weak self] in self?.repeatLastCapture(nil) }
            return
        }
        guard activeSession == nil, activeLongShot == nil, activeRecording == nil, !isCapturing else { return }
        guard let target = OverlaySession.lastCaptureTarget else {
            startCapture()
            return
        }
        ToastHUD.dismissImmediate()
        if hasQuickAccessInitialized { quickAccessOverlay.dismissImmediate() }
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
            guard let rawCropped = snap.cgImage.cropping(to: pxRect) else { return }
            let cropped = ImageTransform.detachedCopy(rawCropped)
            ClipboardAndSave.copyToClipboard(cgImage: cropped, scaleFactor: s)
            let entry = self.recordHistoryAndRefresh(img: cropped, scale: s)
            self.presentScreenshotFeedback(
                entry: entry, img: cropped, scale: s, statusPrefix: "重截已复制",
                fallbackMessage: "✓ 已重截上次区域并复制", fallbackSubtitle: "\(cropped.width) × \(cropped.height) px"
            )
        }
    }

    @objc func openTranslationSettings() { translationSettings.show(tab: .translation) }
    @objc func openShortcutsSettings() { translationSettings.show(tab: .shortcuts) }
    @objc func openGeneralPreferences() { translationSettings.show(tab: .general) }

    func performQuickSave(img: CGImage, scale: CGFloat, historyEntry: CaptureHistoryEntry? = nil) {
        let dir = ClipboardAndSave.resolveQuickSaveDirectory(preferred: config.lastSaveDirectory)
        performSaveToDirectory(img: img, scale: scale, directoryPath: dir.path, rememberDirectory: false, historyEntry: historyEntry)
    }

    func performSaveToDirectory(img: CGImage, scale: CGFloat, directoryPath: String, rememberDirectory: Bool = true, historyEntry: CaptureHistoryEntry? = nil) {
        let dirURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
        guard let url = ClipboardAndSave.quickSavePNG(
            cgImage: img, scaleFactor: scale, intoDirectory: dirURL,
            format: config.exportImageFormat, exportAt1x: config.exportAt1xScale,
            filenameTemplate: config.filenameTemplate
        ) else { ToastHUD.show(message: "保存图片失败"); return }
        ClipboardAndSave.playFeedbackSound(enabled: config.soundFeedbackEnabled)
        if rememberDirectory { config.recordSaveDirectory(directoryPath); config.save(); rebuildMenu() }
        let shortDir = dirURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        presentScreenshotFeedback(
            entry: historyEntry, img: img, scale: scale, savedURL: url, statusPrefix: "已保存",
            fallbackMessage: "✓ 已保存截图至「\(dirURL.lastPathComponent)」",
            fallbackSubtitle: "\(shortDir)/\(url.lastPathComponent)",
            fallbackActionTitle: "在访达中显示",
            fallbackOnAction: { [weak self] in self?.activeSession?.cancel(); ClipboardAndSave.revealInFinder(url) }
        )
    }

    func performInteractiveSave(img: CGImage, scale: CGFloat, historyEntry: CaptureHistoryEntry? = nil) {
        guard let res = ClipboardAndSave.savePNGInteractive(
            cgImage: img, scaleFactor: scale,
            initialDirectory: config.recentSaveDirectories.first ?? config.lastSaveDirectory,
            format: config.exportImageFormat, exportAt1x: config.exportAt1xScale,
            filenameTemplate: config.filenameTemplate
        ) else { return }
        ClipboardAndSave.playFeedbackSound(enabled: config.soundFeedbackEnabled)
        config.recordSaveDirectory(res.dir); config.save(); rebuildMenu()
        let folderName = URL(fileURLWithPath: res.dir).lastPathComponent
        let shortPath = res.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        presentScreenshotFeedback(
            entry: historyEntry, img: img, scale: scale, savedURL: res.url, statusPrefix: "已保存",
            fallbackMessage: "✓ 已保存截图至「\(folderName)」",
            fallbackSubtitle: shortPath,
            fallbackActionTitle: "在访达中显示",
            fallbackOnAction: { [weak self] in self?.activeSession?.cancel(); ClipboardAndSave.revealInFinder(res.url) }
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
                self.shelfController.recordMediaFile(url)
                if self.config.showQuickAccessOverlay {
                    self.quickAccessOverlay.presentMediaFile(url: url, format: fmt, statusPrefix: "已复制")
                } else {
                    let kb = ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) / 1024
                    ToastHUD.show(message: "\(fmt.badgeTitle) 已复制到剪贴板 (\(max(1, kb)) KB) · 可直接粘贴发送")
                }
            case .savedFile(let url, let fmt, let dir):
                self.config.recordSaveDirectory(dir); self.config.save()
                self.shelfController.recordMediaFile(url)
                if self.config.showQuickAccessOverlay {
                    self.quickAccessOverlay.presentMediaFile(url: url, format: fmt, statusPrefix: "已保存")
                } else {
                    ToastHUD.show(
                        message: "✓ 已保存 \(fmt.badgeTitle) 录屏文件",
                        subtitle: url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                        actionTitle: "在访达中显示 ›",
                        onAction: { ClipboardAndSave.revealInFinder(url) }
                    )
                }
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
                let entry = self.recordHistoryAndRefresh(img: img, scale: scale)
                self.presentScreenshotFeedback(entry: entry, img: img, scale: scale, statusPrefix: "长图已复制", fallbackMessage: "长截图已复制 · \(img.width) × \(img.height) px")
            case .quickSaved(let img, let scale):
                let entry = self.recordHistoryAndRefresh(img: img, scale: scale)
                self.performQuickSave(img: img, scale: scale, historyEntry: entry)
            case .saved(let img, let scale):
                let entry = self.recordHistoryAndRefresh(img: img, scale: scale)
                self.performInteractiveSave(img: img, scale: scale, historyEntry: entry)
            case .pinned(let img, let scale, let origin, let targetScreen):
                self.recordHistoryAndRefresh(img: img, scale: scale)
                self.pinManager.pin(cgImage: img, scaleFactor: scale, topLeftOnScreen: origin, screen: targetScreen)
            case .pinAndAnnotate(let img, let scale, let origin, let targetScreen):
                self.recordHistoryAndRefresh(img: img, scale: scale)
                let pinWin = self.pinManager.pin(cgImage: img, scaleFactor: scale, topLeftOnScreen: origin, screen: targetScreen)
                pinWin.beginAnnotationEditing()
            case .extractText(let img, let scale, let targetScreen):
                self.recordHistoryAndRefresh(img: img, scale: scale)
                if self.config.ocrPresentation == .silentCopy {
                    self.performSilentOCRCopy(img: img, scale: scale, screen: targetScreen)
                } else {
                    self.ocrController.present(cgImage: img, scaleFactor: scale, screen: targetScreen, autoTranslate: false)
                }
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
