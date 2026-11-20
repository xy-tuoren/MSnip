import AppKit
import Foundation
import MSnipCore

/// 翻译 API 设置页布局与服务列表管理（紧凑顶部路由条 + 左侧服务列表 + 右侧动态无空隙表单）
extension TranslationSettingsWindow {
    func buildTranslationPage(in page: GeekFlippedView) {
        let W = page.bounds.width
        let cardW = W - 40

        // 1) 顶部全局路由条
        let topCard = GeekCardView(frame: NSRect(x: 20, y: 10, width: cardW, height: 40))
        page.addSubview(topCard)

        addTopCaption("目标", x: 10, in: topCard)
        targetLangPill = GeekDropdownPill(symbol: "globe", items: TranslationTargetLang.allCases.map(\.displayName))
        targetLangPill.frame = NSRect(x: 40, y: 7, width: 128, height: 26)
        targetLangPill.onSelect = { [weak self] idx in
            guard let self, TranslationTargetLang.allCases.indices.contains(idx) else { return }
            self.commitCurrentFormEdits()
            self.draft.targetLang = TranslationTargetLang.allCases[idx]
            self.persistDraft()
        }
        topCard.addSubview(targetLangPill)

        addTopCaption("主力", x: 176, in: topCard)
        primaryEnginePill = GeekDropdownPill(symbol: "cpu")
        primaryEnginePill.frame = NSRect(x: 206, y: 7, width: 132, height: 26)
        primaryEnginePill.onSelect = { [weak self] idx in self?.onSelectPrimaryIndex(idx) }
        topCard.addSubview(primaryEnginePill)

        addTopCaption("回退", x: 346, in: topCard)
        fallbackEnginePill = GeekDropdownPill(symbol: "arrow.triangle.2.circlepath")
        fallbackEnginePill.frame = NSRect(x: 376, y: 7, width: 112, height: 26)
        fallbackEnginePill.onSelect = { [weak self] idx in self?.onSelectFallbackIndex(idx) }
        topCard.addSubview(fallbackEnginePill)

        let autoLbl = NSTextField(labelWithString: "自动复制")
        autoLbl.font = .systemFont(ofSize: 11, weight: .medium)
        autoLbl.textColor = GeekTheme.inkSecondary
        autoLbl.alignment = .right
        autoLbl.frame = NSRect(x: cardW - 96, y: 13, width: 48, height: 15)
        topCard.addSubview(autoLbl)

        autoCopySwitch = GeekToggleSwitch(isOn: draft.autoCopyTranslation)
        autoCopySwitch.toolTip = "翻译完成后自动将译文复制到剪贴板"
        autoCopySwitch.frame = NSRect(x: cardW - 42, y: 11, width: 32, height: 18)
        autoCopySwitch.onToggle = { [weak self] on in
            self?.draft.autoCopyTranslation = on
            self?.persistDraft()
        }
        topCard.addSubview(autoCopySwitch)

        // 2) 左侧服务列表卡片（174px）
        let listCard = GeekCardView(frame: NSRect(x: 20, y: 60, width: 174, height: 294))
        page.addSubview(listCard)

        let scroll = NSScrollView(frame: listCard.bounds.insetBy(dx: 3, dy: 4))
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let tv = NSTableView(frame: scroll.bounds)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("PCol"))
        col.width = 164
        tv.addTableColumn(col); tv.headerView = nil; tv.rowHeight = 32
        tv.backgroundColor = .clear; tv.selectionHighlightStyle = .none
        tv.dataSource = self; tv.delegate = self
        scroll.documentView = tv; self.tableView = tv
        listCard.addSubview(scroll)

        addBtn = GeekButton(title: "新增服务", symbol: "plus", style: .subtle)
        addBtn.frame = NSRect(x: 20, y: 362, width: 110, height: 26)
        addBtn.onClick = { [weak self] in self?.popAddProviderMenu() }
        page.addSubview(addBtn)

        removeBtn = GeekButton(title: "删除", style: .subtle)
        removeBtn.frame = NSRect(x: 136, y: 362, width: 58, height: 26)
        removeBtn.onClick = { [weak self] in self?.removeSelectedProvider() }
        page.addSubview(removeBtn)

        // 3) 右侧动态表单卡片（416 × 328）
        let formCard = GeekCardView(frame: NSRect(x: 204, y: 60, width: cardW - 184, height: 328))
        page.addSubview(formCard)
        self.detailContainer = formCard
        buildDetailFields(in: formCard)
    }

    private func buildDetailFields(in cv: GeekCardView) {
        let fw = cv.bounds.width
        addRowCaption("名称", y: 12, in: cv)
        nameField = NSTextField()
        cv.addSubview(GeekInputBox(frame: NSRect(x: 78, y: 10, width: fw - 210, height: 26), field: nameField, placeholder: "如：DeepSeek 翻译", mono: false))

        enabledSwitch = GeekToggleSwitch(isOn: true)
        enabledSwitch.toolTip = "启用或停用该服务"
        enabledSwitch.frame = NSRect(x: fw - 124, y: 14, width: 32, height: 18)
        enabledSwitch.onToggle = { [weak self] _ in self?.onFormStructuralChanged() }
        cv.addSubview(enabledSwitch)

        setDefaultBtn = GeekButton(title: "设为主力", style: .subtle)
        setDefaultBtn.frame = NSRect(x: fw - 84, y: 10, width: 72, height: 26)
        setDefaultBtn.onClick = { [weak self] in self?.onSetAsPrimaryClicked() }
        cv.addSubview(setDefaultBtn)

        addRowCaption("协议", y: 46, in: cv)
        kindPill = GeekDropdownPill(symbol: "network", items: TranslationProviderKind.allCases.map(\.displayName))
        kindPill.frame = NSRect(x: 78, y: 44, width: fw - 90, height: 26)
        kindPill.onSelect = { [weak self] idx in self?.onSelectKindIndex(idx) }
        cv.addSubview(kindPill)

        presetRowView = GeekFlippedView(frame: NSRect(x: 0, y: 78, width: fw, height: 32))
        addRowCaption("模版", y: 4, in: presetRowView)
        llmPresetPill = GeekDropdownPill(symbol: "sparkles", items: ["一键套用常见大模型预设…"] + LLMQuickPreset.allCases.map(\.title))
        llmPresetPill.frame = NSRect(x: 78, y: 2, width: fw - 90, height: 26)
        llmPresetPill.onSelect = { [weak self] idx in self?.onSelectLLMPresetIndex(idx) }
        presetRowView.addSubview(llmPresetPill)
        cv.addSubview(presetRowView)

        nativeCardBox = GeekFlippedView(frame: NSRect(x: 14, y: 84, width: fw - 28, height: 186))
        nativeCardBox.wantsLayer = true
        nativeCardBox.layer?.backgroundColor = GeekTheme.inputBg.cgColor
        nativeCardBox.layer?.cornerRadius = 8.0
        nativeCardBox.layer?.borderWidth = 1.0
        nativeCardBox.layer?.borderColor = GeekTheme.accent.withAlphaComponent(0.28).cgColor
        nativeInfoLabel = NSTextField(wrappingLabelWithString: "")
        nativeInfoLabel.font = .systemFont(ofSize: 12.0)
        nativeInfoLabel.textColor = GeekTheme.inkSecondary
        nativeInfoLabel.frame = NSRect(x: 14, y: 14, width: fw - 56, height: 158)
        nativeCardBox.addSubview(nativeInfoLabel)
        cv.addSubview(nativeCardBox)

        (appIdRow, appIdLabel, appIdField) = makeDynamicRow(label: "AppID", placeholder: "", mono: true, width: fw)
        (endpointRow, endpointLabel, endpointField) = makeDynamicRow(label: "URL", placeholder: "https://api.deepseek.com/v1", mono: true, width: fw)
        (modelRow, modelLabel, modelField) = makeDynamicRow(label: "Model", placeholder: "deepseek-chat", mono: true, width: fw)
        (extra1Row, extraLabel1, extraField1) = makeDynamicRow(label: "提示词", placeholder: "", mono: false, width: fw)
        (extra2Row, extraLabel2, extraField2) = makeDynamicRow(label: "请求头", placeholder: "", mono: true, width: fw)

        apiKeyRow = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: fw, height: 32))
        apiKeyLabel = addRowCaption("API Key", y: 4, in: apiKeyRow)
        let keyW = fw - 90 - 34
        apiKeySecureField = NSSecureTextField()
        apiKeySecureBox = GeekInputBox(frame: NSRect(x: 78, y: 2, width: keyW, height: 26), field: apiKeySecureField, placeholder: "粘贴密钥（本地模型可留空）", mono: true)
        apiKeyRow.addSubview(apiKeySecureBox)
        apiKeyPlainField = NSTextField()
        apiKeyPlainBox = GeekInputBox(frame: NSRect(x: 78, y: 2, width: keyW, height: 26), field: apiKeyPlainField, placeholder: "粘贴密钥（本地模型可留空）", mono: true)
        apiKeyPlainBox.isHidden = true
        apiKeyRow.addSubview(apiKeyPlainBox)
        eyeToggleBtn = GeekButton(title: "", symbol: "eye", style: .subtle)
        eyeToggleBtn.toolTip = "显示 / 隐藏明文密钥"
        eyeToggleBtn.frame = NSRect(x: 78 + keyW + 4, y: 2, width: 30, height: 26)
        eyeToggleBtn.onClick = { [weak self] in self?.toggleAPIKeyVisibility() }
        apiKeyRow.addSubview(eyeToggleBtn)

        for r in [appIdRow!, endpointRow!, apiKeyRow!, modelRow!, extra1Row!, extra2Row!] { cv.addSubview(r) }

        cv.addHairline(atY: 286)
        testBtn = GeekButton(title: "测试连通", symbol: "bolt.horizontal", style: .accent)
        testBtn.frame = NSRect(x: 12, y: 294, width: 92, height: 25)
        testBtn.onClick = { [weak self] in self?.onTestClicked() }
        cv.addSubview(testBtn)

        testStatusLabel = NSTextField(labelWithString: "")
        testStatusLabel.font = .monospacedSystemFont(ofSize: 11.0, weight: .medium)
        testStatusLabel.textColor = GeekTheme.inkSecondary
        testStatusLabel.lineBreakMode = .byTruncatingTail
        testStatusLabel.frame = NSRect(x: 112, y: 299, width: fw - 124, height: 16)
        cv.addSubview(testStatusLabel)
    }

    private func makeDynamicRow(label: String, placeholder: String, mono: Bool, width fw: CGFloat) -> (GeekFlippedView, NSTextField, NSTextField) {
        let row = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: fw, height: 32))
        let lbl = addRowCaption(label, y: 4, in: row)
        let tf = NSTextField()
        row.addSubview(GeekInputBox(frame: NSRect(x: 78, y: 2, width: fw - 90, height: 26), field: tf, placeholder: placeholder, mono: mono))
        return (row, lbl, tf)
    }

    private func addTopCaption(_ text: String, x: CGFloat, in parent: NSView) {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11.0, weight: .medium); l.textColor = GeekTheme.inkMuted
        l.frame = NSRect(x: x, y: 13, width: 28, height: 15)
        parent.addSubview(l)
    }

    @discardableResult
    private func addRowCaption(_ text: String, y: CGFloat, in parent: NSView) -> NSTextField {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = .systemFont(ofSize: 11.5, weight: .medium); lbl.textColor = GeekTheme.inkSecondary; lbl.alignment = .right
        lbl.frame = NSRect(x: 8, y: y + 4, width: 62, height: 16)
        parent.addSubview(lbl)
        return lbl
    }

    func popAddProviderMenu() {
        commitCurrentFormEdits()
        let m = NSMenu()
        let nativeItem = NSMenuItem(title: "macOS 原生离线翻译（免费）", action: #selector(onAddMenuSelected(_:)), keyEquivalent: "")
        nativeItem.image = MSnipUITheme.menuSymbol("apple.logo")
        nativeItem.representedObject = ("kind", TranslationProviderKind.appleNative.rawValue)
        nativeItem.target = self
        m.addItem(nativeItem); m.addItem(.separator())

        for preset in LLMQuickPreset.allCases {
            let it = NSMenuItem(title: preset.title, action: #selector(onAddMenuSelected(_:)), keyEquivalent: "")
            it.image = MSnipUITheme.menuSymbol("sparkles")
            it.representedObject = ("llm", preset.rawValue); it.target = self
            m.addItem(it)
        }
        m.addItem(.separator())
        for kind in [TranslationProviderKind.anthropicCompatible, .geminiNative, .tencent, .baidu, .youdao, .deepl, .customWebhook] {
            let it = NSMenuItem(title: kind.displayName, action: #selector(onAddMenuSelected(_:)), keyEquivalent: "")
            it.image = MSnipUITheme.menuSymbol("cloud")
            it.representedObject = ("kind", kind.rawValue); it.target = self
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
        persistDraft(); refreshTopBarPopups()
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        loadSelectedProfileIntoForm()
    }

    func removeSelectedProvider() {
        guard draft.profiles.count > 1, draft.profiles.indices.contains(selectedIndex) else { NSSound.beep(); return }
        draft.profiles.remove(at: selectedIndex)
        selectedIndex = max(0, min(selectedIndex, draft.profiles.count - 1))
        if !draft.profiles.contains(where: { $0.id == draft.activeProfileID }) {
            draft.activeProfileID = draft.profiles.first?.id
        }
        persistDraft(); refreshTopBarPopups()
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        loadSelectedProfileIntoForm()
    }

    func revealJSONConfig() {
        commitCurrentFormEdits(); persistDraft()
        NSWorkspace.shared.activateFileViewerSelecting([TranslationSettingsConfig.storageURL])
    }
}
