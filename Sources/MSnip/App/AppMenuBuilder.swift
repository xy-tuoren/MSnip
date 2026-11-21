import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 极简极客顶部状态栏菜单（固定 6 项核心入口，权限缺失与贴图清理按需动态显隐）
extension AppController {
    func rebuildMenu() {
        let menu = NSMenu()
        let capKey = config.activeCaptureCombo
        let pinKey = config.activePinCombo

        // 仅在缺失屏幕录制权限时于最顶部显示单行提醒，授权后自动隐藏
        let screenOK = ScreenCapturer.runtimeVerifiedAccess || CGPreflightScreenCaptureAccess()
        let warnItem = NSMenuItem(
            title: "开启屏幕录制权限…",
            action: #selector(openPermissionGuide),
            keyEquivalent: ""
        )
        warnItem.image = MSnipUITheme.menuSymbol("exclamationmark.triangle")
        warnItem.target = self
        warnItem.isHidden = screenOK
        menu.addItem(warnItem)
        axMenuItem = warnItem

        let warnSep = NSMenuItem.separator()
        warnSep.isHidden = screenOK
        menu.addItem(warnSep)
        permWarnSepItem = warnSep

        // 1) 截图
        let shotItem = NSMenuItem(title: "截图", action: #selector(startCapture), keyEquivalent: capKey.menuKeyEquivalent)
        shotItem.keyEquivalentModifierMask = capKey.cocoaModifierMask
        shotItem.image = MSnipUITheme.menuSymbol("viewfinder")
        shotItem.target = self
        menu.addItem(shotItem)

        // 2) 贴图
        let pinItem = NSMenuItem(title: "贴图", action: #selector(handlePinHotKey), keyEquivalent: pinKey.menuKeyEquivalent)
        pinItem.keyEquivalentModifierMask = pinKey.cocoaModifierMask
        pinItem.image = MSnipUITheme.menuSymbol("pin")
        pinItem.target = self
        menu.addItem(pinItem)

        // 3) 最近截图
        let histTitle = historyRing.entries.isEmpty ? "最近截图" : "最近截图 (\(historyRing.entries.count))"
        let histRoot = NSMenuItem(title: histTitle, action: nil, keyEquivalent: "")
        histRoot.image = MSnipUITheme.menuSymbol("clock")
        histRoot.submenu = buildHistorySubmenu()
        menu.addItem(histRoot)

        // 动态贴图管理项（仅在桌面存在贴图时出现）
        if pinManager.clickThroughCount > 0 {
            let unghostItem = NSMenuItem(
                title: "恢复穿透贴图 (\(pinManager.clickThroughCount))",
                action: #selector(restoreClickThroughPins),
                keyEquivalent: ""
            )
            unghostItem.image = MSnipUITheme.menuSymbol("hand.point.up.left")
            unghostItem.target = self
            menu.addItem(unghostItem)
        }
        if pinManager.count > 0 {
            let clearItem = NSMenuItem(
                title: "关闭全部贴图 (\(pinManager.count))",
                action: #selector(closeAllPins),
                keyEquivalent: ""
            )
            clearItem.image = MSnipUITheme.menuSymbol("xmark.circle")
            clearItem.target = self
            menu.addItem(clearItem)
        }

        menu.addItem(.separator())

        // 4) 极简设置窗（常规 / 翻译 API）
        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(openGeneralPreferences),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.image = MSnipUITheme.menuSymbol("slider.horizontal.3")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // 5) 开机自启
        let loginItem = NSMenuItem(title: "开机自启", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.image = MSnipUITheme.menuSymbol("bolt")
        loginItem.state = LaunchAtLoginManager.isEnabled ? .on : .off
        loginItem.target = self
        menu.addItem(loginItem)
        loginMenuItem = loginItem

        // 6) 退出
        let quitItem = NSMenuItem(title: "退出 MSnip", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.image = MSnipUITheme.menuSymbol("power")
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = self
        statusItem.menu = menu
    }

    private func buildHistorySubmenu() -> NSMenu {
        let sub = NSMenu()
        if historyRing.entries.isEmpty {
            let empty = NSMenuItem(title: "暂无截图记录", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
            return sub
        }

        let tip = NSMenuItem(title: "单击复制 · ⌥ 贴图 · ⌘ 选目录下载", action: nil, keyEquivalent: "")
        tip.isEnabled = false
        sub.addItem(tip)

        let dlLatest = NSMenuItem(title: "下载最新截图到…", action: nil, keyEquivalent: "")
        dlLatest.image = MSnipUITheme.menuSymbol("square.and.arrow.down")
        dlLatest.submenu = buildQuickDownloadSubmenu()
        sub.addItem(dlLatest)
        sub.addItem(.separator())

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        for (idx, entry) in historyRing.entries.enumerated() {
            let title = "\(fmt.string(from: entry.createdAt))  ·  \(entry.pixelWidth) × \(entry.pixelHeight)"
            let item = NSMenuItem(title: title, action: #selector(restoreHistoryItem(_:)), keyEquivalent: "")
            item.tag = idx
            item.target = self
            item.image = historyRing.menuThumbnail(for: entry)
            sub.addItem(item)
        }

        sub.addItem(.separator())
        let clear = NSMenuItem(title: "清空记录", action: #selector(clearCaptureHistory), keyEquivalent: "")
        clear.image = MSnipUITheme.menuSymbol("trash")
        clear.target = self
        sub.addItem(clear)
        return sub
    }

    func menuWillOpen(_ menu: NSMenu) {
        let screenOK = ScreenCapturer.runtimeVerifiedAccess || CGPreflightScreenCaptureAccess()
        axMenuItem?.isHidden = screenOK
        permWarnSepItem?.isHidden = screenOK
        loginMenuItem?.state = LaunchAtLoginManager.isEnabled ? .on : .off
    }

    private func buildQuickDownloadSubmenu() -> NSMenu {
        let m = NSMenu()
        let folders = ClipboardAndSave.quickSaveFolders(preferred: config.lastSaveDirectory, recent: config.recentSaveDirectories)
        for f in folders {
            let it = NSMenuItem(title: f.title, action: #selector(downloadLatestHistoryToFolder(_:)), keyEquivalent: "")
            it.representedObject = f.path
            it.image = MSnipUITheme.menuSymbol(f.symbol)
            it.target = self
            m.addItem(it)
        }
        m.addItem(.separator())
        let pick = NSMenuItem(title: "选择其他目录保存…", action: #selector(downloadLatestHistoryPickFolder), keyEquivalent: "")
        pick.image = MSnipUITheme.menuSymbol("folder.badge.plus")
        pick.target = self
        m.addItem(pick)
        return m
    }

    @objc func downloadLatestHistoryToFolder(_ sender: NSMenuItem) {
        guard let dir = sender.representedObject as? String,
              let entry = historyRing.entries.first,
              let cg = historyRing.loadCGImage(for: entry) else { NSSound.beep(); return }
        performSaveToDirectory(img: cg, scale: entry.scaleFactor, directoryPath: dir)
    }

    @objc func downloadLatestHistoryPickFolder() {
        guard let entry = historyRing.entries.first,
              let cg = historyRing.loadCGImage(for: entry) else { NSSound.beep(); return }
        performPickDirectorySave(img: cg, scale: entry.scaleFactor)
    }

    @objc func restoreHistoryItem(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard historyRing.entries.indices.contains(idx) else { return }
        let entry = historyRing.entries[idx]
        guard let cg = historyRing.loadCGImage(for: entry) else {
            NSSound.beep(); return
        }
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            performPickDirectorySave(img: cg, scale: entry.scaleFactor)
        } else if mods.contains(.option), let scr = NSScreen.main ?? NSScreen.screens.first {
            pinManager.pin(cgImage: cg, scaleFactor: entry.scaleFactor, topLeftOnScreen: nil, screen: scr)
            ToastHUD.show(message: "已将历史截图贴到屏幕")
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

    @objc func restoreClickThroughPins() { pinManager.restoreAllClickThroughPins() }
    @objc func closeAllPins() { pinManager.closeAll() }
    @objc func openHotKeyRecorder() { hotKeyRecorder.show(with: config) }

    @objc func toggleLaunchAtLogin() {
        _ = LaunchAtLoginManager.setEnabled(!LaunchAtLoginManager.isEnabled)
        rebuildMenu()
    }

    @objc func openPermissionGuide() {
        let screenOK = ScreenCapturer.runtimeVerifiedAccess || CGPreflightScreenCaptureAccess()
        let pane: PermissionPane? = !screenOK
            ? .screenRecording
            : (!RegionDetector.checkAccessibilityPermission(prompt: false) ? .accessibility : nil)
        permissionGuide.show(opening: pane)
    }

    @objc func quitApp() { NSApp.terminate(nil) }
}
