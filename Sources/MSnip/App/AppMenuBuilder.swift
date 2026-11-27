import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 极简极客顶部状态栏菜单（固定 6 项核心入口，权限缺失与贴图清理按需动态显隐）
extension AppController {
    private static let historyTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    func rebuildMenu() {
        if isStatusMenuOpen {
            needsMenuRebuild = true
            return
        }
        needsMenuRebuild = false
        let menu = NSMenu()
        menu.autoenablesItems = false
        func makeHotKeyItem(title: String, symbol: String, action: Selector, slot: GlobalHotKeyAction) -> NSMenuItem {
            let combo = config.hotKeysEnabled ? config.activeCombo(for: slot) : nil
            let item = NSMenuItem(title: title, action: action, keyEquivalent: combo?.menuKeyEquivalent ?? "")
            item.keyEquivalentModifierMask = combo?.cocoaModifierMask ?? []
            item.setVisibleImage(MSnipUITheme.menuSymbol(symbol))
            item.target = self
            return item
        }

        // 若存在进行中的录屏或 MP4 裁剪窗口，在顶部提供直达操作，绝不卡死在红点态
        if let rec = activeRecording {
            if rec.isShowingTrimWindow {
                let focusTrim = NSMenuItem(title: "回到 MP4 裁剪窗口", action: #selector(finishActiveRecordingFromMenu), keyEquivalent: "")
                focusTrim.setVisibleImage(MSnipUITheme.menuSymbol("scissors")); focusTrim.target = self
                menu.addItem(focusTrim)
            } else {
                let stopRec = NSMenuItem(title: "完成并复制当前录屏", action: #selector(finishActiveRecordingFromMenu), keyEquivalent: "")
                stopRec.setVisibleImage(MSnipUITheme.menuSymbol("stop.circle")); stopRec.target = self
                menu.addItem(stopRec)
                let cancelRec = NSMenuItem(title: "放弃当前录屏", action: #selector(cancelActiveRecordingFromMenu), keyEquivalent: "")
                cancelRec.setVisibleImage(MSnipUITheme.menuSymbol("xmark.circle")); cancelRec.target = self
                menu.addItem(cancelRec)
            }
            menu.addItem(.separator())
        }

        // 仅在缺失屏幕录制权限时于最顶部显示单行提醒，授权后自动隐藏
        let screenOK = ScreenCapturer.runtimeVerifiedAccess || CGPreflightScreenCaptureAccess()
        let warnItem = NSMenuItem(title: "开启屏幕录制权限…", action: #selector(openPermissionGuide), keyEquivalent: "")
        warnItem.setVisibleImage(MSnipUITheme.menuSymbol("exclamationmark.triangle"))
        warnItem.target = self; warnItem.isHidden = screenOK
        menu.addItem(warnItem); axMenuItem = warnItem

        let warnSep = NSMenuItem.separator(); warnSep.isHidden = screenOK
        menu.addItem(warnSep); permWarnSepItem = warnSep

        menu.addItem(makeHotKeyItem(title: "区域截图", symbol: "viewfinder", action: #selector(startCapture), slot: .capture))
        menu.addItem(makeHotKeyItem(title: "重截上次选区", symbol: "arrow.counterclockwise", action: #selector(repeatLastCapture(_:)), slot: .repeatCapture))
        let defaultSecs = DelayedCaptureSettings.clampedSeconds(config.delayedCaptureSeconds)
        let delayRoot = NSMenuItem(title: "延时截图（\(defaultSecs) 秒）", action: nil, keyEquivalent: "")
        delayRoot.setVisibleImage(MSnipUITheme.menuSymbol("timer"))
        let delaySub = NSMenu()
        delaySub.autoenablesItems = false
        delaySub.addItem(makeHotKeyItem(title: "按默认延时截图（\(defaultSecs) 秒）", symbol: "timer", action: #selector(startDefaultDelayedCapture), slot: .delayedCapture))
        delaySub.addItem(.separator())
        for secs in DelayedCaptureSettings.quickPresets {
            let di = NSMenuItem(title: "\(secs) 秒后截图", action: #selector(startDelayedCapture(_:)), keyEquivalent: "")
            di.tag = secs; di.target = self; delaySub.addItem(di)
        }
        delaySub.addItem(.separator())
        let customDelay = NSMenuItem(title: "自定义秒数与快捷键…", action: #selector(openGeneralPreferences), keyEquivalent: "")
        customDelay.setVisibleImage(MSnipUITheme.menuSymbol("slider.horizontal.3")); customDelay.target = self
        delaySub.addItem(customDelay); delayRoot.submenu = delaySub; menu.addItem(delayRoot)
        let fullItem = makeHotKeyItem(title: "截取当前全屏", symbol: "rectangle.dashed", action: #selector(captureCurrentFullScreen), slot: .fullScreenCapture)
        fullItem.toolTip = "截取鼠标所在屏幕（当前默认：\(config.fullScreenCaptureAction.title)；按住 ⌥ 点击直接保存到默认目录）"
        menu.addItem(fullItem)
        menu.addItem(makeHotKeyItem(title: "桌面贴图", symbol: "pin", action: #selector(handlePinHotKey), slot: .pin))
        menu.addItem(makeHotKeyItem(title: "快捷识字", symbol: "text.viewfinder", action: #selector(startQuickOCR), slot: .ocr))
        menu.addItem(makeHotKeyItem(title: "公式识别 (LaTeX)", symbol: "function", action: #selector(startQuickLatex(_:)), slot: .latex))
        menu.addItem(makeHotKeyItem(title: "截图翻译", symbol: "character.bubble", action: #selector(startQuickTranslate), slot: .translate))
        menu.addItem(makeHotKeyItem(title: "滚动长截图", symbol: "scissors", action: #selector(startQuickLongShot), slot: .longShot))
        menu.addItem(makeHotKeyItem(title: "区域录屏", symbol: "video", action: #selector(startQuickRecord), slot: .record))

        menu.addItem(.separator())

        menu.addItem(makeHotKeyItem(title: "顶部暂存架", symbol: "tray.and.arrow.down", action: #selector(toggleTopShelf), slot: .toggleShelf))
        let studioItem = NSMenuItem(title: "拼图与合并 PDF…", action: #selector(openCollageStudioWindow), keyEquivalent: "")
        studioItem.setVisibleImage(MSnipUITheme.menuSymbol("rectangle.split.2x2")); studioItem.target = self
        menu.addItem(studioItem)

        // 最近截图（按需懒加载缩略图子菜单，避免每次配置变更/开关贴图都重复解码全部历史缩略图）
        let histTitle = historyRing.entries.isEmpty ? "最近截图" : "最近截图 (\(historyRing.entries.count))"
        let histRoot = NSMenuItem(title: histTitle, action: nil, keyEquivalent: "")
        histRoot.setVisibleImage(MSnipUITheme.menuSymbol("clock"))
        let lazyHistoryMenu = NSMenu()
        lazyHistoryMenu.autoenablesItems = false
        lazyHistoryMenu.delegate = self
        histRoot.submenu = lazyHistoryMenu
        historyRootItem = histRoot
        historySubmenu = lazyHistoryMenu
        renderedHistoryMenuIDs = []
        menu.addItem(histRoot)

        // 动态贴图管理项（仅在桌面存在贴图时出现）
        if pinManager.count > 0 {
            let visTitle = pinManager.arePinsHidden ? "恢复显示贴图 (\(pinManager.count))" : "暂藏全部贴图 (\(pinManager.count))"
            menu.addItem(makeHotKeyItem(title: visTitle, symbol: pinManager.arePinsHidden ? "eye" : "eye.slash", action: #selector(togglePinsVisibility), slot: .togglePins))
        }
        if pinManager.clickThroughCount > 0 {
            let unghostItem = NSMenuItem(title: "恢复穿透贴图 (\(pinManager.clickThroughCount))", action: #selector(restoreClickThroughPins), keyEquivalent: "")
            unghostItem.setVisibleImage(MSnipUITheme.menuSymbol("hand.point.up.left")); unghostItem.target = self
            menu.addItem(unghostItem)
        }
        if pinManager.count > 0 {
            let clearItem = NSMenuItem(title: "关闭全部贴图 (\(pinManager.count))", action: #selector(closeAllPins), keyEquivalent: "")
            clearItem.setVisibleImage(MSnipUITheme.menuSymbol("xmark.circle")); clearItem.target = self
            menu.addItem(clearItem)
        }

        menu.addItem(.separator())

        // 4) 极简设置窗（常规 / 翻译 API）
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openGeneralPreferences), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.setVisibleImage(MSnipUITheme.menuSymbol("slider.horizontal.3"))
        settingsItem.target = self
        menu.addItem(settingsItem)

        // 5) 开机自启
        let loginItem = NSMenuItem(title: "开机自启", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.setVisibleImage(MSnipUITheme.menuSymbol("bolt"))
        loginItem.state = LaunchAtLoginManager.isEnabled ? .on : .off
        loginItem.target = self
        menu.addItem(loginItem); loginMenuItem = loginItem

        // 6) 退出
        let quitItem = NSMenuItem(title: "退出 MSnip", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.setVisibleImage(MSnipUITheme.menuSymbol("power"))
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusMenu = menu
        statusItem.menu = menu
    }

    private func populateHistorySubmenu(_ sub: NSMenu) {
        let currentEntries = historyRing.entries
        let currentIDs = currentEntries.map(\.id)
        if !sub.items.isEmpty && currentIDs == renderedHistoryMenuIDs { return }
        renderedHistoryMenuIDs = currentIDs
        sub.removeAllItems()
        if currentEntries.isEmpty {
            let empty = NSMenuItem(title: "暂无截图记录", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
            sub.addItem(.separator())
            let openDir = NSMenuItem(title: "打开最近截图目录…", action: #selector(openHistoryDirectory), keyEquivalent: "")
            openDir.setVisibleImage(MSnipUITheme.menuSymbol("folder")); openDir.target = self
            sub.addItem(openDir)
            return
        }

        let tip = NSMenuItem(title: "点击复制 · ⌘贴图 · ⇧识字 · ⌥打开", action: nil, keyEquivalent: "")
        tip.isEnabled = false
        sub.addItem(tip)
        sub.addItem(.separator())

        for (idx, entry) in currentEntries.enumerated() {
            let tag = entry.isCollage ? "拼图 · " : ""
            let title = "\(Self.historyTimeFormatter.string(from: entry.createdAt))  ·  \(tag)\(entry.pixelWidth) × \(entry.pixelHeight)"
            let item = NSMenuItem(title: title, action: #selector(restoreHistoryItem(_:)), keyEquivalent: "")
            item.tag = idx; item.target = self
            item.setVisibleImage(historyRing.menuThumbnail(for: entry))
            sub.addItem(item)
        }

        sub.addItem(.separator())
        let openStudio = NSMenuItem(title: "多图拼接 / 合并 PDF…", action: #selector(openCollageStudioWindow), keyEquivalent: "")
        openStudio.setVisibleImage(MSnipUITheme.menuSymbol("rectangle.split.2x2")); openStudio.target = self
        sub.addItem(openStudio)
        let openDir = NSMenuItem(title: "打开最近截图目录…", action: #selector(openHistoryDirectory), keyEquivalent: "")
        openDir.setVisibleImage(MSnipUITheme.menuSymbol("folder")); openDir.target = self
        sub.addItem(openDir)

        let clear = NSMenuItem(title: "清空记录", action: #selector(clearCaptureHistory), keyEquivalent: "")
        clear.setVisibleImage(MSnipUITheme.menuSymbol("trash")); clear.target = self
        sub.addItem(clear)
    }

    func beginMenuInteractiveActivity() {
        guard menuActivityToken == nil else { return }
        let opts: ProcessInfo.ActivityOptions = {
            if #available(macOS 13.0, *) { return [.userInteractive, .latencyCritical] }
            return [.userInitiated, .latencyCritical]
        }()
        menuActivityToken = ProcessInfo.processInfo.beginActivity(options: opts, reason: "MSnip Interactive Menu Tracking")
    }

    func endMenuInteractiveActivity() {
        if let tok = menuActivityToken { ProcessInfo.processInfo.endActivity(tok); menuActivityToken = nil }
    }

    func prepareStatusMenuBeforeOpen() {
        let screenOK = ScreenCapturer.runtimeVerifiedAccess || CGPreflightScreenCaptureAccess()
        axMenuItem?.isHidden = screenOK
        permWarnSepItem?.isHidden = screenOK
        loginMenuItem?.state = LaunchAtLoginManager.isEnabled ? .on : .off
        historyRootItem?.title = historyRing.entries.isEmpty ? "最近截图" : "最近截图 (\(historyRing.entries.count))"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusMenu {
            prepareStatusMenuBeforeOpen()
        } else if menu === historySubmenu {
            populateHistorySubmenu(menu)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusMenu {
            trackingRootMenu = menu
            isStatusMenuOpen = true
            if hasShelfInitialized { shelfController.setMenuTrackingPaused(true) }
            beginMenuInteractiveActivity()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu === trackingRootMenu || menu === statusMenu {
            finishStatusMenuTrackingIfNeeded()
        }
    }

    /// 统一收尾状态栏菜单追踪态：恢复顶边暂存架监听、释放高优先级功耗锁并补跑被延迟的菜单重建
    func finishStatusMenuTrackingIfNeeded() {
        let wasOpen = isStatusMenuOpen
        isStatusMenuOpen = false
        trackingRootMenu = nil
        if wasOpen, hasShelfInitialized { shelfController.setMenuTrackingPaused(false) }
        endMenuInteractiveActivity()
        if needsMenuRebuild {
            needsMenuRebuild = false
            rebuildMenu()
        }
    }

    @objc func finishActiveRecordingFromMenu() {
        activeRecording?.finishActiveRecordingFromMenu()
    }

    @objc func cancelActiveRecordingFromMenu() {
        activeRecording?.cancel()
    }

    /// 退出自身状态栏菜单模态追踪循环（`NSEventTrackingRunLoopMode`）并待菜单淡出后再执行抓屏，彻底避免自锁与截进自身菜单
    func runAfterStatusMenuDismissed(fromMenuClick: Bool = false, _ work: @escaping @MainActor () -> Void) {
        if isStatusMenuOpen {
            (trackingRootMenu ?? statusMenu)?.cancelTrackingWithoutAnimation()
            finishStatusMenuTrackingIfNeeded()
        }
        let delay: TimeInterval = fromMenuClick ? 0.065 : 0.08
        RunLoop.main.perform(inModes: [.default]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { work() }
            }
        }
    }

    @objc func openHistoryDirectory() {
        try? FileManager.default.createDirectory(at: historyRing.directoryURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(historyRing.directoryURL)
    }

    @objc func restoreHistoryItem(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard historyRing.entries.indices.contains(idx) else { return }
        let entry = historyRing.entries[idx]
        let mods = NSEvent.modifierFlags
        if mods.contains(.option) {
            if let url = historyRing.fileURL(for: entry) {
                NSWorkspace.shared.open(url)
            } else {
                NSSound.beep()
            }
            return
        }
        guard let cg = historyRing.loadCGImage(for: entry) else {
            NSSound.beep(); return
        }
        if mods.contains(.command), let scr = NSScreen.main ?? NSScreen.screens.first {
            pinManager.pin(cgImage: cg, scaleFactor: entry.scaleFactor, topLeftOnScreen: nil, screen: scr)
            ToastHUD.show(message: "已将历史截图贴到屏幕")
        } else if mods.contains(.shift), let scr = NSScreen.main ?? NSScreen.screens.first {
            ocrController.present(cgImage: cg, scaleFactor: entry.scaleFactor, screen: scr, autoTranslate: false)
        } else {
            ClipboardAndSave.copyToClipboard(cgImage: cg, scaleFactor: entry.scaleFactor)
            ToastHUD.show(message: "已恢复历史截图到剪贴板 · \(entry.pixelWidth) × \(entry.pixelHeight)")
        }
    }

    @objc func clearCaptureHistory() {
        historyRing.clearAll()
        rebuildMenu()
        ToastHUD.show(message: "已清空最近截图记录")
    }

    @objc func startDelayedCapture(_ sender: NSMenuItem) {
        let secs = max(1, sender.tag)
        delayedCapture.start(seconds: secs) { [weak self] in self?.beginCaptureSession(mode: .standard) }
    }

    @objc func restoreClickThroughPins() { pinManager.restoreAllClickThroughPins() }
    @objc func closeAllPins() { pinManager.closeAll() }
    @objc func openHotKeyRecorder() { translationSettings.show(tab: .shortcuts) }

    @objc func toggleLaunchAtLogin() {
        _ = LaunchAtLoginManager.setEnabled(!LaunchAtLoginManager.isEnabled)
        rebuildMenu()
    }

    @objc func openPermissionGuide() {
        showPermissionGuide(pane: nil)
    }

    func showPermissionGuide(pane preferredPane: PermissionPane?) {
        if let target = preferredPane { permissionGuide.show(opening: target); return }
        let screenOK = ScreenCapturer.runtimeVerifiedAccess || CGPreflightScreenCaptureAccess()
        let pane: PermissionPane? = !screenOK
            ? .screenRecording
            : (!RegionDetector.checkAccessibilityPermission(prompt: false) ? .accessibility : nil)
        permissionGuide.show(opening: pane)
    }

    @objc func quitApp() { NSApp.terminate(nil) }
}
