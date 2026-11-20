import AppKit
import Foundation
import MSnipCore

/// 极简宽敞「翻译」设置页（零截断顶栏 + 216px 无裁切列表 + 434px 可折叠高级项表单）
extension TranslationSettingsWindow {
    func buildTranslationPage(in page: GeekFlippedView) {
        let cardW = page.bounds.width - 56 // 664

        // 1) 顶部极简偏好条（仅目标语言 + 自动复制，完全不截断）
        let topCard = GeekCardView(frame: NSRect(x: 28, y: 14, width: cardW, height: 48))
        page.addSubview(topCard)

        let langLbl = NSTextField(labelWithString: "目标语言")
        langLbl.font = .systemFont(ofSize: 13.5, weight: .medium)
        langLbl.textColor = GeekTheme.inkPrimary
        langLbl.frame = NSRect(x: 16, y: 15, width: 62, height: 18)
        topCard.addSubview(langLbl)

        targetLangPill = GeekDropdownPill(symbol: "globe", items: TranslationTargetLang.allCases.map(\.displayName))
        targetLangPill.frame = NSRect(x: 84, y: 9, width: 244, height: 30)
        targetLangPill.onSelect = { [weak self] idx in
            guard let self, TranslationTargetLang.allCases.indices.contains(idx) else { return }
            self.commitCurrentFormEdits()
            self.draft.targetLang = TranslationTargetLang.allCases[idx]
            self.persistDraft()
        }
        topCard.addSubview(targetLangPill)

        let autoLbl = NSTextField(labelWithString: "翻译后自动复制译文")
        autoLbl.font = .systemFont(ofSize: 13.5, weight: .medium)
        autoLbl.textColor = GeekTheme.inkPrimary
        autoLbl.alignment = .right
        autoLbl.frame = NSRect(x: cardW - 208, y: 15, width: 146, height: 18)
        topCard.addSubview(autoLbl)

        autoCopySwitch = GeekToggleSwitch(isOn: draft.autoCopyTranslation)
        autoCopySwitch.frame = NSRect(x: cardW - 54, y: 13, width: 38, height: 22)
        autoCopySwitch.onToggle = { [weak self] on in
            self?.draft.autoCopyTranslation = on
            self?.persistDraft()
        }
        topCard.addSubview(autoCopySwitch)

        // 2) 左侧服务列表（216px 宽 + .plain 样式杜绝系统默认 16px 内缩裁切）
        let listW: CGFloat = 216
        let listCard = GeekCardView(frame: NSRect(x: 28, y: 74, width: listW, height: 336))
        page.addSubview(listCard)

        let scroll = NSScrollView(frame: listCard.bounds.insetBy(dx: 4, dy: 6))
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let tv = NSTableView(frame: scroll.bounds)
        if #available(macOS 11.0, *) { tv.style = .plain }
        tv.intercellSpacing = NSSize(width: 0, height: 2)
        tv.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("PCol"))
        col.width = scroll.bounds.width
        tv.addTableColumn(col); tv.headerView = nil; tv.rowHeight = 38
        tv.backgroundColor = .clear; tv.selectionHighlightStyle = .none
        tv.dataSource = self; tv.delegate = self
        scroll.documentView = tv; self.tableView = tv
        listCard.addSubview(scroll)

        addBtn = GeekButton(title: "添加接口", symbol: "plus", style: .subtle)
        addBtn.frame = NSRect(x: 28, y: 418, width: 142, height: 32)
        addBtn.onClick = { [weak self] in self?.popAddProviderMenu() }
        page.addSubview(addBtn)

        removeBtn = GeekButton(title: "删除", style: .subtle)
        removeBtn.frame = NSRect(x: 178, y: 418, width: 66, height: 32)
        removeBtn.onClick = { [weak self] in self?.removeSelectedProvider() }
        page.addSubview(removeBtn)

        // 3) 右侧详情配置卡片（434 × 376）
        let detailW = cardW - listW - 14 // 434
        let formCard = GeekCardView(frame: NSRect(x: 28 + listW + 14, y: 74, width: detailW, height: 376))
        page.addSubview(formCard)
        self.detailContainer = formCard
        buildDetailCard(in: formCard)
    }

    private func buildDetailCard(in cv: GeekCardView) {
        let fw = cv.bounds.width

        // 卡片顶栏：服务名称 + 唯一的「设为当前引擎 / 使用中」按钮
        detailHeaderTitle = NSTextField(labelWithString: "")
        detailHeaderTitle.font = .systemFont(ofSize: 15.0, weight: .semibold)
        detailHeaderTitle.textColor = GeekTheme.inkPrimary
        detailHeaderTitle.lineBreakMode = .byTruncatingTail
        detailHeaderTitle.frame = NSRect(x: 16, y: 17, width: fw - 148, height: 20)
        cv.addSubview(detailHeaderTitle)

        setDefaultBtn = GeekButton(title: "设为当前引擎", style: .accent)
        setDefaultBtn.frame = NSRect(x: fw - 124, y: 12, width: 108, height: 30)
        setDefaultBtn.onClick = { [weak self] in self?.onSetAsPrimaryClicked() }
        cv.addSubview(setDefaultBtn)
        cv.addHairline(atY: 54, insetX: 0)

        // 中段可滚动表单容器（默认收起高级项时一屏无滚动条，展开后顺滑滚动）
        let bodyRect = NSRect(x: 0, y: 55, width: fw, height: 265)
        let fScroll = NSScrollView(frame: bodyRect)
        fScroll.drawsBackground = false; fScroll.borderType = .noBorder
        fScroll.hasVerticalScroller = true; fScroll.autohidesScrollers = true
        let content = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: fw, height: bodyRect.height))
        fScroll.documentView = content
        cv.addSubview(fScroll)
        self.formScrollView = fScroll
        self.formContentView = content

        // 名称 & 接口类型
        addRowCaption("名称", y: 14, in: content)
        nameField = NSTextField()
        content.addSubview(GeekInputBox(frame: NSRect(x: 88, y: 12, width: fw - 104, height: 30), field: nameField, placeholder: "给此翻译接口起个简短名称", mono: false))

        addRowCaption("接口类型", y: 52, in: content)
        kindPill = GeekDropdownPill(symbol: "network", items: TranslationProviderKind.allCases.map(\.displayName))
        kindPill.frame = NSRect(x: 88, y: 50, width: fw - 104, height: 30)
        kindPill.onSelect = { [weak self] idx in self?.onSelectKindIndex(idx) }
        content.addSubview(kindPill)

        // 厂商模版（仅 OpenAI 兼容显示）
        presetRowView = GeekFlippedView(frame: NSRect(x: 0, y: 88, width: fw, height: 38))
        addRowCaption("快捷预设", y: 4, in: presetRowView)
        llmPresetPill = GeekDropdownPill(symbol: "sparkles", items: ["一键套用大模型预设…"] + LLMQuickPreset.allCases.map(\.title))
        llmPresetPill.frame = NSRect(x: 88, y: 2, width: fw - 104, height: 30)
        llmPresetPill.onSelect = { [weak self] idx in self?.onSelectLLMPresetIndex(idx) }
        presetRowView.addSubview(llmPresetPill)
        content.addSubview(presetRowView)

        // Apple 离线说明卡（带系统翻译语言设置直达按钮）
        nativeCardBox = GeekFlippedView(frame: NSRect(x: 16, y: 94, width: fw - 32, height: 156))
        nativeCardBox.wantsLayer = true
        nativeCardBox.layer?.backgroundColor = GeekTheme.inputBg.cgColor
        nativeCardBox.layer?.cornerRadius = 8.0
        nativeCardBox.layer?.borderWidth = 1.0
        nativeCardBox.layer?.borderColor = GeekTheme.border.cgColor
        nativeInfoLabel = NSTextField(wrappingLabelWithString: "")
        nativeInfoLabel.font = .systemFont(ofSize: 13.0)
        nativeInfoLabel.textColor = GeekTheme.inkSecondary
        nativeInfoLabel.frame = NSRect(x: 14, y: 12, width: fw - 60, height: 98)
        nativeCardBox.addSubview(nativeInfoLabel)

        let sysLangBtn = GeekButton(title: "打开系统翻译语言设置…", symbol: "globe", style: .subtle)
        sysLangBtn.frame = NSRect(x: 14, y: 114, width: 196, height: 28)
        sysLangBtn.onClick = {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
        nativeCardBox.addSubview(sysLangBtn)
        content.addSubview(nativeCardBox)

        (appIdRow, appIdLabel, appIdField) = makeDynamicRow(label: "AppID", placeholder: "", mono: true, width: fw)
        (endpointRow, endpointLabel, endpointField) = makeDynamicRow(label: "接口地址", placeholder: "https://api.deepseek.com/v1", mono: true, width: fw)
        (modelRow, modelLabel, modelField) = makeDynamicRow(label: "模型", placeholder: "deepseek-chat", mono: true, width: fw)
        (extra1Row, extraLabel1, extraField1) = makeDynamicRow(label: "提示词", placeholder: "", mono: false, width: fw)
        (extra2Row, extraLabel2, extraField2) = makeDynamicRow(label: "请求头", placeholder: "", mono: true, width: fw)

        apiKeyRow = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: fw, height: 38))
        apiKeyLabel = addRowCaption("API 密钥", y: 4, in: apiKeyRow)
        let keyW = fw - 104 - 40
        apiKeySecureField = NSSecureTextField()
        apiKeySecureBox = GeekInputBox(frame: NSRect(x: 88, y: 2, width: keyW, height: 30), field: apiKeySecureField, placeholder: "粘贴密钥（本地模型可留空）", mono: true)
        apiKeyRow.addSubview(apiKeySecureBox)
        apiKeyPlainField = NSTextField()
        apiKeyPlainBox = GeekInputBox(frame: NSRect(x: 88, y: 2, width: keyW, height: 30), field: apiKeyPlainField, placeholder: "粘贴密钥（本地模型可留空）", mono: true)
        apiKeyPlainBox.isHidden = true
        apiKeyRow.addSubview(apiKeyPlainBox)
        eyeToggleBtn = GeekButton(title: "", symbol: "eye", style: .subtle)
        eyeToggleBtn.toolTip = "显示 / 隐藏明文密钥"
        eyeToggleBtn.frame = NSRect(x: 88 + keyW + 6, y: 2, width: 34, height: 30)
        eyeToggleBtn.onClick = { [weak self] in self?.toggleAPIKeyVisibility() }
        apiKeyRow.addSubview(eyeToggleBtn)

        advancedToggleBtn = GeekButton(title: "高级选项（提示词 / 请求头）", symbol: "chevron.right", style: .ghost)
        advancedToggleBtn.frame = NSRect(x: 84, y: 0, width: 214, height: 26)
        advancedToggleBtn.onClick = { [weak self] in
            guard let self, self.draft.profiles.indices.contains(self.selectedIndex) else { return }
            self.commitCurrentFormEdits()
            self.isAdvancedExpanded.toggle()
            self.updateFieldVisibility(for: self.draft.profiles[self.selectedIndex])
        }
        content.addSubview(advancedToggleBtn)

        for r in [appIdRow!, endpointRow!, apiKeyRow!, modelRow!, extra1Row!, extra2Row!] { content.addSubview(r) }

        // 底部测试栏（留足呼吸空间）
        cv.addHairline(atY: 320, insetX: 0)
        testBtn = GeekButton(title: "测试连接", symbol: "bolt.horizontal", style: .accent)
        testBtn.frame = NSRect(x: 16, y: 333, width: 108, height: 30)
        testBtn.onClick = { [weak self] in self?.onTestClicked() }
        cv.addSubview(testBtn)

        testStatusLabel = NSTextField(labelWithString: "")
        testStatusLabel.font = .monospacedSystemFont(ofSize: 12.5, weight: .medium)
        testStatusLabel.textColor = GeekTheme.inkSecondary
        testStatusLabel.lineBreakMode = .byTruncatingTail
        testStatusLabel.frame = NSRect(x: 136, y: 340, width: fw - 152, height: 18)
        cv.addSubview(testStatusLabel)
    }

    private func makeDynamicRow(label: String, placeholder: String, mono: Bool, width fw: CGFloat) -> (GeekFlippedView, NSTextField, NSTextField) {
        let row = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: fw, height: 38))
        let lbl = addRowCaption(label, y: 4, in: row)
        let tf = NSTextField()
        row.addSubview(GeekInputBox(frame: NSRect(x: 88, y: 2, width: fw - 104, height: 30), field: tf, placeholder: placeholder, mono: mono))
        return (row, lbl, tf)
    }

    @discardableResult
    private func addRowCaption(_ text: String, y: CGFloat, in parent: NSView) -> NSTextField {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = .systemFont(ofSize: 13.0, weight: .medium); lbl.textColor = GeekTheme.inkSecondary; lbl.alignment = .right
        lbl.frame = NSRect(x: 10, y: y + 4, width: 70, height: 18)
        parent.addSubview(lbl)
        return lbl
    }

    func popAddProviderMenu() {
        commitCurrentFormEdits()
        let m = NSMenu()
        let nativeItem = NSMenuItem(title: "Apple 离线翻译（免费）", action: #selector(onAddMenuSelected(_:)), keyEquivalent: "")
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
        isAdvancedExpanded = false
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
        isAdvancedExpanded = false
        persistDraft(); refreshTopBarPopups()
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        loadSelectedProfileIntoForm()
    }
}
