import AppKit
import Foundation
import MSnipCore

/// 双栏对照浮窗流式翻译控制条（自定义清爽胶囊下拉选择器 + 实时流式译文输出）扩展
@MainActor
extension OCRResultController {
    func buildOCREngineControls(in root: NSView) {
        let engPill = LightDropdownPill(symbol: "text.viewfinder", items: OCREngineKind.allCases.map(\.shortName))
        engPill.toolTip = "快速切换文字识别引擎（Apple 离线 / AI 视觉 / 百度 / 腾讯 / 有道 / 自定义 HTTP）"
        engPill.onSelect = { [weak self] idx in
            guard let self, OCREngineKind.allCases.indices.contains(idx), let img = self.currentCGImage else { return }
            self.selectedOCREngine = OCREngineKind.allCases[idx]
            self.exactModeButton?.isHidden = (self.selectedOCREngine != .appleVision)
            self.requestToken &+= 1
            self.runSelectedOCREngine(on: img, token: self.requestToken)
        }
        root.addSubview(engPill)
        self.ocrEnginePill = engPill

        let cfgBtn = OCRPillButton(title: "", symbol: "slider.horizontal.3")
        cfgBtn.toolTip = "前往「设置 → 识字与翻译」统一配置 OCR、公式与翻译引擎"
        cfgBtn.onClick = { [weak self] in self?.onOpenOCRSettings?() }
        root.addSubview(cfgBtn)
        self.ocrSettingsBtn = cfgBtn

        if ocrConfigObserver == nil {
            ocrConfigObserver = NotificationCenter.default.addObserver(forName: .msnipOCRLatexConfigChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.selectedOCREngine = OCRRecognitionConfig.load().engineKind
                    self.ocrEnginePill?.selectedIndex = OCREngineKind.allCases.firstIndex(of: self.selectedOCREngine) ?? 0
                    self.exactModeButton?.isHidden = (self.selectedOCREngine != .appleVision)
                    self.refreshTranslationPopups(); self.relayoutContent()
                }
            }
        }
    }

    func runSelectedOCREngine(on image: CGImage, token: UInt64) {
        visionOCRTask?.cancel(); visionOCRTask = nil
        if selectedOCREngine != .appleVision {
            let engine = selectedOCREngine
            let ocrCfg = OCRRecognitionConfig.load()
            let activeID = TranslationService.shared.settings.activeProfileID
            let profiles = VisionLLMOCRService.availableVisionLLMProfiles()
            statusBadgeLabel.stringValue = "正在用「\(engine.shortName)」识别…"
            statusBadgeLabel.textColor = MSnipUITheme.accent
            tableCopyButton?.isHidden = true
            relayoutContent()
            // 同时在后台为左图挂载 Live Text，保证云端/大模型识字模式下左侧原图依然可划词
            VisionTextExtractor.recognizeAsync(from: image, exactCodeMode: false) { [weak self] output in
                guard let self, self.requestToken == token else { return }
                self.liveImageView?.applyPrecomputedAnalysis(output.liveAnalysisObject, highlightBlocks: self.highlightButton.isToggledOn)
            }
            visionOCRTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let out = try await CloudOCRService.recognizeText(
                        image: image, engine: engine, config: ocrCfg, activeProfileID: activeID, profiles: profiles
                    )
                    guard !Task.isCancelled, self.requestToken == token else { return }
                    self.currentOutput = nil
                    self.textView.string = out.text
                    self.qrBannerBox.isHidden = true
                    if !self.isTranslationActive {
                        if self.ocrAutoCopyProvider?() ?? true {
                            ClipboardAndSave.copyText(out.text)
                            self.statusBadgeLabel.stringValue = "✓ \(out.providerName) · \(out.elapsedMs)ms · 已复制"
                        } else {
                            self.statusBadgeLabel.stringValue = "✓ \(out.providerName) · \(out.elapsedMs)ms"
                        }
                        self.statusBadgeLabel.textColor = MSnipUITheme.success
                    }
                    self.updateStatsLabel(); self.relayoutContent()
                    if self.isTranslationActive { self.triggerStreamingTranslation() }
                } catch {
                    guard !Task.isCancelled, self.requestToken == token else { return }
                    self.statusBadgeLabel.stringValue = "⚠ \(error.localizedDescription)（已回退离线）"
                    self.statusBadgeLabel.textColor = MSnipUITheme.warning
                    self.relayoutContent()
                    VisionTextExtractor.recognizeAsync(from: image, exactCodeMode: self.exactCodeMode) { [weak self] output in
                        guard let self, self.requestToken == token else { return }
                        self.applyRecognitionOutput(output)
                        self.liveImageView?.applyPrecomputedAnalysis(output.liveAnalysisObject, highlightBlocks: self.highlightButton.isToggledOn)
                    }
                }
            }
            return
        }
        statusBadgeLabel.stringValue = "正在离线识别…"
        statusBadgeLabel.textColor = MSnipUITheme.inkSecondary
        relayoutContent()
        VisionTextExtractor.recognizeAsync(from: image, exactCodeMode: exactCodeMode) { [weak self] output in
            guard let self, self.requestToken == token else { return }
            self.applyRecognitionOutput(output)
            self.liveImageView?.applyPrecomputedAnalysis(output.liveAnalysisObject, highlightBlocks: self.highlightButton.isToggledOn)
        }
    }

    func buildTableCopyButton(in root: NSView) {
        let btn = OCRPillButton(title: "复制表格", symbol: "tablecells")
        btn.toolTip = "复制为 Markdown 表格（按住 ⌥ 点击复制 TSV，可直接粘贴进 Excel / Numbers 分列）"
        btn.isHidden = true
        btn.onClick = { [weak self] in
            guard let self, let tbl = self.currentOutput?.tableResult else { return }
            let useTSV = NSEvent.modifierFlags.contains(.option)
            ClipboardAndSave.copyText(useTSV ? tbl.tsv : tbl.markdown)
            self.statusBadgeLabel.stringValue = useTSV
                ? "✓ 已复制 TSV 表格（\(tbl.rows.count)×\(tbl.columnCount)）"
                : "✓ 已复制 Markdown 表格（\(tbl.rows.count)×\(tbl.columnCount)）"
            self.statusBadgeLabel.textColor = MSnipUITheme.success
            self.relayoutContent()
        }
        root.addSubview(btn)
        self.tableCopyButton = btn
    }

    func applyWindowTheme(dark: Bool) {
        guard let win = window, let root = win.contentView else { return }
        ResultWindowChrome.applyAppearance(to: win, dark: dark)
        if let themeButton { ResultWindowChrome.syncThemeButton(themeButton, dark: dark) }
        ResultWindowChrome.styleCardLayer(leftCard, dark: dark)
        ResultWindowChrome.styleCardLayer(rightCard, dark: dark)
        if let well = leftCard?.subviews.first(where: { $0.identifier?.rawValue == "ImgWell" }) {
            well.layer?.backgroundColor = ResultTheme.cgColor(ResultTheme.subtleFill, dark: dark)
        }
        qrBannerBox?.layer?.backgroundColor = ResultTheme.cgColor(ResultTheme.activeSoftFill, dark: dark)
        transControlStrip?.layer?.backgroundColor = ResultTheme.cgColor(ResultTheme.subtleFill, dark: dark)
        transControlStrip?.layer?.borderColor = ResultTheme.cgColor(ResultTheme.borderHairline, dark: dark)
        transScrollView?.layer?.backgroundColor = ResultTheme.cgColor(ResultTheme.transWellFill, dark: dark)
        ResultWindowChrome.invalidateSubtree(root)
    }

    func buildTranslationSubtree(in rightCard: NSView) {
        let strip = NSView()
        strip.wantsLayer = true
        strip.layer?.backgroundColor = MSnipUITheme.subtleFill.cgColor
        strip.layer?.cornerRadius = 8
        strip.layer?.borderWidth = 1.0
        strip.layer?.borderColor = MSnipUITheme.borderHairline.cgColor

        let badge = NSTextField(labelWithString: "实时译文")
        badge.font = .systemFont(ofSize: 11.5, weight: .semibold)
        badge.textColor = ResultTheme.accent
        strip.addSubview(badge)
        self.transHeaderLabel = badge

        let engPill = LightDropdownPill(symbol: "cpu")
        engPill.onSelect = { [weak self] idx in
            guard let self else { return }
            let list = TranslationService.shared.selectableProfiles
            guard list.indices.contains(idx) else { return }
            let pid = list[idx].id
            self.selectedEngineID = pid
            TranslationService.shared.updateSettings { $0.activeProfileID = pid }
            self.triggerStreamingTranslation()
        }
        strip.addSubview(engPill)
        self.enginePill = engPill

        let langPill = LightDropdownPill(symbol: "globe")
        langPill.customDisplayTitle = TranslationService.shared.settings.targetLang.displayName
        langPill.onCustomClick = { [weak self] anchor in
            guard let self else { return }
            let cur = self.selectedTargetLang ?? TranslationService.shared.settings.targetLang
            LanguagePickerPopover.shared.show(anchoredTo: anchor, current: cur, dark: ResultWindowChrome.prefersDarkAppearance) { [weak self] picked in
                guard let self else { return }
                self.selectedTargetLang = picked
                self.targetLangPill?.customDisplayTitle = picked.displayName
                TranslationService.shared.updateSettings { $0.targetLang = picked }
                self.triggerStreamingTranslation()
            }
        }
        strip.addSubview(langPill)
        self.targetLangPill = langPill

        let cfgBtn = OCRPillButton(title: "接口设置", symbol: "slider.horizontal.3")
        cfgBtn.onClick = { [weak self] in self?.onOpenSettings?() }
        strip.addSubview(cfgBtn)
        self.transConfigBtn = cfgBtn

        strip.isHidden = true
        rightCard.addSubview(strip)
        self.transControlStrip = strip

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
        scroll.wantsLayer = true
        scroll.layer?.backgroundColor = MSnipUITheme.transWellFill.cgColor
        scroll.layer?.cornerRadius = 8
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 340, height: 180))
        tv.minSize = NSSize(width: 0, height: 80)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.drawsBackground = false
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = false
        tv.font = .systemFont(ofSize: 13.5, weight: .regular)
        tv.textColor = ResultTheme.inkTrans
        tv.insertionPointColor = ResultTheme.accent
        tv.textContainerInset = NSSize(width: 10, height: 9)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 5.0
        tv.defaultParagraphStyle = para
        scroll.documentView = tv
        scroll.isHidden = true
        rightCard.addSubview(scroll)
        self.transScrollView = scroll
        self.transTextView = tv
    }

    func refreshTranslationPopups() {
        guard enginePill != nil, targetLangPill != nil else { return }
        let cfg = TranslationService.shared.settings
        let enabled = TranslationService.shared.selectableProfiles
        enginePill.items = enabled.map(\.name)
        let activeID = selectedEngineID ?? cfg.activeProfileID
        if let idx = enabled.firstIndex(where: { $0.id == activeID }) {
            enginePill.selectedIndex = idx
        } else {
            enginePill.selectedIndex = 0
        }

        let target = selectedTargetLang ?? cfg.targetLang
        targetLangPill.customDisplayTitle = target.displayName
    }

    func toggleTranslationPane() {
        isTranslationActive.toggle()
        translateButton.isToggledOn = isTranslationActive
        titleLabel.stringValue = isTranslationActive ? "截图识字与翻译" : "截图提取文字"
        copyButton.title = isTranslationActive ? "复制译文 (⌘↩)" : "复制文本 (⌘↩)"
        relayoutContent()
        if isTranslationActive {
            refreshTranslationPopups()
            triggerStreamingTranslation()
        }
    }

    func triggerStreamingTranslation() {
        guard isTranslationActive else { return }
        let source = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            transTextView.string = "等待识别原文…"
            return
        }

        translationTask?.cancel()
        transTextView.string = "正在翻译…"
        statusBadgeLabel.stringValue = "正在请求翻译…"
        statusBadgeLabel.textColor = MSnipUITheme.accent
        relayoutContent()

        let hostWin = self.window
        let engID = self.selectedEngineID
        let lang = self.selectedTargetLang

        translationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let res = try await TranslationService.shared.translateDocument(
                    text: source,
                    targetOverride: lang,
                    profileOverrideID: engID,
                    hostWindow: hostWin,
                    onStreamChunk: { [weak self] partial in
                        self?.transTextView.string = partial
                    }
                )
                guard !Task.isCancelled else { return }
                self.transTextView.string = res.translatedText
                let fbNote = res.usedFallback ? " (备选)" : ""
                self.statusBadgeLabel.stringValue = "✓ \(res.providerName)\(fbNote) · \(res.elapsedMs)ms"
                self.statusBadgeLabel.textColor = MSnipUITheme.success
                self.relayoutContent()
                if TranslationService.shared.settings.autoCopyTranslation, !res.translatedText.isEmpty {
                    ClipboardAndSave.copyText(res.translatedText)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.transTextView.string = "翻译未完成：\(error.localizedDescription)\n\n点击上方「接口设置」可切换免费的 macOS 原生离线翻译或检查 API Key。"
                self.statusBadgeLabel.stringValue = "翻译未完成"
                self.statusBadgeLabel.textColor = MSnipUITheme.warning
                self.relayoutContent()
            }
        }
    }
}
