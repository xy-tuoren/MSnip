import AppKit
import Foundation
import MSnipCore

/// 统一「识字与翻译」设置页控件盒：一站式管理文字识别 (OCR)、LaTeX 公式识别与截图翻译偏好
@MainActor
final class OCRLatexSettingsControls {
    var scrollView: NSScrollView?
    var contentView: GeekFlippedView?

    // 1) 文字识别 (OCR)
    var ocrHeaderLabel: NSTextField?; var ocrCard: GeekCardView?
    var ocrModeSegment: GeekSegmentControl?
    var ocrEnginePill: GeekDropdownPill?
    var ocrVisionProfileRow: GeekFlippedView?; var ocrVisionProfilePill: GeekDropdownPill?
    var ocrVisionModelRow: GeekFlippedView?; var ocrVisionModelField: NSTextField?
    var baiduKeyRow: GeekFlippedView?; var baiduKeyField: NSTextField?
    var baiduSecretRow: GeekFlippedView?; var baiduSecretField: NSSecureTextField?
    var tencentIDRow: GeekFlippedView?; var tencentIDField: NSTextField?
    var tencentKeyRow: GeekFlippedView?; var tencentKeyField: NSSecureTextField?
    var tencentRegionRow: GeekFlippedView?; var tencentRegionField: NSTextField?
    var youdaoIDRow: GeekFlippedView?; var youdaoIDField: NSTextField?
    var youdaoSecretRow: GeekFlippedView?; var youdaoSecretField: NSSecureTextField?
    var customURLRow: GeekFlippedView?; var customURLField: NSTextField?
    var customHeadersRow: GeekFlippedView?; var customHeadersField: NSTextField?
    var customBodyRow: GeekFlippedView?; var customBodyField: NSTextField?
    var customPathRow: GeekFlippedView?; var customPathField: NSTextField?
    var ocrAutoCopyRow: GeekFlippedView?; var ocrAutoCopySwitch: GeekToggleSwitch?
    var ocrTestRow: GeekFlippedView?; var ocrTestBtn: GeekButton?; var ocrTestStatusLabel: NSTextField?
    var ocrTestTask: Task<Void, Never>?

    // 2) LaTeX 公式识别
    var latexHeaderLabel: NSTextField?; var latexCard: GeekCardView?
    var latexEnginePill: GeekDropdownPill?
    var latexVisionProfileRow: GeekFlippedView?; var latexVisionProfilePill: GeekDropdownPill?
    var latexVisionModelRow: GeekFlippedView?; var latexVisionModelField: NSTextField?
    var simpleTexRow: GeekFlippedView?; var simpleTexTokenField: NSSecureTextField?
    var mathpixIDRow: GeekFlippedView?; var mathpixIDField: NSTextField?
    var mathpixKeyRow: GeekFlippedView?; var mathpixKeyField: NSSecureTextField?
    var offlineHintRow: GeekFlippedView?
    var latexWrapRow: GeekFlippedView?; var latexWrapSegment: GeekSegmentControl?
    var latexAutoCopyRow: GeekFlippedView?; var latexAutoCopySwitch: GeekToggleSwitch?
    var latexTestRow: GeekFlippedView?; var latexTestBtn: GeekButton?; var latexTestStatusLabel: NSTextField?
    var latexTestTask: Task<Void, Never>?

    // 3) 截图翻译偏好（已从「模型与服务」池拆出）
    var transHeaderLabel: NSTextField?; var transCard: GeekCardView?
    var transModeSegment: GeekSegmentControl?
    var transEnginePill: GeekDropdownPill?

    var ocrConfig: OCRRecognitionConfig = OCRRecognitionConfig.load()
    var latexConfig: LatexRecognitionConfig = LatexRecognitionConfig.load()
    var visionProfiles: [TranslationProviderProfile] = []
    var translationProfiles: [TranslationProviderProfile] = []
}

/// 主设置窗第 3 标签「识字与翻译」：Card 1 文字识别 (OCR) 构建与动态表单行工厂
extension TranslationSettingsWindow {
    func buildOCRAndLatexPage(in page: GeekFlippedView) {
        let cardX: CGFloat = 28, cardW = page.bounds.width - 56, insetX: CGFloat = 16, headerX = cardX + insetX
        let rowH: CGFloat = 44, ctrlH: CGFloat = 28, ctrlY: CGFloat = 8, switchH: CGFloat = 22, switchY: CGFloat = 11
        let switchX = cardW - insetX - 38, ctrlW: CGFloat = 396, ctrlX = cardW - insetX - ctrlW

        let scroll = NSScrollView(frame: page.bounds)
        configureVerticalScroll(scroll)
        let content = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: 780))
        content.autoresizingMask = [.width]
        scroll.documentView = content; page.addSubview(scroll)
        ocrLatex.scrollView = scroll; ocrLatex.contentView = content

        // 2) 文字识别 (OCR) —— 按所选引擎动态联动展开对应接口/厂商凭据/通用 HTTP 适配项
        let ocrHdr = NSTextField(labelWithString: "文字识别 (OCR)")
        ocrHdr.font = .systemFont(ofSize: 12.0, weight: .semibold); ocrHdr.textColor = GeekTheme.inkSecondary
        GeekTheme.placeCentered(ocrHdr, x: headerX, width: 180, centerY: 0)
        content.addSubview(ocrHdr); ocrLatex.ocrHeaderLabel = ocrHdr
        let ocrCard = GeekCardView(frame: NSRect(x: cardX, y: 0, width: cardW, height: rowH * 3))
        content.addSubview(ocrCard); ocrLatex.ocrCard = ocrCard

        let ocrTip = "原位划词：留在截图页直接拖选文字；双栏面板：打开双栏对照窗；静默直拷：不打开双栏，提取完直接关闭截图页并复制（按住 ⌥ 可临时切换）"
        addRowLabel("默认展示方式", y: 0, height: rowH, in: ocrCard, toolTip: ocrTip)
        let modeSeg = GeekSegmentControl(items: OCRDefaultPresentation.allCases.map(\.title), selectedIndex: 0)
        modeSeg.toolTip = ocrTip; modeSeg.frame = NSRect(x: cardW - insetX - 276, y: ctrlY, width: 276, height: ctrlH)
        modeSeg.onSelect = { [weak self] idx in
            let all = OCRDefaultPresentation.allCases
            guard all.indices.contains(idx) else { return }
            self?.onAppConfigMutated? { $0.ocrPresentation = all[idx]; $0.ocrAutoOpenDualPane = (all[idx] == .dualPane) }
        }
        ocrLatex.ocrModeSegment = modeSeg; ocrCard.addSubview(modeSeg)

        ocrCard.addHairline(atY: rowH)
        let engTip = "支持 Apple 离线 Vision、视觉大模型、百度/腾讯/有道云 OCR 及自定义 HTTP 通用接口；切换后自动展开对应配置"
        addRowLabel("默认识字引擎", y: rowH, height: rowH, in: ocrCard, toolTip: engTip)
        let ocrEngPill = GeekDropdownPill(symbol: "text.viewfinder", items: OCREngineKind.allCases.map(\.displayName))
        ocrEngPill.toolTip = engTip; ocrEngPill.frame = NSRect(x: ctrlX, y: rowH + ctrlY, width: ctrlW, height: ctrlH)
        ocrEngPill.onSelect = { [weak self] idx in
            guard let self, OCREngineKind.allCases.indices.contains(idx) else { return }
            self.commitOCRAndLatexEdits()
            self.ocrLatex.ocrConfig.engineKind = OCREngineKind.allCases[idx]
            self.saveOCRAndLatexConfigs(); self.relayoutOCRLatexCards()
        }
        ocrLatex.ocrEnginePill = ocrEngPill; ocrCard.addSubview(ocrEngPill)

        // 视觉大模型行
        let ovRow = makeOCRLatexDynRow("AI 视觉接口", cardW: cardW, in: ocrCard, tip: "复用「模型与服务」中的 OpenAI / Claude / Gemini 接口进行高精度识字与表格提取")
        let ocrProfPill = GeekDropdownPill(symbol: "cpu", items: [])
        ocrProfPill.frame = NSRect(x: ctrlX, y: ctrlY, width: ctrlW - 84, height: ctrlH)
        ocrProfPill.onSelect = { [weak self] idx in
            guard let self else { return }
            self.ocrLatex.ocrConfig.visionProfileID = self.selectedVisionProfileID(at: idx)
            self.saveOCRAndLatexConfigs()
        }
        ovRow.addSubview(ocrProfPill); ocrLatex.ocrVisionProfilePill = ocrProfPill
        let ocrManageBtn = GeekButton(title: "管理服务", style: .subtle)
        ocrManageBtn.frame = NSRect(x: cardW - insetX - 78, y: ctrlY, width: 78, height: ctrlH)
        ocrManageBtn.onClick = { [weak self] in self?.switchTab(.translation) }
        ovRow.addSubview(ocrManageBtn); ocrLatex.ocrVisionProfileRow = ovRow

        (ocrLatex.ocrVisionModelRow, ocrLatex.ocrVisionModelField) = makeTextDynRow(
            "视觉模型名", placeholder: "选填，留空沿用所选接口默认模型",
            tip: "可单独指定视觉专用模型（如 gpt-4o-mini / gemini-2.5-flash / qwen-vl-plus）",
            cardW: cardW, ctrlX: ctrlX, ctrlW: ctrlW, in: ocrCard
        )

        // 百度智能云 OCR 行
        (ocrLatex.baiduKeyRow, ocrLatex.baiduKeyField) = makeTextDynRow(
            "API Key", placeholder: "粘贴百度智能云 OCR API Key",
            tip: "百度智能云通用文字识别（高精度版），每月含免费调用额度",
            cardW: cardW, ctrlX: ctrlX, ctrlW: ctrlW, in: ocrCard
        )
        (ocrLatex.baiduSecretRow, ocrLatex.baiduSecretField) = makeSecretDynRow(
            "Secret Key", placeholder: "粘贴百度智能云 Secret Key",
            consoleURL: "https://console.bce.baidu.com/ai/#/ai/ocr/overview/index",
            cardW: cardW, ctrlX: ctrlX, ctrlW: ctrlW, in: ocrCard
        )

        // 腾讯云 OCR 行
        (ocrLatex.tencentIDRow, ocrLatex.tencentIDField) = makeTextDynRow(
            "SecretId", placeholder: "粘贴腾讯云 API 密钥 SecretId",
            tip: "使用腾讯云 GeneralAccurateOCR（TC3-HMAC-SHA256 签名直连）",
            cardW: cardW, ctrlX: ctrlX, ctrlW: ctrlW, in: ocrCard
        )
        (ocrLatex.tencentKeyRow, ocrLatex.tencentKeyField) = makeSecretDynRow(
            "SecretKey", placeholder: "粘贴腾讯云 SecretKey",
            consoleURL: "https://console.cloud.tencent.com/ocr",
            cardW: cardW, ctrlX: ctrlX, ctrlW: ctrlW, in: ocrCard
        )
        (ocrLatex.tencentRegionRow, ocrLatex.tencentRegionField) = makeTextDynRow(
            "服务地域", placeholder: "默认 ap-guangzhou（如 ap-shanghai / ap-beijing）",
            cardW: cardW, ctrlX: ctrlX, ctrlW: ctrlW, in: ocrCard
        )

        // 有道智云 OCR 行
        (ocrLatex.youdaoIDRow, ocrLatex.youdaoIDField) = makeTextDynRow(
            "应用 ID", placeholder: "粘贴有道智云应用 ID (appKey)",
            tip: "有道智云通用文字识别（V3 SHA256 签名）",
            cardW: cardW, ctrlX: ctrlX, ctrlW: ctrlW, in: ocrCard
        )
        (ocrLatex.youdaoSecretRow, ocrLatex.youdaoSecretField) = makeSecretDynRow(
            "应用密钥", placeholder: "粘贴有道智云应用密钥",
            consoleURL: "https://ai.youdao.com/console/",
            cardW: cardW, ctrlX: ctrlX, ctrlW: ctrlW, in: ocrCard
        )

        // 通用自定义 HTTP OCR 适配器行
        (ocrLatex.customURLRow, ocrLatex.customURLField) = makeTextDynRow(
            "接口 URL", placeholder: "如 http://127.0.0.1:1224/api/ocr",
            tip: "兼容 Umi-OCR、PaddleOCR、RapidOCR、阿里云或任意自建 HTTP OCR 接口",
            cardW: cardW, ctrlX: ctrlX, ctrlW: ctrlW, in: ocrCard
        )
        (ocrLatex.customHeadersRow, ocrLatex.customHeadersField) = makeTextDynRow(
            "请求头 JSON", placeholder: "{\"Content-Type\":\"application/json\"}",
            tip: "可选自定义请求头（JSON 对象），如 Authorization / X-API-Key",
            cardW: cardW, ctrlX: ctrlX, ctrlW: ctrlW, in: ocrCard
        )
        (ocrLatex.customBodyRow, ocrLatex.customBodyField) = makeTextDynRow(
            "Body 模版", placeholder: "{\"base64\":\"{{image_base64}}\"}",
            tip: "支持占位符：{{image_base64}}（纯 PNG Base64）或 {{image_data_uri}}（含 data:image/png;base64, 前缀）",
            cardW: cardW, ctrlX: ctrlX, ctrlW: ctrlW, in: ocrCard
        )
        (ocrLatex.customPathRow, ocrLatex.customPathField) = makeTextDynRow(
            "JSON 路径", placeholder: "如 data.*.text 或 words_result.*.words",
            tip: "点分路径提取文字，支持 * 数组通配符（自动按行拼接所有匹配项）",
            cardW: cardW, ctrlX: ctrlX, ctrlW: ctrlW, in: ocrCard
        )

        let oacRow = makeOCRLatexDynRow("识字完成后自动复制", cardW: cardW, in: ocrCard, tip: "关闭后，双栏 OCR 窗口仅展示识别结果，不会自动覆盖剪贴板")
        let copySw = GeekToggleSwitch(isOn: true)
        copySw.frame = NSRect(x: switchX, y: switchY, width: 38, height: switchH)
        copySw.onToggle = { [weak self] on in self?.onAppConfigMutated? { $0.ocrAutoCopy = on } }
        oacRow.addSubview(copySw); ocrLatex.ocrAutoCopySwitch = copySw; ocrLatex.ocrAutoCopyRow = oacRow

        (ocrLatex.ocrTestRow, ocrLatex.ocrTestBtn, ocrLatex.ocrTestStatusLabel) = makeTestDynRow(
            title: "测试识字", cardW: cardW, in: ocrCard
        ) { [weak self] in self?.onTestOCRClicked() }

        buildLatexAndTranslateSections(in: content, cardX: cardX, cardW: cardW, headerX: headerX, ctrlX: ctrlX, ctrlW: ctrlW, switchX: switchX)
    }

    func makeTestDynRow(title: String, cardW: CGFloat, in card: GeekCardView, action: @escaping () -> Void) -> (GeekFlippedView, GeekButton, NSTextField) {
        let insetX: CGFloat = 16, rowH: CGFloat = 44
        let row = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: cardW, height: rowH))
        row.addSubview(GeekSurfaceView(frame: NSRect(x: insetX, y: 0, width: cardW - insetX * 2, height: 1), fill: GeekTheme.divider))
        let btn = GeekButton(title: title, symbol: "bolt.horizontal", style: .subtle)
        btn.frame = NSRect(x: insetX, y: 8, width: 102, height: 28)
        btn.onClick = action; row.addSubview(btn)
        let lbl = NSTextField(labelWithString: "")
        lbl.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium); lbl.textColor = GeekTheme.inkSecondary
        lbl.lineBreakMode = .byTruncatingTail
        GeekTheme.placeCentered(lbl, x: insetX + 112, width: cardW - insetX * 2 - 112, centerY: rowH * 0.5)
        row.addSubview(lbl); card.addSubview(row)
        return (row, btn, lbl)
    }

    func makeOCRLatexDynRow(_ label: String, cardW: CGFloat, in card: GeekCardView, tip: String? = nil) -> GeekFlippedView {
        let insetX: CGFloat = 16, rowH: CGFloat = 44
        let row = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: cardW, height: rowH))
        row.addSubview(GeekSurfaceView(frame: NSRect(x: insetX, y: 0, width: cardW - insetX * 2, height: 1), fill: GeekTheme.divider))
        let lbl = NSTextField(labelWithString: label)
        lbl.font = .systemFont(ofSize: 13.5, weight: .regular); lbl.textColor = GeekTheme.inkPrimary; lbl.sizeToFit(); lbl.toolTip = tip
        GeekTheme.placeCentered(lbl, x: 16, width: lbl.frame.width + 6, centerY: rowH * 0.5)
        row.addSubview(lbl); card.addSubview(row)
        return row
    }

    func makeTextDynRow(
        _ label: String, placeholder: String, mono: Bool = true, tip: String? = nil,
        cardW: CGFloat, ctrlX: CGFloat, ctrlW: CGFloat, in card: GeekCardView
    ) -> (GeekFlippedView, NSTextField) {
        let row = makeOCRLatexDynRow(label, cardW: cardW, in: card, tip: tip)
        let tf = NSTextField(); tf.delegate = self
        row.addSubview(GeekInputBox(frame: NSRect(x: ctrlX, y: 8, width: ctrlW, height: 28), field: tf, placeholder: placeholder, mono: mono))
        return (row, tf)
    }

    func makeSecretDynRow(
        _ label: String, placeholder: String, consoleURL: String?, tip: String? = nil,
        cardW: CGFloat, ctrlX: CGFloat, ctrlW: CGFloat, in card: GeekCardView
    ) -> (GeekFlippedView, NSSecureTextField) {
        let insetX: CGFloat = 16, ctrlY: CGFloat = 8, ctrlH: CGFloat = 28
        let row = makeOCRLatexDynRow(label, cardW: cardW, in: card, tip: tip)
        let sf = NSSecureTextField(); sf.delegate = self
        let hasGet = (consoleURL != nil)
        let boxW = hasGet ? (ctrlW - 132) : (ctrlW - 56)
        row.addSubview(GeekInputBox(frame: NSRect(x: ctrlX, y: ctrlY, width: boxW, height: ctrlH), field: sf, placeholder: placeholder, mono: true))

        let pasteBtn = GeekButton(title: "粘贴", style: .subtle)
        pasteBtn.frame = NSRect(x: ctrlX + boxW + 6, y: ctrlY, width: 50, height: ctrlH)
        pasteBtn.onClick = { [weak self] in
            if let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                sf.stringValue = s; self?.commitOCRAndLatexEdits(); self?.saveOCRAndLatexConfigs()
            }
        }
        row.addSubview(pasteBtn)

        if let urlStr = consoleURL {
            let getBtn = GeekButton(title: "获取", symbol: "arrow.up.right", style: .accent)
            getBtn.frame = NSRect(x: cardW - insetX - 70, y: ctrlY, width: 70, height: ctrlH)
            getBtn.onClick = { if let u = URL(string: urlStr) { NSWorkspace.shared.open(u) } }
            row.addSubview(getBtn)
        }
        return (row, sf)
    }
}

// MARK: - OCR 与公式引擎动态表单刷新

/// 主设置窗第 3 标签「识字与翻译」：Card 2 LaTeX 公式识别、Card 3 截图翻译偏好、动态折叠布局与持久化同步
extension TranslationSettingsWindow {
    func buildLatexAndTranslateSections(
        in content: GeekFlippedView, cardX: CGFloat, cardW: CGFloat, headerX: CGFloat,
        ctrlX: CGFloat, ctrlW: CGFloat, switchX: CGFloat
    ) {
        let insetX: CGFloat = 16, rowH: CGFloat = 44, ctrlH: CGFloat = 28, ctrlY: CGFloat = 8, switchH: CGFloat = 22, switchY: CGFloat = 11

        // 2) LaTeX 公式识别（按所选引擎动态展开对应接口/凭据行）
        let lxHdr = NSTextField(labelWithString: "LaTeX 公式识别")
        lxHdr.font = .systemFont(ofSize: 12.0, weight: .semibold); lxHdr.textColor = GeekTheme.inkSecondary
        GeekTheme.placeCentered(lxHdr, x: headerX, width: 180, centerY: 0)
        content.addSubview(lxHdr); ocrLatex.latexHeaderLabel = lxHdr

        let lxCard = GeekCardView(frame: NSRect(x: cardX, y: 0, width: cardW, height: rowH * 4))
        content.addSubview(lxCard); ocrLatex.latexCard = lxCard

        addRowLabel("公式识别引擎", y: 0, height: rowH, in: lxCard)
        let lxEngPill = GeekDropdownPill(symbol: "function", items: LatexEngineKind.allCases.map(\.displayName))
        lxEngPill.frame = NSRect(x: ctrlX, y: ctrlY, width: ctrlW, height: ctrlH)
        lxEngPill.onSelect = { [weak self] idx in
            guard let self, LatexEngineKind.allCases.indices.contains(idx) else { return }
            self.commitOCRAndLatexEdits()
            self.ocrLatex.latexConfig.engineKind = LatexEngineKind.allCases[idx]
            self.saveOCRAndLatexConfigs(); self.relayoutOCRLatexCards()
        }
        ocrLatex.latexEnginePill = lxEngPill; lxCard.addSubview(lxEngPill)

        let lvRow = makeOCRLatexDynRow("AI 视觉接口", cardW: cardW, in: lxCard, tip: "复用「模型与服务」里的多模态大模型识别复杂分式、积分与矩阵")
        let lvPill = GeekDropdownPill(symbol: "cpu", items: [])
        lvPill.frame = NSRect(x: ctrlX, y: ctrlY, width: ctrlW - 84, height: ctrlH)
        lvPill.onSelect = { [weak self] idx in
            guard let self else { return }
            self.ocrLatex.latexConfig.visionProfileID = self.selectedVisionProfileID(at: idx)
            self.saveOCRAndLatexConfigs()
        }
        lvRow.addSubview(lvPill); ocrLatex.latexVisionProfilePill = lvPill
        let lvManage = GeekButton(title: "管理服务", style: .subtle)
        lvManage.frame = NSRect(x: cardW - insetX - 78, y: ctrlY, width: 78, height: ctrlH)
        lvManage.onClick = { [weak self] in self?.switchTab(.translation) }
        lvRow.addSubview(lvManage); ocrLatex.latexVisionProfileRow = lvRow

        (ocrLatex.latexVisionModelRow, ocrLatex.latexVisionModelField) = makeTextDynRow(
            "视觉模型名", placeholder: "选填，留空沿用接口默认模型",
            tip: "选填：留空沿用所选接口默认模型", cardW: cardW, ctrlX: ctrlX, ctrlW: ctrlW, in: lxCard
        )
        (ocrLatex.simpleTexRow, ocrLatex.simpleTexTokenField) = makeSecretDynRow(
            "UAT 令牌", placeholder: "粘贴 SimpleTex UAT Token", consoleURL: "https://simpletex.cn",
            tip: "SimpleTex 专攻印刷体与手写数学公式，国内直连极快且每月自带免费额度",
            cardW: cardW, ctrlX: ctrlX, ctrlW: ctrlW, in: lxCard
        )
        (ocrLatex.mathpixIDRow, ocrLatex.mathpixIDField) = makeTextDynRow(
            "App ID", placeholder: "粘贴 Mathpix app_id", cardW: cardW, ctrlX: ctrlX, ctrlW: ctrlW, in: lxCard
        )
        (ocrLatex.mathpixKeyRow, ocrLatex.mathpixKeyField) = makeSecretDynRow(
            "App Key", placeholder: "粘贴 Mathpix app_key", consoleURL: "https://console.mathpix.com",
            cardW: cardW, ctrlX: ctrlX, ctrlW: ctrlW, in: lxCard
        )

        let offRow = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: cardW, height: 38))
        offRow.addSubview(GeekSurfaceView(frame: NSRect(x: insetX, y: 0, width: cardW - insetX * 2, height: 1), fill: GeekTheme.divider))
        let offLbl = NSTextField(labelWithString: "完全离线运行（基于 Apple Vision + 数学符号转换），无需联网，适合基础行内公式")
        offLbl.font = .systemFont(ofSize: 12.0); offLbl.textColor = GeekTheme.inkSecondary
        GeekTheme.placeCentered(offLbl, x: insetX, width: cardW - insetX * 2, centerY: 19)
        offRow.addSubview(offLbl); lxCard.addSubview(offRow); ocrLatex.offlineHintRow = offRow

        let wrapRow = makeOCRLatexDynRow("默认复制格式", cardW: cardW, in: lxCard)
        let wrapSeg = GeekSegmentControl(items: LatexWrapFormat.allCases.map(\.shortTitle), selectedIndex: 2, mono: true)
        wrapSeg.frame = NSRect(x: ctrlX, y: ctrlY, width: ctrlW, height: ctrlH)
        wrapSeg.onSelect = { [weak self] idx in
            guard let self, LatexWrapFormat.allCases.indices.contains(idx) else { return }
            self.ocrLatex.latexConfig.preferredWrap = LatexWrapFormat.allCases[idx]; self.saveOCRAndLatexConfigs()
        }
        wrapRow.addSubview(wrapSeg); ocrLatex.latexWrapSegment = wrapSeg; ocrLatex.latexWrapRow = wrapRow

        let acRow = makeOCRLatexDynRow("识别完成后自动复制", cardW: cardW, in: lxCard)
        let acSw = GeekToggleSwitch(isOn: true)
        acSw.frame = NSRect(x: switchX, y: switchY, width: 38, height: switchH)
        acSw.onToggle = { [weak self] on in self?.ocrLatex.latexConfig.autoCopy = on; self?.saveOCRAndLatexConfigs() }
        acRow.addSubview(acSw); ocrLatex.latexAutoCopySwitch = acSw; ocrLatex.latexAutoCopyRow = acRow

        (ocrLatex.latexTestRow, ocrLatex.latexTestBtn, ocrLatex.latexTestStatusLabel) = makeTestDynRow(
            title: "测试公式", cardW: cardW, in: lxCard
        ) { [weak self] in self?.onTestLatexClicked() }

        // 3) 截图翻译（从「模型与服务」池拆出，与 OCR / LaTeX 并列管理功能级偏好）
        let trHdr = NSTextField(labelWithString: "截图翻译")
        trHdr.font = .systemFont(ofSize: 12.0, weight: .semibold); trHdr.textColor = GeekTheme.inkSecondary
        GeekTheme.placeCentered(trHdr, x: headerX, width: 180, centerY: 0)
        content.addSubview(trHdr); ocrLatex.transHeaderLabel = trHdr

        let trCard = GeekCardView(frame: NSRect(x: cardX, y: 0, width: cardW, height: rowH * 4))
        content.addSubview(trCard); ocrLatex.transCard = trCard

        let trModeTip = "原位译文：在截图选区内直接悬浮替换译文；双栏面板：打开双栏流式翻译对照窗（按住 ⌥ 可临时切换）"
        addRowLabel("默认展示方式", y: 0, height: rowH, in: trCard, toolTip: trModeTip)
        let trModeSeg = GeekSegmentControl(items: ["原位译文", "双栏面板"], selectedIndex: 0)
        trModeSeg.toolTip = trModeTip; trModeSeg.frame = NSRect(x: cardW - insetX - 200, y: ctrlY, width: 200, height: ctrlH)
        trModeSeg.onSelect = { [weak self] idx in
            self?.onAppConfigMutated? { $0.translateAutoOpenDualPane = (idx == 1) }
        }
        ocrLatex.transModeSegment = trModeSeg; trCard.addSubview(trModeSeg)

        trCard.addHairline(atY: rowH)
        addRowLabel("默认翻译引擎", y: rowH, height: rowH, in: trCard, toolTip: "从「模型与服务」池中挑选默认用于截图翻译的引擎（可独立于 OCR / 公式引擎）")
        let trEngPill = GeekDropdownPill(symbol: "cpu", items: [])
        trEngPill.frame = NSRect(x: ctrlX, y: rowH + ctrlY, width: ctrlW - 84, height: ctrlH)
        trEngPill.onSelect = { [weak self] idx in
            guard let self, self.ocrLatex.translationProfiles.indices.contains(idx) else { return }
            let pickedID = self.ocrLatex.translationProfiles[idx].id
            self.draft.activeProfileID = pickedID
            if let rowIdx = self.draft.profiles.firstIndex(where: { $0.id == pickedID }) { self.selectedIndex = rowIdx }
            self.persistDraft(); self.refreshOCRAndLatexUI()
        }
        ocrLatex.transEnginePill = trEngPill; trCard.addSubview(trEngPill)
        let trManage = GeekButton(title: "管理服务", style: .subtle)
        trManage.frame = NSRect(x: cardW - insetX - 78, y: rowH + ctrlY, width: 78, height: ctrlH)
        trManage.onClick = { [weak self] in self?.switchTab(.translation) }
        trCard.addSubview(trManage)

        trCard.addHairline(atY: rowH * 2)
        addRowLabel("默认目标语言", y: rowH * 2, height: rowH, in: trCard)
        targetLangPill = GeekDropdownPill(symbol: "globe")
        targetLangPill.customDisplayTitle = draft.targetLang.displayName
        targetLangPill.frame = NSRect(x: ctrlX, y: rowH * 2 + ctrlY, width: ctrlW, height: ctrlH)
        targetLangPill.onCustomClick = { [weak self] anchor in self?.presentTargetLanguagePicker(from: anchor) }
        trCard.addSubview(targetLangPill)

        trCard.addHairline(atY: rowH * 3)
        addRowLabel("翻译完成后自动复制", y: rowH * 3, height: rowH, in: trCard)
        autoCopySwitch = GeekToggleSwitch(isOn: draft.autoCopyTranslation)
        autoCopySwitch.frame = NSRect(x: switchX, y: rowH * 3 + switchY, width: 38, height: switchH)
        autoCopySwitch.onToggle = { [weak self] on in self?.draft.autoCopyTranslation = on; self?.persistDraft() }
        trCard.addSubview(autoCopySwitch)
    }

    func visionProfileDropdownItems() -> [String] {
        let list = ocrLatex.visionProfiles
        if list.isEmpty { return ["暂无可用 AI 接口（点右侧添加）"] }
        if list.count == 1 { return [list[0].name] }
        let activeLLM = OCRRecognitionConfig.resolveVisionProfile(preferredID: nil, activeID: draft.activeProfileID, profiles: list)
        let autoTitle = activeLLM.map { "自动跟随当前接口（\($0.name)）" } ?? "自动跟随当前接口"
        return [autoTitle] + list.map(\.name)
    }

    func visionProfileDropdownIndex(for savedID: UUID?) -> Int {
        let list = ocrLatex.visionProfiles
        guard list.count >= 2 else { return 0 }
        guard let id = savedID, let idx = list.firstIndex(where: { $0.id == id }) else { return 0 }
        return idx + 1
    }

    func selectedVisionProfileID(at dropdownIndex: Int) -> UUID? {
        let list = ocrLatex.visionProfiles
        guard list.count >= 2 else { return nil }
        return dropdownIndex == 0 ? nil : (list.indices.contains(dropdownIndex - 1) ? list[dropdownIndex - 1].id : nil)
    }

    func refreshTranslationEnginePill() {
        let enabled = draft.profiles.filter(\.isEnabled)
        ocrLatex.translationProfiles = enabled
        ocrLatex.transEnginePill?.items = enabled.isEmpty ? ["暂无可用服务"] : enabled.map(\.name)
        if let aid = draft.activeProfileID, let idx = enabled.firstIndex(where: { $0.id == aid }) {
            ocrLatex.transEnginePill?.selectedIndex = idx
        } else {
            ocrLatex.transEnginePill?.selectedIndex = 0
        }
    }

    func refreshOCRAndLatexUI() {
        guard ocrLatex.ocrEnginePill != nil else { return }
        let appCfg = appConfigProvider?() ?? AppConfig()
        ocrLatex.ocrConfig = OCRRecognitionConfig.load()
        ocrLatex.latexConfig = LatexRecognitionConfig.load()
        ocrLatex.visionProfiles = draft.profiles.filter { $0.isEnabled && $0.kind.isLLMProtocol }

        if let oIdx = OCRDefaultPresentation.allCases.firstIndex(of: appCfg.ocrPresentation) { ocrLatex.ocrModeSegment?.selectedIndex = oIdx }
        ocrLatex.ocrAutoCopySwitch?.isOn = appCfg.ocrAutoCopy
        ocrLatex.ocrEnginePill?.selectedIndex = OCREngineKind.allCases.firstIndex(of: ocrLatex.ocrConfig.engineKind) ?? 0

        let profileTitles = visionProfileDropdownItems()
        ocrLatex.ocrVisionProfilePill?.items = profileTitles
        ocrLatex.ocrVisionProfilePill?.selectedIndex = visionProfileDropdownIndex(for: ocrLatex.ocrConfig.visionProfileID)
        ocrLatex.ocrVisionModelField?.stringValue = ocrLatex.ocrConfig.visionModelOverride
        ocrLatex.baiduKeyField?.stringValue = ocrLatex.ocrConfig.baiduAPIKey
        ocrLatex.baiduSecretField?.stringValue = ocrLatex.ocrConfig.baiduSecretKey
        ocrLatex.tencentIDField?.stringValue = ocrLatex.ocrConfig.tencentSecretID
        ocrLatex.tencentKeyField?.stringValue = ocrLatex.ocrConfig.tencentSecretKey
        ocrLatex.tencentRegionField?.stringValue = ocrLatex.ocrConfig.tencentRegion
        ocrLatex.youdaoIDField?.stringValue = ocrLatex.ocrConfig.youdaoAppKey
        ocrLatex.youdaoSecretField?.stringValue = ocrLatex.ocrConfig.youdaoAppSecret
        ocrLatex.customURLField?.stringValue = ocrLatex.ocrConfig.customEndpoint
        ocrLatex.customHeadersField?.stringValue = ocrLatex.ocrConfig.customHeadersJSON
        ocrLatex.customBodyField?.stringValue = ocrLatex.ocrConfig.customBodyTemplate
        ocrLatex.customPathField?.stringValue = ocrLatex.ocrConfig.customResponsePath

        ocrLatex.latexEnginePill?.selectedIndex = LatexEngineKind.allCases.firstIndex(of: ocrLatex.latexConfig.engineKind) ?? 0
        ocrLatex.latexVisionProfilePill?.items = profileTitles
        ocrLatex.latexVisionProfilePill?.selectedIndex = visionProfileDropdownIndex(for: ocrLatex.latexConfig.visionProfileID)
        ocrLatex.latexVisionModelField?.stringValue = ocrLatex.latexConfig.visionModelOverride
        ocrLatex.simpleTexTokenField?.stringValue = ocrLatex.latexConfig.simpleTexToken
        ocrLatex.mathpixIDField?.stringValue = ocrLatex.latexConfig.mathpixAppID
        ocrLatex.mathpixKeyField?.stringValue = ocrLatex.latexConfig.mathpixAppKey
        ocrLatex.latexWrapSegment?.selectedIndex = LatexWrapFormat.allCases.firstIndex(of: ocrLatex.latexConfig.preferredWrap) ?? 2
        ocrLatex.latexAutoCopySwitch?.isOn = ocrLatex.latexConfig.autoCopy

        refreshTopBarPopups()
        relayoutOCRLatexCards()
    }

    func relayoutOCRLatexCards() {
        guard let trCard = ocrLatex.transCard, let ocrCard = ocrLatex.ocrCard, let lxCard = ocrLatex.latexCard else { return }

        // 1) 截图翻译（排第一）
        let trHeaderY: CGFloat = 18
        if let hdr = ocrLatex.transHeaderLabel { GeekTheme.placeCentered(hdr, x: 44, width: 180, centerY: trHeaderY + 8.0) }
        trCard.frame.origin.y = trHeaderY + 24

        // 2) 文字识别 (OCR)（排第二，按引擎动态展开）
        let ocrHeaderY = trCard.frame.maxY + 20
        if let hdr = ocrLatex.ocrHeaderLabel { GeekTheme.placeCentered(hdr, x: 44, width: 180, centerY: ocrHeaderY + 8.0) }
        ocrCard.frame.origin.y = ocrHeaderY + 24

        let ok = ocrLatex.ocrConfig.engineKind
        let ocrRows: [(GeekFlippedView?, Bool)] = [
            (ocrLatex.ocrVisionProfileRow, ok == .visionLLM), (ocrLatex.ocrVisionModelRow, ok == .visionLLM),
            (ocrLatex.baiduKeyRow, ok == .baiduOCR), (ocrLatex.baiduSecretRow, ok == .baiduOCR),
            (ocrLatex.tencentIDRow, ok == .tencentOCR), (ocrLatex.tencentKeyRow, ok == .tencentOCR), (ocrLatex.tencentRegionRow, ok == .tencentOCR),
            (ocrLatex.youdaoIDRow, ok == .youdaoOCR), (ocrLatex.youdaoSecretRow, ok == .youdaoOCR),
            (ocrLatex.customURLRow, ok == .customHTTP), (ocrLatex.customHeadersRow, ok == .customHTTP),
            (ocrLatex.customBodyRow, ok == .customHTTP), (ocrLatex.customPathRow, ok == .customHTTP),
            (ocrLatex.ocrAutoCopyRow, true), (ocrLatex.ocrTestRow, ok != .appleVision)
        ]
        var ocrY: CGFloat = 88
        for (row, vis) in ocrRows {
            row?.isHidden = !vis
            if vis, let r = row { r.frame.origin.y = ocrY; ocrY += r.frame.height }
        }
        ocrCard.frame.size.height = ocrY

        // 3) LaTeX 公式识别（排最后，按引擎动态展开）
        let lxHeaderY = ocrCard.frame.maxY + 20
        if let hdr = ocrLatex.latexHeaderLabel { GeekTheme.placeCentered(hdr, x: 44, width: 180, centerY: lxHeaderY + 8.0) }
        lxCard.frame.origin.y = lxHeaderY + 24

        let lk = ocrLatex.latexConfig.engineKind
        let latexRows: [(GeekFlippedView?, Bool)] = [
            (ocrLatex.latexVisionProfileRow, lk == .autoVisionLLM), (ocrLatex.latexVisionModelRow, lk == .autoVisionLLM),
            (ocrLatex.simpleTexRow, lk == .simpleTex), (ocrLatex.mathpixIDRow, lk == .mathpix),
            (ocrLatex.mathpixKeyRow, lk == .mathpix), (ocrLatex.offlineHintRow, lk == .offlineBasic),
            (ocrLatex.latexWrapRow, true), (ocrLatex.latexAutoCopyRow, true), (ocrLatex.latexTestRow, lk != .offlineBasic)
        ]
        var cy: CGFloat = 44
        for (row, vis) in latexRows {
            row?.isHidden = !vis
            if vis, let r = row { r.frame.origin.y = cy; cy += r.frame.height }
        }
        lxCard.frame.size.height = cy

        if let content = ocrLatex.contentView {
            content.frame.size.height = max(ocrLatex.scrollView?.bounds.height ?? 500, lxCard.frame.maxY + 24)
        }
    }

    func commitOCRAndLatexEdits() {
        guard ocrLatex.ocrEnginePill != nil else { return }
        func clean(_ f: NSTextField?) -> String { f?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        ocrLatex.ocrConfig.visionModelOverride = clean(ocrLatex.ocrVisionModelField)
        ocrLatex.ocrConfig.baiduAPIKey = clean(ocrLatex.baiduKeyField)
        ocrLatex.ocrConfig.baiduSecretKey = clean(ocrLatex.baiduSecretField)
        ocrLatex.ocrConfig.tencentSecretID = clean(ocrLatex.tencentIDField)
        ocrLatex.ocrConfig.tencentSecretKey = clean(ocrLatex.tencentKeyField)
        ocrLatex.ocrConfig.tencentRegion = clean(ocrLatex.tencentRegionField)
        ocrLatex.ocrConfig.youdaoAppKey = clean(ocrLatex.youdaoIDField)
        ocrLatex.ocrConfig.youdaoAppSecret = clean(ocrLatex.youdaoSecretField)
        ocrLatex.ocrConfig.customEndpoint = clean(ocrLatex.customURLField)
        ocrLatex.ocrConfig.customHeadersJSON = clean(ocrLatex.customHeadersField)
        ocrLatex.ocrConfig.customBodyTemplate = clean(ocrLatex.customBodyField)
        ocrLatex.ocrConfig.customResponsePath = clean(ocrLatex.customPathField)
        ocrLatex.latexConfig.visionModelOverride = clean(ocrLatex.latexVisionModelField)
        ocrLatex.latexConfig.simpleTexToken = clean(ocrLatex.simpleTexTokenField)
        ocrLatex.latexConfig.mathpixAppID = clean(ocrLatex.mathpixIDField)
        ocrLatex.latexConfig.mathpixAppKey = clean(ocrLatex.mathpixKeyField)
    }

    func saveOCRAndLatexConfigs() {
        let useKC = draft.preferKeychainStorage
        ocrLatex.ocrConfig.save(useKeychain: useKC)
        ocrLatex.latexConfig.save(useKeychain: useKC)
        NotificationCenter.default.post(name: .msnipOCRLatexConfigChanged, object: nil)
    }

    func onTestOCRClicked() {
        commitOCRAndLatexEdits(); saveOCRAndLatexConfigs()
        let cfg = ocrLatex.ocrConfig
        let activeID = draft.activeProfileID
        let profiles = draft.profiles.filter { $0.isEnabled && $0.kind.isLLMProtocol }
        ocrLatex.ocrTestBtn?.isEnabled = false
        ocrLatex.ocrTestStatusLabel?.setTextWithTooltip("正在探测「\(cfg.engineKind.shortName)」…", color: GeekTheme.inkSecondary)
        ocrLatex.ocrTestTask?.cancel()
        ocrLatex.ocrTestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let res = await OCRLatexTestService.testOCR(config: cfg, activeProfileID: activeID, profiles: profiles)
            guard !Task.isCancelled else { return }
            self.ocrLatex.ocrTestBtn?.isEnabled = true
            self.ocrLatex.ocrTestStatusLabel?.setTextWithTooltip(res.message, color: res.ok ? GeekTheme.emerald : GeekTheme.amber)
        }
    }

    func onTestLatexClicked() {
        commitOCRAndLatexEdits(); saveOCRAndLatexConfigs()
        let cfg = ocrLatex.latexConfig
        let activeID = draft.activeProfileID
        let profiles = draft.profiles.filter { $0.isEnabled && $0.kind.isLLMProtocol }
        ocrLatex.latexTestBtn?.isEnabled = false
        ocrLatex.latexTestStatusLabel?.setTextWithTooltip("正在探测「\(cfg.engineKind.shortName)」…", color: GeekTheme.inkSecondary)
        ocrLatex.latexTestTask?.cancel()
        ocrLatex.latexTestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let res = await OCRLatexTestService.testLatex(config: cfg, activeProfileID: activeID, profiles: profiles)
            guard !Task.isCancelled else { return }
            self.ocrLatex.latexTestBtn?.isEnabled = true
            self.ocrLatex.latexTestStatusLabel?.setTextWithTooltip(res.message, color: res.ok ? GeekTheme.emerald : GeekTheme.amber)
        }
    }
}
