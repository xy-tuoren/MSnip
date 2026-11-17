import AppKit
import Foundation
import MSnipCore

/// 服务列表行矢量圆点视图（替代 Emoji 状态球）
final class ProviderRowCellView: NSTableCellView {
    private let titleText: String
    private let isPrimary: Bool
    private let dotColor: NSColor

    init(title: String, isPrimary: Bool, dotColor: NSColor) {
        self.titleText = title
        self.isPrimary = isPrimary
        self.dotColor = dotColor
        super.init(frame: .zero)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        MSnipUITheme.drawStatusDot(ctx: ctx, center: CGPoint(x: 12, y: bounds.midY), color: dotColor, halo: isPrimary)

        var rightReserve: CGFloat = 6
        if isPrimary {
            let badgeRect = CGRect(x: bounds.width - 38, y: round((bounds.height - 18) * 0.5), width: 32, height: 18)
            ctx.setFillColor(MSnipUITheme.activeSoftFill.cgColor)
            ctx.addPath(CGPath(roundedRect: badgeRect, cornerWidth: 4.5, cornerHeight: 4.5, transform: nil))
            ctx.fillPath()
            let bAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: MSnipUITheme.accent
            ]
            let bStr = "默认" as NSString
            let bSz = bStr.size(withAttributes: bAttrs)
            bStr.draw(at: CGPoint(x: round(badgeRect.midX - bSz.width * 0.5), y: round(badgeRect.midY - bSz.height * 0.5)), withAttributes: bAttrs)
            rightReserve = 44
        }

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: isPrimary ? .semibold : .medium),
            .foregroundColor: MSnipUITheme.inkPrimary,
            .paragraphStyle: para
        ]
        let sz = (titleText as NSString).size(withAttributes: attrs)
        let r = CGRect(x: 24, y: round((bounds.height - sz.height) * 0.5), width: max(30, bounds.width - 24 - rightReserve), height: sz.height + 2)
        (titleText as NSString).draw(in: r, withAttributes: attrs)
    }
}

/// 翻译与大模型设置页：清爽白底卡片布局、密码显隐眼标、自定义胶囊选择器扩展
extension TranslationSettingsWindow {
    func buildTranslationPage(in page: NSView) {
        let W = page.bounds.width, H = page.bounds.height
        let hdr = NSTextField(labelWithString: "截图翻译与 API 接口")
        hdr.font = .systemFont(ofSize: 16, weight: .bold)
        hdr.textColor = MSnipUITheme.inkPrimary
        hdr.frame = NSRect(x: 20, y: H - 42, width: 260, height: 22)
        page.addSubview(hdr)

        // 1) 顶部全局路由白底卡片
        let topCard = makeWhiteCard(frame: NSRect(x: 18, y: H - 98, width: W - 36, height: 46))
        page.addSubview(topCard)

        addFormCaption("目标语种", x: 12, y: 14, width: 54, in: topCard)
        targetLangPill = LightDropdownPill(symbol: "globe", items: TranslationTargetLang.allCases.map(\.displayName))
        targetLangPill.frame = NSRect(x: 68, y: 9, width: 156, height: 28)
        targetLangPill.onSelect = { [weak self] idx in
            guard let self, TranslationTargetLang.allCases.indices.contains(idx) else { return }
            self.commitCurrentFormEdits()
            self.draft.targetLang = TranslationTargetLang.allCases[idx]
            self.persistDraft()
        }
        topCard.addSubview(targetLangPill)

        addFormCaption("默认引擎", x: 232, y: 14, width: 54, in: topCard)
        primaryEnginePill = LightDropdownPill(symbol: "cpu")
        primaryEnginePill.frame = NSRect(x: 288, y: 9, width: 146, height: 28)
        primaryEnginePill.onSelect = { [weak self] idx in self?.onSelectPrimaryIndex(idx) }
        topCard.addSubview(primaryEnginePill)

        addFormCaption("失败回退", x: 442, y: 14, width: 54, in: topCard)
        fallbackEnginePill = LightDropdownPill(symbol: "arrow.triangle.2.circlepath")
        fallbackEnginePill.frame = NSRect(x: 498, y: 9, width: 130, height: 28)
        fallbackEnginePill.onSelect = { [weak self] idx in self?.onSelectFallbackIndex(idx) }
        topCard.addSubview(fallbackEnginePill)

        // 2) 左侧服务列表白底圆角卡片（告别生硬 bezelBorder）
        let listCard = makeWhiteCard(frame: NSRect(x: 18, y: 54, width: 200, height: H - 164))
        page.addSubview(listCard)

        let scroll = NSScrollView(frame: listCard.bounds.insetBy(dx: 4, dy: 4))
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let tv = NSTableView(frame: scroll.bounds)
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("PCol"))
        col.width = 186
        tv.addTableColumn(col)
        tv.headerView = nil
        tv.rowHeight = 34
        tv.backgroundColor = .clear
        tv.selectionHighlightStyle = .regular
        tv.dataSource = self
        tv.delegate = self
        scroll.documentView = tv
        self.tableView = tv
        listCard.addSubview(scroll)

        addBtn = OCRPillButton(title: "新增服务", symbol: "plus")
        addBtn.frame = NSRect(x: 18, y: 16, width: 92, height: 28)
        addBtn.onClick = { [weak self] in self?.popAddProviderMenu() }
        page.addSubview(addBtn)

        removeBtn = OCRPillButton(title: "删除")
        removeBtn.frame = NSRect(x: 114, y: 16, width: 50, height: 28)
        removeBtn.onClick = { [weak self] in self?.removeSelectedProvider() }
        page.addSubview(removeBtn)

        let jsonBtn = OCRPillButton(title: "JSON")
        jsonBtn.toolTip = "在 Finder 中显示 translation_providers.json（0600 权限）"
        jsonBtn.frame = NSRect(x: 168, y: 16, width: 50, height: 28)
        jsonBtn.onClick = { [weak self] in self?.revealJSONConfig() }
        page.addSubview(jsonBtn)

        // 3) 右侧服务参数配置白底卡片
        let formCard = makeWhiteCard(frame: NSRect(x: 228, y: 54, width: W - 246, height: H - 164))
        page.addSubview(formCard)
        self.detailContainer = formCard
        buildDetailFields(in: formCard)

        let saveBtn = OCRPillButton(title: "保存并生效", symbol: "checkmark", primary: true)
        saveBtn.frame = NSRect(x: W - 134, y: 16, width: 116, height: 28)
        saveBtn.onClick = { [weak self] in self?.onSaveAndClose() }
        page.addSubview(saveBtn)
    }

    private func buildDetailFields(in cv: NSView) {
        let fw = cv.bounds.width
        addRowLabel("显示名称", y: 350, in: cv)
        nameField = makeInput(frame: NSRect(x: 102, y: 346, width: 204, height: 26), placeholder: "如：DeepSeek 主力翻译")
        cv.addSubview(nameField)

        enabledCheck = NSButton(checkboxWithTitle: "启用", target: self, action: #selector(onFormStructuralChanged))
        enabledCheck.frame = NSRect(x: 314, y: 349, width: 54, height: 20)
        cv.addSubview(enabledCheck)

        let defBtn = OCRPillButton(title: "设为默认")
        defBtn.frame = NSRect(x: fw - 82, y: 345, width: 70, height: 27)
        defBtn.onClick = { [weak self] in self?.onSetAsPrimaryClicked() }
        cv.addSubview(defBtn)

        addRowLabel("协议类型", y: 311, in: cv)
        kindPill = LightDropdownPill(symbol: "network", items: TranslationProviderKind.allCases.map(\.displayName))
        kindPill.frame = NSRect(x: 102, y: 306, width: fw - 116, height: 28)
        kindPill.onSelect = { [weak self] idx in self?.onSelectKindIndex(idx) }
        cv.addSubview(kindPill)

        presetRowView = NSView(frame: NSRect(x: 0, y: 268, width: fw, height: 30))
        addRowLabel("厂商模版", y: 6, in: presetRowView)
        llmPresetPill = LightDropdownPill(
            symbol: "sparkles",
            items: ["一键套用常见大模型地址与模型…"] + LLMQuickPreset.allCases.map(\.title)
        )
        llmPresetPill.frame = NSRect(x: 102, y: 1, width: fw - 116, height: 28)
        llmPresetPill.onSelect = { [weak self] idx in self?.onSelectLLMPresetIndex(idx) }
        presetRowView.addSubview(llmPresetPill)
        cv.addSubview(presetRowView)

        nativeCardBox = NSView(frame: NSRect(x: 16, y: 132, width: fw - 32, height: 154))
        nativeCardBox.wantsLayer = true
        nativeCardBox.layer?.backgroundColor = MSnipUITheme.transWellFill.cgColor
        nativeCardBox.layer?.cornerRadius = 9
        nativeCardBox.layer?.borderWidth = 1.0
        nativeCardBox.layer?.borderColor = MSnipUITheme.accent.withAlphaComponent(0.22).cgColor
        nativeInfoLabel = NSTextField(wrappingLabelWithString: "")
        nativeInfoLabel.font = .systemFont(ofSize: 12.5)
        nativeInfoLabel.textColor = MSnipUITheme.inkPrimary
        nativeInfoLabel.frame = NSRect(x: 14, y: 12, width: fw - 60, height: 130)
        nativeCardBox.addSubview(nativeInfoLabel)
        cv.addSubview(nativeCardBox)

        appIdLabel = addRowLabel("AppID / ID", y: 232, in: cv)
        appIdField = makeInput(frame: NSRect(x: 102, y: 228, width: fw - 116, height: 26), placeholder: "")
        cv.addSubview(appIdField)

        endpointLabel = addRowLabel("接口 URL", y: 194, in: cv)
        endpointField = makeInput(frame: NSRect(x: 102, y: 190, width: fw - 116, height: 26), placeholder: "https://api.deepseek.com/v1")
        cv.addSubview(endpointField)

        apiKeyLabel = addRowLabel("API 密钥", y: 156, in: cv)
        let keyW = fw - 116 - 38
        apiKeySecureField = NSSecureTextField(frame: NSRect(x: 102, y: 152, width: keyW, height: 26))
        styleTextField(apiKeySecureField, placeholder: "粘贴 API Key / SecretKey（本地离线可留空）")
        cv.addSubview(apiKeySecureField)

        apiKeyPlainField = makeInput(frame: NSRect(x: 102, y: 152, width: keyW, height: 26), placeholder: "粘贴 API Key / SecretKey")
        apiKeyPlainField.isHidden = true
        cv.addSubview(apiKeyPlainField)

        eyeToggleBtn = OCRPillButton(title: "", symbol: "eye")
        eyeToggleBtn.toolTip = "显示 / 隐藏明文密钥"
        eyeToggleBtn.frame = NSRect(x: 102 + keyW + 4, y: 151, width: 34, height: 28)
        eyeToggleBtn.onClick = { [weak self] in self?.toggleAPIKeyVisibility() }
        cv.addSubview(eyeToggleBtn)

        modelLabel = addRowLabel("模型 / 地域", y: 118, in: cv)
        modelField = makeInput(frame: NSRect(x: 102, y: 114, width: fw - 116, height: 26), placeholder: "如 deepseek-chat / glm-4-flash")
        cv.addSubview(modelField)

        extraLabel1 = addRowLabel("附加配置 1", y: 80, in: cv)
        extraField1 = makeInput(frame: NSRect(x: 102, y: 76, width: fw - 116, height: 26), placeholder: "")
        cv.addSubview(extraField1)

        extraLabel2 = addRowLabel("附加配置 2", y: 44, in: cv)
        extraField2 = makeInput(frame: NSRect(x: 102, y: 40, width: fw - 116, height: 26), placeholder: "")
        cv.addSubview(extraField2)

        testBtn = OCRPillButton(title: "测试连接与延迟", symbol: "bolt.horizontal")
        testBtn.frame = NSRect(x: 14, y: 8, width: 126, height: 27)
        testBtn.onClick = { [weak self] in self?.onTestClicked() }
        cv.addSubview(testBtn)

        testStatusLabel = NSTextField(labelWithString: "")
        testStatusLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        testStatusLabel.lineBreakMode = .byTruncatingTail
        testStatusLabel.frame = NSRect(x: 148, y: 12, width: fw - 162, height: 18)
        cv.addSubview(testStatusLabel)
    }

    func makeWhiteCard(frame: NSRect) -> NSView {
        let v = NSView(frame: frame)
        v.wantsLayer = true
        v.layer?.backgroundColor = MSnipUITheme.cardSolid.cgColor
        v.layer?.cornerRadius = 10
        v.layer?.borderWidth = 1.0
        v.layer?.borderColor = MSnipUITheme.borderHairline.cgColor
        return v
    }

    private func addFormCaption(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, in parent: NSView) {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11.5, weight: .medium)
        l.textColor = MSnipUITheme.inkSecondary
        l.frame = NSRect(x: x, y: y, width: width, height: 18)
        parent.addSubview(l)
    }

    @discardableResult
    func addRowLabel(_ text: String, y: CGFloat, in parent: NSView) -> NSTextField {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = .systemFont(ofSize: 12, weight: .medium)
        lbl.textColor = MSnipUITheme.inkSecondary
        lbl.alignment = .right
        lbl.frame = NSRect(x: 8, y: y, width: 86, height: 18)
        parent.addSubview(lbl)
        return lbl
    }

    func makeInput(frame: NSRect, placeholder: String) -> NSTextField {
        let tf = NSTextField(frame: frame)
        styleTextField(tf, placeholder: placeholder)
        return tf
    }

    private func styleTextField(_ tf: NSTextField, placeholder: String) {
        tf.font = .systemFont(ofSize: 12.5)
        tf.textColor = MSnipUITheme.inkPrimary
        tf.backgroundColor = MSnipUITheme.subtleFill
        tf.drawsBackground = true
        tf.isBezeled = true
        tf.bezelStyle = .roundedBezel
        tf.placeholderString = placeholder
        tf.lineBreakMode = .byTruncatingTail
        tf.cell?.isScrollable = true
        tf.cell?.wraps = false
    }
}
