import AppKit
import CoreGraphics
import Foundation
import MSnipCore

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
        win.minSize = NSSize(width: 700, height: 400)
        win.delegate = self
        win.onEscape = { [weak win] in win?.close() }
        win.onQuickCopy = { [weak self] in self?.copyPreferredText() }

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 840, height: 530))
        root.wantsLayer = true
        root.autoresizingMask = [.width, .height]
        win.contentView = root

        buildSubtree(in: root)
        self.window = win
        applyWindowTheme(dark: ResultWindowChrome.prefersDarkAppearance)
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
        highlightButton.isToggledOn = true
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
            if let out = self.currentOutput {
                let nextText = out.formattedText(for: newMode)
                self.textView.string = nextText
                self.updateStatsLabel()
                if self.isTranslationActive {
                    self.triggerStreamingTranslation()
                } else {
                    ClipboardAndSave.copyText(nextText)
                    self.statusBadgeLabel.stringValue = "✓ 已切换并复制 · \(nextText.count) 字"
                    self.statusBadgeLabel.textColor = MSnipUITheme.success
                    self.relayoutContent()
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
            if let code = self?.currentOutput?.qrPayloads.first {
                ClipboardAndSave.copyText(code)
                self?.statusBadgeLabel.stringValue = "✓ 二维码内容已复制"
            }
        }
        qrBannerBox.addSubview(qrCopyBtn)

        qrOpenBtn = OCRPillButton(title: "打开链接")
        qrOpenBtn.onClick = { [weak self] in
            if let raw = self?.currentOutput?.qrPayloads.first, let url = URL(string: raw) {
                NSWorkspace.shared.open(url)
            }
        }
        qrBannerBox.addSubview(qrOpenBtn)
        rightCard.addSubview(qrBannerBox)

        textScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 300))
        textScrollView.drawsBackground = false
        textScrollView.borderType = .noBorder
        textScrollView.hasVerticalScroller = true
        textScrollView.autohidesScrollers = true
        let contentSz = textScrollView.contentSize
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: contentSz.width, height: contentSz.height))
        tv.minSize = NSSize(width: 0, height: 60)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.drawsBackground = false
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = NSFont.systemFont(ofSize: 13.5)
        tv.textColor = ResultTheme.inkPrimary
        tv.insertionPointColor = ResultTheme.accent
        tv.textContainerInset = NSSize(width: 10, height: 10)
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

        exactModeButton = OCRPillButton(title: "代码防纠错", symbol: "curlybraces")
        exactModeButton.isToggledOn = exactCodeMode
        exactModeButton.onClick = { [weak self] in self?.toggleExactCodeMode() }
        root.addSubview(exactModeButton)

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
            transHeaderLabel.sizeToFit()
            transHeaderLabel.frame.origin = NSPoint(x: 10, y: 10)
            let cfgSz = transConfigBtn.intrinsicContentSize
            transConfigBtn.frame = NSRect(x: sw - cfgSz.width - 4, y: 4, width: cfgSz.width, height: 28)
            let popSpan = max(120, transConfigBtn.frame.minX - transHeaderLabel.frame.maxX - 16)
            let engW = round(popSpan * 0.50)
            let langW = popSpan - engW - 6
            enginePill.frame = NSRect(x: transHeaderLabel.frame.maxX + 8, y: 4, width: engW, height: 28)
            targetLangPill.frame = NSRect(x: enginePill.frame.maxX + 6, y: 4, width: langW, height: 28)
            transTextView.frame.size.width = transScrollView.contentSize.width
        } else {
            transControlStrip.isHidden = true
            transScrollView.isHidden = true
            textScrollView.frame = NSRect(x: 6, y: 6, width: rightW - 12, height: max(60, availTopY - 6))
        }
        textView.frame.size.width = textScrollView.contentSize.width

        statsLabel.sizeToFit()
        statsLabel.frame.origin = NSPoint(x: pad + 2, y: round((botH - statsLabel.frame.height) * 0.5))
        let exSz = exactModeButton.intrinsicContentSize
        exactModeButton.frame = NSRect(x: statsLabel.frame.maxX + 10, y: round((botH - exSz.height) * 0.5), width: exSz.width, height: exSz.height)
        let psz = pinButton.intrinsicContentSize
        pinButton.frame = NSRect(x: exactModeButton.frame.maxX + 8, y: round((botH - psz.height) * 0.5), width: psz.width, height: psz.height)
        let cpSz = copyButton.intrinsicContentSize
        copyButton.frame = NSRect(x: W - pad - cpSz.width, y: round((botH - cpSz.height) * 0.5), width: cpSz.width, height: cpSz.height)
    }

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        ResultWindowChrome.makeLabel(text, size: size, weight: weight, color: color)
    }
}
