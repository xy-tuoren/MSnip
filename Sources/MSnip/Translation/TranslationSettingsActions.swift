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
        setDefaultBtn.title = isMain ? "使用中" : "设为当前"
        setDefaultBtn.symbolName = isMain ? "checkmark" : nil
        setDefaultBtn.style = isMain ? .emeraldSoft : .subtle
        setDefaultBtn.isEnabled = !isMain

        testBtn.title = isMain ? "测试连接" : "测试并启用"

        if let kIdx = TranslationProviderKind.allCases.firstIndex(of: p.kind) {
            kindPill.selectedIndex = kIdx
        }
        if let pIdx = TranslationProviderKind.llmProtocolCases.firstIndex(of: p.kind) {
            llmProtocolPill.selectedIndex = pIdx
        }
        if let matched = LLMQuickPreset.match(endpoint: p.endpoint) {
            llmPresetPill.customDisplayTitle = matched.shortName
        } else {
            llmPresetPill.customDisplayTitle = "自定义 / 中转站"
        }
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
        case .appleNative: return "macOS 内置神经网络 · 免费离线"
        case .openAICompatible, .openAIResponses, .anthropicCompatible, .geminiNative:
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
            testStatusLabel.setTextWithTooltip("剪贴板中暂无文本", color: GeekTheme.amber)
            return
        }
        apiKeySecureField.stringValue = raw
        apiKeyPlainField.stringValue = raw
        commitCurrentFormEdits()
        persistDraft()
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        testStatusLabel.setTextWithTooltip("✓ 已粘贴密钥 · 点左侧「\(testBtn.title)」验证", color: GeekTheme.emerald)
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

        let fullW = formScrollView.bounds.width - 114
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

        let keyPlaceholder = (isLLMKind && p.isLocalNoKeyEndpoint) ? "可选（本机/局域网免鉴权可留空）" : "粘贴 API Key 即可使用"
        apiKeySecureField.setGeekPlaceholder(keyPlaceholder)
        apiKeyPlainField.setGeekPlaceholder(keyPlaceholder)

        advancedToggleBtn.isHidden = isNative
        advancedToggleBtn.symbolName = isAdvancedExpanded ? "chevron.down" : "chevron.right"
        advancedToggleBtn.title = isAdvancedExpanded
            ? "收起高级设置"
            : (isLLMKind ? "高级设置（显示名称 / 提示词 / 请求头）" : "更多设置（显示名称 / 类型 / 地址 / 参数）")

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
        case .openAICompatible, .openAIResponses, .anthropicCompatible, .geminiNative:
            endpointLabel.stringValue = "接口地址"; apiKeyLabel.stringValue = "API 密钥"; modelLabel.stringValue = "模型名称"
            let epSuffix = p.kind == .openAIResponses ? "/v1/responses" : (p.kind == .anthropicCompatible ? "/v1/messages" : (p.kind == .geminiNative ? "/v1beta" : "/v1/chat/completions"))
            endpointField.setGeekPlaceholder("https://your-relay.com（自动补全 \(epSuffix)）")
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
        } else if p.kind.isLLMProtocol {
            p.systemPrompt = extraField1.stringValue
            p.customHeadersJSON = extraField2.stringValue
        }
        draft.profiles[selectedIndex] = p
        detailHeaderTitle.setTextWithTooltip(p.name)
        detailHeaderSubtitle.setTextWithTooltip(makeSubtitle(for: p))
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
        testStatusLabel.setTextWithTooltip("✓ 已设为当前翻译引擎", color: GeekTheme.emerald)
    }

    func onTestClicked() {
        commitCurrentFormEdits(); persistDraft()
        guard draft.profiles.indices.contains(selectedIndex) else { return }
        let prof = draft.profiles[selectedIndex]
        testStatusLabel.setTextWithTooltip("正在探测连通性…", color: GeekTheme.inkSecondary)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let res = await TranslationService.shared.testConnectivity(profile: prof, hostWindow: self.window)
            if res.ok && self.draft.activeProfileID != prof.id {
                self.draft.activeProfileID = prof.id
                self.persistDraft(); self.refreshTopBarPopups()
                self.loadSelectedProfileIntoForm()
                self.testStatusLabel.setTextWithTooltip("\(res.message) · 已启用", color: GeekTheme.emerald)
            } else {
                self.testStatusLabel.setTextWithTooltip(res.message, color: res.ok ? GeekTheme.emerald : GeekTheme.amber)
            }
            self.tableView.reloadData()
            self.tableView.selectRowIndexes(IndexSet(integer: self.selectedIndex), byExtendingSelection: false)
        }
    }
}
