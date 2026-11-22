import AppKit
import Foundation
import MSnipCore

/// 对标 Bob / Easydict 的「两步极简」翻译设置页：
/// 默认只呈现 1~2 个必填项（API 密钥 + 一键获取 Key + 一键粘贴 + 测试并启用），协议/地址/模型/提示词折叠进更多设置。
extension TranslationSettingsWindow {
    func buildTranslationPage(in page: GeekFlippedView) {
        let cardW = page.bounds.width - 56 // 664

        // 1) 顶部极简偏好条（目标语言 + 自动复制）
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

        // 2) 左侧服务列表（220px，自带「使用中 / 已就绪 / 填 Key」中文状态徽章）
        let listW: CGFloat = 220
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

        addBtn = GeekButton(title: "添加服务", symbol: "plus", style: .subtle)
        addBtn.frame = NSRect(x: 28, y: 418, width: 146, height: 32)
        addBtn.onClick = { [weak self] in self?.popAddProviderMenu() }
        page.addSubview(addBtn)

        removeBtn = GeekButton(title: "删除", style: .subtle)
        removeBtn.frame = NSRect(x: 182, y: 418, width: 66, height: 32)
        removeBtn.onClick = { [weak self] in self?.removeSelectedProvider() }
        page.addSubview(removeBtn)

        // 3) 右侧极简配置卡片（430 × 376）
        let detailW = cardW - listW - 14 // 430
        let formCard = GeekCardView(frame: NSRect(x: 28 + listW + 14, y: 74, width: detailW, height: 376))
        page.addSubview(formCard)
        self.detailContainer = formCard
        buildDetailCard(in: formCard)
    }

    private func buildDetailCard(in cv: GeekCardView) {
        let fw = cv.bounds.width

        // 卡片顶栏：服务名称 + 简明模型副标题 + 设为当前
        detailHeaderTitle = NSTextField(labelWithString: "")
        detailHeaderTitle.font = .systemFont(ofSize: 15.0, weight: .semibold); detailHeaderTitle.textColor = GeekTheme.inkPrimary
        detailHeaderTitle.lineBreakMode = .byTruncatingTail
        detailHeaderTitle.frame = NSRect(x: 16, y: 12, width: fw - 128, height: 20); cv.addSubview(detailHeaderTitle)

        detailHeaderSubtitle = NSTextField(labelWithString: "")
        detailHeaderSubtitle.font = .systemFont(ofSize: 11.5, weight: .regular); detailHeaderSubtitle.textColor = GeekTheme.inkMuted
        detailHeaderSubtitle.lineBreakMode = .byTruncatingTail
        detailHeaderSubtitle.frame = NSRect(x: 16, y: 34, width: fw - 128, height: 15); cv.addSubview(detailHeaderSubtitle)

        setDefaultBtn = GeekButton(title: "设为当前", style: .accent)
        setDefaultBtn.frame = NSRect(x: fw - 104, y: 14, width: 88, height: 30)
        setDefaultBtn.onClick = { [weak self] in self?.onSetAsPrimaryClicked() }
        cv.addSubview(setDefaultBtn); cv.addHairline(atY: 58, insetX: 0)

        let bodyRect = NSRect(x: 0, y: 59, width: fw, height: 261)
        let fScroll = NSScrollView(frame: bodyRect)
        fScroll.drawsBackground = false; fScroll.borderType = .noBorder
        fScroll.hasVerticalScroller = true; fScroll.autohidesScrollers = true
        let content = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: fw, height: bodyRect.height))
        fScroll.documentView = content; cv.addSubview(fScroll)
        self.formScrollView = fScroll; self.formContentView = content

        // 一句话指引条 + 官方「获取 Key ↗」直达按钮
        guideCard = makeSubCard(frame: NSRect(x: 16, y: 14, width: fw - 32, height: 42))
        guideLabel = NSTextField(labelWithString: "")
        guideLabel.font = .systemFont(ofSize: 12.0, weight: .medium)
        guideLabel.textColor = GeekTheme.inkSecondary
        guideLabel.lineBreakMode = .byTruncatingTail
        guideLabel.frame = NSRect(x: 12, y: 13, width: fw - 148, height: 16)
        guideCard.addSubview(guideLabel)

        getKeyBtn = GeekButton(title: "获取 Key", symbol: "arrow.up.right", style: .accent)
        getKeyBtn.frame = NSRect(x: fw - 32 - 96, y: 7, width: 88, height: 28)
        getKeyBtn.onClick = { [weak self] in self?.onOpenConsoleURLClicked() }
        guideCard.addSubview(getKeyBtn)
        content.addSubview(guideCard)

        // Apple 离线开箱即用状态卡
        nativeCardBox = makeSubCard(frame: NSRect(x: 16, y: 16, width: fw - 32, height: 168))
        nativeInfoLabel = NSTextField(wrappingLabelWithString: "")
        nativeInfoLabel.font = .systemFont(ofSize: 13.0)
        nativeInfoLabel.textColor = GeekTheme.inkSecondary
        nativeInfoLabel.frame = NSRect(x: 14, y: 14, width: fw - 60, height: 102)
        nativeCardBox.addSubview(nativeInfoLabel)

        let sysLangBtn = GeekButton(title: "打开系统翻译语言设置…", symbol: "globe", style: .subtle)
        sysLangBtn.frame = NSRect(x: 14, y: 124, width: 196, height: 28)
        sysLangBtn.onClick = {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") { NSWorkspace.shared.open(url) }
        }
        nativeCardBox.addSubview(sysLangBtn)
        content.addSubview(nativeCardBox)

        // 核心极简表单行（AppID + 带「粘贴」与「眼睛」的 API Key）
        (appIdRow, appIdLabel, appIdField) = makeDynamicRow(label: "AppID", placeholder: "输入平台应用 ID", mono: true, width: fw)

        apiKeyRow = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: fw, height: 42))
        apiKeyLabel = addRowCaption("API 密钥", y: 6, in: apiKeyRow)
        let keyW = fw - 104 - 92
        apiKeySecureField = NSSecureTextField()
        apiKeySecureBox = GeekInputBox(frame: NSRect(x: 88, y: 4, width: keyW, height: 32), field: apiKeySecureField, placeholder: "粘贴 API Key 即可使用", mono: true)
        apiKeyRow.addSubview(apiKeySecureBox)
        apiKeyPlainField = NSTextField()
        apiKeyPlainBox = GeekInputBox(frame: NSRect(x: 88, y: 4, width: keyW, height: 32), field: apiKeyPlainField, placeholder: "粘贴 API Key 即可使用", mono: true)
        apiKeyPlainBox.isHidden = true
        apiKeyRow.addSubview(apiKeyPlainBox)

        pasteKeyBtn = GeekButton(title: "粘贴", style: .subtle)
        pasteKeyBtn.toolTip = "一键从剪贴板粘贴 API 密钥"
        pasteKeyBtn.frame = NSRect(x: 88 + keyW + 6, y: 4, width: 48, height: 32)
        pasteKeyBtn.onClick = { [weak self] in self?.onPasteAPIKeyClicked() }
        apiKeyRow.addSubview(pasteKeyBtn)

        eyeToggleBtn = GeekButton(title: "", symbol: "eye", style: .subtle)
        eyeToggleBtn.toolTip = "显示 / 隐藏明文密钥"
        eyeToggleBtn.frame = NSRect(x: 88 + keyW + 58, y: 4, width: 32, height: 32)
        eyeToggleBtn.onClick = { [weak self] in self?.toggleAPIKeyVisibility() }
        apiKeyRow.addSubview(eyeToggleBtn)

        // 可折叠的更多设置行（默认隐藏）
        (nameRow, _, nameField) = makeDynamicRow(label: "显示名称", placeholder: "自定义显示名称", mono: false, width: fw)
        kindRow = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: fw, height: 38))
        addRowCaption("接口协议", y: 4, in: kindRow)
        kindPill = GeekDropdownPill(symbol: "network", items: TranslationProviderKind.allCases.map(\.displayName))
        kindPill.frame = NSRect(x: 88, y: 2, width: fw - 104, height: 30)
        kindPill.onSelect = { [weak self] idx in self?.onSelectKindIndex(idx) }
        kindRow.addSubview(kindPill)

        presetRowView = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: fw, height: 38))
        addRowCaption("换用模版", y: 4, in: presetRowView)
        llmPresetPill = GeekDropdownPill(symbol: "sparkles", items: ["一键套用厂商预设…"] + LLMQuickPreset.allCases.map(\.title))
        llmPresetPill.frame = NSRect(x: 88, y: 2, width: fw - 104, height: 30)
        llmPresetPill.onSelect = { [weak self] idx in self?.onSelectLLMPresetIndex(idx) }
        presetRowView.addSubview(llmPresetPill)

        (endpointRow, endpointLabel, endpointField) = makeDynamicRow(label: "接口地址", placeholder: "https://api.deepseek.com/v1", mono: true, width: fw)
        (modelRow, modelLabel, modelField) = makeDynamicRow(label: "模型名称", placeholder: "deepseek-chat", mono: true, width: fw)
        (extra1Row, extraLabel1, extraField1) = makeDynamicRow(label: "提示词", placeholder: "", mono: false, width: fw)
        (extra2Row, extraLabel2, extraField2) = makeDynamicRow(label: "请求头", placeholder: "", mono: true, width: fw)

        advancedToggleBtn = GeekButton(title: "更多设置（自定义模型 / 地址 / 名称 / 协议）", symbol: "chevron.right", style: .ghost)
        advancedToggleBtn.frame = NSRect(x: 14, y: 0, width: 300, height: 28)
        advancedToggleBtn.onClick = { [weak self] in
            guard let self, self.draft.profiles.indices.contains(self.selectedIndex) else { return }
            self.commitCurrentFormEdits(); self.isAdvancedExpanded.toggle()
            self.updateFieldVisibility(for: self.draft.profiles[self.selectedIndex])
        }
        content.addSubview(advancedToggleBtn)
        for r in [appIdRow!, apiKeyRow!, endpointRow!, modelRow!, nameRow!, kindRow!, presetRowView!, extra1Row!, extra2Row!] { content.addSubview(r) }

        cv.addHairline(atY: 320, insetX: 0)
        testBtn = GeekButton(title: "测试并启用", symbol: "bolt.horizontal", style: .accent)
        testBtn.frame = NSRect(x: 16, y: 333, width: 118, height: 30)
        testBtn.onClick = { [weak self] in self?.onTestClicked() }
        cv.addSubview(testBtn)

        testStatusLabel = NSTextField(labelWithString: "")
        testStatusLabel.font = .monospacedSystemFont(ofSize: 12.0, weight: .medium); testStatusLabel.textColor = GeekTheme.inkSecondary
        testStatusLabel.lineBreakMode = .byTruncatingTail
        testStatusLabel.frame = NSRect(x: 144, y: 340, width: fw - 158, height: 18)
        cv.addSubview(testStatusLabel)
    }

    private func makeSubCard(frame: NSRect) -> GeekFlippedView {
        let v = GeekFlippedView(frame: frame); v.wantsLayer = true
        v.layer?.backgroundColor = GeekTheme.inputBg.cgColor; v.layer?.cornerRadius = 8.0
        v.layer?.borderWidth = 1.0; v.layer?.borderColor = GeekTheme.border.cgColor
        return v
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
        lbl.frame = NSRect(x: 8, y: y + 4, width: 72, height: 18)
        parent.addSubview(lbl)
        return lbl
    }

    func popAddProviderMenu() {
        commitCurrentFormEdits()
        let m = NSMenu()
        func addHeader(_ title: String) {
            let h = NSMenuItem(title: title, action: nil, keyEquivalent: ""); h.isEnabled = false; m.addItem(h)
        }
        func addKind(_ title: String, _ kind: TranslationProviderKind, sym: String) {
            let it = NSMenuItem(title: title, action: #selector(onAddMenuSelected(_:)), keyEquivalent: "")
            it.image = MSnipUITheme.menuSymbol(sym); it.representedObject = ("kind", kind.rawValue); it.target = self; m.addItem(it)
        }
        func addLLM(_ preset: LLMQuickPreset, sym: String = "sparkles") {
            let it = NSMenuItem(title: preset.title, action: #selector(onAddMenuSelected(_:)), keyEquivalent: "")
            it.image = MSnipUITheme.menuSymbol(sym); it.representedObject = ("llm", preset.rawValue); it.target = self; m.addItem(it)
        }

        addHeader("免费 / 含免费额度（推荐）")
        addKind("Apple 离线翻译（系统免费 · 无需 Key）", .appleNative, sym: "apple.logo")
        addLLM(.zhipuFree); addLLM(.siliconflow)
        addKind("Google Gemini（AI Studio 免费额度）", .geminiNative, sym: "sparkles")
        addLLM(.ollamaLocal, sym: "desktopcomputer")
        m.addItem(.separator())

        addHeader("热门 AI 大模型（填 1 个 Key 即用）")
        for p in [LLMQuickPreset.deepseek, .qwen, .doubao, .kimi, .openai, .openrouter] { addLLM(p) }
        addKind("Claude (Anthropic)", .anthropicCompatible, sym: "sparkles")
        m.addItem(.separator())

        addHeader("传统云翻译 / 自定义")
        addKind("腾讯云翻译（月 500 万字符免费）", .tencent, sym: "cloud")
        addKind("百度翻译（月百万字符免费）", .baidu, sym: "cloud")
        addKind("有道智云翻译", .youdao, sym: "cloud")
        addKind("DeepL / 自建 DeepLX", .deepl, sym: "globe")
        addKind("自定义 HTTP JSON 接口（开发者）", .customWebhook, sym: "wrench.and.screwdriver")
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: addBtn.bounds.height + 2), in: addBtn)
    }

    @objc private func onAddMenuSelected(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? (String, String) else { return }
        let created: TranslationProviderProfile
        if pair.0 == "llm", let preset = LLMQuickPreset(rawValue: pair.1) { created = .makePreset(.openAICompatible, llmPreset: preset) }
        else if let kind = TranslationProviderKind(rawValue: pair.1) { created = .makePreset(kind) }
        else { return }
        draft.profiles.append(created); selectedIndex = draft.profiles.count - 1
        isAdvancedExpanded = (created.kind == .customWebhook)
        persistDraft(); refreshTopBarPopups(); tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        loadSelectedProfileIntoForm()
    }

    func removeSelectedProvider() {
        guard draft.profiles.count > 1, draft.profiles.indices.contains(selectedIndex) else { NSSound.beep(); return }
        draft.profiles.remove(at: selectedIndex)
        selectedIndex = max(0, min(selectedIndex, draft.profiles.count - 1))
        if !draft.profiles.contains(where: { $0.id == draft.activeProfileID }) { draft.activeProfileID = draft.profiles.first?.id }
        isAdvancedExpanded = false
        persistDraft(); refreshTopBarPopups(); tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        loadSelectedProfileIntoForm()
    }
}
