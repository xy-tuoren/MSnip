import AppKit
import Foundation
import MSnipCore

/// 统一「模型与服务」管理页：集中管理大模型 API（OpenAI Chat/Responses、Anthropic、Gemini、Ollama）与各云翻译服务凭据，
/// 同时供给截图翻译、AI 视觉识字 (OCR) 与 LaTeX 公式识别复用；翻译偏好已拆出至「识字与翻译」标签页。
extension TranslationSettingsWindow {
    func buildTranslationPage(in page: GeekFlippedView) {
        let cardW = page.bounds.width - 56 // 724

        // 1) 左侧服务列表（248px 宽敞栏宽，完整显示服务全称 + 底部添加/删除操作栏）
        let listW: CGFloat = 248
        let listCard = GeekCardView(frame: NSRect(x: 28, y: 16, width: listW, height: 426))
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
        addBtn.frame = NSRect(x: 28, y: 452, width: 170, height: 32)
        addBtn.onClick = { [weak self] in self?.popAddProviderMenu() }
        page.addSubview(addBtn)

        removeBtn = GeekButton(title: "删除", style: .subtle)
        removeBtn.frame = NSRect(x: 206, y: 452, width: 70, height: 32)
        removeBtn.onClick = { [weak self] in self?.removeSelectedProvider() }
        page.addSubview(removeBtn)

        // 2) 右侧详情配置卡片（462 × 468，宽敞零拥挤）
        let detailW = cardW - listW - 14 // 462
        let formCard = GeekCardView(frame: NSRect(x: 28 + listW + 14, y: 16, width: detailW, height: 468))
        page.addSubview(formCard)
        self.detailContainer = formCard
        buildDetailCard(in: formCard)
    }

    private func buildDetailCard(in cv: GeekCardView) {
        let fw = cv.bounds.width // 476
        let ctrlX: CGFloat = 96
        let ctrlW = fw - ctrlX - 18 // 362

        // 卡片顶栏（60px）：服务名称 + 简明副标题 + 设为当前
        detailHeaderTitle = NSTextField(labelWithString: "")
        detailHeaderTitle.font = .systemFont(ofSize: 15.0, weight: .semibold); detailHeaderTitle.textColor = GeekTheme.inkPrimary
        detailHeaderTitle.lineBreakMode = .byTruncatingTail; cv.addSubview(detailHeaderTitle)

        detailHeaderSubtitle = NSTextField(labelWithString: "")
        detailHeaderSubtitle.font = .systemFont(ofSize: 11.5, weight: .regular); detailHeaderSubtitle.textColor = GeekTheme.inkMuted
        detailHeaderSubtitle.lineBreakMode = .byTruncatingTail; cv.addSubview(detailHeaderSubtitle)
        GeekTheme.placeTwoLineStack(detailHeaderTitle, detailHeaderSubtitle, x: 18, width: fw - 138, centerY: 30.0, gap: 2.0)

        setDefaultBtn = GeekButton(title: "设为当前", style: .accent)
        setDefaultBtn.frame = NSRect(x: fw - 110, y: 15, width: 92, height: 30)
        setDefaultBtn.onClick = { [weak self] in self?.onSetAsPrimaryClicked() }
        cv.addSubview(setDefaultBtn); cv.addHairline(atY: 60, insetX: 0)

        let bodyRect = NSRect(x: 0, y: 61, width: fw, height: 349)
        let fScroll = NSScrollView(frame: bodyRect)
        fScroll.drawsBackground = false; fScroll.borderType = .noBorder
        fScroll.hasVerticalScroller = true; fScroll.autohidesScrollers = true
        let content = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: fw, height: bodyRect.height))
        fScroll.documentView = content; cv.addSubview(fScroll)
        self.formScrollView = fScroll; self.formContentView = content

        // 传统云翻译指引条 + 官方「获取 Key ↗」直达按钮
        guideCard = makeSubCard(frame: NSRect(x: 18, y: 14, width: fw - 36, height: 42))
        guideLabel = NSTextField(labelWithString: "")
        guideLabel.font = .systemFont(ofSize: 12.0, weight: .medium)
        guideLabel.textColor = GeekTheme.inkSecondary
        guideLabel.lineBreakMode = .byTruncatingTail
        GeekTheme.placeCentered(guideLabel, x: 14, width: fw - 152, centerY: 21.0)
        guideCard.addSubview(guideLabel)

        getKeyBtn = GeekButton(title: "获取 Key", symbol: "arrow.up.right", style: .accent)
        getKeyBtn.frame = NSRect(x: fw - 36 - 96, y: 7, width: 88, height: 28)
        getKeyBtn.onClick = { [weak self] in self?.onOpenConsoleURLClicked() }
        guideCard.addSubview(getKeyBtn)
        content.addSubview(guideCard)

        // Apple 离线开箱即用状态卡
        nativeCardBox = makeSubCard(frame: NSRect(x: 18, y: 16, width: fw - 36, height: 176))
        nativeInfoLabel = NSTextField(wrappingLabelWithString: "")
        nativeInfoLabel.font = .systemFont(ofSize: 13.0)
        nativeInfoLabel.textColor = GeekTheme.inkSecondary
        nativeInfoLabel.frame = NSRect(x: 16, y: 16, width: fw - 68, height: 104)
        nativeCardBox.addSubview(nativeInfoLabel)

        let sysLangBtn = GeekButton(title: "打开系统翻译语言设置…", symbol: "globe", style: .subtle)
        sysLangBtn.frame = NSRect(x: 16, y: 130, width: 208, height: 30)
        sysLangBtn.onClick = {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") { NSWorkspace.shared.open(url) }
        }
        nativeCardBox.addSubview(sysLangBtn)
        content.addSubview(nativeCardBox)

        // 统一 38px 行高与 30px 控件高度，所有控件严格对齐 x = 96 .. fw - 18
        (appIdRow, appIdLabel, appIdField) = makeDynamicRow(label: "AppID", placeholder: "输入平台应用 ID", mono: true, width: fw)

        apiKeyRow = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: fw, height: 38))
        apiKeyLabel = addRowCaption("API 密钥", rowHeight: 38, in: apiKeyRow)
        let keyW = ctrlW - 94 // 50(粘贴) + 32(眼) + 12(双6pt间距)
        apiKeySecureField = NSSecureTextField()
        apiKeySecureBox = GeekInputBox(frame: NSRect(x: ctrlX, y: 4, width: keyW, height: 30), field: apiKeySecureField, placeholder: "粘贴 API Key 即可使用", mono: true)
        apiKeyRow.addSubview(apiKeySecureBox)
        apiKeyPlainField = NSTextField()
        apiKeyPlainBox = GeekInputBox(frame: NSRect(x: ctrlX, y: 4, width: keyW, height: 30), field: apiKeyPlainField, placeholder: "粘贴 API Key 即可使用", mono: true)
        apiKeyPlainBox.isHidden = true
        apiKeyRow.addSubview(apiKeyPlainBox)

        pasteKeyBtn = GeekButton(title: "粘贴", style: .subtle)
        pasteKeyBtn.toolTip = "一键从剪贴板粘贴 API 密钥"
        pasteKeyBtn.frame = NSRect(x: ctrlX + keyW + 6, y: 4, width: 50, height: 30)
        pasteKeyBtn.onClick = { [weak self] in self?.onPasteAPIKeyClicked() }
        apiKeyRow.addSubview(pasteKeyBtn)

        eyeToggleBtn = GeekButton(title: "", symbol: "eye", style: .subtle)
        eyeToggleBtn.toolTip = "显示 / 隐藏明文密钥"
        eyeToggleBtn.frame = NSRect(x: ctrlX + keyW + 62, y: 4, width: 32, height: 30)
        eyeToggleBtn.onClick = { [weak self] in self?.toggleAPIKeyVisibility() }
        apiKeyRow.addSubview(eyeToggleBtn)

        llmProtocolRow = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: fw, height: 38))
        addRowCaption("接口格式", rowHeight: 38, in: llmProtocolRow)
        llmProtocolPill = GeekDropdownPill(symbol: "network", items: TranslationProviderKind.llmProtocolCases.map(\.llmFormatTitle))
        llmProtocolPill.frame = NSRect(x: ctrlX, y: 4, width: ctrlW, height: 30)
        llmProtocolPill.onSelect = { [weak self] idx in self?.onSelectLLMProtocolIndex(idx) }
        llmProtocolRow.addSubview(llmProtocolPill)

        presetRowView = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: fw, height: 38))
        addRowCaption("服务预设", rowHeight: 38, in: presetRowView)
        llmPresetPill = GeekDropdownPill(symbol: "sparkles")
        llmPresetPill.customDisplayTitle = "自定义 / 中转站"
        llmPresetPill.frame = NSRect(x: ctrlX, y: 4, width: ctrlW, height: 30)
        llmPresetPill.onCustomClick = { [weak self] anchor in self?.popLLMPresetMenu(from: anchor) }
        presetRowView.addSubview(llmPresetPill)
        presetGetKeyBtn = GeekButton(title: "获取 Key", symbol: "arrow.up.right", style: .accent)
        presetGetKeyBtn.frame = NSRect(x: fw - 18 - 88, y: 4, width: 88, height: 30)
        presetGetKeyBtn.onClick = { [weak self] in self?.onOpenConsoleURLClicked() }
        presetRowView.addSubview(presetGetKeyBtn)

        (nameRow, _, nameField) = makeDynamicRow(label: "显示名称", placeholder: "自定义显示名称", mono: false, width: fw)
        kindRow = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: fw, height: 38))
        addRowCaption("服务类型", rowHeight: 38, in: kindRow)
        kindPill = GeekDropdownPill(symbol: "network", items: TranslationProviderKind.allCases.map(\.displayName))
        kindPill.frame = NSRect(x: ctrlX, y: 4, width: ctrlW, height: 30)
        kindPill.onSelect = { [weak self] idx in self?.onSelectKindIndex(idx) }
        kindRow.addSubview(kindPill)

        (endpointRow, endpointLabel, endpointField) = makeDynamicRow(label: "接口地址", placeholder: "https://your-api.com（自动补全协议路径）", mono: true, width: fw)
        endpointField.delegate = self

        modelRow = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: fw, height: 38))
        modelLabel = addRowCaption("模型名称", rowHeight: 38, in: modelRow)
        modelField = NSTextField()
        let modelW = ctrlW - 74 // 68(拉取) + 6(间距)
        modelInputBox = GeekInputBox(frame: NSRect(x: ctrlX, y: 4, width: modelW, height: 30), field: modelField, placeholder: "如 deepseek-chat，或点右侧拉取", mono: true)
        modelRow.addSubview(modelInputBox)
        fetchModelsBtn = GeekButton(title: "拉取", symbol: "arrow.clockwise", style: .subtle)
        fetchModelsBtn.toolTip = "从当前接口地址自动拉取 /v1/models 可用模型列表"
        fetchModelsBtn.frame = NSRect(x: ctrlX + modelW + 6, y: 4, width: 68, height: 30)
        fetchModelsBtn.onClick = { [weak self] in self?.onFetchModelsClicked() }
        modelRow.addSubview(fetchModelsBtn)

        (extra1Row, extraLabel1, extraField1) = makeDynamicRow(label: "提示词", placeholder: "", mono: false, width: fw)
        (extra2Row, extraLabel2, extraField2) = makeDynamicRow(label: "请求头", placeholder: "", mono: true, width: fw)

        advancedToggleBtn = GeekButton(title: "高级设置（显示名称 / 提示词 / 请求头）", symbol: "chevron.right", style: .ghost)
        advancedToggleBtn.contentAlignment = .left
        advancedToggleBtn.frame = NSRect(x: 88, y: 0, width: 320, height: 28)
        advancedToggleBtn.onClick = { [weak self] in
            guard let self, self.draft.profiles.indices.contains(self.selectedIndex) else { return }
            self.commitCurrentFormEdits(); self.isAdvancedExpanded.toggle()
            self.updateFieldVisibility(for: self.draft.profiles[self.selectedIndex])
        }
        content.addSubview(advancedToggleBtn)
        for r in [llmProtocolRow!, presetRowView!, appIdRow!, apiKeyRow!, endpointRow!, modelRow!, nameRow!, kindRow!, extra1Row!, extra2Row!] { content.addSubview(r) }

        cv.addHairline(atY: 410, insetX: 0)
        testBtn = GeekButton(title: "测试并启用", symbol: "bolt.horizontal", style: .accent)
        testBtn.frame = NSRect(x: 18, y: 424, width: 124, height: 30)
        testBtn.onClick = { [weak self] in self?.onTestClicked() }
        cv.addSubview(testBtn)

        testStatusLabel = NSTextField(labelWithString: "")
        testStatusLabel.font = .monospacedSystemFont(ofSize: 12.0, weight: .medium); testStatusLabel.textColor = GeekTheme.inkSecondary
        testStatusLabel.lineBreakMode = .byTruncatingTail
        GeekTheme.placeCentered(testStatusLabel, x: 152, width: fw - 170, centerY: 439.0)
        cv.addSubview(testStatusLabel)
    }

    private func makeSubCard(frame: NSRect) -> GeekFlippedView {
        GeekSurfaceView(frame: frame, fill: GeekTheme.inputBg, border: GeekTheme.border, cornerRadius: 9.0, borderWidth: 1.0)
    }

    private func makeDynamicRow(label: String, placeholder: String, mono: Bool, width fw: CGFloat) -> (GeekFlippedView, NSTextField, NSTextField) {
        let row = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: fw, height: 38))
        let lbl = addRowCaption(label, rowHeight: 38, in: row)
        let tf = NSTextField()
        row.addSubview(GeekInputBox(frame: NSRect(x: 96, y: 4, width: fw - 114, height: 30), field: tf, placeholder: placeholder, mono: mono))
        return (row, lbl, tf)
    }

    @discardableResult
    private func addRowCaption(_ text: String, rowHeight: CGFloat, in parent: NSView) -> NSTextField {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = .systemFont(ofSize: 13.0, weight: .medium); lbl.textColor = GeekTheme.inkSecondary; lbl.alignment = .right
        GeekTheme.placeCentered(lbl, x: 12, width: 72, centerY: rowHeight * 0.5)
        parent.addSubview(lbl)
        return lbl
    }
}
