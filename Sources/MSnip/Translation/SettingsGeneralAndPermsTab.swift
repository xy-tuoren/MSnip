import AppKit
import Foundation
import MSnipCore

/// 极客设置窗口「常规」页：行内快捷键直接录制、偏好开关、路径选择与权限状态灯
extension TranslationSettingsWindow {
    func buildGeneralPage(in page: GeekFlippedView) {
        let W = page.bounds.width, cardW = W - 40

        // 1) 快捷键区块
        addSectionHeader("快捷键", x: 22, y: 10, in: page)
        hotKeyHintLabel = NSTextField(labelWithString: "点击键帽直接录制")
        hotKeyHintLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        hotKeyHintLabel.textColor = GeekTheme.inkMuted
        hotKeyHintLabel.frame = NSRect(x: 72, y: 11, width: 342, height: 15)
        page.addSubview(hotKeyHintLabel)

        presetDropdown = GeekDropdownPill(symbol: "command", items: ["⌘1 / ⌘2 / ⌘3", "⌘⇧A / ⌘⇧P / ⌘⇧O", "⌥A / ⌥P / ⌥O", "F1 / F3 / F2"])
        presetDropdown.toolTip = "一键切换常用快捷键预设"
        presetDropdown.frame = NSRect(x: W - 218, y: 6, width: 134, height: 22)
        presetDropdown.onSelect = { [weak self] idx in
            guard let self, HotKeyPreset.allCases.indices.contains(idx) else { return }
            self.cancelInlineHotKeyRecording(restoreHotKeys: false)
            let preset = HotKeyPreset.allCases[idx]
            self.onAppConfigMutated? { $0.hotKeyPreset = preset; $0.clearCustomHotKeys(); $0.hotKeysEnabled = true }
            self.refreshGeneralAndPermissionsUI()
        }
        page.addSubview(presetDropdown)

        let hkStateLbl = NSTextField(labelWithString: "启用")
        hkStateLbl.font = .systemFont(ofSize: 11, weight: .medium); hkStateLbl.textColor = GeekTheme.inkSecondary; hkStateLbl.alignment = .right
        hkStateLbl.frame = NSRect(x: W - 80, y: 10, width: 24, height: 15)
        page.addSubview(hkStateLbl)

        hotKeyEnableSwitch = GeekToggleSwitch(isOn: true)
        hotKeyEnableSwitch.frame = NSRect(x: W - 52, y: 8, width: 32, height: 18)
        hotKeyEnableSwitch.onToggle = { [weak self] on in
            self?.onAppConfigMutated? { $0.hotKeysEnabled = on }
            self?.refreshGeneralAndPermissionsUI()
        }
        page.addSubview(hotKeyEnableSwitch)

        let hkCard = GeekCardView(frame: NSRect(x: 20, y: 32, width: cardW, height: 96))
        page.addSubview(hkCard)
        for (i, slot) in HotKeySlot.allCases.enumerated() {
            let ry = CGFloat(i) * 32
            if i > 0 { hkCard.addHairline(atY: ry) }
            addRowTitle(slot.title, subtitle: slot.subtitle, y: ry, in: hkCard)
            let pill = GeekHotKeyPill(frame: NSRect(x: cardW - 114, y: ry + 4, width: 102, height: 24))
            pill.onClick = { [weak self] in self?.toggleInlineHotKey(slot) }
            hotKeyPills[slot] = pill; hkCard.addSubview(pill)
        }

        // 2) 偏好区块
        addSectionHeader("偏好与保存", x: 22, y: 140, in: page)
        let prefCard = GeekCardView(frame: NSRect(x: 20, y: 162, width: cardW, height: 128))
        page.addSubview(prefCard)

        addRowTitle("开机自动启动", subtitle: "登录 macOS 后静默驻留菜单栏", y: 0, in: prefCard)
        loginSwitch = GeekToggleSwitch()
        loginSwitch.frame = NSRect(x: cardW - 44, y: 7, width: 32, height: 18)
        loginSwitch.onToggle = { on in _ = LaunchAtLoginManager.setEnabled(on) }
        prefCard.addSubview(loginSwitch)

        prefCard.addHairline(atY: 32)
        addRowTitle("截图快捷键提示卡", subtitle: "截图时在左下角显示操作提示（可按 H 随时开关）", y: 32, in: prefCard)
        tipsSwitch = GeekToggleSwitch()
        tipsSwitch.frame = NSRect(x: cardW - 44, y: 39, width: 32, height: 18)
        tipsSwitch.onToggle = { [weak self] on in self?.onAppConfigMutated? { $0.showShortcutTips = on } }
        prefCard.addSubview(tipsSwitch)

        prefCard.addHairline(atY: 64)
        addRowTitle("取色 / 录屏默认格式", subtitle: nil, y: 64, in: prefCard)
        colorFmtSegment = GeekSegmentControl(items: ColorCopyFormat.allCases.map(\.rawValue), selectedIndex: 0, mono: true)
        colorFmtSegment.frame = NSRect(x: cardW - 280, y: 68, width: 176, height: 24)
        colorFmtSegment.onSelect = { [weak self] idx in
            guard ColorCopyFormat.allCases.indices.contains(idx) else { return }
            self?.onAppConfigMutated? { $0.colorCopyFormat = ColorCopyFormat.allCases[idx] }
        }
        prefCard.addSubview(colorFmtSegment)

        recFmtSegment = GeekSegmentControl(items: ["GIF", "MP4"], selectedIndex: 0, mono: true)
        recFmtSegment.frame = NSRect(x: cardW - 96, y: 68, width: 84, height: 24)
        recFmtSegment.onSelect = { [weak self] idx in
            self?.onAppConfigMutated? { $0.preferredRecordingFormat = (idx == 1) ? .mp4 : .gif }
        }
        prefCard.addSubview(recFmtSegment)

        prefCard.addHairline(atY: 96)
        addRowTitle("快存图片目录", subtitle: nil, y: 96, in: prefCard)
        saveDirPathLabel = NSTextField(labelWithString: "~/Desktop")
        saveDirPathLabel.font = .monospacedSystemFont(ofSize: 11.0, weight: .regular)
        saveDirPathLabel.textColor = GeekTheme.inkSecondary; saveDirPathLabel.lineBreakMode = .byTruncatingMiddle; saveDirPathLabel.alignment = .right
        saveDirPathLabel.frame = NSRect(x: 118, y: 105, width: cardW - 234, height: 15)
        prefCard.addSubview(saveDirPathLabel)

        let chooseBtn = GeekButton(title: "更改", style: .subtle)
        chooseBtn.frame = NSRect(x: cardW - 108, y: 100, width: 46, height: 24)
        chooseBtn.onClick = { [weak self] in self?.chooseQuickSaveDirectory() }
        prefCard.addSubview(chooseBtn)

        let openDirBtn = GeekButton(title: "打开", style: .subtle)
        openDirBtn.frame = NSRect(x: cardW - 58, y: 100, width: 46, height: 24)
        openDirBtn.onClick = { [weak self] in
            NSWorkspace.shared.open(ClipboardAndSave.resolveQuickSaveDirectory(preferred: self?.appConfigProvider?().lastSaveDirectory))
        }
        prefCard.addSubview(openDirBtn)

        // 3) 权限与免重授签名区块
        addSectionHeader("系统权限", x: 22, y: 302, in: page)
        let certBtn = GeekButton(title: "复制免重授签名命令", symbol: "terminal", style: .ghost, mono: true)
        certBtn.toolTip = "运行一次生成本机固定证书，此后重编升级永久免重授权限"
        certBtn.frame = NSRect(x: W - 180, y: 298, width: 160, height: 22)
        certBtn.onClick = {
            ClipboardAndSave.copyText("bash /Users/xy/code/MSnip/scripts/setup-cert.sh")
            ToastHUD.show(message: "签名命令已复制，在终端运行一次即可永久锁定权限")
        }
        page.addSubview(certBtn)

        let permCard = GeekCardView(frame: NSRect(x: 20, y: 324, width: cardW, height: 64))
        page.addSubview(permCard)

        screenPermRow = GeekDotLabel(frame: NSRect(x: 12, y: 0, width: cardW - 110, height: 32))
        permCard.addSubview(screenPermRow)
        screenPermBtn = GeekButton(title: "权限向导", style: .subtle)
        screenPermBtn.frame = NSRect(x: cardW - 86, y: 4, width: 74, height: 24)
        screenPermBtn.onClick = { [weak self] in self?.onOpenPermissionGuide?() }
        permCard.addSubview(screenPermBtn)

        permCard.addHairline(atY: 32)
        axPermRow = GeekDotLabel(frame: NSRect(x: 12, y: 32, width: cardW - 110, height: 32))
        permCard.addSubview(axPermRow)
        axPermBtn = GeekButton(title: "前往开启", style: .subtle)
        axPermBtn.frame = NSRect(x: cardW - 86, y: 36, width: 74, height: 24)
        axPermBtn.onClick = { [weak self] in self?.onOpenPermissionGuide?() }
        permCard.addSubview(axPermBtn)
    }

    func refreshGeneralAndPermissionsUI() {
        guard loginSwitch != nil else { return }
        let cfg = appConfigProvider?() ?? AppConfig()
        hotKeyEnableSwitch.isOn = cfg.hotKeysEnabled
        if let pIdx = HotKeyPreset.allCases.firstIndex(of: cfg.hotKeyPreset) { presetDropdown.selectedIndex = pIdx }
        for slot in HotKeySlot.allCases {
            hotKeyPills[slot]?.configure(label: comboForSlot(slot, in: cfg).displayString, recording: activeRecordingSlot == slot)
        }
        loginSwitch.isOn = LaunchAtLoginManager.isEnabled
        tipsSwitch.isOn = cfg.showShortcutTips
        if let cIdx = ColorCopyFormat.allCases.firstIndex(of: cfg.colorCopyFormat) { colorFmtSegment.selectedIndex = cIdx }
        recFmtSegment.selectedIndex = (cfg.preferredRecordingFormat == .mp4) ? 1 : 0
        saveDirPathLabel.stringValue = ClipboardAndSave.resolveQuickSaveDirectory(preferred: cfg.lastSaveDirectory)
            .path.replacingOccurrences(of: NSHomeDirectory(), with: "~")

        let scrOK = ScreenCapturer.runtimeVerifiedAccess || CGPreflightScreenCaptureAccess()
        screenPermRow.dotColor = scrOK ? GeekTheme.emerald : GeekTheme.amber
        screenPermRow.text = "屏幕录制"; screenPermRow.detail = scrOK ? "已授权" : "未授权 · 截图必需"
        screenPermBtn.title = scrOK ? "向导" : "前往授权"; screenPermBtn.style = scrOK ? .ghost : .accent

        let axOK = RegionDetector.checkAccessibilityPermission(prompt: false)
        axPermRow.dotColor = axOK ? GeekTheme.emerald : GeekTheme.inkMuted
        axPermRow.text = "辅助功能"; axPermRow.detail = axOK ? "已授权" : "可选 · 控件对齐与自动滚动"
        axPermBtn.title = axOK ? "已开启" : "前往开启"; axPermBtn.style = axOK ? .ghost : .subtle
    }

    private func comboForSlot(_ slot: HotKeySlot, in cfg: AppConfig) -> KeyCombo {
        switch slot {
        case .capture: return cfg.activeCaptureCombo
        case .pin:     return cfg.activePinCombo
        case .ocr:     return cfg.activeOCRCombo
        }
    }

    private func toggleInlineHotKey(_ slot: HotKeySlot) {
        if activeRecordingSlot == slot { cancelInlineHotKeyRecording(restoreHotKeys: true); return }
        activeRecordingSlot = slot
        onBeginHotKeyRecording?()
        hotKeyHintLabel.textColor = GeekTheme.accent
        hotKeyHintLabel.stringValue = "录制「\(slot.title)」· Esc 取消 · ⌫ 恢复默认"
        refreshGeneralAndPermissionsUI()
    }

    func cancelInlineHotKeyRecording(restoreHotKeys: Bool) {
        guard activeRecordingSlot != nil else { return }
        activeRecordingSlot = nil
        if restoreHotKeys { onEndHotKeyRecording?() }
        hotKeyHintLabel?.textColor = GeekTheme.inkMuted
        hotKeyHintLabel?.stringValue = "点击键帽直接录制"
        refreshGeneralAndPermissionsUI()
    }

    func handleInlineHotKeyEvent(_ event: NSEvent) -> Bool {
        guard let slot = activeRecordingSlot else { return false }
        if event.keyCode == 53 { cancelInlineHotKeyRecording(restoreHotKeys: true); return true }
        if event.keyCode == 51 || event.keyCode == 117 {
            applyCustomCombo(nil, for: slot)
            hotKeyHintLabel.textColor = GeekTheme.emerald; hotKeyHintLabel.stringValue = "已恢复「\(slot.title)」为默认"
            return true
        }
        guard let combo = KeyCombo.from(event: event) else {
            NSSound.beep(); hotKeyHintLabel.textColor = GeekTheme.amber; hotKeyHintLabel.stringValue = "需含 ⌘ / ⌥ / ⌃ 修饰键，或按 F1–F19"
            return true
        }
        let cfg = appConfigProvider?() ?? AppConfig()
        for other in HotKeySlot.allCases where other != slot && comboForSlot(other, in: cfg) == combo {
            NSSound.beep(); hotKeyHintLabel.textColor = GeekTheme.danger; hotKeyHintLabel.stringValue = "\(combo.displayString) 已被「\(other.title)」占用"
            return true
        }
        applyCustomCombo(combo, for: slot)
        hotKeyHintLabel.textColor = GeekTheme.emerald; hotKeyHintLabel.stringValue = "已设为 \(combo.displayString)"
        return true
    }

    private func applyCustomCombo(_ combo: KeyCombo?, for slot: HotKeySlot) {
        onAppConfigMutated? { c in
            if combo != nil { c.hotKeysEnabled = true }
            switch slot {
            case .capture: c.customCaptureCombo = combo
            case .pin:     c.customPinCombo = combo
            case .ocr:     c.customOCRCombo = combo
            }
        }
        activeRecordingSlot = nil
        refreshGeneralAndPermissionsUI()
    }

    private func chooseQuickSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false; panel.prompt = "设为快存目录"
        panel.directoryURL = ClipboardAndSave.resolveQuickSaveDirectory(preferred: appConfigProvider?().lastSaveDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onAppConfigMutated? { $0.lastSaveDirectory = url.path }
        refreshGeneralAndPermissionsUI()
    }

    private func addSectionHeader(_ text: String, x: CGFloat, y: CGFloat, in parent: NSView) {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = .systemFont(ofSize: 11.5, weight: .semibold); lbl.textColor = GeekTheme.inkSecondary
        lbl.frame = NSRect(x: x, y: y, width: 120, height: 16)
        parent.addSubview(lbl)
    }

    private func addRowTitle(_ title: String, subtitle: String?, y: CGFloat, in card: GeekCardView) {
        let lbl = NSTextField(labelWithString: title)
        lbl.font = .systemFont(ofSize: 12.5, weight: .medium); lbl.textColor = GeekTheme.inkPrimary; lbl.sizeToFit()
        lbl.frame = NSRect(x: 12, y: round(y + (32 - lbl.frame.height) * 0.5), width: lbl.frame.width + 2, height: lbl.frame.height)
        card.addSubview(lbl)
        if let sub = subtitle {
            let s = NSTextField(labelWithString: sub)
            s.font = .systemFont(ofSize: 11.0); s.textColor = GeekTheme.inkMuted; s.lineBreakMode = .byTruncatingTail
            let sx = lbl.frame.maxX + 8
            s.frame = NSRect(x: sx, y: round(y + 9), width: max(40, card.bounds.width - sx - 124), height: 15)
            card.addSubview(s)
        }
    }

    func revealAppConfigJSON() {
        if !FileManager.default.fileExists(atPath: AppConfig.configURL.path) { appConfigProvider?().save() }
        NSWorkspace.shared.activateFileViewerSelecting([AppConfig.configURL])
    }
}
