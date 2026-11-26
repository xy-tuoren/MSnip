import AppKit
import Foundation
import MSnipCore

/// 统一「识字与翻译」设置页控件盒：一站式管理文字识别 (OCR)、LaTeX 公式识别与截图翻译偏好
@MainActor
final class OCRLatexSettingsControls {
    var scrollView: NSScrollView?
    var contentView: GeekFlippedView?

    // 1) 文字识别 (OCR)
    var ocrCard: GeekCardView?
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
        let switchX = cardW - insetX - 38, ctrlW: CGFloat = 336, ctrlX = cardW - insetX - ctrlW

        let scroll = NSScrollView(frame: page.bounds)
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let content = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: page.bounds.width, height: 780))
        scroll.documentView = content; page.addSubview(scroll)
        ocrLatex.scrollView = scroll; ocrLatex.contentView = content

        // 1) 文字识别 (OCR) —— 按所选引擎动态联动展开对应接口/厂商凭据/通用 HTTP 适配项
        addSectionHeader("文字识别 (OCR)", x: headerX, y: 18, in: content)
        let ocrCard = GeekCardView(frame: NSRect(x: cardX, y: 42, width: cardW, height: rowH * 3))
        content.addSubview(ocrCard); ocrLatex.ocrCard = ocrCard

        let ocrTip = "原位划词：留在截图页直接拖选文字；双栏面板：打开双栏对照窗；静默直拷：不打开双栏，提取完直接关闭截图页并复制（按住 ⌥ 可临时切换）"
        addRowLabel("默认展示方式", y: 0, height: rowH, in: ocrCard, toolTip: ocrTip)
        let modeSeg = GeekSegmentControl(items: OCRDefaultPresentation.allCases.map(\.title), selectedIndex: 0)
        modeSeg.toolTip = ocrTip; modeSeg.frame = NSRect(x: cardW - insetX - 246, y: ctrlY, width: 246, height: ctrlH)
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

        buildLatexAndTranslateSections(in: content, cardX: cardX, cardW: cardW, headerX: headerX, ctrlX: ctrlX, ctrlW: ctrlW, switchX: switchX)
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
        let boxW = hasGet ? (ctrlW - 118) : (ctrlW - 56)
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
            getBtn.frame = NSRect(x: cardW - insetX - 56, y: ctrlY, width: 56, height: ctrlH)
            getBtn.onClick = { if let u = URL(string: urlStr) { NSWorkspace.shared.open(u) } }
            row.addSubview(getBtn)
        }
        return (row, sf)
    }
}
