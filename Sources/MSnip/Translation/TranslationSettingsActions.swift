import AppKit
import Foundation
import MSnipCore

/// 翻译页状态绑定、零空隙动态排布（含可折叠高级选项）与连通性测速扩展
extension TranslationSettingsWindow {
    func refreshTopBarPopups() {
        if let idx = TranslationTargetLang.allCases.firstIndex(of: draft.targetLang) {
            targetLangPill.selectedIndex = idx
        }
        autoCopySwitch.isOn = draft.autoCopyTranslation
        removeBtn.isEnabled = draft.profiles.count > 1
    }

    func loadSelectedProfileIntoForm() {
        guard draft.profiles.indices.contains(selectedIndex) else { return }
        let p = draft.profiles[selectedIndex]
        detailHeaderTitle.stringValue = p.name
        nameField.stringValue = p.name

        let isMain = (p.id == draft.activeProfileID)
        setDefaultBtn.title = isMain ? "当前使用中" : "设为当前引擎"
        setDefaultBtn.symbolName = isMain ? "checkmark" : nil
        setDefaultBtn.style = isMain ? .emeraldSoft : .accent
        setDefaultBtn.isEnabled = !isMain

        if let kIdx = TranslationProviderKind.allCases.firstIndex(of: p.kind) {
            kindPill.selectedIndex = kIdx
        }
        llmPresetPill.selectedIndex = 0
        appIdField.stringValue = p.appIdOrSecretId
        endpointField.stringValue = p.endpoint
        apiKeySecureField.stringValue = p.apiKey
        apiKeyPlainField.stringValue = p.apiKey
        modelField.stringValue = p.model
        testStatusLabel.stringValue = ""
        updateFieldVisibility(for: p)
    }

    func toggleAPIKeyVisibility() {
        if isAPIKeyRevealed {
            apiKeySecureField.stringValue = apiKeyPlainField.stringValue
        } else {
            apiKeyPlainField.stringValue = apiKeySecureField.stringValue
        }
        isAPIKeyRevealed.toggle()
        eyeToggleBtn.symbolName = isAPIKeyRevealed ? "eye.slash" : "eye"
        apiKeySecureBox.isHidden = isAPIKeyRevealed
        apiKeyPlainBox.isHidden = !isAPIKeyRevealed
    }

    func updateFieldVisibility(for p: TranslationProviderProfile) {
        let kind = p.kind
        let isNative = (kind == .appleNative)
        presetRowView.isHidden = (kind != .openAICompatible)
        nativeCardBox.isHidden = !isNative

        let needsAppId = (kind == .tencent || kind == .baidu || kind == .youdao)
        appIdRow.isHidden = isNative || !needsAppId
        endpointRow.isHidden = isNative
        apiKeyRow.isHidden = isNative
        apiKeySecureBox.isHidden = isAPIKeyRevealed
        apiKeyPlainBox.isHidden = !isAPIKeyRevealed

        let needsModel = (kind == .openAICompatible || kind == .anthropicCompatible || kind == .geminiNative || kind == .tencent)
        modelRow.isHidden = isNative || !needsModel

        let hasAdvanced = (kind == .openAICompatible || kind == .anthropicCompatible || kind == .geminiNative || kind == .customWebhook)
        advancedToggleBtn.isHidden = isNative || !hasAdvanced
        advancedToggleBtn.symbolName = isAdvancedExpanded ? "chevron.down" : "chevron.right"
        advancedToggleBtn.title = (kind == .customWebhook) ? "高级选项（Body / JSON 路径）" : "高级选项（提示词 / 请求头）"
        extra1Row.isHidden = isNative || !hasAdvanced || !isAdvancedExpanded
        extra2Row.isHidden = isNative || !hasAdvanced || !isAdvancedExpanded

        switch kind {
        case .appleNative:
            nativeInfoLabel.stringValue = "macOS 系统内置离线神经网络翻译\n完全免费 · 无需 API 密钥 · 断网可用\n\n正在检测本机离线语言包状态…"
            Task { @MainActor [weak self] in
                let status = await AppleNativeTranslator.queryAvailabilitySummary()
                self?.nativeInfoLabel.stringValue = "macOS 系统内置离线神经网络翻译\n完全免费 · 无需 API 密钥 · 断网可用\n\n\(status)"
            }
        case .openAICompatible, .anthropicCompatible, .geminiNative:
            endpointLabel.stringValue = "接口地址"; apiKeyLabel.stringValue = "API 密钥"; modelLabel.stringValue = "模型名称"
            extraLabel1.stringValue = "提示词"; extraField1.setGeekPlaceholder("留空使用内置精准截图翻译提示词")
            extraField1.stringValue = p.systemPrompt
            extraLabel2.stringValue = "请求头"; extraField2.setGeekPlaceholder("可选 JSON，如 {\"X-Key\":\"val\"}")
            extraField2.stringValue = p.customHeadersJSON
        case .tencent:
            appIdLabel.stringValue = "SecretId"; apiKeyLabel.stringValue = "SecretKey"
            endpointLabel.stringValue = "请求域名"; modelLabel.stringValue = "地域"
        case .baidu:
            appIdLabel.stringValue = "AppID"; apiKeyLabel.stringValue = "密钥"; endpointLabel.stringValue = "接口地址"
        case .youdao:
            appIdLabel.stringValue = "应用 ID"; apiKeyLabel.stringValue = "应用密钥"; endpointLabel.stringValue = "接口地址"
        case .deepl:
            endpointLabel.stringValue = "接口地址"; apiKeyLabel.stringValue = "Auth Key"
        case .customWebhook:
            endpointLabel.stringValue = "请求 URL"; apiKeyLabel.stringValue = "Bearer"
            extraLabel1.stringValue = "Body"; extraField1.stringValue = p.customBodyTemplate
            extraLabel2.stringValue = "JSON 路径"; extraField2.stringValue = p.customResponsePath
        }

        // 动态零空隙堆叠所有可见行，并按需扩展滚动高度
        var cursorY: CGFloat = 88
        for row in [presetRowView!, appIdRow!, endpointRow!, apiKeyRow!, modelRow!] where !row.isHidden {
            row.frame.origin.y = cursorY
            cursorY += 38
        }
        if !advancedToggleBtn.isHidden {
            advancedToggleBtn.frame.origin.y = cursorY + 2
            cursorY += 32
        }
        for row in [extra1Row!, extra2Row!] where !row.isHidden {
            row.frame.origin.y = cursorY
            cursorY += 38
        }
        let minH = formScrollView.bounds.height
        let contentH = isNative ? minH : max(minH, cursorY + 12)
        formContentView.frame = NSRect(x: 0, y: 0, width: formScrollView.bounds.width, height: contentH)
    }

    func commitCurrentFormEdits() {
        guard draft.profiles.indices.contains(selectedIndex), nameField != nil else { return }
        var p = draft.profiles[selectedIndex]
        let trimmedName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty { p.name = trimmedName }
        p.isEnabled = true
        p.appIdOrSecretId = appIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        p.endpoint = endpointField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeKey = isAPIKeyRevealed ? apiKeyPlainField.stringValue : apiKeySecureField.stringValue
        p.apiKey = activeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        p.model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.kind == .customWebhook {
            p.customBodyTemplate = extraField1.stringValue
            p.customResponsePath = extraField2.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if p.kind == .openAICompatible || p.kind == .anthropicCompatible || p.kind == .geminiNative {
            p.systemPrompt = extraField1.stringValue
            p.customHeadersJSON = extraField2.stringValue
        }
        draft.profiles[selectedIndex] = p
        detailHeaderTitle.stringValue = p.name
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
        isAdvancedExpanded = false
        loadSelectedProfileIntoForm()
    }

    func onSelectLLMPresetIndex(_ rawIdx: Int) {
        let idx = rawIdx - 1
        guard LLMQuickPreset.allCases.indices.contains(idx), draft.profiles.indices.contains(selectedIndex) else { return }
        commitCurrentFormEdits()
        let preset = LLMQuickPreset.allCases[idx]
        draft.profiles[selectedIndex].name = preset.title
        draft.profiles[selectedIndex].endpoint = preset.baseURL
        draft.profiles[selectedIndex].model = preset.defaultModel
        loadSelectedProfileIntoForm()
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
    }

    func onSetAsPrimaryClicked() {
        commitCurrentFormEdits()
        guard draft.profiles.indices.contains(selectedIndex) else { return }
        draft.profiles[selectedIndex].isEnabled = true
        draft.activeProfileID = draft.profiles[selectedIndex].id
        persistDraft(); refreshTopBarPopups()
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        loadSelectedProfileIntoForm()
        testStatusLabel.textColor = GeekTheme.emerald
        testStatusLabel.stringValue = "✓ 已切换为当前翻译引擎"
    }

    func onTestClicked() {
        commitCurrentFormEdits(); persistDraft()
        guard draft.profiles.indices.contains(selectedIndex) else { return }
        let prof = draft.profiles[selectedIndex]
        testStatusLabel.textColor = GeekTheme.inkSecondary
        testStatusLabel.stringValue = "正在探测延迟…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            let res = await TranslationService.shared.testConnectivity(profile: prof, hostWindow: self.window)
            self.testStatusLabel.textColor = res.ok ? GeekTheme.emerald : GeekTheme.amber
            self.testStatusLabel.stringValue = res.message
            self.tableView.reloadData()
            self.tableView.selectRowIndexes(IndexSet(integer: self.selectedIndex), byExtendingSelection: false)
        }
    }
}
