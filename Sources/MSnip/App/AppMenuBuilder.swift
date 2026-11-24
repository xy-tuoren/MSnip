import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 极简极客顶部状态栏菜单（固定 6 项核心入口，权限缺失与贴图清理按需动态显隐）
extension AppController {
    func rebuildMenu() {
        let menu = NSMenu()
        func makeHotKeyItem(title: String, symbol: String, action: Selector, slot: GlobalHotKeyAction) -> NSMenuItem {
            let combo = config.hotKeysEnabled ? config.activeCombo(for: slot) : nil
            let item = NSMenuItem(title: title, action: action, keyEquivalent: combo?.menuKeyEquivalent ?? "")
            item.keyEquivalentModifierMask = combo?.cocoaModifierMask ?? []
            item.image = MSnipUITheme.menuSymbol(symbol)
            item.target = self
            return item
        }

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

        menu.addItem(makeHotKeyItem(title: "区域截图", symbol: "viewfinder", action: #selector(startCapture), slot: .capture))
        menu.addItem(makeHotKeyItem(title: "桌面贴图", symbol: "pin", action: #selector(handlePinHotKey), slot: .pin))
        menu.addItem(makeHotKeyItem(title: "快捷识字", symbol: "text.viewfinder", action: #selector(startQuickOCR), slot: .ocr))
        menu.addItem(makeHotKeyItem(title: "截图翻译", symbol: "character.bubble", action: #selector(startQuickTranslate), slot: .translate))
        menu.addItem(makeHotKeyItem(title: "滚动长截图", symbol: "scissors", action: #selector(startQuickLongShot), slot: .longShot))
        menu.addItem(makeHotKeyItem(title: "区域录屏", symbol: "video", action: #selector(startQuickRecord), slot: .record))

        menu.addItem(.separator())

        // 最近截图（按需懒加载缩略图子菜单，避免每次配置变更/开关贴图都重复解码全部历史缩略图）
        let histTitle = historyRing.entries.isEmpty ? "最近截图" : "最近截图 (\(historyRing.entries.count))"
        let histRoot = NSMenuItem(title: histTitle, action: nil, keyEquivalent: "")
        histRoot.image = MSnipUITheme.menuSymbol("clock")
        let lazyHistoryMenu = NSMenu()
        lazyHistoryMenu.delegate = self
        histRoot.submenu = lazyHistoryMenu
        historyRootItem = histRoot
        historySubmenu = lazyHistoryMenu
        menu.addItem(histRoot)

        // 动态贴图管理项（仅在桌面存在贴图时出现）
        if pinManager.count > 0 {
            let visTitle = pinManager.arePinsHidden ? "恢复显示贴图 (\(pinManager.count))" : "暂藏全部贴图 (\(pinManager.count))"
            menu.addItem(makeHotKeyItem(title: visTitle, symbol: pinManager.arePinsHidden ? "eye" : "eye.slash", action: #selector(togglePinsVisibility), slot: .togglePins))
        }
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

    private func populateHistorySubmenu(_ sub: NSMenu) {
        sub.removeAllItems()
        if historyRing.entries.isEmpty {
            let empty = NSMenuItem(title: "暂无截图记录", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
            sub.addItem(.separator())
            let openDir = NSMenuItem(title: "打开最近截图目录…", action: #selector(openHistoryDirectory), keyEquivalent: "")
            openDir.image = MSnipUITheme.menuSymbol("folder")
            openDir.target = self
            sub.addItem(openDir)
            return
        }

        let tip = NSMenuItem(title: "点击复制 · ⌥+点击打开 · ⌘+点击贴图", action: nil, keyEquivalent: "")
        tip.isEnabled = false
        sub.addItem(tip)
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
        let openDir = NSMenuItem(title: "打开最近截图目录…", action: #selector(openHistoryDirectory), keyEquivalent: "")
        openDir.image = MSnipUITheme.menuSymbol("folder")
        openDir.target = self
        sub.addItem(openDir)

        let clear = NSMenuItem(title: "清空记录", action: #selector(clearCaptureHistory), keyEquivalent: "")
        clear.image = MSnipUITheme.menuSymbol("trash")
        clear.target = self
        sub.addItem(clear)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === historySubmenu {
            populateHistorySubmenu(menu)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu !== historySubmenu else { return }
        let screenOK = ScreenCapturer.runtimeVerifiedAccess || CGPreflightScreenCaptureAccess()
        axMenuItem?.isHidden = screenOK
        permWarnSepItem?.isHidden = screenOK
        loginMenuItem?.state = LaunchAtLoginManager.isEnabled ? .on : .off
        historyRootItem?.title = historyRing.entries.isEmpty ? "最近截图" : "最近截图 (\(historyRing.entries.count))"
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
    @objc func openHotKeyRecorder() { translationSettings.show(tab: .shortcuts) }

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
