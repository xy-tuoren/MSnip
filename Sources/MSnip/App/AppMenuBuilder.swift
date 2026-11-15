import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 顶部状态栏菜单构建与权限状态实时同步扩展
extension AppController {
    func rebuildMenu() {
        let menu = NSMenu()
        let capKey = config.hotKeyPreset.captureShortcut
        let pinKey = config.hotKeyPreset.pinShortcut
        let ocrKey = config.hotKeyPreset.ocrShortcut

        let shotItem = NSMenuItem(title: "区域截图 / 长截图", action: #selector(startCapture), keyEquivalent: capKey.keyEquivalent)
        shotItem.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: capKey.mask)
        shotItem.target = self
        menu.addItem(shotItem)

        let ocrItem = NSMenuItem(title: "截图提取文字 (OCR)", action: #selector(startQuickOCR), keyEquivalent: ocrKey.keyEquivalent)
        ocrItem.keyEquivalentModifierMask = NSEvent.ModifierFlags(rawValue: ocrKey.mask)
        ocrItem.target = self
        menu.addItem(ocrItem)

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

        let permItem = NSMenuItem(
            title: "权限设置引导（拖拽开启）…",
            action: #selector(openPermissionGuide),
            keyEquivalent: ""
        )
        permItem.state = currentPermissionMenuState()
        permItem.target = self
        axMenuItem = permItem
        menu.addItem(permItem)

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
        axMenuItem?.state = currentPermissionMenuState()
    }

    func currentPermissionMenuState() -> NSControl.StateValue {
        let screenOK = CGPreflightScreenCaptureAccess()
        let axOK = RegionDetector.checkAccessibilityPermission(prompt: false)
        if screenOK && axOK { return .on }
        if screenOK { return .mixed }
        return .off
    }
}
