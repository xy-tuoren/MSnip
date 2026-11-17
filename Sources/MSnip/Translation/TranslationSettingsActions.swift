import AppKit
import Foundation
import MSnipCore

/// 翻译与大模型设置页状态绑定、密钥明文显隐切换、零 Emoji 菜单与连通性测速扩展
extension TranslationSettingsWindow {
    func refreshTopBarPopups() {
        if let idx = TranslationTargetLang.allCases.firstIndex(of: draft.targetLang) {
            targetLangPill.selectedIndex = idx
        }
        let enabled = draft.profiles.filter(\.isEnabled)
        primaryEnginePill.items = enabled.map(\.name)
        if let pIdx = enabled.firstIndex(where: { $0.id == draft.activeProfileID }) {
            primaryEnginePill.selectedIndex = pIdx
        } else {
            primaryEnginePill.selectedIndex = 0
        }

        fallbackEnginePill.items = ["不启用回退"] + enabled.map(\.name)
        if let fbID = draft.fallbackProfileID, let fIdx = enabled.firstIndex(where: { $0.id == fbID }) {
            fallbackEnginePill.selectedIndex = fIdx + 1
        } else {
            fallbackEnginePill.selectedIndex = 0
        }
    }

    func onSelectPrimaryIndex(_ idx: Int) {
        commitCurrentFormEdits()
        let enabled = draft.profiles.filter(\.isEnabled)
        guard enabled.indices.contains(idx) else { return }
        draft.activeProfileID = enabled[idx].id
        persistDraft()
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
    }

    func onSelectFallbackIndex(_ idx: Int) {
        commitCurrentFormEdits()
        let enabled = draft.profiles.filter(\.isEnabled)
        if idx <= 0 || !enabled.indices.contains(idx - 1) {
            draft.fallbackProfileID = nil
        } else {
            draft.fallbackProfileID = enabled[idx - 1].id
        }
        persistDraft()
    }

    func loadSelectedProfileIntoForm() {
        guard draft.profiles.indices.contains(selectedIndex) else { return }
        let p = draft.profiles[selectedIndex]
        nameField.stringValue = p.name
        enabledCheck.state = p.isEnabled ? .on : .off
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
        if draft.profiles.indices.contains(selectedIndex) {
            updateFieldVisibility(for: draft.profiles[selectedIndex])
        }
    }

    func updateFieldVisibility(for p: TranslationProviderProfile) {
        let kind = p.kind
        let isNative = (kind == .appleNative)
        presetRowView.isHidden = (kind != .openAICompatible)
        nativeCardBox.isHidden = !isNative

        let needsAppId = (kind == .tencent || kind == .baidu || kind == .youdao)
        appIdLabel.isHidden = isNative || !needsAppId
        appIdField.isHidden = isNative || !needsAppId

        endpointLabel.isHidden = isNative
        endpointField.isHidden = isNative
        apiKeyLabel.isHidden = isNative
        apiKeySecureField.isHidden = isNative || isAPIKeyRevealed
        apiKeyPlainField.isHidden = isNative || !isAPIKeyRevealed
        eyeToggleBtn.isHidden = isNative

        let needsModel = (kind == .openAICompatible || kind == .anthropicCompatible || kind == .geminiNative || kind == .tencent)
        modelLabel.isHidden = isNative || !needsModel
        modelField.isHidden = isNative || !needsModel

        let showExtras = (kind == .openAICompatible || kind == .anthropicCompatible || kind == .geminiNative || kind == .customWebhook)
        extraLabel1.isHidden = isNative || !showExtras
        extraField1.isHidden = isNative || !showExtras
        extraLabel2.isHidden = isNative || !showExtras
        extraField2.isHidden = isNative || !showExtras

        switch kind {
        case .appleNative:
            nativeInfoLabel.stringValue = """
            macOS 原生离线神经网络翻译（免费 · 无需 API Key · 断网可用）

            • 直接调用 macOS 15+ 系统内置离线翻译模型，无需注册第三方账号，隐私零上传。
            • 正在读取本机离线语言包状态…
            """
            Task { @MainActor [weak self] in
                let status = await AppleNativeTranslator.queryAvailabilitySummary()
                self?.nativeInfoLabel.stringValue = """
                macOS 原生离线神经网络翻译（免费 · 无需 API Key · 断网可用）

                • 当前状态：\(status)
                • 点击下方「测试连接与延迟」即可立即验证或唤起系统官方免费语言包下载面板。
                """
            }
        case .openAICompatible, .anthropicCompatible, .geminiNative:
            endpointLabel.stringValue = "Base URL"
            apiKeyLabel.stringValue = "API Key"
            modelLabel.stringValue = "模型 Model"
            extraLabel1.stringValue = "系统提示词"
            extraField1.placeholderString = "留空使用内置精准截图翻译提示词"
            extraField1.stringValue = p.systemPrompt
            extraLabel2.stringValue = "附加请求头"
            extraField2.placeholderString = "可选 JSON，如 {\"X-Custom\": \"value\"}"
            extraField2.stringValue = p.customHeadersJSON
        case .tencent:
            appIdLabel.stringValue = "SecretId"
            apiKeyLabel.stringValue = "SecretKey"
            endpointLabel.stringValue = "请求域名"
            modelLabel.stringValue = "地域 Region"
        case .baidu:
            appIdLabel.stringValue = "百度 AppID"
            apiKeyLabel.stringValue = "百度密钥"
            endpointLabel.stringValue = "接口地址"
        case .youdao:
            appIdLabel.stringValue = "应用 ID"
            apiKeyLabel.stringValue = "应用密钥"
            endpointLabel.stringValue = "接口地址"
        case .deepl:
            endpointLabel.stringValue = "DeepL 地址"
            apiKeyLabel.stringValue = "Auth Key"
        case .customWebhook:
            endpointLabel.stringValue = "请求 URL"
            apiKeyLabel.stringValue = "Bearer Key"
            extraLabel1.stringValue = "Body 模版"
            extraField1.stringValue = p.customBodyTemplate
            extraLabel2.stringValue = "结果 JSON 路径"
            extraField2.stringValue = p.customResponsePath
        }
    }

    func commitCurrentFormEdits() {
        guard draft.profiles.indices.contains(selectedIndex), nameField != nil else { return }
        var p = draft.profiles[selectedIndex]
        let trimmedName = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty { p.name = trimmedName }
        p.isEnabled = (enabledCheck.state == .on)
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

    @objc func onFormStructuralChanged() {
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
        testStatusLabel.textColor = MSnipUITheme.success
        testStatusLabel.stringValue = "✓ 已设为当前默认主翻译引擎"
    }

    func onTestClicked() {
        commitCurrentFormEdits(); persistDraft()
        guard draft.profiles.indices.contains(selectedIndex) else { return }
        let prof = draft.profiles[selectedIndex]
        testStatusLabel.textColor = MSnipUITheme.inkSecondary
        testStatusLabel.stringValue = "正在发起测试请求…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            let res = await TranslationService.shared.testConnectivity(profile: prof, hostWindow: self.window)
            self.testStatusLabel.textColor = res.ok ? MSnipUITheme.success : MSnipUITheme.warning
            self.testStatusLabel.stringValue = res.message
            self.tableView.reloadData()
            self.tableView.selectRowIndexes(IndexSet(integer: self.selectedIndex), byExtendingSelection: false)
        }
    }

    func onSaveAndClose() {
        commitCurrentFormEdits(); persistDraft()
        window?.close()
        ToastHUD.show(message: "设置已保存并生效")
    }
}
