import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 双栏对照浮窗流式翻译控制条（自定义清爽胶囊下拉选择器 + 实时流式译文输出）扩展
@MainActor
extension OCRResultController {
    func buildOCREngineControls(in root: NSView) {
        let engPill = LightDropdownPill(symbol: "text.viewfinder", items: OCREngineKind.allCases.map(\.shortName))
        engPill.toolTip = L("快速切换文字识别引擎（Apple 离线 / AI 视觉 / 百度 / 腾讯 / 有道 / 自定义 HTTP）")
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
        cfgBtn.toolTip = L("前往「设置 → 识字与翻译」统一配置 OCR、公式与翻译引擎")
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

    func applyPreRecognizedOutcome(_ out: VisionLLMOCROutcome, on image: CGImage, token: UInt64) {
        attachLiveTextAndBarcodes(for: image, token: token)
        applyNonAppleOutcome(out, autoCopy: false)
    }

    private func attachLiveTextAndBarcodes(for image: CGImage, token: UInt64) {
        Task { @MainActor [weak self] in
            async let liveObj = VisionTextExtractor.analyzeLiveTextOverlay(cgImage: image)
            async let codes = VisionTextExtractor.detectBarcodesOffMain(cgImage: image)
            let (live, qrList) = await (liveObj, codes)
            guard let self, self.requestToken == token else { return }
            self.liveImageView?.applyPrecomputedAnalysis(live, highlightBlocks: self.highlightButton.isToggledOn)
            self.nonAppleQRPayloads = qrList
            if let firstQR = qrList.first {
                self.qrBannerBox.isHidden = false; self.qrValueLabel.stringValue = L("二维码：%@", firstQR)
                let low = firstQR.lowercased(); self.qrOpenBtn.isHidden = !(low.hasPrefix("http://") || low.hasPrefix("https://"))
                self.relayoutContent()
            }
        }
    }

    private func applyNonAppleOutcome(_ out: VisionLLMOCROutcome, autoCopy: Bool) {
        currentOutput = nil; rawNonAppleText = out.text
        let shown = (layoutMode == .mergeParagraphs) ? OCRTextFormatter.mergeTranscriptLines(out.text) : out.text
        textView.string = shown
        if !isTranslationActive {
            if autoCopy && (ocrAutoCopyProvider?() ?? true) {
                ClipboardAndSave.copyText(shown)
                statusBadgeLabel.stringValue = L("✓ %@ · %@ms · 已复制", out.providerName, out.elapsedMs)
            } else {
                statusBadgeLabel.stringValue = "✓ \(out.providerName) · \(out.elapsedMs)ms"
            }
            statusBadgeLabel.textColor = MSnipUITheme.success
        }
        updateStatsLabel(); relayoutContent()
        if isTranslationActive { triggerStreamingTranslation() }
    }

    func runSelectedOCREngine(on image: CGImage, token: UInt64) {
        visionOCRTask?.cancel(); visionOCRTask = nil
        if selectedOCREngine != .appleVision {
            let engine = selectedOCREngine
            let ocrCfg = OCRRecognitionConfig.load()
            let activeID = TranslationService.shared.settings.activeProfileID
            let profiles = VisionLLMOCRService.availableVisionLLMProfiles()
            statusBadgeLabel.stringValue = L("正在用「%@」识别…", engine.shortName)
            statusBadgeLabel.textColor = MSnipUITheme.accent
            tableCopyButton?.isHidden = true; relayoutContent()
            // 仅挂载左图 Live Text + 轻量二维码扫描，绝不冗余跑整套离线 OCR
            attachLiveTextAndBarcodes(for: image, token: token)
            visionOCRTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let out = try await CloudOCRService.recognizeText(
                        image: image, engine: engine, config: ocrCfg, activeProfileID: activeID, profiles: profiles
                    )
                    guard !Task.isCancelled, self.requestToken == token else { return }
                    self.applyNonAppleOutcome(out, autoCopy: true)
                } catch {
                    guard !Task.isCancelled, self.requestToken == token else { return }
                    let warn = L("⚠ %@（已回退离线）", error.localizedDescription)
                    let output = await VisionTextExtractor.recognizeTextOnlyOffMain(cgImage: image, exactCodeMode: self.exactCodeMode)
                    guard !Task.isCancelled, self.requestToken == token else { return }
                    self.applyRecognitionOutput(output, fallbackWarning: warn)
                }
            }
            return
        }
        statusBadgeLabel.stringValue = L("正在离线识别…")
        statusBadgeLabel.textColor = MSnipUITheme.inkSecondary
        relayoutContent()
        VisionTextExtractor.recognizeAsync(from: image, exactCodeMode: exactCodeMode) { [weak self] output in
            guard let self, self.requestToken == token else { return }
            self.applyRecognitionOutput(output)
            self.liveImageView?.applyPrecomputedAnalysis(output.liveAnalysisObject, highlightBlocks: self.highlightButton.isToggledOn)
        }
    }

    func buildTableCopyButton(in root: NSView) {
        let btn = OCRPillButton(title: L("复制表格"), symbol: "tablecells")
        btn.toolTip = L("复制为 Markdown 表格（按住 ⌥ 点击复制 TSV，可直接粘贴进 Excel / Numbers 分列）")
        btn.isHidden = true
        btn.onClick = { [weak self] in
            guard let self, let tbl = self.currentOutput?.tableResult else { return }
            let useTSV = NSEvent.modifierFlags.contains(.option)
            ClipboardAndSave.copyText(useTSV ? tbl.tsv : tbl.markdown)
            self.statusBadgeLabel.stringValue = useTSV
                ? L("✓ 已复制 TSV 表格（%@×%@）", tbl.rows.count, tbl.columnCount)
                : L("✓ 已复制 Markdown 表格（%@×%@）", tbl.rows.count, tbl.columnCount)
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

        let badge = NSTextField(labelWithString: L("实时译文"))
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

        let rtBtn = OCRPillButton(title: L("重译"), symbol: "arrow.clockwise")
        rtBtn.toolTip = L("按当前原文与所选翻译引擎重新翻译")
        rtBtn.onClick = { [weak self] in self?.triggerStreamingTranslation() }
        strip.addSubview(rtBtn); self.retranslateBtn = rtBtn

        let cfgBtn = OCRPillButton(title: L("接口设置"), symbol: "slider.horizontal.3")
        cfgBtn.onClick = { [weak self] in self?.onOpenSettings?() }
        strip.addSubview(cfgBtn); self.transConfigBtn = cfgBtn

        strip.isHidden = true
        rightCard.addSubview(strip)
        self.transControlStrip = strip

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 180))
        scroll.wantsLayer = true; scroll.layer?.backgroundColor = MSnipUITheme.transWellFill.cgColor; scroll.layer?.cornerRadius = 8
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false; scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay; scroll.horizontalScrollElasticity = .none
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 340, height: 180))
        tv.minSize = NSSize(width: 0, height: 80); tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true; tv.isHorizontallyResizable = false; tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true; tv.drawsBackground = false
        tv.isEditable = true; tv.isSelectable = true; tv.isRichText = false
        tv.font = .systemFont(ofSize: 13.5, weight: .regular); tv.textColor = ResultTheme.inkTrans
        tv.insertionPointColor = ResultTheme.accent; tv.textContainerInset = NSSize(width: 10, height: 9)
        let para = NSMutableParagraphStyle(); para.lineSpacing = 5.0; tv.defaultParagraphStyle = para
        scroll.documentView = tv; scroll.isHidden = true; rightCard.addSubview(scroll)
        self.transScrollView = scroll; self.transTextView = tv
    }

    func refreshTranslationPopups() {
        guard enginePill != nil, targetLangPill != nil else { return }
        let cfg = TranslationService.shared.settings
        let enabled = TranslationService.shared.selectableProfiles
        enginePill.items = enabled.map(\.displayName)
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
        titleLabel.stringValue = isTranslationActive ? L("截图识字与翻译") : L("截图提取文字")
        copyButton.title = isTranslationActive ? L("复制译文 (⌘↩)") : L("复制文本 (⌘↩)")
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
            transTextView.string = L("等待识别原文…")
            return
        }

        translationTask?.cancel(); translationToken &+= 1
        let tToken = translationToken
        lastTranslationFailed = false
        transTextView.string = L("正在翻译…")
        statusBadgeLabel.stringValue = L("正在请求翻译…"); statusBadgeLabel.textColor = MSnipUITheme.accent
        relayoutContent()

        let hostWin = self.window; let engID = self.selectedEngineID; let lang = self.selectedTargetLang

        translationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let res = try await TranslationService.shared.translateDocument(
                    text: source, targetOverride: lang, profileOverrideID: engID, hostWindow: hostWin,
                    onStreamChunk: { [weak self] partial in
                        guard let self, self.translationToken == tToken else { return }
                        self.transTextView.string = partial
                    }
                )
                guard !Task.isCancelled, self.translationToken == tToken else { return }
                self.lastTranslationFailed = false
                self.transTextView.string = res.translatedText
                let fbNote = res.usedFallback ? L(" (备选)") : ""
                self.statusBadgeLabel.stringValue = "✓ \(res.providerName)\(fbNote) · \(res.elapsedMs)ms"
                self.statusBadgeLabel.textColor = MSnipUITheme.success; self.relayoutContent()
                if TranslationService.shared.settings.autoCopyTranslation, !res.translatedText.isEmpty {
                    ClipboardAndSave.copyText(res.translatedText)
                }
            } catch {
                guard !Task.isCancelled, self.translationToken == tToken else { return }
                self.lastTranslationFailed = true
                self.transTextView.string = L("翻译未完成：%@\n\n点击上方「接口设置」可切换免费的 macOS 原生离线翻译或检查 API Key。", error.localizedDescription)
                self.statusBadgeLabel.stringValue = L("翻译未完成"); self.statusBadgeLabel.textColor = MSnipUITheme.warning
                self.relayoutContent()
            }
        }
    }
}

// MARK: - 结果浮窗自定义按钮与控件

/// OCR 与翻译对照窗使用的清爽浅色白底胶囊按钮（支持高亮激活态、主色调 CTA 态及手指光标）
final class OCRPillButton: NSView {
    var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var symbolName: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var isToggledOn: Bool = false { didSet { needsDisplay = true } }
    var isPrimaryAccent: Bool = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    private var hovered = false

    override var isFlipped: Bool { true }

    init(title: String, symbol: String? = nil, primary: Bool = false) {
        self.title = title
        self.symbolName = symbol
        self.isPrimaryAccent = primary
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        if title.isEmpty, symbolName != nil {
            return NSSize(width: 28, height: 28)
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]
        let tw = (title as NSString).size(withAttributes: attrs).width
        let iconW: CGFloat = symbolName != nil ? 17 : 0
        return NSSize(width: ceil(tw + iconW + 22), height: 28)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: r, cornerWidth: 7.0, cornerHeight: 7.0, transform: nil)

        ctx.saveGState()
        let fg: NSColor
        if isPrimaryAccent {
            MSnipUITheme.drawPrimaryCTA(ctx: ctx, rect: r, radius: 7.0, hovered: hovered)
            fg = .white
        } else if isToggledOn {
            ctx.setFillColor(ResultTheme.activeSoftFill.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setStrokeColor(ResultTheme.accent.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(1.0)
            ctx.addPath(path)
            ctx.strokePath()
            fg = ResultTheme.accent
        } else {
            ctx.setFillColor((hovered ? ResultTheme.subtleFill : ResultTheme.cardSolid).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setStrokeColor(ResultTheme.borderStrong.cgColor)
            ctx.setLineWidth(1.0)
            ctx.addPath(path)
            ctx.strokePath()
            fg = ResultTheme.inkPrimary
        }

        if title.isEmpty, let sym = symbolName {
            let ir = CGRect(x: round((bounds.width - 14) * 0.5), y: 0, width: 14, height: bounds.height)
            ToolbarView.drawSymbol(sym, in: ir, alpha: 0.96, tint: fg)
            ctx.restoreGState()
            return
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: (isPrimaryAccent || isToggledOn) ? .semibold : .medium),
            .foregroundColor: fg
        ]
        let tSz = (title as NSString).size(withAttributes: attrs)
        var startX = (bounds.width - tSz.width - (symbolName != nil ? 16 : 0)) * 0.5

        if let sym = symbolName {
            let ir = CGRect(x: round(startX), y: 0, width: 14, height: bounds.height)
            ToolbarView.drawSymbol(sym, in: ir, alpha: 0.96, tint: fg)
            startX += 16
        }
        (title as NSString).draw(
            at: CGPoint(x: round(startX), y: round((bounds.height - tSz.height) * 0.5)),
            withAttributes: attrs
        )
        ctx.restoreGState()
    }
}

/// 清爽浅色白底「保持换行 / 合并段落」双态分段切换控件
final class OCRModeSegmentView: NSView {
    var mode: OCRLayoutMode = .preserveLines { didSet { needsDisplay = true } }
    var onModeChanged: ((OCRLayoutMode) -> Void)?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 28) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let target: OCRLayoutMode = p.x < bounds.width * 0.5 ? .preserveLines : .mergeParagraphs
        if target != mode {
            mode = target
            onModeChanged?(target)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let outer = bounds.insetBy(dx: 0.5, dy: 0.5)
        ctx.saveGState()
        ctx.setFillColor(ResultTheme.sidebarBg.cgColor)
        ctx.addPath(CGPath(roundedRect: outer, cornerWidth: 7.0, cornerHeight: 7.0, transform: nil))
        ctx.fillPath()
        ctx.setStrokeColor(ResultTheme.borderHairline.cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(CGPath(roundedRect: outer, cornerWidth: 7.0, cornerHeight: 7.0, transform: nil))
        ctx.strokePath()

        let halfW = (bounds.width - 4) * 0.5
        let selX: CGFloat = mode == .preserveLines ? 2 : (2 + halfW)
        let selRect = CGRect(x: selX, y: 2, width: halfW, height: bounds.height - 4)
        let thumbPath = CGPath(roundedRect: selRect, cornerWidth: 5.5, cornerHeight: 5.5, transform: nil)
        ctx.setFillColor(ResultTheme.cardSolid.cgColor)
        ctx.addPath(thumbPath)
        ctx.fillPath()
        ctx.setStrokeColor(ResultTheme.borderHairline.cgColor)
        ctx.addPath(thumbPath)
        ctx.strokePath()

        let labels: [(String, CGRect, Bool)] = [
            (L("保持换行"), CGRect(x: 2, y: 0, width: halfW, height: bounds.height), mode == .preserveLines),
            (L("合并段落"), CGRect(x: 2 + halfW, y: 0, width: halfW, height: bounds.height), mode == .mergeParagraphs)
        ]
        for (txt, rect, active) in labels {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: active ? .semibold : .medium),
                .foregroundColor: active ? ResultTheme.inkPrimary : ResultTheme.inkSecondary
            ]
            let sz = (txt as NSString).size(withAttributes: attrs)
            (txt as NSString).draw(
                at: CGPoint(x: round(rect.minX + (rect.width - sz.width) * 0.5), y: round((rect.height - sz.height) * 0.5)),
                withAttributes: attrs
            )
        }
        ctx.restoreGState()
    }
}
