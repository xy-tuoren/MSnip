import AppKit
import Foundation
import MSnipCore

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
            "App Key", placeholder: "粘贴 Mathpix app_key", consoleURL: nil,
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
        trModeSeg.toolTip = trModeTip; trModeSeg.frame = NSRect(x: cardW - insetX - 186, y: ctrlY, width: 186, height: ctrlH)
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
        guard let ocrCard = ocrLatex.ocrCard, let lxCard = ocrLatex.latexCard, let trCard = ocrLatex.transCard else { return }
        let ok = ocrLatex.ocrConfig.engineKind
        let ocrRows: [(GeekFlippedView?, Bool)] = [
            (ocrLatex.ocrVisionProfileRow, ok == .visionLLM), (ocrLatex.ocrVisionModelRow, ok == .visionLLM),
            (ocrLatex.baiduKeyRow, ok == .baiduOCR), (ocrLatex.baiduSecretRow, ok == .baiduOCR),
            (ocrLatex.tencentIDRow, ok == .tencentOCR), (ocrLatex.tencentKeyRow, ok == .tencentOCR), (ocrLatex.tencentRegionRow, ok == .tencentOCR),
            (ocrLatex.youdaoIDRow, ok == .youdaoOCR), (ocrLatex.youdaoSecretRow, ok == .youdaoOCR),
            (ocrLatex.customURLRow, ok == .customHTTP), (ocrLatex.customHeadersRow, ok == .customHTTP),
            (ocrLatex.customBodyRow, ok == .customHTTP), (ocrLatex.customPathRow, ok == .customHTTP),
            (ocrLatex.ocrAutoCopyRow, true)
        ]
        var ocrY: CGFloat = 88
        for (row, vis) in ocrRows {
            row?.isHidden = !vis
            if vis, let r = row { r.frame.origin.y = ocrY; ocrY += r.frame.height }
        }
        ocrCard.frame.size.height = ocrY

        let lxHeaderY = ocrCard.frame.maxY + 20
        if let hdr = ocrLatex.latexHeaderLabel { GeekTheme.placeCentered(hdr, x: 44, width: 180, centerY: lxHeaderY + 8.0) }
        lxCard.frame.origin.y = lxHeaderY + 24

        let lk = ocrLatex.latexConfig.engineKind
        let latexRows: [(GeekFlippedView?, Bool)] = [
            (ocrLatex.latexVisionProfileRow, lk == .autoVisionLLM), (ocrLatex.latexVisionModelRow, lk == .autoVisionLLM),
            (ocrLatex.simpleTexRow, lk == .simpleTex), (ocrLatex.mathpixIDRow, lk == .mathpix),
            (ocrLatex.mathpixKeyRow, lk == .mathpix), (ocrLatex.offlineHintRow, lk == .offlineBasic),
            (ocrLatex.latexWrapRow, true), (ocrLatex.latexAutoCopyRow, true)
        ]
        var cy: CGFloat = 44
        for (row, vis) in latexRows {
            row?.isHidden = !vis
            if vis, let r = row { r.frame.origin.y = cy; cy += r.frame.height }
        }
        lxCard.frame.size.height = cy

        let trHeaderY = lxCard.frame.maxY + 20
        if let hdr = ocrLatex.transHeaderLabel { GeekTheme.placeCentered(hdr, x: 44, width: 180, centerY: trHeaderY + 8.0) }
        trCard.frame.origin.y = trHeaderY + 24

        if let content = ocrLatex.contentView {
            content.frame.size.height = max(ocrLatex.scrollView?.bounds.height ?? 500, trCard.frame.maxY + 24)
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
}
