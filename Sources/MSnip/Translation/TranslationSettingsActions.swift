import AppKit
import Foundation
import MSnipCore

/// 翻译 API 设置页状态绑定、零空隙动态行排布与连通性测速扩展
extension TranslationSettingsWindow {
    func refreshTopBarPopups() {
        if let idx = TranslationTargetLang.allCases.firstIndex(of: draft.targetLang) {
            targetLangPill.selectedIndex = idx
        }
        autoCopySwitch.isOn = draft.autoCopyTranslation
        let enabled = draft.profiles.filter(\.isEnabled)
        primaryEnginePill.items = enabled.map(\.name)
        primaryEnginePill.selectedIndex = enabled.firstIndex(where: { $0.id == draft.activeProfileID }) ?? 0

        fallbackEnginePill.items = ["不启用回退"] + enabled.map(\.name)
        if let fbID = draft.fallbackProfileID, let fIdx = enabled.firstIndex(where: { $0.id == fbID }) {
            fallbackEnginePill.selectedIndex = fIdx + 1
        } else {
            fallbackEnginePill.selectedIndex = 0
        }
        removeBtn.isEnabled = draft.profiles.count > 1
    }

    func onSelectPrimaryIndex(_ idx: Int) {
        commitCurrentFormEdits()
        let enabled = draft.profiles.filter(\.isEnabled)
        guard enabled.indices.contains(idx) else { return }
        draft.activeProfileID = enabled[idx].id
        persistDraft()
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        loadSelectedProfileIntoForm()
    }

    func onSelectFallbackIndex(_ idx: Int) {
        commitCurrentFormEdits()
        let enabled = draft.profiles.filter(\.isEnabled)
        draft.fallbackProfileID = (idx > 0 && enabled.indices.contains(idx - 1)) ? enabled[idx - 1].id : nil
        persistDraft()
    }

    func loadSelectedProfileIntoForm() {
        guard draft.profiles.indices.contains(selectedIndex) else { return }
        let p = draft.profiles[selectedIndex]
        nameField.stringValue = p.name
        enabledSwitch.isOn = p.isEnabled
        let isMain = (p.id == draft.activeProfileID)
        setDefaultBtn.title = isMain ? "当前主力" : "设为主力"
        setDefaultBtn.style = isMain ? .accent : .subtle
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

        let showExtras = (kind == .openAICompatible || kind == .anthropicCompatible || kind == .geminiNative || kind == .customWebhook)
        extra1Row.isHidden = isNative || !showExtras
        extra2Row.isHidden = isNative || !showExtras

        switch kind {
        case .appleNative:
            nativeInfoLabel.stringValue = "macOS 原生离线神经网络翻译\n免费 · 无需 API Key · 断网可用 · 隐私零上传\n\n状态：正在检测系统语言包…"
            Task { @MainActor [weak self] in
                let status = await AppleNativeTranslator.queryAvailabilitySummary()
                self?.nativeInfoLabel.stringValue = """
                macOS 原生离线神经网络翻译
                免费 · 无需 API Key · 断网可用 · 隐私零上传

                当前状态：\(status)
                点击下方「测试连通」可立即验证或拉起系统语言包下载。
                """
            }
        case .openAICompatible, .anthropicCompatible, .geminiNative:
            endpointLabel.stringValue = "Base URL"; apiKeyLabel.stringValue = "API Key"; modelLabel.stringValue = "Model"
            extraLabel1.stringValue = "提示词"; extraField1.setGeekPlaceholder("留空使用内置精准截图翻译提示词")
            extraField1.stringValue = p.systemPrompt
            extraLabel2.stringValue = "请求头"; extraField2.setGeekPlaceholder("可选 JSON，如 {\"X-Key\":\"val\"}")
            extraField2.stringValue = p.customHeadersJSON
        case .tencent:
            appIdLabel.stringValue = "SecretId"; apiKeyLabel.stringValue = "SecretKey"
            endpointLabel.stringValue = "域名"; modelLabel.stringValue = "Region"
        case .baidu:
            appIdLabel.stringValue = "AppID"; apiKeyLabel.stringValue = "密钥"; endpointLabel.stringValue = "接口 URL"
        case .youdao:
            appIdLabel.stringValue = "应用 ID"; apiKeyLabel.stringValue = "应用密钥"; endpointLabel.stringValue = "接口 URL"
        case .deepl:
            endpointLabel.stringValue = "URL"; apiKeyLabel.stringValue = "Auth Key"
        case .customWebhook:
            endpointLabel.stringValue = "URL"; apiKeyLabel.stringValue = "Bearer"
            extraLabel1.stringValue = "Body"; extraField1.stringValue = p.customBodyTemplate
            extraLabel2.stringValue = "JSON 路径"; extraField2.stringValue = p.customResponsePath
        }

        // 零空隙紧凑排布所有可见表单行
        var cursorY: CGFloat = 78
        for row in [presetRowView!, appIdRow!, endpointRow!, apiKeyRow!, modelRow!, extra1Row!, extra2Row!] where !row.isHidden {
            row.frame.origin.y = cursorY
            cursorY += 33
        }
    }

    func commitCurrentFormEdits() {
        guard draft.profiles.indices.contains(selectedIndex), nameField != nil else { return }
        var p = draft.profiles[selectedIndex]
        let trimmedName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty { p.name = trimmedName }
        p.isEnabled = enabledSwitch.isOn
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

    func onFormStructuralChanged() {
        commitCurrentFormEdits(); persistDraft(); refreshTopBarPopups()
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
        testStatusLabel.stringValue = "✓ 已设为主力引擎"
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

    func onSaveAndClose() {
        commitCurrentFormEdits(); persistDraft()
        window?.close()
    }
}
