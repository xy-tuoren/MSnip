import AppKit
import Foundation
import MSnipCore

/// 翻译页两步极简状态绑定：默认仅露核心密钥框、一键获取 Key、一键粘贴、测通自动启用
extension TranslationSettingsWindow {
    func refreshTopBarPopups() {
        targetLangPill?.customDisplayTitle = draft.targetLang.displayName
        autoCopySwitch?.isOn = draft.autoCopyTranslation
        ocrLatex.transModeSegment?.selectedIndex = (appConfigProvider?().translateAutoOpenDualPane ?? false) ? 1 : 0
        removeBtn?.isEnabled = draft.profiles.count > 1
        refreshTranslationEnginePill()
    }

    func presentTargetLanguagePicker(from anchor: NSView) {
        LanguagePickerPopover.shared.show(anchoredTo: anchor, current: draft.targetLang, dark: GeekTheme.isDark) { [weak self] picked in
            guard let self else { return }
            self.commitCurrentFormEdits()
            self.draft.targetLang = picked
            self.targetLangPill.customDisplayTitle = picked.displayName
            self.persistDraft()
        }
    }

    func loadSelectedProfileIntoForm() {
        guard draft.profiles.indices.contains(selectedIndex) else { return }
        let p = draft.profiles[selectedIndex]
        detailHeaderTitle.setTextWithTooltip(p.name)
        detailHeaderSubtitle.setTextWithTooltip(makeSubtitle(for: p))
        nameField.stringValue = p.name

        let isMain = (p.id == draft.activeProfileID)
        setDefaultBtn.title = isMain ? L("使用中") : L("设为当前")
        setDefaultBtn.symbolName = isMain ? "checkmark" : nil
        setDefaultBtn.style = isMain ? .emeraldSoft : .subtle
        setDefaultBtn.isEnabled = !isMain

        testBtn.title = isMain ? L("测试连接") : L("测试并启用")

        if let kIdx = TranslationProviderKind.allCases.firstIndex(of: p.kind) { kindPill.selectedIndex = kIdx }
        if let pIdx = TranslationProviderKind.llmProtocolCases.firstIndex(of: p.kind) { llmProtocolPill.selectedIndex = pIdx }
        llmPresetPill.customDisplayTitle = LLMQuickPreset.match(endpoint: p.endpoint)?.shortName ?? L("自定义 / 中转站")
        appIdField.stringValue = p.appIdOrSecretId
        endpointField.stringValue = p.endpoint
        apiKeySecureField.stringValue = p.apiKey
        apiKeyPlainField.stringValue = p.apiKey
        modelField.stringValue = p.model
        testStatusLabel.setTextWithTooltip("")
        updateFieldVisibility(for: p)
    }

    private func makeSubtitle(for p: TranslationProviderProfile) -> String {
        switch p.kind {
        case .appleNative: return L("macOS 内置神经网络 · 免费离线")
        case .openAICompatible, .openAIResponses, .anthropicCompatible, .geminiNative:
            let m = p.model.trimmingCharacters(in: .whitespacesAndNewlines)
            let tag = m.isEmpty ? L("默认模型") : L("模型 %@", m)
            return p.isLocalNoKeyEndpoint ? L("%@ · 本机离线免密钥", tag) : L("%@ · 仅需填入 API 密钥", tag)
        case .tencent: return L("腾讯云机器翻译 · 填入 SecretId / SecretKey")
        case .baidu: return L("百度翻译开放平台 · 填入 AppID / 密钥")
        case .youdao: return L("有道智云 · 填入应用 ID / 应用密钥")
        case .deepl: return p.isLocalNoKeyEndpoint ? L("自建 DeepLX · 无需 Auth Key") : L("DeepL 官方 · 仅需填入 Auth Key")
        case .customWebhook: return L("自定义 HTTP JSON 接口")
        }
    }

    func toggleAPIKeyVisibility() {
        let wasFocused = (window?.firstResponder as? NSTextView)?.delegate as AnyObject?
            === (isAPIKeyRevealed ? apiKeyPlainField : apiKeySecureField)
        window?.makeFirstResponder(nil)
        if isAPIKeyRevealed {
            apiKeySecureField.stringValue = apiKeyPlainField.stringValue
        } else {
            apiKeyPlainField.stringValue = apiKeySecureField.stringValue
        }
        isAPIKeyRevealed.toggle()
        eyeToggleBtn.symbolName = isAPIKeyRevealed ? "eye.slash" : "eye"
        apiKeySecureBox.isHidden = isAPIKeyRevealed
        apiKeyPlainBox.isHidden = !isAPIKeyRevealed
        if wasFocused {
            window?.makeFirstResponder(isAPIKeyRevealed ? apiKeyPlainField : apiKeySecureField)
        }
    }

    func onPasteAPIKeyClicked() {
        guard let raw = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            testStatusLabel.setTextWithTooltip(L("剪贴板中暂无文本"), color: GeekTheme.amber)
            return
        }
        apiKeySecureField.stringValue = raw
        apiKeyPlainField.stringValue = raw
        commitCurrentFormEdits()
        persistDraft()
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        testStatusLabel.setTextWithTooltip(L("✓ 已粘贴密钥 · 点左侧「%@」验证", testBtn.title), color: GeekTheme.emerald)
    }

    func onOpenConsoleURLClicked() {
        guard draft.profiles.indices.contains(selectedIndex),
              let urlStr = draft.profiles[selectedIndex].consoleURL,
              let url = URL(string: urlStr) else { return }
        NSWorkspace.shared.open(url)
    }

    func updateFieldVisibility(for p: TranslationProviderProfile) {
        let kind = p.kind
        let isNative = (kind == .appleNative)
        let isCustom = (kind == .customWebhook)
        let isLLMKind = kind.isLLMProtocol

        nativeCardBox.isHidden = !isNative
        guideCard.isHidden = isNative || isLLMKind

        let fullW = formScrollView.contentSize.width - 114
        if !guideCard.isHidden {
            guideLabel.setTextWithTooltip(p.quickGuideText)
            let hasLink = (p.consoleURL != nil)
            getKeyBtn.isHidden = !hasLink
            guideLabel.frame.size.width = hasLink ? (guideCard.bounds.width - 118) : (guideCard.bounds.width - 28)
        }
        let hasLLMLink = isLLMKind && (LLMQuickPreset.match(endpoint: p.endpoint)?.consoleURL != nil)
        presetGetKeyBtn.isHidden = !hasLLMLink
        llmPresetPill.frame.size.width = hasLLMLink ? (fullW - 94) : fullW

        // 大模型统一表单：请求协议 + 快捷模版 + 接口地址 + API 密钥 + 模型名称(+拉取) 一屏直出
        let primaryNeedsAppId = (kind == .tencent || kind == .baidu || kind == .youdao)
        let primaryNeedsKey = !isNative && !(kind == .deepl && p.isLocalNoKeyEndpoint)
        let primaryNeedsModel = isLLMKind
        let primaryNeedsEndpoint = isLLMKind || isCustom || (kind == .deepl && p.isLocalNoKeyEndpoint)

        let supportsModel = isLLMKind || (kind == .tencent)
        let supportsExtra = isLLMKind || isCustom

        llmProtocolRow.isHidden = !isLLMKind
        presetRowView.isHidden = !isLLMKind
        appIdRow.isHidden = !primaryNeedsAppId
        apiKeyRow.isHidden = !primaryNeedsKey
        apiKeySecureBox.isHidden = isAPIKeyRevealed
        apiKeyPlainBox.isHidden = !isAPIKeyRevealed
        fetchModelsBtn.isHidden = !isLLMKind
        let nextModelW = isLLMKind ? (fullW - 74) : fullW
        modelInputBox.frame.size.width = nextModelW
        modelField.frame.size.width = max(40, nextModelW - 20)

        let keyPlaceholder = (isLLMKind && p.isLocalNoKeyEndpoint) ? L("可选（本机/局域网免鉴权可留空）") : L("粘贴 API Key 即可使用")
        apiKeySecureField.setGeekPlaceholder(keyPlaceholder)
        apiKeyPlainField.setGeekPlaceholder(keyPlaceholder)

        advancedToggleBtn.isHidden = isNative
        advancedToggleBtn.symbolName = isAdvancedExpanded ? "chevron.down" : "chevron.right"
        advancedToggleBtn.title = isAdvancedExpanded
            ? L("收起高级设置")
            : (isLLMKind ? L("高级设置（显示名称 / 提示词 / 请求头）") : L("更多设置（显示名称 / 类型 / 地址 / 参数）"))

        nameRow.isHidden = isNative || !isAdvancedExpanded
        kindRow.isHidden = isNative || isLLMKind || !isAdvancedExpanded
        endpointRow.isHidden = isNative || (!primaryNeedsEndpoint && !isAdvancedExpanded)
        modelRow.isHidden = isNative || !supportsModel || (!primaryNeedsModel && !isAdvancedExpanded)
        extra1Row.isHidden = isNative || !supportsExtra || !isAdvancedExpanded
        extra2Row.isHidden = isNative || !supportsExtra || !isAdvancedExpanded

        configureFieldLabels(for: p)

        // 按「指引条/LLM协议模版 → 核心必填项 → 展开按钮 → 高级设置」舒适排布
        var cursorY: CGFloat = 14
        if !guideCard.isHidden {
            guideCard.frame.origin.y = cursorY
            cursorY += 52
        }
        var primaryRows: [GeekFlippedView] = []
        if isLLMKind { primaryRows.append(contentsOf: [presetRowView, llmProtocolRow]) }
        if primaryNeedsAppId { primaryRows.append(appIdRow) }
        if primaryNeedsEndpoint { primaryRows.append(endpointRow) }
        if primaryNeedsKey { primaryRows.append(apiKeyRow) }
        if primaryNeedsModel { primaryRows.append(modelRow) }
        for row in primaryRows where !row.isHidden {
            row.frame.origin.y = cursorY
            cursorY += row.frame.height + 4
        }

        if !advancedToggleBtn.isHidden {
            advancedToggleBtn.frame.origin.y = cursorY + 4
            cursorY += 36
        }

        var advancedRows: [GeekFlippedView] = [nameRow, kindRow]
        if !primaryNeedsEndpoint { advancedRows.append(endpointRow) }
        if !primaryNeedsModel { advancedRows.append(modelRow) }
        advancedRows.append(contentsOf: [extra1Row, extra2Row])
        for row in advancedRows where !row.isHidden {
            row.frame.origin.y = cursorY
            cursorY += row.frame.height + 4
        }

        let minH = formScrollView.contentSize.height
        let contentH = isNative ? minH : max(minH, cursorY + 12)
        formContentView.frame = NSRect(x: 0, y: 0, width: formScrollView.contentSize.width, height: contentH)
    }

    private func configureFieldLabels(for p: TranslationProviderProfile) {
        switch p.kind {
        case .appleNative:
            nativeInfoLabel.stringValue = L("macOS 系统内置离线神经网络翻译\n完全免费 · 无需 API 密钥 · 断网可用\n\n正在检测本机离线语言包状态…")
            Task { @MainActor [weak self] in
                let status = await AppleNativeTranslator.queryAvailabilitySummary()
                self?.nativeInfoLabel.stringValue = L("macOS 系统内置离线神经网络翻译\n完全免费 · 无需 API 密钥 · 断网可用\n\n%@", status)
            }
        case .openAICompatible, .openAIResponses, .anthropicCompatible, .geminiNative:
            endpointLabel.stringValue = L("接口地址"); apiKeyLabel.stringValue = L("API 密钥"); modelLabel.stringValue = L("模型名称")
            let epSuffix = p.kind == .openAIResponses ? "/v1/responses" : (p.kind == .anthropicCompatible ? "/v1/messages" : (p.kind == .geminiNative ? "/v1beta" : "/v1/chat/completions"))
            endpointField.setGeekPlaceholder(L("https://your-relay.com（自动补全 %@）", epSuffix))
            extraLabel1.stringValue = L("提示词"); extraField1.setGeekPlaceholder(L("留空使用内置精准截图翻译提示词"))
            extraField1.stringValue = p.systemPrompt
            extraLabel2.stringValue = L("请求头"); extraField2.setGeekPlaceholder(L("可选 JSON，如 {\"X-Key\":\"val\"}"))
            extraField2.stringValue = p.customHeadersJSON
        case .tencent:
            appIdLabel.stringValue = "SecretId"; appIdField.setGeekPlaceholder(L("填入腾讯云 SecretId"))
            apiKeyLabel.stringValue = "SecretKey"; endpointLabel.stringValue = L("请求域名"); endpointField.setGeekPlaceholder(L("默认 tmt.tencentcloudapi.com"))
            modelLabel.stringValue = L("地域"); modelField.setGeekPlaceholder(L("默认 ap-guangzhou"))
        case .baidu:
            appIdLabel.stringValue = "AppID"; appIdField.setGeekPlaceholder(L("填入百度翻译 AppID"))
            apiKeyLabel.stringValue = L("密钥"); endpointLabel.stringValue = L("接口地址"); endpointField.setGeekPlaceholder(L("默认百度通用翻译 API"))
        case .youdao:
            appIdLabel.stringValue = L("应用 ID"); appIdField.setGeekPlaceholder(L("填入有道应用 ID"))
            apiKeyLabel.stringValue = L("应用密钥"); endpointLabel.stringValue = L("接口地址"); endpointField.setGeekPlaceholder(L("默认有道智云文本翻译 API"))
        case .deepl:
            endpointLabel.stringValue = L("接口地址"); endpointField.setGeekPlaceholder(L("默认 DeepL 官方或自建 DeepLX 地址")); apiKeyLabel.stringValue = "Auth Key"
        case .customWebhook:
            endpointLabel.stringValue = L("请求 URL"); endpointField.setGeekPlaceholder("https://your-service/translate")
            apiKeyLabel.stringValue = "Bearer"; extraLabel1.stringValue = "Body"; extraField1.setGeekPlaceholder(L("JSON 模板，支持 {{text}} {{target}}"))
            extraField1.stringValue = p.customBodyTemplate; extraLabel2.stringValue = L("JSON 路径"); extraField2.setGeekPlaceholder(L("如 data.translatedText")); extraField2.stringValue = p.customResponsePath
        }
    }

    func commitCurrentFormEdits() {
        guard draft.profiles.indices.contains(selectedIndex), nameField != nil else { return }
        let old = draft.profiles[selectedIndex]
        var p = old
        let trimmedName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty { p.name = trimmedName }
        p.appIdOrSecretId = appIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        p.endpoint = endpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeKey = isAPIKeyRevealed ? apiKeyPlainField.stringValue : apiKeySecureField.stringValue
        p.apiKey = activeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        p.model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.kind == .customWebhook {
            p.customBodyTemplate = extraField1.stringValue; p.customResponsePath = extraField2.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if p.kind.isLLMProtocol {
            p.systemPrompt = extraField1.stringValue; p.customHeadersJSON = extraField2.stringValue
        }
        let userEditedFields = (p.endpoint != old.endpoint || p.model != old.model || p.name != old.name
            || p.customBodyTemplate != old.customBodyTemplate || p.customResponsePath != old.customResponsePath)
        if p.kind == .appleNative || !p.apiKey.isEmpty || !p.appIdOrSecretId.isEmpty || (userEditedFields && p.isConfiguredReady) {
            p.isEnabled = true
        }
        draft.profiles[selectedIndex] = p
        detailHeaderTitle.setTextWithTooltip(p.name); detailHeaderSubtitle.setTextWithTooltip(makeSubtitle(for: p))
    }

    func onSetAsPrimaryClicked() {
        commitCurrentFormEdits()
        guard draft.profiles.indices.contains(selectedIndex) else { return }
        draft.profiles[selectedIndex].isEnabled = true; draft.activeProfileID = draft.profiles[selectedIndex].id
        persistDraft(); refreshTopBarPopups()
        tableView.reloadData(); tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        loadSelectedProfileIntoForm()
        testStatusLabel.setTextWithTooltip(L("✓ 已设为当前翻译引擎"), color: GeekTheme.emerald)
    }

    func onTestClicked() {
        commitCurrentFormEdits(); persistDraft()
        guard draft.profiles.indices.contains(selectedIndex) else { return }
        let prof = draft.profiles[selectedIndex]
        activeTestTask?.cancel(); testBtn.isEnabled = false
        testStatusLabel.setTextWithTooltip(L("正在探测连通性…"), color: GeekTheme.inkSecondary)
        activeTestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let res = await TranslationService.shared.testConnectivity(profile: prof, hostWindow: self.window)
            guard !Task.isCancelled, self.draft.profiles.indices.contains(self.selectedIndex),
                  self.draft.profiles[self.selectedIndex].id == prof.id else { return }
            self.testBtn.isEnabled = true
            if res.ok {
                self.draft.profiles[self.selectedIndex].isEnabled = true
                if self.draft.activeProfileID != prof.id {
                    self.draft.activeProfileID = prof.id
                    self.persistDraft(); self.refreshTopBarPopups(); self.loadSelectedProfileIntoForm()
                    self.testStatusLabel.setTextWithTooltip(L("%@ · 已启用", res.message), color: GeekTheme.emerald)
                } else {
                    self.persistDraft(); self.testStatusLabel.setTextWithTooltip(res.message, color: GeekTheme.emerald)
                }
            } else {
                self.testStatusLabel.setTextWithTooltip(res.message, color: GeekTheme.amber)
            }
            self.tableView.reloadData(); self.tableView.selectRowIndexes(IndexSet(integer: self.selectedIndex), byExtendingSelection: false)
        }
    }
}

// MARK: - 模型下拉选择与快速切换

/// 翻译设置窗：一键从兼容协议服务端 `/v1/models` 拉取模型列表并下拉选择
extension TranslationSettingsWindow {
    func onFetchModelsClicked() {
        commitCurrentFormEdits()
        guard draft.profiles.indices.contains(selectedIndex) else { return }
        let prof = draft.profiles[selectedIndex]
        activeFetchModelsTask?.cancel(); fetchModelsBtn.isEnabled = false
        testStatusLabel.setTextWithTooltip(L("正在拉取服务端模型列表…"), color: GeekTheme.inkSecondary)

        activeFetchModelsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { self.fetchModelsBtn.isEnabled = true } }
            do {
                let models = try await LLMModelFetcher.fetchModels(profile: prof)
                guard !Task.isCancelled, self.draft.profiles.indices.contains(self.selectedIndex),
                      self.draft.profiles[self.selectedIndex].id == prof.id else { return }
                self.testStatusLabel.setTextWithTooltip(L("✓ 已拉取 %@ 个可用模型，请选择", models.count), color: GeekTheme.emerald)
                self.presentFetchedModelsMenu(models, currentModel: prof.model)
            } catch {
                guard !Task.isCancelled, self.draft.profiles.indices.contains(self.selectedIndex),
                      self.draft.profiles[self.selectedIndex].id == prof.id else { return }
                self.testStatusLabel.setTextWithTooltip("✗ \(error.localizedDescription)", color: GeekTheme.amber)
            }
        }
    }

    private func presentFetchedModelsMenu(_ models: [String], currentModel: String) {
        let menu = NSMenu()
        let limit = 60
        for id in models.prefix(limit) {
            let item = NSMenuItem(title: id, action: #selector(onPickedFetchedModel(_:)), keyEquivalent: "")
            item.representedObject = id
            item.state = (id == currentModel) ? .on : .off
            item.target = self
            menu.addItem(item)
        }
        if models.count > limit {
            menu.addItem(.separator())
            let more = NSMenuItem(title: L("共 %@ 个模型（已显示前 %@ 项，其余可直接输入）", models.count, limit), action: nil, keyEquivalent: "")
            more.isEnabled = false
            menu.addItem(more)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: modelInputBox.bounds.height + 3), in: modelInputBox)
    }

    @objc private func onPickedFetchedModel(_ sender: NSMenuItem) {
        guard let modelID = sender.representedObject as? String,
              draft.profiles.indices.contains(selectedIndex) else { return }
        modelField.stringValue = modelID
        commitCurrentFormEdits()
        persistDraft()
        testStatusLabel.setTextWithTooltip(L("✓ 已选择模型：%@", modelID), color: GeekTheme.emerald)
    }

    func popAddProviderMenu() {
        commitCurrentFormEdits()
        ProviderAddAndPresetPopover.shared.showAddService(anchoredTo: addBtn) { [weak self] created in
            guard let self else { return }
            self.draft.profiles.append(created)
            self.selectedIndex = self.draft.profiles.count - 1
            self.isAdvancedExpanded = (created.kind == .customWebhook)
            self.persistDraft()
            self.refreshTopBarPopups()
            self.tableView.reloadData()
            self.tableView.selectRowIndexes(IndexSet(integer: self.selectedIndex), byExtendingSelection: false)
            self.loadSelectedProfileIntoForm()
        }
    }

    func removeSelectedProvider() {
        guard draft.profiles.count > 1, draft.profiles.indices.contains(selectedIndex) else { NSSound.beep(); return }
        let removed = draft.profiles.remove(at: selectedIndex)
        TranslationSettingsConfig.deleteKeychainSecret(for: removed.id)
        selectedIndex = max(0, min(selectedIndex, draft.profiles.count - 1))
        if !draft.profiles.contains(where: { $0.id == draft.activeProfileID }) { draft.activeProfileID = draft.profiles.first?.id }
        isAdvancedExpanded = false
        persistDraft(); refreshTopBarPopups(); tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        loadSelectedProfileIntoForm()
    }

    func onSelectLLMProtocolIndex(_ idx: Int) {
        let kinds = TranslationProviderKind.llmProtocolCases
        guard kinds.indices.contains(idx), draft.profiles.indices.contains(selectedIndex) else { return }
        commitCurrentFormEdits()
        let nextKind = kinds[idx]
        var p = draft.profiles[selectedIndex]
        guard p.kind != nextKind else { return }
        // 切换「接口格式」绝不擅自改写用户的接口地址、密钥、模型或预设归属
        p.kind = nextKind
        draft.profiles[selectedIndex] = p
        persistDraft()
        loadSelectedProfileIntoForm()
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
    }

    func onSelectKindIndex(_ kIdx: Int) {
        guard draft.profiles.indices.contains(selectedIndex), TranslationProviderKind.allCases.indices.contains(kIdx) else { return }
        commitCurrentFormEdits()
        let newKind = TranslationProviderKind.allCases[kIdx]
        let tpl = TranslationProviderProfile.makePreset(newKind)
        var p = draft.profiles[selectedIndex]
        p.kind = newKind
        if p.endpoint.isEmpty { p.endpoint = tpl.endpoint }
        if p.model.isEmpty { p.model = tpl.model }
        if p.customBodyTemplate.isEmpty { p.customBodyTemplate = tpl.customBodyTemplate }
        if p.customResponsePath.isEmpty { p.customResponsePath = tpl.customResponsePath }
        draft.profiles[selectedIndex] = p
        loadSelectedProfileIntoForm()
    }

    func popLLMPresetMenu(from anchor: NSView) {
        commitCurrentFormEdits()
        let currentEndpoint = draft.profiles.indices.contains(selectedIndex) ? draft.profiles[selectedIndex].endpoint : ""
        ProviderAddAndPresetPopover.shared.showLLMPresetPicker(anchoredTo: anchor, currentEndpoint: currentEndpoint) { [weak self] preset in
            guard let self, self.draft.profiles.indices.contains(self.selectedIndex) else { return }
            self.commitCurrentFormEdits()
            var p = self.draft.profiles[self.selectedIndex]
            if preset == .customOpenAI {
                // 切换为「自定义 / 中转站」：完整保留当前「接口格式」，仅清理旧官网预设预填的地址与默认模型
                if let prevOfficial = LLMQuickPreset.match(endpoint: p.endpoint) {
                    p.endpoint = ""
                    if p.model == prevOfficial.defaultModel { p.model = "" }
                    if p.name == prevOfficial.shortName { p.name = preset.shortName }
                }
            } else {
                p.kind = preset.providerKind
                p.name = preset.shortName
                p.endpoint = preset.baseURL
                p.model = preset.defaultModel
            }
            self.draft.profiles[self.selectedIndex] = p
            self.persistDraft()
            self.loadSelectedProfileIntoForm()
            self.tableView.reloadData()
            self.tableView.selectRowIndexes(IndexSet(integer: self.selectedIndex), byExtendingSelection: false)
            if preset == .customOpenAI && p.endpoint.isEmpty { self.window?.makeFirstResponder(self.endpointField) }
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === endpointField,
              draft.profiles.indices.contains(selectedIndex),
              draft.profiles[selectedIndex].kind.isLLMProtocol else { return }
        let ep = endpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = LLMQuickPreset.match(endpoint: ep)
        llmPresetPill.customDisplayTitle = matched?.shortName ?? L("自定义 / 中转站")
        let hasLink = (matched?.consoleURL != nil)
        presetGetKeyBtn.isHidden = !hasLink
        let fullW = formScrollView.bounds.width - 114
        llmPresetPill.frame.size.width = hasLink ? (fullW - 94) : fullW
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if activeTab == .ocrAndLatex {
            commitOCRAndLatexEdits(); saveOCRAndLatexConfigs()
        } else if activeTab == .translation {
            commitCurrentFormEdits(); persistDraft()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        commitCurrentFormEdits(); commitOCRAndLatexEdits()
        persistDraft(); saveOCRAndLatexConfigs()
    }
}
