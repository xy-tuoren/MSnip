import AppKit
import Foundation
import MSnipCore

/// 设置中心「热键与偏好」及「权限与签名」分页构建扩展
extension TranslationSettingsWindow {
    func buildGeneralAndPermissionsPages() {
        buildGeneralPage(in: generalPage)
        buildPermissionsPage(in: permissionsPage)
    }

    private func buildGeneralPage(in page: NSView) {
        let W = page.bounds.width, H = page.bounds.height
        let hdr = NSTextField(labelWithString: "全局快捷键与通用偏好")
        hdr.font = .systemFont(ofSize: 16, weight: .bold)
        hdr.textColor = MSnipUITheme.inkPrimary
        hdr.frame = NSRect(x: 20, y: H - 42, width: 280, height: 22)
        page.addSubview(hdr)

        // 1) 快捷键预设与录制卡片
        let hkCard = makeWhiteCard(frame: NSRect(x: 18, y: H - 222, width: W - 36, height: 166))
        page.addSubview(hkCard)

        let hkTitle = NSTextField(labelWithString: "全局热键方案")
        hkTitle.font = .systemFont(ofSize: 13.5, weight: .bold)
        hkTitle.textColor = MSnipUITheme.inkPrimary
        hkTitle.frame = NSRect(x: 16, y: 130, width: 160, height: 20)
        hkCard.addSubview(hkTitle)

        addRowLabel("预设组合", y: 92, in: hkCard)
        presetDropdown = LightDropdownPill(symbol: "command", items: HotKeyPreset.allCases.map(\.menuTitle))
        presetDropdown.frame = NSRect(x: 102, y: 87, width: 360, height: 28)
        presetDropdown.onSelect = { [weak self] idx in
            guard let self, HotKeyPreset.allCases.indices.contains(idx) else { return }
            let preset = HotKeyPreset.allCases[idx]
            self.onAppConfigMutated? { cfg in
                cfg.hotKeyPreset = preset
                cfg.clearCustomHotKeys()
                cfg.hotKeysEnabled = true
            }
            self.refreshGeneralAndPermissionsUI()
        }
        hkCard.addSubview(presetDropdown)

        hotKeySummaryLabel = NSTextField(labelWithString: "")
        hotKeySummaryLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        hotKeySummaryLabel.textColor = MSnipUITheme.accent
        hotKeySummaryLabel.frame = NSRect(x: 18, y: 48, width: 420, height: 20)
        hkCard.addSubview(hotKeySummaryLabel)

        let recBtn = OCRPillButton(title: "自由录制自定义组合键…", symbol: "keyboard")
        recBtn.frame = NSRect(x: 16, y: 12, width: 182, height: 28)
        recBtn.onClick = { [weak self] in self?.onOpenHotKeyRecorder?() }
        hkCard.addSubview(recBtn)

        // 2) 截图与交互体验卡片
        let prefCard = makeWhiteCard(frame: NSRect(x: 18, y: 66, width: W - 36, height: 234))
        page.addSubview(prefCard)

        let pfTitle = NSTextField(labelWithString: "截图与翻译行为")
        pfTitle.font = .systemFont(ofSize: 13.5, weight: .bold)
        pfTitle.textColor = MSnipUITheme.inkPrimary
        pfTitle.frame = NSRect(x: 16, y: 198, width: 180, height: 20)
        prefCard.addSubview(pfTitle)

        loginToggle = NSButton(checkboxWithTitle: "开机登录 macOS 时自动启动 MSnip", target: self, action: #selector(onGeneralCheckboxChanged))
        loginToggle.frame = NSRect(x: 18, y: 162, width: 320, height: 20)
        prefCard.addSubview(loginToggle)

        tipsToggle = NSButton(checkboxWithTitle: "在截图界面左下角显示高对比快捷键提示卡片（可按 H 随时开关）", target: self, action: #selector(onGeneralCheckboxChanged))
        tipsToggle.frame = NSRect(x: 18, y: 130, width: 460, height: 20)
        prefCard.addSubview(tipsToggle)

        autoCopyToggle = NSButton(checkboxWithTitle: "原位翻译或双栏翻译完成后自动复制译文到剪贴板", target: self, action: #selector(onGeneralCheckboxChanged))
        autoCopyToggle.frame = NSRect(x: 18, y: 98, width: 420, height: 20)
        prefCard.addSubview(autoCopyToggle)

        addRowLabel("默认取色格式", y: 58, in: prefCard)
        colorFmtDropdown = LightDropdownPill(symbol: "eyedropper", items: ColorCopyFormat.allCases.map(\.rawValue))
        colorFmtDropdown.frame = NSRect(x: 102, y: 53, width: 140, height: 28)
        colorFmtDropdown.onSelect = { [weak self] idx in
            guard let self, ColorCopyFormat.allCases.indices.contains(idx) else { return }
            let fmt = ColorCopyFormat.allCases[idx]
            self.onAppConfigMutated? { $0.colorCopyFormat = fmt }
        }
        prefCard.addSubview(colorFmtDropdown)

        let openDirBtn = OCRPillButton(title: "打开一键快存目录 (⌘⇧S)", symbol: "folder")
        openDirBtn.frame = NSRect(x: 16, y: 14, width: 186, height: 28)
        openDirBtn.onClick = { [weak self] in
            let dir = ClipboardAndSave.resolveQuickSaveDirectory(preferred: self?.appConfigProvider?().lastSaveDirectory)
            NSWorkspace.shared.open(dir)
        }
        prefCard.addSubview(openDirBtn)
    }

    private func buildPermissionsPage(in page: NSView) {
        let W = page.bounds.width, H = page.bounds.height
        let hdr = NSTextField(labelWithString: "系统权限与免重授签名")
        hdr.font = .systemFont(ofSize: 16, weight: .bold)
        hdr.textColor = MSnipUITheme.inkPrimary
        hdr.frame = NSRect(x: 20, y: H - 42, width: 280, height: 22)
        page.addSubview(hdr)

        let card1 = makeWhiteCard(frame: NSRect(x: 18, y: H - 208, width: W - 36, height: 150))
        page.addSubview(card1)

        permStatusLabel = NSTextField(wrappingLabelWithString: "")
        permStatusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        permStatusLabel.textColor = MSnipUITheme.inkPrimary
        permStatusLabel.frame = NSRect(x: 18, y: 56, width: W - 72, height: 80)
        card1.addSubview(permStatusLabel)

        let guideBtn = OCRPillButton(title: "打开拖拽式权限开启向导", symbol: "checkmark.shield", primary: true)
        guideBtn.frame = NSRect(x: 18, y: 14, width: 190, height: 28)
        guideBtn.onClick = { [weak self] in self?.onOpenPermissionGuide?() }
        card1.addSubview(guideBtn)

        let card2 = makeWhiteCard(frame: NSRect(x: 18, y: 88, width: W - 36, height: 168))
        page.addSubview(card2)

        let certDesc = NSTextField(wrappingLabelWithString: """
        本地固定签名证书（永久告别编译升级后重复授权）

        • 日常正常使用或重启电脑绝不会丢失权限；仅当重新编译更新二进制且未配置固定证书时，macOS 才会校验新二进制指纹。
        • 点击下方按钮复制一键命令并在终端执行一次，即可在本机生成 10 年期「MSnip Local Signer」签名证书，此后任何升级均永久免重授权限。
        """)
        certDesc.font = .systemFont(ofSize: 12.5)
        certDesc.textColor = MSnipUITheme.inkSecondary
        certDesc.frame = NSRect(x: 18, y: 52, width: W - 72, height: 102)
        card2.addSubview(certDesc)

        let copyCmdBtn = OCRPillButton(title: "复制本机固定证书生成命令", symbol: "terminal")
        copyCmdBtn.frame = NSRect(x: 18, y: 14, width: 198, height: 28)
        copyCmdBtn.onClick = {
            ClipboardAndSave.copyText("bash /Users/xy/code/MSnip/scripts/setup-cert.sh")
            ToastHUD.show(message: "命令已复制，粘贴到终端运行一次即可永久锁定权限")
        }
        card2.addSubview(copyCmdBtn)
    }

    func refreshGeneralAndPermissionsUI() {
        guard presetDropdown != nil else { return }
        if let cfg = appConfigProvider?() {
            if let idx = HotKeyPreset.allCases.firstIndex(of: cfg.hotKeyPreset) {
                presetDropdown.selectedIndex = idx
            }
            if let cIdx = ColorCopyFormat.allCases.firstIndex(of: cfg.colorCopyFormat) {
                colorFmtDropdown.selectedIndex = cIdx
            }
            tipsToggle.state = cfg.showShortcutTips ? .on : .off
            hotKeySummaryLabel.stringValue = "当前生效热键：截图 \(cfg.activeCaptureCombo.displayString)   ·   贴图 \(cfg.activePinCombo.displayString)   ·   识字 \(cfg.activeOCRCombo.displayString)"
        }
        loginToggle.state = LaunchAtLoginManager.isEnabled ? .on : .off
        autoCopyToggle.state = draft.autoCopyTranslation ? .on : .off

        let scrOK = ScreenCapturer.runtimeVerifiedAccess || CGPreflightScreenCaptureAccess()
        let axOK = RegionDetector.checkAccessibilityPermission(prompt: false)
        permStatusLabel.stringValue = """
        • 屏幕录制权限：\(scrOK ? "✓ 已授权生效（支持高清截图、取色放大镜、长截图与录屏）" : "待开启（点击下方按钮一键拖拽授权）")
        • 辅助功能权限：\(axOK ? "✓ 已授权生效（支持深层控件智能矩阵对齐与长截图自动滚动）" : "可选开启（开启后支持窗口内子控件识别与自动滚轮）")
        """
    }

    @objc private func onGeneralCheckboxChanged() {
        _ = LaunchAtLoginManager.setEnabled(loginToggle.state == .on)
        let showTips = (tipsToggle.state == .on)
        onAppConfigMutated? { $0.showShortcutTips = showTips }
        draft.autoCopyTranslation = (autoCopyToggle.state == .on)
        persistDraft()
    }

    func popAddProviderMenu() {
        commitCurrentFormEdits()
        let m = NSMenu()
        let nativeItem = NSMenuItem(title: "macOS 原生离线翻译（免费）", action: #selector(onAddMenuSelected(_:)), keyEquivalent: "")
        nativeItem.image = MSnipUITheme.menuSymbol("apple.logo")
        nativeItem.representedObject = ("kind", TranslationProviderKind.appleNative.rawValue)
        nativeItem.target = self
        m.addItem(nativeItem)
        m.addItem(.separator())

        for preset in LLMQuickPreset.allCases {
            let it = NSMenuItem(title: preset.title, action: #selector(onAddMenuSelected(_:)), keyEquivalent: "")
            it.image = MSnipUITheme.menuSymbol("sparkles")
            it.representedObject = ("llm", preset.rawValue)
            it.target = self
            m.addItem(it)
        }
        m.addItem(.separator())
        for kind in [TranslationProviderKind.anthropicCompatible, .geminiNative, .tencent, .baidu, .youdao, .deepl, .customWebhook] {
            let it = NSMenuItem(title: kind.displayName, action: #selector(onAddMenuSelected(_:)), keyEquivalent: "")
            it.image = MSnipUITheme.menuSymbol("cloud")
            it.representedObject = ("kind", kind.rawValue)
            it.target = self
            m.addItem(it)
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: addBtn.bounds.height + 2), in: addBtn)
    }

    @objc private func onAddMenuSelected(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? (String, String) else { return }
        let created: TranslationProviderProfile
        if pair.0 == "llm", let preset = LLMQuickPreset(rawValue: pair.1) {
            created = .makePreset(.openAICompatible, llmPreset: preset)
        } else if let kind = TranslationProviderKind(rawValue: pair.1) {
            created = .makePreset(kind)
        } else { return }
        draft.profiles.append(created)
        selectedIndex = draft.profiles.count - 1
        persistDraft()
        refreshTopBarPopups()
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        loadSelectedProfileIntoForm()
    }

    func removeSelectedProvider() {
        guard draft.profiles.count > 1, draft.profiles.indices.contains(selectedIndex) else {
            NSSound.beep(); return
        }
        draft.profiles.remove(at: selectedIndex)
        selectedIndex = max(0, min(selectedIndex, draft.profiles.count - 1))
        if !draft.profiles.contains(where: { $0.id == draft.activeProfileID }) {
            draft.activeProfileID = draft.profiles.first?.id
        }
        persistDraft()
        refreshTopBarPopups()
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        loadSelectedProfileIntoForm()
    }

    func revealJSONConfig() {
        commitCurrentFormEdits(); persistDraft()
        NSWorkspace.shared.activateFileViewerSelecting([TranslationSettingsConfig.storageURL])
    }
}
