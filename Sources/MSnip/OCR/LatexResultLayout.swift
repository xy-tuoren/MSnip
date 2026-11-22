import AppKit
import Foundation
import MSnipCore

/// 双栏 LaTeX 数学公式浮窗视图树组装与自适应布局扩展
extension LatexResultController {
    func ensureWindowCreated() {
        if window != nil { return }
        let win = OCRFloatingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 540),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        win.title = ""
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.minSize = NSSize(width: 700, height: 440)
        win.appearance = NSAppearance(named: .aqua)
        win.backgroundColor = MSnipUITheme.canvasBg
        win.delegate = self
        win.onEscape = { [weak win] in win?.close() }
        win.onQuickCopy = { [weak self] in
            guard let self else { return }
            self.copyFormula(as: self.config.preferredWrap)
        }

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 840, height: 540))
        root.wantsLayer = true
        root.layer?.backgroundColor = MSnipUITheme.canvasBg.cgColor
        root.autoresizingMask = [.width, .height]
        win.contentView = root
        buildUI(in: root)
        self.window = win

        configPanel.onSaved = { [weak self] updated in
            guard let self else { return }
            self.config = updated
            self.enginePill.selectedIndex = LatexEngineKind.allCases.firstIndex(of: updated.engineKind) ?? 0
            self.runRecognition()
        }
        configPanel.onOpenMainAISettings = { [weak self] in self?.onOpenMainAISettings?() }
    }

    private func buildUI(in root: NSView) {
        titleLabel = makeLabel("LaTeX 公式识别", size: 14, weight: .bold, color: MSnipUITheme.inkPrimary)
        root.addSubview(titleLabel)
        statusBadgeLabel = makeLabel("", size: 11.5, weight: .medium, color: MSnipUITheme.success)
        statusBadgeLabel.lineBreakMode = .byTruncatingTail
        root.addSubview(statusBadgeLabel)

        enginePill = LightDropdownPill(symbol: "function", items: LatexEngineKind.allCases.map(\.shortName))
        enginePill.onSelect = { [weak self] idx in
            guard let self, LatexEngineKind.allCases.indices.contains(idx) else { return }
            self.config.engineKind = LatexEngineKind.allCases[idx]
            self.config.save()
            self.runRecognition()
        }
        root.addSubview(enginePill)

        retryButton = OCRPillButton(title: "重识", symbol: "arrow.clockwise")
        retryButton.onClick = { [weak self] in self?.runRecognition() }
        root.addSubview(retryButton)

        configButton = OCRPillButton(title: "接口配置", symbol: "slider.horizontal.3")
        configButton.onClick = { [weak self] in self?.configPanel.show(relativeTo: self?.window) }
        root.addSubview(configButton)

        leftCard = makeCard()
        imgWell = NSView(); imgWell.wantsLayer = true
        imgWell.layer?.backgroundColor = MSnipUITheme.subtleFill.cgColor; imgWell.layer?.cornerRadius = 8
        leftCard.addSubview(imgWell)
        imageView = NSImageView(); imageView.imageScaling = .scaleProportionallyDown
        leftCard.addSubview(imageView)
        leftTipLabel = makeLabel("左侧原图对照 · 右侧源码实时联动预览", size: 11, weight: .medium, color: MSnipUITheme.inkMuted)
        leftCard.addSubview(leftTipLabel)
        root.addSubview(leftCard)

        rightCard = makeCard()
        previewTitleLabel = makeLabel("公式渲染预览", size: 11.5, weight: .semibold, color: MSnipUITheme.inkSecondary)
        rightCard.addSubview(previewTitleLabel)
        previewView = LatexPreviewWebView(frame: .zero)
        rightCard.addSubview(previewView)

        noticeBanner = NSView(); noticeBanner.wantsLayer = true
        noticeBanner.layer?.backgroundColor = MSnipUITheme.activeSoftFill.cgColor; noticeBanner.layer?.cornerRadius = 7
        noticeLabel = makeLabel("", size: 11, weight: .medium, color: MSnipUITheme.inkPrimary)
        noticeLabel.lineBreakMode = .byTruncatingTail
        noticeBanner.addSubview(noticeLabel)
        noticeActionBtn = OCRPillButton(title: "去配置")
        noticeActionBtn.onClick = { [weak self] in self?.configPanel.show(relativeTo: self?.window) }
        noticeBanner.addSubview(noticeActionBtn)
        noticeBanner.isHidden = true
        rightCard.addSubview(noticeBanner)

        formatButtons = LatexWrapFormat.allCases.map { fmt in
            let btn = OCRPillButton(title: fmt.shortTitle)
            btn.onClick = { [weak self] in self?.copyFormula(as: fmt) }
            rightCard.addSubview(btn)
            return btn
        }

        codeScrollView = NSScrollView(); codeScrollView.drawsBackground = false; codeScrollView.borderType = .noBorder
        codeScrollView.hasVerticalScroller = true; codeScrollView.autohidesScrollers = true
        codeScrollView.wantsLayer = true; codeScrollView.layer?.backgroundColor = MSnipUITheme.subtleFill.cgColor; codeScrollView.layer?.cornerRadius = 8
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 180))
        tv.isVerticallyResizable = true; tv.isHorizontallyResizable = false; tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true; tv.drawsBackground = false
        tv.isRichText = false; tv.allowsUndo = true; tv.delegate = self
        tv.font = .monospacedSystemFont(ofSize: 13.5, weight: .regular)
        tv.textColor = MSnipUITheme.inkPrimary; tv.insertionPointColor = MSnipUITheme.accent
        tv.textContainerInset = NSSize(width: 10, height: 10)
        codeScrollView.documentView = tv; self.codeTextView = tv
        rightCard.addSubview(codeScrollView)
        root.addSubview(rightCard)

        statsLabel = makeLabel("0 字符", size: 11.5, weight: .medium, color: MSnipUITheme.inkSecondary)
        root.addSubview(statsLabel)
        pinButton = OCRPillButton(title: "贴原图到桌面", symbol: "pin")
        pinButton.onClick = { [weak self] in
            guard let self, let img = self.currentImage, let scr = self.currentScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
            self.onPinImage?(img, self.currentScale, scr)
        }
        root.addSubview(pinButton)
        copyButton = OCRPillButton(title: "复制公式 (⌘↩)", symbol: "doc.on.doc", primary: true)
        copyButton.onClick = { [weak self] in
            guard let self else { return }
            self.copyFormula(as: self.config.preferredWrap)
        }
        root.addSubview(copyButton)
    }

    func relayout() {
        guard let root = window?.contentView else { return }
        let W = root.bounds.width, H = root.bounds.height, pad: CGFloat = 14, topH: CGFloat = 48, botH: CGFloat = 48

        let cfgSz = configButton.intrinsicContentSize
        configButton.frame = NSRect(x: W - pad - cfgSz.width, y: round(H - topH + (topH - cfgSz.height) * 0.5), width: cfgSz.width, height: cfgSz.height)
        let rSz = retryButton.intrinsicContentSize
        retryButton.frame = NSRect(x: configButton.frame.minX - rSz.width - 8, y: configButton.frame.minY, width: rSz.width, height: rSz.height)
        enginePill.frame = NSRect(x: retryButton.frame.minX - 122 - 8, y: configButton.frame.minY, width: 122, height: cfgSz.height)

        titleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(x: 78, y: round(H - topH + (topH - titleLabel.frame.height) * 0.5))
        statusBadgeLabel.sizeToFit()
        let bx = titleLabel.frame.maxX + 10
        statusBadgeLabel.frame = NSRect(
            x: bx, y: round(H - topH + (topH - statusBadgeLabel.frame.height) * 0.5),
            width: max(0, min(statusBadgeLabel.frame.width, enginePill.frame.minX - bx - 10)),
            height: statusBadgeLabel.frame.height
        )

        let bodyH = max(200, H - topH - botH)
        let leftW = round((W - pad * 2 - 12) * 0.40)
        leftCard.frame = NSRect(x: pad, y: botH, width: leftW, height: bodyH)
        imgWell.frame = NSRect(x: 10, y: 30, width: leftW - 20, height: bodyH - 40)
        imageView.frame = imgWell.frame.insetBy(dx: 8, dy: 8)
        leftTipLabel.sizeToFit()
        leftTipLabel.frame.origin = NSPoint(x: 12, y: 10)

        let rightX = leftCard.frame.maxX + 12, rightW = W - rightX - pad
        rightCard.frame = NSRect(x: rightX, y: botH, width: rightW, height: bodyH)
        var topCursor = bodyH - 12

        if !noticeBanner.isHidden {
            let bh: CGFloat = 32
            topCursor -= bh
            noticeBanner.frame = NSRect(x: 10, y: topCursor, width: rightW - 20, height: bh)
            let actSz = noticeActionBtn.intrinsicContentSize
            noticeActionBtn.frame = NSRect(x: noticeBanner.bounds.width - actSz.width - 6, y: round((bh - actSz.height) * 0.5), width: actSz.width, height: actSz.height)
            noticeLabel.frame = NSRect(x: 10, y: 8, width: noticeActionBtn.frame.minX - 16, height: 16)
            topCursor -= 8
        }

        previewTitleLabel.sizeToFit()
        topCursor -= 16
        previewTitleLabel.frame.origin = NSPoint(x: 12, y: topCursor)
        topCursor -= 6

        let prevH = min(136, max(88, round(bodyH * 0.30)))
        topCursor -= prevH
        previewView.frame = NSRect(x: 10, y: topCursor, width: rightW - 20, height: prevH)
        topCursor -= 10

        let fmtH: CGFloat = 26
        topCursor -= fmtH
        var fx: CGFloat = 10
        for btn in formatButtons {
            let bw = btn.intrinsicContentSize.width
            btn.frame = NSRect(x: fx, y: topCursor, width: bw, height: fmtH)
            fx += bw + 6
        }
        topCursor -= 8
        codeScrollView.frame = NSRect(x: 10, y: 10, width: rightW - 20, height: max(64, topCursor - 10))

        statsLabel.sizeToFit()
        statsLabel.frame.origin = NSPoint(x: pad, y: round((botH - statsLabel.frame.height) * 0.5))
        let cpSz = copyButton.intrinsicContentSize
        copyButton.frame = NSRect(x: W - pad - cpSz.width, y: round((botH - cpSz.height) * 0.5), width: cpSz.width, height: cpSz.height)
        let pinSz = pinButton.intrinsicContentSize
        pinButton.frame = NSRect(x: copyButton.frame.minX - pinSz.width - 8, y: copyButton.frame.minY, width: pinSz.width, height: pinSz.height)
    }

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: text); l.font = .systemFont(ofSize: size, weight: weight); l.textColor = color; return l
    }

    private func makeCard() -> NSView {
        let v = NSView(); v.wantsLayer = true
        v.layer?.backgroundColor = MSnipUITheme.cardSolid.cgColor; v.layer?.cornerRadius = 10
        v.layer?.borderWidth = 1; v.layer?.borderColor = MSnipUITheme.borderHairline.cgColor
        return v
    }
}
