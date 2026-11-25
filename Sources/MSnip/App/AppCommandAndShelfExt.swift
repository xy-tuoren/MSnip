import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 命令行/URL Scheme 直达路由、顶部暂存架联动与后台静默 OCR 直拷扩展
extension AppController {
    func setupShelfAndRemoteIPC() {
        shelfController.triggerMode = config.topShelfTriggerMode
        shelfController.isSuppressed = { [weak self] in
            guard let self else { return true }
            return self.activeSession != nil || self.activeLongShot != nil
                || self.activeRecording != nil || self.isCapturing || self.isStatusMenuOpen
        }
        shelfController.onCopyHistory = { [weak self] entry in
            guard let self, let cg = self.historyRing.loadCGImage(for: entry) else { NSSound.beep(); return }
            ClipboardAndSave.copyToClipboard(cgImage: cg, scaleFactor: entry.scaleFactor)
            ClipboardAndSave.playFeedbackSound(enabled: self.config.soundFeedbackEnabled)
            ToastHUD.show(message: "已复制暂存截图 · \(entry.pixelWidth) × \(entry.pixelHeight)")
        }
        shelfController.onPinHistory = { [weak self] entry in
            guard let self, let cg = self.historyRing.loadCGImage(for: entry),
                  let scr = NSScreen.main ?? NSScreen.screens.first else { NSSound.beep(); return }
            self.shelfController.hide()
            self.pinManager.pin(cgImage: cg, scaleFactor: entry.scaleFactor, topLeftOnScreen: nil, screen: scr)
        }
        shelfController.onOCRHistory = { [weak self] entry in
            guard let self, let cg = self.historyRing.loadCGImage(for: entry),
                  let scr = NSScreen.main ?? NSScreen.screens.first else { NSSound.beep(); return }
            self.shelfController.hide()
            self.ocrController.present(cgImage: cg, scaleFactor: entry.scaleFactor, screen: scr, autoTranslate: false)
        }
        shelfController.onPinText = { [weak self] text in
            guard let self, let scr = NSScreen.main ?? NSScreen.screens.first else { return }
            let scale = max(1.0, scr.backingScaleFactor)
            guard let img = TextPinCardRenderer.render(text: text, scale: scale) else { return }
            self.shelfController.hide()
            self.pinManager.pin(cgImage: img, scaleFactor: scale, topLeftOnScreen: nil, screen: scr)
        }
        shelfController.onQuickCollage = { [weak self] in
            guard let self else { return }
            self.shelfController.hide()
            let dummy = NSMenuItem(); dummy.tag = 12 // 最近 2 张横向并排对比
            self.createHistoryCollage(dummy)
        }
        shelfController.onOpenSettings = { [weak self] in self?.openGeneralPreferences() }
        shelfController.onHistoryMutated = { [weak self] in self?.rebuildMenu() }

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleRemoteIPCNotification(_:)),
            name: Notification.Name(MSnipLaunchCommand.ipcNotificationName),
            object: nil
        )

        if let initialCmd = MSnipLaunchCommand.parse(arguments: CommandLine.arguments), initialCmd != .tray {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
                MainActor.assumeIsolated { self?.executeLaunchCommand(initialCmd) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated { self?.shelfController.presentInitiallyIfNeeded() }
        }
    }

    /// 左键点击启动台 / 访达 / 聚焦搜索 / 程序坞中的 MSnip 应用图标重新激活时，直接打开设置面板
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openGeneralPreferences()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let cmd = MSnipLaunchCommand.parse(url: url) {
                executeLaunchCommand(cmd)
                break
            }
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

    @objc func toggleTopShelf() {
        shelfController.toggle()
    }

    /// 顶部菜单栏图标点击分发：左键正常展开菜单，右键（或按住 ⌥ 左键）一键开关顶部暂存架
    @objc func handleStatusBarClick(_ sender: Any?) {
        let ev = NSApp.currentEvent
        if ev?.type == .rightMouseUp || ev?.modifierFlags.contains(.option) == true {
            toggleTopShelf()
            return
        }
        guard let menu = statusMenu else { return }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    /// 快捷识字静默直拷：关闭冻结层后纯后台离线 Vision 识字并直接写入剪贴板，不弹窗打断心流
    func performSilentOCRCopy(img: CGImage, scale: CGFloat, screen: NSScreen) {
        ToastHUD.show(message: "正在离线识字…")
        VisionTextExtractor.recognizeAsync(from: img) { [weak self] output in
            guard let self else { return }
            if let qr = output.qrPayloads.first, output.preservedText.isEmpty {
                ClipboardAndSave.copyText(qr)
                ClipboardAndSave.playFeedbackSound(enabled: self.config.soundFeedbackEnabled)
                let lower = qr.lowercased()
                let isURL = (lower.hasPrefix("http://") || lower.hasPrefix("https://")), parsed = URL(string: qr)
                ToastHUD.show(
                    message: "✓ 已静默识别二维码并复制",
                    subtitle: qr,
                    actionTitle: isURL && parsed != nil ? "打开链接 ›" : nil,
                    onAction: (isURL && parsed != nil) ? { NSWorkspace.shared.open(parsed!) } : nil
                )
                return
            }
            let text = output.initialClipboardText
            guard !text.isEmpty else {
                ToastHUD.show(message: "选区内未检测到可识别文字或二维码")
                return
            }
            ClipboardAndSave.copyText(text)
            ClipboardAndSave.playFeedbackSound(enabled: self.config.soundFeedbackEnabled)
            ToastHUD.show(
                message: "✓ 已静默识别 \(text.count) 字并复制",
                actionTitle: "双栏查看 ›",
                onAction: { [weak self] in
                    self?.ocrController.present(cgImage: img, scaleFactor: scale, screen: screen, autoTranslate: false)
                }
            )
        }
    }
}
