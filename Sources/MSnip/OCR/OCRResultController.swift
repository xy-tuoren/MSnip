import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 支持 Esc 键快速关闭与 ⌘↩ 一键复制的 OCR / 翻译双栏对照浮窗面板
final class OCRFloatingWindow: NSPanel {
    var onEscape: (() -> Void)?
    var onQuickCopy: (() -> Void)?
    var onFontZoom: ((Int) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command && (event.keyCode == 36 || event.keyCode == 76) {
            onQuickCopy?()
            return true
        }
        if flags == .command || flags == [.command, .shift] {
            let ch = event.charactersIgnoringModifiers ?? ""
            if ch == "=" || ch == "+" { onFontZoom?(1); return true }
            if ch == "-" || ch == "_" { onFontZoom?(-1); return true }
            if ch == "0" { onFontZoom?(0); return true }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// 左图（原生 Live Text 实况划词）+ 右文（可编辑原文 + 流式多引擎译文对照 / 二维码提取）窗口控制器
@MainActor
final class OCRResultController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    var onPinImage: ((CGImage, CGFloat, NSScreen) -> Void)?
    var onRecognizeLatex: ((CGImage, CGFloat, NSScreen) -> Void)?
    var onOpenOCRSettings: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var ocrAutoCopyProvider: (() -> Bool)?

    var window: OCRFloatingWindow?
    var titleLabel: NSTextField!
    var leftCard: NSView!
    var leftTipLabel: NSTextField!
    var liveImageView: LiveTextImageView!
    var statusBadgeLabel: NSTextField!
    var latexButton: OCRPillButton!
    var translateButton: OCRPillButton!
    var highlightButton: OCRPillButton!
    var modeSwitch: OCRModeSegmentView!
    var themeButton: OCRPillButton!
    var pinTopButton: OCRPillButton!
    var rightCard: NSView!
    var qrBannerBox: NSView!
    var qrValueLabel: NSTextField!
    var qrCopyBtn: OCRPillButton!
    var qrOpenBtn: OCRPillButton!
    var textScrollView: NSScrollView!
    var textView: NSTextView!

    // 流式翻译分栏控件
    var transControlStrip: NSView!; var transHeaderLabel: NSTextField!
    var enginePill: LightDropdownPill!; var targetLangPill: LightDropdownPill!
    var retranslateBtn: OCRPillButton!; var transConfigBtn: OCRPillButton!
    var transScrollView: NSScrollView!; var transTextView: NSTextView!

    var statsLabel: NSTextField!; var ocrEnginePill: LightDropdownPill!; var ocrSettingsBtn: OCRPillButton!
    var exactModeButton: OCRPillButton!; var tableCopyButton: OCRPillButton!; var pinButton: OCRPillButton!; var copyButton: OCRPillButton!

    var currentCGImage: CGImage?; var currentScale: CGFloat = 2.0; var currentScreen: NSScreen?
    var currentOutput: OCRRecognitionOutput?; var layoutMode: OCRLayoutMode = .preserveLines
    var exactCodeMode: Bool = false; var isTranslationActive: Bool = false; var lastTranslationFailed: Bool = false
    var selectedOCREngine: OCREngineKind = .appleVision; var rawNonAppleText: String?; var nonAppleQRPayloads: [String] = []
    var selectedEngineID: UUID?; var selectedTargetLang: TranslationTargetLang?
    var translationTask: Task<Void, Never>?; var visionOCRTask: Task<Void, Never>?
    var ocrConfigObserver: NSObjectProtocol?; var appearanceObserver: NSObjectProtocol?; var userEditedManually = false
    var editorFontSize: CGFloat = 13.5; var requestToken: UInt64 = 0; var translationToken: UInt64 = 0

    func present(cgImage: CGImage, scaleFactor: CGFloat, screen: NSScreen, autoTranslate: Bool = false, preRecognized: VisionLLMOCROutcome? = nil) {
        self.requestToken &+= 1; self.translationToken &+= 1
        let token = self.requestToken
        translationTask?.cancel(); visionOCRTask?.cancel()
        self.currentCGImage = cgImage; self.currentScale = max(1.0, scaleFactor); self.currentScreen = screen
        self.currentOutput = nil; self.rawNonAppleText = nil; self.nonAppleQRPayloads = []
        self.userEditedManually = false; self.isTranslationActive = autoTranslate; self.lastTranslationFailed = false
        self.selectedEngineID = nil; self.selectedTargetLang = nil
        self.selectedOCREngine = OCRRecognitionConfig.load().engineKind
        if autoTranslate { self.layoutMode = .mergeParagraphs }

        ensureWindowCreated()
        guard let win = window else { return }

        modeSwitch.mode = layoutMode
        translateButton.isToggledOn = isTranslationActive
        titleLabel.stringValue = isTranslationActive ? "截图识字与翻译" : "截图提取文字"
        copyButton.title = isTranslationActive ? "复制译文 (⌘↩)" : "复制文本 (⌘↩)"
        ocrEnginePill?.selectedIndex = OCREngineKind.allCases.firstIndex(of: selectedOCREngine) ?? 0
        exactModeButton?.isHidden = (selectedOCREngine != .appleVision)
        refreshTranslationPopups()

        let logicalSize = NSSize(
            width: CGFloat(cgImage.width) / currentScale,
            height: CGFloat(cgImage.height) / currentScale
        )
        liveImageView.setPreviewImageOnly(cgImage: cgImage, logicalSize: logicalSize, highlightBlocks: highlightButton.isToggledOn)
        statusBadgeLabel.stringValue = "正在离线识别…"
        statusBadgeLabel.textColor = MSnipUITheme.inkSecondary
        textView.string = ""
        transTextView.string = autoTranslate ? "等待文字识别后立即翻译…" : ""
        qrBannerBox.isHidden = true
        tableCopyButton?.isHidden = true
        updateStatsLabel()
        relayoutContent()

        if !win.isVisible {
            let frame = ResultWindowKind.ocr.resolveInitialFrame(
                defaultSize: NSSize(width: 810, height: 510),
                minSize: win.minSize,
                on: screen
            )
            win.setFrame(frame, display: true)
        }
        let pinned = ResultWindowKind.ocr.isAlwaysOnTop
        ResultWindowChrome.applyWindowLevel(to: win, alwaysOnTop: pinned)
        if let pinTopButton { ResultWindowChrome.syncPinButton(pinTopButton, alwaysOnTop: pinned) }
        applyWindowTheme(dark: ResultWindowChrome.prefersDarkAppearance)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)

        let targetImg = cgImage
        if let pre = preRecognized {
            applyPreRecognizedOutcome(pre, on: targetImg, token: token)
        } else {
            runOCRPass(on: targetImg, token: token)
        }
    }

    func toggleExactCodeMode() {
        exactCodeMode.toggle()
        exactModeButton?.isToggledOn = exactCodeMode
        guard let img = currentCGImage else { return }
        requestToken &+= 1
        let token = requestToken
        statusBadgeLabel.stringValue = exactCodeMode ? "正在按防纠错原样重识…" : "正在按高精度模式重识…"
        statusBadgeLabel.textColor = MSnipUITheme.inkSecondary
        relayoutContent()
        runOCRPass(on: img, token: token)
    }

    func runOCRPass(on image: CGImage, token: UInt64) {
        runSelectedOCREngine(on: image, token: token)
    }

    func applyRecognitionOutput(_ output: OCRRecognitionOutput, fallbackWarning: String? = nil) {
        self.currentOutput = output; self.rawNonAppleText = nil
        if output.isEmpty {
            statusBadgeLabel.stringValue = fallbackWarning ?? "未识别到文字或二维码"
            statusBadgeLabel.textColor = MSnipUITheme.warning
            textView.string = ""; transTextView.string = ""; qrBannerBox.isHidden = true
            updateStatsLabel(); relayoutContent(); return
        }

        let body = output.formattedText(for: layoutMode)
        textView.string = body

        if !isTranslationActive {
            let autoClip = output.initialClipboardText
            if ocrAutoCopyProvider?() ?? true { ClipboardAndSave.copyText(autoClip) }
            if let warn = fallbackWarning {
                statusBadgeLabel.stringValue = warn
                statusBadgeLabel.textColor = MSnipUITheme.warning
            } else {
                statusBadgeLabel.stringValue = (ocrAutoCopyProvider?() ?? true) ? "✓ 已自动复制 · \(autoClip.count) 字" : "✓ 识别完成 · \(autoClip.count) 字"
                statusBadgeLabel.textColor = MSnipUITheme.success
            }
        }

        if let firstQR = output.qrPayloads.first {
            qrBannerBox.isHidden = false
            qrValueLabel.stringValue = "二维码：\(firstQR)"
            let isLink = firstQR.lowercased().hasPrefix("http://") || firstQR.lowercased().hasPrefix("https://")
            qrOpenBtn.isHidden = !isLink
        } else {
            qrBannerBox.isHidden = true
        }
        tableCopyButton?.isHidden = (output.tableResult == nil)
        updateStatsLabel()
        relayoutContent()

        if isTranslationActive {
            triggerStreamingTranslation()
        }
    }

    func copyPreferredText() {
        if liveImageView.hasSelection, liveImageView.copySelectionIfActive() {
            let cnt = liveImageView.selectedText.count
            statusBadgeLabel.stringValue = cnt > 0 ? "✓ 已复制左图划选（\(cnt) 字）" : "✓ 已复制左图划选文本"
            statusBadgeLabel.textColor = MSnipUITheme.success
            relayoutContent()
            return
        }
        if isTranslationActive && !lastTranslationFailed {
            let selTrans = transTextView.selectedRange()
            if selTrans.length > 0, let sub = (transTextView.string as NSString?)?.substring(with: selTrans) {
                ClipboardAndSave.copyText(sub)
                statusBadgeLabel.stringValue = "✓ 已复制选中译文（\(sub.count) 字）"
                statusBadgeLabel.textColor = MSnipUITheme.success
                relayoutContent()
                return
            }
            let fullTrans = transTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            let isPlaceholder = fullTrans.isEmpty || fullTrans == "正在翻译…" || fullTrans == "等待文字识别后立即翻译…" || fullTrans == "等待识别原文…"
            if !isPlaceholder {
                ClipboardAndSave.copyText(fullTrans)
                statusBadgeLabel.stringValue = "✓ 已复制全文译文（\(fullTrans.count) 字）"
                statusBadgeLabel.textColor = MSnipUITheme.success
                relayoutContent()
                return
            }
        }
        let selectedRange = textView.selectedRange()
        if selectedRange.length > 0, let sub = (textView.string as NSString?)?.substring(with: selectedRange) {
            ClipboardAndSave.copyText(sub)
            statusBadgeLabel.stringValue = "✓ 已复制选中文本（\(sub.count) 字）"
            statusBadgeLabel.textColor = MSnipUITheme.success
            relayoutContent()
            return
        }
        ClipboardAndSave.copyText(textView.string)
        statusBadgeLabel.stringValue = "✓ 已复制全文（\(textView.string.count) 字）"
        statusBadgeLabel.textColor = MSnipUITheme.success
        relayoutContent()
    }

    func adjustEditorFontSize(step: Int) {
        editorFontSize = (step == 0) ? 13.5 : min(24.0, max(11.0, editorFontSize + CGFloat(step)))
        let font = NSFont.systemFont(ofSize: editorFontSize)
        for tv in [textView, transTextView] {
            guard let tv else { continue }
            tv.font = font
            var attrs = tv.typingAttributes
            attrs[.font] = font
            tv.typingAttributes = attrs
        }
    }

    func updateStatsLabel() {
        let s = textView?.string ?? ""
        let lines = s.isEmpty ? 0 : s.components(separatedBy: .newlines).filter { !$0.isEmpty }.count
        statsLabel?.stringValue = "\(lines) 行 · \(s.count) 字"
    }

    func windowDidResize(_ notification: Notification) { relayoutContent() }

    func windowDidEndLiveResize(_ notification: Notification) {
        if let f = window?.frame { ResultWindowKind.ocr.saveFrame(f) }
    }

    func windowDidMove(_ notification: Notification) {
        if let f = window?.frame { ResultWindowKind.ocr.saveFrame(f) }
    }

    func windowWillClose(_ notification: Notification) {
        if let f = window?.frame { ResultWindowKind.ocr.saveFrame(f) }
        requestToken &+= 1
        translationTask?.cancel(); translationTask = nil; visionOCRTask?.cancel(); visionOCRTask = nil
        if let obs = ocrConfigObserver { NotificationCenter.default.removeObserver(obs); ocrConfigObserver = nil }
        if let obs = appearanceObserver { NotificationCenter.default.removeObserver(obs); appearanceObserver = nil }
        currentCGImage = nil; currentScreen = nil; currentOutput = nil
        liveImageView?.clearAll()
        textView?.string = ""; transTextView?.string = ""
        window?.delegate = nil; window?.contentView = nil; window = nil
        liveImageView = nil; textView = nil; transTextView = nil; leftCard = nil; rightCard = nil; retranslateBtn = nil
    }

    func textDidChange(_ notification: Notification) { userEditedManually = true; updateStatsLabel() }
}

// MARK: - 视图树组装与自适应布局

/// OCR 与流式双栏对照翻译浮窗（Daylight Porcelain 清爽浅色白底风）视图树组装及自适应布局
extension OCRResultController {
    func ensureWindowCreated() {
        if window != nil { return }

        let win = OCRFloatingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 530),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = ""
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        ResultWindowChrome.applyWindowLevel(to: win, alwaysOnTop: ResultWindowKind.ocr.isAlwaysOnTop)
        win.minSize = NSSize(width: 780, height: 400)
        win.delegate = self
        win.onEscape = { [weak win] in win?.close() }
        win.onQuickCopy = { [weak self] in self?.copyPreferredText() }
        win.onFontZoom = { [weak self] step in self?.adjustEditorFontSize(step: step) }

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 840, height: 530))
        root.wantsLayer = true; root.autoresizingMask = [.width, .height]
        win.contentView = root
        buildSubtree(in: root)
        self.window = win
        applyWindowTheme(dark: ResultWindowChrome.prefersDarkAppearance)
        appearanceObserver = NotificationCenter.default.addObserver(forName: .msnipAppearanceDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applyWindowTheme(dark: ResultWindowChrome.prefersDarkAppearance) }
        }
    }

    private func buildSubtree(in root: NSView) {
        titleLabel = makeLabel("截图提取文字", size: 14, weight: .bold, color: ResultTheme.inkPrimary)
        root.addSubview(titleLabel)

        statusBadgeLabel = makeLabel("", size: 11.5, weight: .medium, color: MSnipUITheme.success)
        statusBadgeLabel.lineBreakMode = .byTruncatingTail
        root.addSubview(statusBadgeLabel)

        latexButton = OCRPillButton(title: "LaTeX", symbol: "function")
        latexButton.onClick = { [weak self] in
            guard let self, let img = self.currentCGImage else { return }
            let scr = self.currentScreen ?? NSScreen.main ?? NSScreen.screens.first
            if let scr { self.onRecognizeLatex?(img, self.currentScale, scr) }
        }
        root.addSubview(latexButton)

        translateButton = OCRPillButton(title: "翻译对照", symbol: "character.bubble")
        translateButton.onClick = { [weak self] in self?.toggleTranslationPane() }
        root.addSubview(translateButton)

        highlightButton = OCRPillButton(title: "高亮字块", symbol: "text.viewfinder")
        highlightButton.isToggledOn = false
        highlightButton.onClick = { [weak self] in
            guard let self else { return }
            self.highlightButton.isToggledOn.toggle()
            self.liveImageView.highlightBlocks = self.highlightButton.isToggledOn
        }
        root.addSubview(highlightButton)

        modeSwitch = OCRModeSegmentView()
        modeSwitch.mode = layoutMode
        modeSwitch.onModeChanged = { [weak self] newMode in
            guard let self else { return }
            self.layoutMode = newMode
            let nextText: String? = self.currentOutput?.formattedText(for: newMode)
                ?? self.rawNonAppleText.map { newMode == .mergeParagraphs ? OCRTextFormatter.mergeTranscriptLines($0) : $0 }
            if let nextText {
                self.textView.string = nextText
                self.updateStatsLabel()
                if self.isTranslationActive {
                    self.triggerStreamingTranslation()
                } else if self.ocrAutoCopyProvider?() ?? true {
                    ClipboardAndSave.copyText(nextText)
                    self.statusBadgeLabel.stringValue = "✓ 已切换并复制 · \(nextText.count) 字"
                    self.statusBadgeLabel.textColor = MSnipUITheme.success; self.relayoutContent()
                }
            }
        }
        root.addSubview(modeSwitch)

        themeButton = ResultWindowChrome.makeThemeButton { [weak self] dark in self?.applyWindowTheme(dark: dark) }
        root.addSubview(themeButton)

        pinTopButton = ResultWindowChrome.makePinButton(kind: .ocr) { [weak self] in self?.window }
        root.addSubview(pinTopButton)

        leftCard = ResultWindowChrome.makeCardContainer()
        let imgWell = NSView()
        imgWell.wantsLayer = true
        imgWell.layer?.cornerRadius = 8
        imgWell.identifier = NSUserInterfaceItemIdentifier("ImgWell")
        leftCard.addSubview(imgWell)

        liveImageView = LiveTextImageView(scaling: .scaleProportionallyUpOrDown)
        leftCard.addSubview(liveImageView)
        leftTipLabel = makeLabel("原图支持直接划选局部词句 (⌘C)", size: 11, weight: .medium, color: ResultTheme.inkMuted)
        leftCard.addSubview(leftTipLabel)
        root.addSubview(leftCard)

        rightCard = ResultWindowChrome.makeCardContainer()
        qrBannerBox = NSView()
        qrBannerBox.wantsLayer = true
        qrBannerBox.layer?.cornerRadius = 8
        qrValueLabel = makeLabel("", size: 11.5, weight: .semibold, color: ResultTheme.inkPrimary)
        qrValueLabel.lineBreakMode = .byTruncatingMiddle
        qrBannerBox.addSubview(qrValueLabel)

        qrCopyBtn = OCRPillButton(title: "复制码值")
        qrCopyBtn.onClick = { [weak self] in
            if let code = self?.currentOutput?.qrPayloads.first ?? self?.nonAppleQRPayloads.first {
                ClipboardAndSave.copyText(code)
                self?.statusBadgeLabel.stringValue = "✓ 二维码内容已复制"
            }
        }
        qrBannerBox.addSubview(qrCopyBtn)

        qrOpenBtn = OCRPillButton(title: "打开链接")
        qrOpenBtn.onClick = { [weak self] in
            if let raw = self?.currentOutput?.qrPayloads.first ?? self?.nonAppleQRPayloads.first, let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
            }
        }
        qrBannerBox.addSubview(qrOpenBtn)
        rightCard.addSubview(qrBannerBox)

        textScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 300))
        textScrollView.drawsBackground = false; textScrollView.borderType = .noBorder
        textScrollView.hasVerticalScroller = true; textScrollView.hasHorizontalScroller = false
        textScrollView.autohidesScrollers = true; textScrollView.scrollerStyle = .overlay; textScrollView.horizontalScrollElasticity = .none
        let tv = NSTextView(frame: NSRect(origin: .zero, size: textScrollView.contentSize))
        tv.minSize = NSSize(width: 0, height: 60)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true; tv.isHorizontallyResizable = false; tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true; tv.drawsBackground = false
        tv.isEditable = true; tv.isSelectable = true; tv.isRichText = false; tv.allowsUndo = true
        tv.font = NSFont.systemFont(ofSize: 13.5); tv.textColor = ResultTheme.inkPrimary
        tv.insertionPointColor = ResultTheme.accent; tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.delegate = self
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 4.5
        tv.defaultParagraphStyle = para
        tv.typingAttributes = [.font: NSFont.systemFont(ofSize: 13.5), .foregroundColor: ResultTheme.inkPrimary, .paragraphStyle: para]
        textScrollView.documentView = tv
        self.textView = tv
        rightCard.addSubview(textScrollView)

        buildTranslationSubtree(in: rightCard)
        root.addSubview(rightCard)

        statsLabel = makeLabel("0 行 · 0 字", size: 11.5, weight: .medium, color: ResultTheme.inkSecondary)
        root.addSubview(statsLabel)
        buildOCREngineControls(in: root)

        exactModeButton = OCRPillButton(title: "代码防纠错", symbol: "curlybraces")
        exactModeButton.isToggledOn = exactCodeMode
        exactModeButton.onClick = { [weak self] in self?.toggleExactCodeMode() }
        root.addSubview(exactModeButton)

        buildTableCopyButton(in: root)

        pinButton = OCRPillButton(title: "贴原图到桌面", symbol: "pin")
        pinButton.onClick = { [weak self] in
            guard let self, let img = self.currentCGImage else { return }
            let scr = self.currentScreen ?? NSScreen.main ?? NSScreen.screens.first
            if let scr { self.onPinImage?(img, self.currentScale, scr) }
        }
        root.addSubview(pinButton)

        copyButton = OCRPillButton(title: "复制文本 (⌘↩)", symbol: "doc.on.doc", primary: true)
        copyButton.onClick = { [weak self] in self?.copyPreferredText() }
        root.addSubview(copyButton)
    }

    func relayoutContent() {
        guard let root = window?.contentView else { return }
        let W = root.bounds.width, H = root.bounds.height
        let pad: CGFloat = 14
        let topH: CGFloat = 48, botH: CGFloat = 48

        let topY = round(H - topH + (topH - 28) * 0.5)
        let pinTopSz = pinTopButton.intrinsicContentSize
        pinTopButton.frame = NSRect(x: W - pad - pinTopSz.width, y: topY, width: pinTopSz.width, height: pinTopSz.height)
        let thSz = themeButton.intrinsicContentSize
        themeButton.frame = NSRect(x: pinTopButton.frame.minX - thSz.width - 6, y: topY, width: thSz.width, height: thSz.height)
        let modeSz = modeSwitch.intrinsicContentSize
        modeSwitch.frame = NSRect(x: themeButton.frame.minX - modeSz.width - 8, y: round(H - topH + (topH - modeSz.height) * 0.5), width: modeSz.width, height: modeSz.height)
        let hlSz = highlightButton.intrinsicContentSize
        highlightButton.frame = NSRect(x: modeSwitch.frame.minX - hlSz.width - 8, y: modeSwitch.frame.minY, width: hlSz.width, height: hlSz.height)
        let trSz = translateButton.intrinsicContentSize
        translateButton.frame = NSRect(x: highlightButton.frame.minX - trSz.width - 8, y: modeSwitch.frame.minY, width: trSz.width, height: trSz.height)
        let lxSz = latexButton.intrinsicContentSize
        latexButton.frame = NSRect(x: translateButton.frame.minX - lxSz.width - 8, y: modeSwitch.frame.minY, width: lxSz.width, height: lxSz.height)

        titleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(x: 78, y: round(H - topH + (topH - titleLabel.frame.height) * 0.5))
        statusBadgeLabel.sizeToFit()
        let badgeX = titleLabel.frame.maxX + 10
        let maxBadgeW = max(0, latexButton.frame.minX - badgeX - 10)
        statusBadgeLabel.frame = NSRect(
            x: badgeX,
            y: round(H - topH + (topH - statusBadgeLabel.frame.height) * 0.5),
            width: min(statusBadgeLabel.frame.width, maxBadgeW),
            height: statusBadgeLabel.frame.height
        )

        let bodyY = botH
        let bodyH = max(150, H - topH - botH)
        let leftW = round((W - pad * 2 - 12) * 0.44)
        let rightW = W - pad * 2 - 12 - leftW

        leftCard.frame = NSRect(x: pad, y: bodyY, width: leftW, height: bodyH)
        if let well = leftCard.subviews.first(where: { $0.identifier?.rawValue == "ImgWell" }) {
            well.frame = NSRect(x: 8, y: 28, width: leftW - 16, height: bodyH - 36)
        }
        leftTipLabel.sizeToFit()
        leftTipLabel.frame.origin = NSPoint(x: round((leftW - leftTipLabel.frame.width) * 0.5), y: 8)
        liveImageView.frame = NSRect(x: 12, y: 32, width: leftW - 24, height: bodyH - 44)

        rightCard.frame = NSRect(x: pad + leftW + 12, y: bodyY, width: rightW, height: bodyH)
        var availTopY = bodyH - 6
        if !qrBannerBox.isHidden {
            let qh: CGFloat = 36
            qrBannerBox.frame = NSRect(x: 8, y: bodyH - qh - 8, width: rightW - 16, height: qh)
            var rightBtnX = qrBannerBox.bounds.width - 6
            if !qrOpenBtn.isHidden {
                let osz = qrOpenBtn.intrinsicContentSize
                rightBtnX -= osz.width
                qrOpenBtn.frame = NSRect(x: rightBtnX, y: 4, width: osz.width, height: 28)
                rightBtnX -= 6
            }
            let csz = qrCopyBtn.intrinsicContentSize
            rightBtnX -= csz.width
            qrCopyBtn.frame = NSRect(x: rightBtnX, y: 4, width: csz.width, height: 28)
            qrValueLabel.frame = NSRect(x: 10, y: 9, width: max(40, rightBtnX - 18), height: 18)
            availTopY = qrBannerBox.frame.minY - 6
        }

        if isTranslationActive {
            transControlStrip.isHidden = false
            transScrollView.isHidden = false
            let stripH: CGFloat = 36
            let srcH = max(72, round((availTopY - 16 - stripH) * 0.36))
            let dstH = max(72, availTopY - 16 - stripH - srcH)
            textScrollView.frame = NSRect(x: 6, y: availTopY - srcH, width: rightW - 12, height: srcH)
            transControlStrip.frame = NSRect(x: 8, y: textScrollView.frame.minY - stripH - 4, width: rightW - 16, height: stripH)
            transScrollView.frame = NSRect(x: 8, y: 8, width: rightW - 16, height: dstH - 4)

            let sw = transControlStrip.bounds.width
            transHeaderLabel.sizeToFit(); transHeaderLabel.frame.origin = NSPoint(x: 10, y: 10)
            let cfgSz = transConfigBtn.intrinsicContentSize
            transConfigBtn.frame = NSRect(x: sw - cfgSz.width - 4, y: 4, width: cfgSz.width, height: 28)
            let rtSz = retranslateBtn.intrinsicContentSize
            retranslateBtn.frame = NSRect(x: transConfigBtn.frame.minX - rtSz.width - 5, y: 4, width: rtSz.width, height: 28)
            let popSpan = max(110, retranslateBtn.frame.minX - transHeaderLabel.frame.maxX - 16)
            let engW = round(popSpan * 0.50), langW = popSpan - engW - 6
            enginePill.frame = NSRect(x: transHeaderLabel.frame.maxX + 8, y: 4, width: engW, height: 28)
            targetLangPill.frame = NSRect(x: enginePill.frame.maxX + 6, y: 4, width: langW, height: 28)
            transTextView.frame.size.width = transScrollView.contentSize.width
        } else {
            transControlStrip.isHidden = true; transScrollView.isHidden = true
            textScrollView.frame = NSRect(x: 6, y: 6, width: rightW - 12, height: max(60, availTopY - 6))
        }
        textView.frame.size.width = textScrollView.contentSize.width

        let cpSz = copyButton.intrinsicContentSize
        copyButton.frame = NSRect(x: W - pad - cpSz.width, y: round((botH - cpSz.height) * 0.5), width: cpSz.width, height: cpSz.height)
        let psz = pinButton.intrinsicContentSize
        pinButton.frame = NSRect(x: copyButton.frame.minX - psz.width - 8, y: round((botH - psz.height) * 0.5), width: psz.width, height: psz.height)
        let leftMaxX = pinButton.frame.minX - 8

        statsLabel.sizeToFit()
        statsLabel.frame.origin = NSPoint(x: pad + 2, y: round((botH - statsLabel.frame.height) * 0.5))
        var nextFooterX = statsLabel.frame.maxX + 8
        if let eng = ocrEnginePill { eng.frame = NSRect(x: nextFooterX, y: round((botH - 28) * 0.5), width: 108, height: 28); nextFooterX = eng.frame.maxX + 6 }
        if let cfgBtn = ocrSettingsBtn { cfgBtn.frame = NSRect(x: nextFooterX, y: round((botH - 28) * 0.5), width: 30, height: 28); nextFooterX = cfgBtn.frame.maxX + 6 }
        if !exactModeButton.isHidden {
            let exSz = exactModeButton.intrinsicContentSize
            exactModeButton.frame = NSRect(x: nextFooterX, y: round((botH - exSz.height) * 0.5), width: min(exSz.width, max(0, leftMaxX - nextFooterX)), height: exSz.height)
            nextFooterX = exactModeButton.frame.maxX + 6
        }
        if let tblBtn = tableCopyButton, !tblBtn.isHidden {
            let tsz = tblBtn.intrinsicContentSize
            tblBtn.frame = NSRect(x: nextFooterX, y: round((botH - tsz.height) * 0.5), width: min(tsz.width, max(0, leftMaxX - nextFooterX)), height: tsz.height)
        }
    }

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        ResultWindowChrome.makeLabel(text, size: size, weight: weight, color: color)
    }
}
