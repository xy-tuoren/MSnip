import AppKit
import Foundation
import MSnipCore

/// 快捷键行前置极客小图标底座
private final class GeekIconBadge: NSView {
    private let symbol: String
    override var isFlipped: Bool { true }
    init(symbol: String, frame: NSRect) {
        self.symbol = symbol
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = GeekTheme.controlBg.cgColor
        layer?.cornerRadius = 8.0
        layer?.borderWidth = 1.0
        layer?.borderColor = GeekTheme.border.cgColor
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        ToolbarView.drawSymbol(symbol, in: bounds, alpha: 0.92, tint: GeekTheme.inkPrimary)
    }
}

/// 设置窗口「通用」页与独立「快捷键」页构建及行内录入扩展
extension TranslationSettingsWindow {
    func buildGeneralPage(in page: GeekFlippedView) {
        let cardW = page.bounds.width - 56 // 664

        // 1) 基础（3 行 × 48px）
        addSectionHeader("基础", x: 30, y: 14, in: page)
        let baseCard = GeekCardView(frame: NSRect(x: 28, y: 38, width: cardW, height: 144))
        page.addSubview(baseCard)

        addRowLabel("开机自动启动", y: 0, height: 48, in: baseCard)
        loginSwitch = GeekToggleSwitch()
        loginSwitch.frame = NSRect(x: cardW - 54, y: 13, width: 38, height: 22)
        loginSwitch.onToggle = { on in _ = LaunchAtLoginManager.setEnabled(on) }
        baseCard.addSubview(loginSwitch)

        baseCard.addHairline(atY: 48)
        addRowLabel("截图时显示快捷键提示", y: 48, height: 48, in: baseCard)
        tipsSwitch = GeekToggleSwitch()
        tipsSwitch.frame = NSRect(x: cardW - 54, y: 61, width: 38, height: 22)
        tipsSwitch.onToggle = { [weak self] on in self?.onAppConfigMutated? { $0.showShortcutTips = on } }
        baseCard.addSubview(tipsSwitch)

        baseCard.addHairline(atY: 96)
        addRowLabel("截图保存位置", y: 96, height: 48, in: baseCard)
        saveDirPathLabel = NSTextField(labelWithString: "~/Pictures/MSnip")
        saveDirPathLabel.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        saveDirPathLabel.textColor = GeekTheme.inkSecondary
        saveDirPathLabel.lineBreakMode = .byTruncatingMiddle
        saveDirPathLabel.alignment = .right
        saveDirPathLabel.frame = NSRect(x: 164, y: 111, width: cardW - 306, height: 18)
        baseCard.addSubview(saveDirPathLabel)

        let chooseBtn = GeekButton(title: "更改", style: .subtle)
        chooseBtn.frame = NSRect(x: cardW - 134, y: 105, width: 56, height: 30)
        chooseBtn.onClick = { [weak self] in self?.chooseQuickSaveDirectory() }
        baseCard.addSubview(chooseBtn)

        let openDirBtn = GeekButton(title: "打开", style: .subtle)
        openDirBtn.frame = NSRect(x: cardW - 72, y: 105, width: 56, height: 30)
        openDirBtn.onClick = { [weak self] in
            NSWorkspace.shared.open(ClipboardAndSave.resolveQuickSaveDirectory(preferred: self?.appConfigProvider?().lastSaveDirectory))
        }
        baseCard.addSubview(openDirBtn)

        // 2) 默认格式（拆成独立 2 行 × 48px，彻底不挤）
        addSectionHeader("默认格式", x: 30, y: 198, in: page)
        let fmtCard = GeekCardView(frame: NSRect(x: 28, y: 222, width: cardW, height: 96))
        page.addSubview(fmtCard)

        addRowLabel("取色复制格式", y: 0, height: 48, in: fmtCard)
        colorFmtSegment = GeekSegmentControl(items: ColorCopyFormat.allCases.map(\.rawValue), selectedIndex: 0, mono: true)
        colorFmtSegment.frame = NSRect(x: cardW - 256, y: 9, width: 240, height: 30)
        colorFmtSegment.onSelect = { [weak self] idx in
            guard ColorCopyFormat.allCases.indices.contains(idx) else { return }
            self?.onAppConfigMutated? { $0.colorCopyFormat = ColorCopyFormat.allCases[idx] }
        }
        fmtCard.addSubview(colorFmtSegment)

        fmtCard.addHairline(atY: 48)
        addRowLabel("录屏导出格式", y: 48, height: 48, in: fmtCard)
        recFmtSegment = GeekSegmentControl(items: ["GIF", "MP4"], selectedIndex: 0, mono: true)
        recFmtSegment.frame = NSRect(x: cardW - 136, y: 57, width: 120, height: 30)
        recFmtSegment.onSelect = { [weak self] idx in
            self?.onAppConfigMutated? { $0.preferredRecordingFormat = (idx == 1) ? .mp4 : .gif }
        }
        fmtCard.addSubview(recFmtSegment)

        // 3) 系统权限（2 行 × 44px，已授权仅显示清爽状态，无多余按钮）
        addSectionHeader("系统权限", x: 30, y: 334, in: page)
        let permCard = GeekCardView(frame: NSRect(x: 28, y: 358, width: cardW, height: 88))
        page.addSubview(permCard)

        screenPermRow = GeekDotLabel(frame: NSRect(x: 16, y: 0, width: cardW - 32, height: 44))
        permCard.addSubview(screenPermRow)
        screenPermBtn = GeekButton(title: "前往开启", style: .accent)
        screenPermBtn.frame = NSRect(x: cardW - 102, y: 7, width: 86, height: 30)
        screenPermBtn.onClick = { [weak self] in self?.onOpenPermissionGuide?() }
        permCard.addSubview(screenPermBtn)

        permCard.addHairline(atY: 44)
        axPermRow = GeekDotLabel(frame: NSRect(x: 16, y: 44, width: cardW - 32, height: 44))
        permCard.addSubview(axPermRow)
        axPermBtn = GeekButton(title: "前往开启", style: .subtle)
        axPermBtn.frame = NSRect(x: cardW - 102, y: 51, width: 86, height: 30)
        axPermBtn.onClick = { [weak self] in self?.onOpenPermissionGuide?() }
        permCard.addSubview(axPermBtn)
    }

    func buildShortcutsPage(in page: GeekFlippedView) {
        let cardW = page.bounds.width - 56 // 664

        addSectionHeader("全局快捷键", x: 30, y: 20, in: page)
        hotKeyHintLabel = NSTextField(labelWithString: "点击右侧键帽直接录入 · Esc 取消 · ⌫ 恢复默认")
        hotKeyHintLabel.font = .systemFont(ofSize: 12.5, weight: .regular)
        hotKeyHintLabel.textColor = GeekTheme.inkMuted
        hotKeyHintLabel.alignment = .right
        hotKeyHintLabel.frame = NSRect(x: 160, y: 20, width: cardW - 134, height: 18)
        page.addSubview(hotKeyHintLabel)

        // 宽敞 3 行大卡片（每行 64px）
        let hkCard = GeekCardView(frame: NSRect(x: 28, y: 48, width: cardW, height: 192))
        page.addSubview(hkCard)
        for (i, slot) in HotKeySlot.allCases.enumerated() {
            let ry = CGFloat(i) * 64
            if i > 0 { hkCard.addHairline(atY: ry) }
            hkCard.addSubview(GeekIconBadge(symbol: slot.symbol, frame: NSRect(x: 16, y: ry + 16, width: 32, height: 32)))

            let titleLbl = NSTextField(labelWithString: slot.title)
            titleLbl.font = .systemFont(ofSize: 14.5, weight: .semibold)
            titleLbl.textColor = GeekTheme.inkPrimary
            titleLbl.frame = NSRect(x: 60, y: ry + 11, width: 280, height: 20)
            hkCard.addSubview(titleLbl)

            let subLbl = NSTextField(labelWithString: slot.subtitle)
            subLbl.font = .systemFont(ofSize: 12.5, weight: .regular)
            subLbl.textColor = GeekTheme.inkSecondary
            subLbl.frame = NSRect(x: 60, y: ry + 34, width: 420, height: 18)
            hkCard.addSubview(subLbl)

            let pill = GeekHotKeyPill(frame: NSRect(x: cardW - 142, y: ry + 16, width: 126, height: 32))
            pill.onClick = { [weak self] in self?.toggleInlineHotKey(slot) }
            hotKeyPills[slot] = pill
            hkCard.addSubview(pill)
        }

        // 快捷预设与总开关（2 行 × 52px）
        addSectionHeader("方案与开关", x: 30, y: 262, in: page)
        let optCard = GeekCardView(frame: NSRect(x: 28, y: 288, width: cardW, height: 104))
        page.addSubview(optCard)

        addRowLabel("常用预设方案", y: 0, height: 52, in: optCard)
        presetSegment = GeekSegmentControl(items: ["⌘1 / ⌘2", "⌘⇧A / P", "⌥A / P", "F1 / F3"], selectedIndex: 0, mono: true)
        presetSegment.frame = NSRect(x: cardW - 396, y: 10, width: 380, height: 32)
        presetSegment.onSelect = { [weak self] idx in
            guard let self, HotKeyPreset.allCases.indices.contains(idx) else { return }
            self.cancelInlineHotKeyRecording(restoreHotKeys: false)
            let preset = HotKeyPreset.allCases[idx]
            self.onAppConfigMutated? { $0.hotKeyPreset = preset; $0.clearCustomHotKeys(); $0.hotKeysEnabled = true }
            self.refreshGeneralAndPermissionsUI()
        }
        optCard.addSubview(presetSegment)

        optCard.addHairline(atY: 52)
        addRowLabel("启用全局快捷键", y: 52, height: 52, in: optCard)
        hotKeyEnableSwitch = GeekToggleSwitch(isOn: true)
        hotKeyEnableSwitch.frame = NSRect(x: cardW - 54, y: 67, width: 38, height: 22)
        hotKeyEnableSwitch.onToggle = { [weak self] on in
            self?.onAppConfigMutated? { $0.hotKeysEnabled = on }
            self?.refreshGeneralAndPermissionsUI()
        }
        optCard.addSubview(hotKeyEnableSwitch)
    }

    func refreshGeneralAndPermissionsUI() {
        guard loginSwitch != nil else { return }
        let cfg = appConfigProvider?() ?? AppConfig()
        loginSwitch.isOn = LaunchAtLoginManager.isEnabled
        tipsSwitch.isOn = cfg.showShortcutTips
        if let cIdx = ColorCopyFormat.allCases.firstIndex(of: cfg.colorCopyFormat) { colorFmtSegment.selectedIndex = cIdx }
        recFmtSegment.selectedIndex = (cfg.preferredRecordingFormat == .mp4) ? 1 : 0
        saveDirPathLabel.stringValue = ClipboardAndSave.resolveQuickSaveDirectory(preferred: cfg.lastSaveDirectory)
            .path.replacingOccurrences(of: NSHomeDirectory(), with: "~")

        let scrOK = ScreenCapturer.runtimeVerifiedAccess || CGPreflightScreenCaptureAccess()
        screenPermRow.dotColor = scrOK ? GeekTheme.emerald : GeekTheme.amber
        screenPermRow.text = "屏幕录制"
        screenPermRow.detail = scrOK ? "已授权" : ""
        screenPermBtn.isHidden = scrOK

        let axOK = RegionDetector.checkAccessibilityPermission(prompt: false)
        axPermRow.dotColor = axOK ? GeekTheme.emerald : GeekTheme.inkMuted
        axPermRow.text = "辅助功能"
        axPermRow.detail = axOK ? "已授权" : ""
        axPermBtn.isHidden = axOK

        hotKeyEnableSwitch.isOn = cfg.hotKeysEnabled
        presetSegment.selectedIndex = cfg.hasCustomHotKeys
            ? -1
            : (HotKeyPreset.allCases.firstIndex(of: cfg.hotKeyPreset) ?? 0)
        for slot in HotKeySlot.allCases {
            hotKeyPills[slot]?.configure(label: comboForSlot(slot, in: cfg).displayString, recording: activeRecordingSlot == slot)
        }
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
        hotKeyHintLabel.stringValue = "请按下「\(slot.title)」的新组合键（Esc 取消，⌫ 恢复默认）"
        refreshGeneralAndPermissionsUI()
    }

    func cancelInlineHotKeyRecording(restoreHotKeys: Bool) {
        guard activeRecordingSlot != nil else { return }
        activeRecordingSlot = nil
        if restoreHotKeys { onEndHotKeyRecording?() }
        hotKeyHintLabel?.textColor = GeekTheme.inkMuted
        hotKeyHintLabel?.stringValue = "点击右侧键帽直接录入 · Esc 取消 · ⌫ 恢复默认"
        refreshGeneralAndPermissionsUI()
    }

    func handleInlineHotKeyEvent(_ event: NSEvent) -> Bool {
        guard let slot = activeRecordingSlot else { return false }
        if event.keyCode == 53 { cancelInlineHotKeyRecording(restoreHotKeys: true); return true }
        if event.keyCode == 51 || event.keyCode == 117 {
            applyCustomCombo(nil, for: slot)
            hotKeyHintLabel.textColor = GeekTheme.emerald; hotKeyHintLabel.stringValue = "已恢复「\(slot.title)」为预设默认"
            return true
        }
        guard let combo = KeyCombo.from(event: event) else {
            NSSound.beep(); hotKeyHintLabel.textColor = GeekTheme.amber; hotKeyHintLabel.stringValue = "请包含 ⌘ / ⌥ / ⌃ 修饰键，或直接按 F1–F19"
            return true
        }
        let cfg = appConfigProvider?() ?? AppConfig()
        for other in HotKeySlot.allCases where other != slot && comboForSlot(other, in: cfg) == combo {
            NSSound.beep(); hotKeyHintLabel.textColor = GeekTheme.danger; hotKeyHintLabel.stringValue = "\(combo.displayString) 已被「\(other.title)」占用"
            return true
        }
        applyCustomCombo(combo, for: slot)
        hotKeyHintLabel.textColor = GeekTheme.emerald; hotKeyHintLabel.stringValue = "「\(slot.title)」已更新为 \(combo.displayString)"
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
        panel.allowsMultipleSelection = false; panel.prompt = "设为保存目录"
        panel.directoryURL = ClipboardAndSave.resolveQuickSaveDirectory(preferred: appConfigProvider?().lastSaveDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onAppConfigMutated? { $0.lastSaveDirectory = url.path }
        refreshGeneralAndPermissionsUI()
    }

    private func addSectionHeader(_ text: String, x: CGFloat, y: CGFloat, in parent: NSView) {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = .systemFont(ofSize: 13.0, weight: .semibold); lbl.textColor = GeekTheme.inkSecondary
        lbl.frame = NSRect(x: x, y: y, width: 140, height: 18)
        parent.addSubview(lbl)
    }

    private func addRowLabel(_ text: String, y: CGFloat, height: CGFloat, in card: GeekCardView) {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = .systemFont(ofSize: 14.0, weight: .medium); lbl.textColor = GeekTheme.inkPrimary; lbl.sizeToFit()
        lbl.frame = NSRect(x: 16, y: round(y + (height - lbl.frame.height) * 0.5), width: lbl.frame.width + 4, height: lbl.frame.height)
        card.addSubview(lbl)
    }

    func revealConfigDirectory() {
        commitCurrentFormEdits(); persistDraft()
        if !FileManager.default.fileExists(atPath: AppConfig.configURL.path) { appConfigProvider?().save() }
        NSWorkspace.shared.open(AppConfig.configURL.deletingLastPathComponent())
    }
}
