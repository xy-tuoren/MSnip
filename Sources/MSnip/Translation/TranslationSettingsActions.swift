import AppKit
import Foundation
import MSnipCore

/// 翻译页两步极简状态绑定：默认仅露核心密钥框、一键获取 Key、一键粘贴、测通自动启用
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
        detailHeaderSubtitle.stringValue = makeSubtitle(for: p)
        nameField.stringValue = p.name

        let isMain = (p.id == draft.activeProfileID)
        setDefaultBtn.title = isMain ? "使用中" : "设为当前"
        setDefaultBtn.symbolName = isMain ? "checkmark" : nil
        setDefaultBtn.style = isMain ? .emeraldSoft : .subtle
        setDefaultBtn.isEnabled = !isMain

        testBtn.title = isMain ? "测试连接" : "测试并启用"

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

    private func makeSubtitle(for p: TranslationProviderProfile) -> String {
        switch p.kind {
        case .appleNative: return "macOS 内置神经网络 · 免费离线"
        case .openAICompatible, .anthropicCompatible, .geminiNative:
            let m = p.model.trimmingCharacters(in: .whitespacesAndNewlines)
            let tag = m.isEmpty ? "默认模型" : "模型 \(m)"
            return p.isLocalNoKeyEndpoint ? "\(tag) · 本机离线免密钥" : "\(tag) · 仅需填入 API 密钥"
        case .tencent: return "腾讯云机器翻译 · 填入 SecretId / SecretKey"
        case .baidu: return "百度翻译开放平台 · 填入 AppID / 密钥"
        case .youdao: return "有道智云 · 填入应用 ID / 应用密钥"
        case .deepl: return p.isLocalNoKeyEndpoint ? "自建 DeepLX · 无需 Auth Key" : "DeepL 官方 · 仅需填入 Auth Key"
        case .customWebhook: return "自定义 HTTP JSON 接口"
        }
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

    func onPasteAPIKeyClicked() {
        guard let raw = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            testStatusLabel.textColor = GeekTheme.amber
            testStatusLabel.stringValue = "剪贴板中暂无文本"
            return
        }
        apiKeySecureField.stringValue = raw
        apiKeyPlainField.stringValue = raw
        commitCurrentFormEdits()
        persistDraft()
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        testStatusLabel.textColor = GeekTheme.emerald
        testStatusLabel.stringValue = "✓ 已粘贴密钥 · 点左侧「\(testBtn.title)」验证"
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
        let isOllama = (kind == .openAICompatible && p.isLocalNoKeyEndpoint)
        let isCustom = (kind == .customWebhook)

        nativeCardBox.isHidden = !isNative
        guideCard.isHidden = isNative

        if !isNative {
            guideLabel.stringValue = p.quickGuideText
            let hasLink = (p.consoleURL != nil)
            getKeyBtn.isHidden = !hasLink
            guideLabel.frame.size.width = hasLink ? (guideCard.bounds.width - 112) : (guideCard.bounds.width - 24)
        }

        // 默认极简视图仅露核心 1~2 项，其余收进可展开的「更多设置」
        let primaryNeedsAppId = (kind == .tencent || kind == .baidu || kind == .youdao)
        let primaryNeedsKey = !isNative && !isOllama && !(kind == .deepl && p.isLocalNoKeyEndpoint)
        let primaryNeedsModel = isOllama
        let primaryNeedsEndpoint = isCustom || (kind == .deepl && p.isLocalNoKeyEndpoint)

        let supportsModel = (kind == .openAICompatible || kind == .anthropicCompatible || kind == .geminiNative || kind == .tencent)
        let supportsExtra = (kind == .openAICompatible || kind == .anthropicCompatible || kind == .geminiNative || kind == .customWebhook)

        appIdRow.isHidden = !primaryNeedsAppId
        apiKeyRow.isHidden = !primaryNeedsKey
        apiKeySecureBox.isHidden = isAPIKeyRevealed
        apiKeyPlainBox.isHidden = !isAPIKeyRevealed

        advancedToggleBtn.isHidden = isNative
        advancedToggleBtn.symbolName = isAdvancedExpanded ? "chevron.down" : "chevron.right"
        advancedToggleBtn.title = isAdvancedExpanded ? "收起更多设置" : "更多设置（自定义模型 / 地址 / 名称 / 协议）"

        nameRow.isHidden = isNative || !isAdvancedExpanded
        kindRow.isHidden = isNative || !isAdvancedExpanded
        presetRowView.isHidden = isNative || !isAdvancedExpanded || (kind != .openAICompatible)
        endpointRow.isHidden = isNative || (!primaryNeedsEndpoint && !isAdvancedExpanded)
        modelRow.isHidden = isNative || !supportsModel || (!primaryNeedsModel && !isAdvancedExpanded)
        extra1Row.isHidden = isNative || !supportsExtra || !isAdvancedExpanded
        extra2Row.isHidden = isNative || !supportsExtra || !isAdvancedExpanded

        configureFieldLabels(for: p)

        // 按「指引条 → 核心必填项 → 展开按钮 → 更多设置」零空隙竖向排布
        var cursorY: CGFloat = 14
        if !guideCard.isHidden {
            guideCard.frame.origin.y = cursorY
            cursorY += 54
        }
        var primaryRows: [GeekFlippedView] = []
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

        var advancedRows: [GeekFlippedView] = [nameRow, kindRow, presetRowView]
        if !primaryNeedsEndpoint { advancedRows.append(endpointRow) }
        if !primaryNeedsModel { advancedRows.append(modelRow) }
        advancedRows.append(contentsOf: [extra1Row, extra2Row])
        for row in advancedRows where !row.isHidden {
            row.frame.origin.y = cursorY
            cursorY += row.frame.height + 2
        }

        let minH = formScrollView.bounds.height
        let contentH = isNative ? minH : max(minH, cursorY + 12)
        formContentView.frame = NSRect(x: 0, y: 0, width: formScrollView.bounds.width, height: contentH)
    }

    private func configureFieldLabels(for p: TranslationProviderProfile) {
        switch p.kind {
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
        detailHeaderSubtitle.stringValue = makeSubtitle(for: p)
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
        draft.profiles[selectedIndex].name = preset.shortName
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
        testStatusLabel.stringValue = "✓ 已设为当前翻译引擎"
    }

    func onTestClicked() {
        commitCurrentFormEdits(); persistDraft()
        guard draft.profiles.indices.contains(selectedIndex) else { return }
        let prof = draft.profiles[selectedIndex]
        testStatusLabel.textColor = GeekTheme.inkSecondary
        testStatusLabel.stringValue = "正在探测连通性…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            let res = await TranslationService.shared.testConnectivity(profile: prof, hostWindow: self.window)
            if res.ok && self.draft.activeProfileID != prof.id {
                self.draft.activeProfileID = prof.id
                self.persistDraft()
                self.loadSelectedProfileIntoForm()
                self.testStatusLabel.textColor = GeekTheme.emerald
                self.testStatusLabel.stringValue = "\(res.message) · 已启用"
            } else {
                self.testStatusLabel.textColor = res.ok ? GeekTheme.emerald : GeekTheme.amber
                self.testStatusLabel.stringValue = res.message
            }
            self.tableView.reloadData()
            self.tableView.selectRowIndexes(IndexSet(integer: self.selectedIndex), byExtendingSelection: false)
        }
    }
}
