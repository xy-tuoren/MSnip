import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 顶部状态栏菜单构建（全系矢量 SF Symbols 图标化）、最近截图历史回溯、贴图穿透解锁与设置中心入口扩展
extension AppController {
    func rebuildMenu() {
        let menu = NSMenu()
        let capKey = config.activeCaptureCombo
        let pinKey = config.activePinCombo
        let ocrKey = config.activeOCRCombo

        let shotItem = NSMenuItem(title: "区域截图 / 长截图 / 录动图", action: #selector(startCapture), keyEquivalent: capKey.menuKeyEquivalent)
        shotItem.keyEquivalentModifierMask = capKey.cocoaModifierMask
        shotItem.image = MSnipUITheme.menuSymbol("viewfinder")
        shotItem.target = self
        menu.addItem(shotItem)

        let ocrItem = NSMenuItem(title: "截图提取文字 (OCR)", action: #selector(startQuickOCR), keyEquivalent: ocrKey.menuKeyEquivalent)
        ocrItem.keyEquivalentModifierMask = ocrKey.cocoaModifierMask
        ocrItem.image = MSnipUITheme.menuSymbol("text.viewfinder")
        ocrItem.target = self
        menu.addItem(ocrItem)

        let transItem = NSMenuItem(title: "截图翻译（原位覆盖 / 双栏对照）", action: #selector(startQuickTranslate), keyEquivalent: "")
        transItem.image = MSnipUITheme.menuSymbol("character.bubble")
        transItem.target = self
        menu.addItem(transItem)

        let pinItem = NSMenuItem(title: "从剪贴板贴图", action: #selector(handlePinHotKey), keyEquivalent: pinKey.menuKeyEquivalent)
        pinItem.keyEquivalentModifierMask = pinKey.cocoaModifierMask
        pinItem.image = MSnipUITheme.menuSymbol("pin")
        pinItem.target = self
        menu.addItem(pinItem)

        if pinManager.clickThroughCount > 0 {
            let unghostItem = NSMenuItem(
                title: "解除贴图鼠标穿透 (\(pinManager.clickThroughCount))",
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

        let histRoot = NSMenuItem(
            title: "最近截图记录 (\(historyRing.entries.count))",
            action: nil,
            keyEquivalent: ""
        )
        histRoot.image = MSnipUITheme.menuSymbol("clock.arrow.circlepath")
        histRoot.submenu = buildHistorySubmenu()
        menu.addItem(histRoot)

        let openDirItem = NSMenuItem(
            title: "打开快存图片目录…",
            action: #selector(openQuickSaveFolder),
            keyEquivalent: ""
        )
        openDirItem.image = MSnipUITheme.menuSymbol("folder")
        openDirItem.target = self
        menu.addItem(openDirItem)

        menu.addItem(.separator())

        let transCfgItem = NSMenuItem(
            title: "偏好与翻译 API 设置中心…",
            action: #selector(openTranslationSettings),
            keyEquivalent: ","
        )
        transCfgItem.keyEquivalentModifierMask = [.command]
        transCfgItem.image = MSnipUITheme.menuSymbol("slider.horizontal.3")
        transCfgItem.target = self
        menu.addItem(transCfgItem)

        let hkSubmenu = NSMenu()
        let enableItem = NSMenuItem(title: "启用全局快捷键", action: #selector(toggleHotKeysEnabled), keyEquivalent: "")
        enableItem.state = config.hotKeysEnabled ? .on : .off
        enableItem.target = self
        hkSubmenu.addItem(enableItem)

        let customTitle = config.hasCustomHotKeys
            ? "自定义录制快捷键… (\(capKey.displayString) / \(pinKey.displayString) / \(ocrKey.displayString))"
            : "自定义录制快捷键…"
        let customItem = NSMenuItem(title: customTitle, action: #selector(openHotKeyRecorder), keyEquivalent: "")
        customItem.state = config.hasCustomHotKeys ? .on : .off
        customItem.target = self
        hkSubmenu.addItem(customItem)
        hkSubmenu.addItem(.separator())

        for preset in HotKeyPreset.allCases {
            let item = NSMenuItem(title: preset.menuTitle, action: #selector(selectHotKeyPreset(_:)), keyEquivalent: "")
            item.representedObject = preset.rawValue
            item.state = (!config.hasCustomHotKeys && config.hotKeyPreset == preset) ? .on : .off
            item.target = self
            hkSubmenu.addItem(item)
        }
        let hkRoot = NSMenuItem(title: "全局快捷键方案", action: nil, keyEquivalent: "")
        hkRoot.image = MSnipUITheme.menuSymbol("keyboard")
        hkRoot.submenu = hkSubmenu
        menu.addItem(hkRoot)

        let permItem = NSMenuItem(
            title: "权限设置引导（拖拽开启）…",
            action: #selector(openPermissionGuide),
            keyEquivalent: ""
        )
        permItem.image = MSnipUITheme.menuSymbol("checkmark.shield")
        permItem.state = currentPermissionMenuState()
        permItem.target = self
        axMenuItem = permItem
        menu.addItem(permItem)

        let loginItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.image = MSnipUITheme.menuSymbol("bolt.horizontal.circle")
        loginItem.state = LaunchAtLoginManager.isEnabled ? .on : .off
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(title: "关于 MSnip", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.image = MSnipUITheme.menuSymbol("info.circle")
        aboutItem.target = self
        menu.addItem(aboutItem)

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

        let tip = NSMenuItem(title: "单击复制到剪贴板 · 按住 ⌥ 单击直接贴到桌面", action: nil, keyEquivalent: "")
        tip.isEnabled = false
        sub.addItem(tip)
        sub.addItem(.separator())

        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        for (idx, entry) in historyRing.entries.enumerated() {
            let title = "\(fmt.string(from: entry.createdAt))  ·  \(entry.pixelWidth) × \(entry.pixelHeight) px"
            let item = NSMenuItem(title: title, action: #selector(restoreHistoryItem(_:)), keyEquivalent: "")
            item.tag = idx
            item.target = self
            item.image = historyRing.menuThumbnail(for: entry)
            sub.addItem(item)
        }

        sub.addItem(.separator())
        let clear = NSMenuItem(title: "清空最近截图记录", action: #selector(clearCaptureHistory), keyEquivalent: "")
        clear.image = MSnipUITheme.menuSymbol("trash")
        clear.target = self
        sub.addItem(clear)
        return sub
    }

    func menuWillOpen(_ menu: NSMenu) {
        axMenuItem?.state = currentPermissionMenuState()
    }

    func currentPermissionMenuState() -> NSControl.StateValue {
        let screenOK = ScreenCapturer.runtimeVerifiedAccess || CGPreflightScreenCaptureAccess()
        let axOK = RegionDetector.checkAccessibilityPermission(prompt: false)
        if screenOK && axOK { return .on }
        if screenOK { return .mixed }
        return .off
    }

    @objc func restoreHistoryItem(_ sender: NSMenuItem) {
        let idx = sender.tag
        guard historyRing.entries.indices.contains(idx) else { return }
        let entry = historyRing.entries[idx]
        guard let cg = historyRing.loadCGImage(for: entry) else {
            NSSound.beep(); return
        }
        if NSEvent.modifierFlags.contains(.option), let scr = NSScreen.main ?? NSScreen.screens.first {
            pinManager.pin(cgImage: cg, scaleFactor: entry.scaleFactor, topLeftOnScreen: nil, screen: scr)
            ToastHUD.show(message: "已将历史截图贴到屏幕")
        } else {
            ClipboardAndSave.copyToClipboard(cgImage: cg, scaleFactor: entry.scaleFactor)
            ToastHUD.show(message: "已恢复历史截图到剪贴板 · \(entry.pixelWidth) × \(entry.pixelHeight) px")
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

    @objc func selectHotKeyPreset(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preset = HotKeyPreset(rawValue: raw) else { return }
        config.hotKeyPreset = preset
        config.clearCustomHotKeys()
        config.hotKeysEnabled = true
        config.save()
        hotKeyManager.apply(config: config)
        rebuildMenu()
    }

    @objc func toggleHotKeysEnabled() {
        config.hotKeysEnabled.toggle()
        config.save()
        hotKeyManager.apply(config: config)
        rebuildMenu()
    }

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

    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "MSnip（麦截）v1.4.1"
        alert.informativeText = """
        超轻量纯原生 macOS 全能截图、截图翻译、长截图、动图录制、实况识字与贴图工具
        • 全系清爽浅色白底（Daylight Porcelain）统一设计系统，零第三方依赖
        • 支持页内原位翻译、双栏流式翻译（内置免费 macOS 原生离线神经模型 + 通用大模型与国内云翻译 API）
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc func openQuickSaveFolder() {
        let url = ClipboardAndSave.resolveQuickSaveDirectory(preferred: config.lastSaveDirectory)
        NSWorkspace.shared.open(url)
    }

    @objc func quitApp() { NSApp.terminate(nil) }
}
