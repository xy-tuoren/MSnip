import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// OCR 对照浮窗的视图树组装与自适应栅格布局扩展
extension OCRResultController {
    func ensureWindowCreated() {
        if window != nil { return }

        let win = OCRFloatingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 750, height: 468),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = ""
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.minSize = NSSize(width: 600, height: 360)
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 0.98)
        win.delegate = self
        win.onEscape = { [weak win] in win?.close() }
        win.onQuickCopy = { [weak self] in self?.copyPreferredText() }

        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 750, height: 468))
        root.autoresizingMask = [.width, .height]
        root.material = .hudWindow
        root.blendingMode = .behindWindow
        root.state = .active
        win.contentView = root

        buildSubtree(in: root)
        self.window = win
    }

    private func buildSubtree(in root: NSView) {
        titleLabel = makeLabel("截图提取文字", size: 13.5, weight: .semibold, color: .white)
        root.addSubview(titleLabel)

        statusBadgeLabel = makeLabel("", size: 11.5, weight: .medium, color: .systemGreen)
        root.addSubview(statusBadgeLabel)

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
                ClipboardAndSave.copyText(nextText)
                self.statusBadgeLabel.stringValue = "✓ 已切换并复制 · \(nextText.count) 字"
                self.statusBadgeLabel.textColor = .systemGreen
                self.updateStatsLabel()
            }
        }
        root.addSubview(modeSwitch)

        // 左侧实况文本原图区
        leftCard = makeCardContainer()
        liveImageView = LiveTextImageView(scaling: .scaleProportionallyUpOrDown)
        leftCard.addSubview(liveImageView)
        leftTipLabel = makeLabel("原图支持直接划选局部词句 (⌘C)", size: 11, weight: .regular, color: NSColor(white: 0.62, alpha: 1))
        leftCard.addSubview(leftTipLabel)
        root.addSubview(leftCard)

        // 右侧可编辑文本 + 二维码横幅
        rightCard = makeCardContainer()
        qrBannerBox = NSView()
        qrBannerBox.wantsLayer = true
        qrBannerBox.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        qrBannerBox.layer?.cornerRadius = 7
        qrValueLabel = makeLabel("", size: 11.5, weight: .medium, color: .white)
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
        tv.minSize = NSSize(width: 0, height: contentSz.height)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: contentSz.width, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.drawsBackground = false
        tv.isEditable = true
        tv.isSelectable = true
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = NSFont.systemFont(ofSize: 13.5)
        tv.textColor = NSColor(white: 0.94, alpha: 1)
        tv.insertionPointColor = .controlAccentColor
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.delegate = self
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 4.5
        tv.defaultParagraphStyle = para
        tv.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 13.5),
            .foregroundColor: NSColor(white: 0.94, alpha: 1),
            .paragraphStyle: para
        ]
        textScrollView.documentView = tv
        self.textView = tv
        rightCard.addSubview(textScrollView)
        root.addSubview(rightCard)

        // 底栏
        statsLabel = makeLabel("0 行 · 0 字", size: 11.5, weight: .regular, color: NSColor(white: 0.65, alpha: 1))
        root.addSubview(statsLabel)

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
        let topH: CGFloat = 44, botH: CGFloat = 46

        titleLabel.sizeToFit()
        titleLabel.frame.origin = NSPoint(x: 78, y: round(H - topH + (topH - titleLabel.frame.height) * 0.5))
        statusBadgeLabel.sizeToFit()
        statusBadgeLabel.frame.origin = NSPoint(
            x: titleLabel.frame.maxX + 10,
            y: round(H - topH + (topH - statusBadgeLabel.frame.height) * 0.5)
        )

        let modeSz = modeSwitch.intrinsicContentSize
        modeSwitch.frame = NSRect(x: W - pad - modeSz.width, y: round(H - topH + (topH - modeSz.height) * 0.5), width: modeSz.width, height: modeSz.height)
        let hlSz = highlightButton.intrinsicContentSize
        highlightButton.frame = NSRect(x: modeSwitch.frame.minX - hlSz.width - 8, y: modeSwitch.frame.minY, width: hlSz.width, height: hlSz.height)

        let bodyY = botH
        let bodyH = max(120, H - topH - botH)
        let leftW = round((W - pad * 2 - 12) * 0.46)
        let rightW = W - pad * 2 - 12 - leftW

        leftCard.frame = NSRect(x: pad, y: bodyY, width: leftW, height: bodyH)
        leftTipLabel.sizeToFit()
        leftTipLabel.frame.origin = NSPoint(x: round((leftW - leftTipLabel.frame.width) * 0.5), y: 7)
        liveImageView.frame = NSRect(x: 10, y: 26, width: leftW - 20, height: bodyH - 36)

        rightCard.frame = NSRect(x: pad + leftW + 12, y: bodyY, width: rightW, height: bodyH)
        var editorH = bodyH - 8
        if !qrBannerBox.isHidden {
            let qh: CGFloat = 36
            qrBannerBox.frame = NSRect(x: 8, y: bodyH - qh - 8, width: rightW - 16, height: qh)
            var rightBtnX = qrBannerBox.bounds.width - 6
            if !qrOpenBtn.isHidden {
                let osz = qrOpenBtn.intrinsicContentSize
                rightBtnX -= osz.width
                qrOpenBtn.frame = NSRect(x: rightBtnX, y: 5, width: osz.width, height: 26)
                rightBtnX -= 6
            }
            let csz = qrCopyBtn.intrinsicContentSize
            rightBtnX -= csz.width
            qrCopyBtn.frame = NSRect(x: rightBtnX, y: 5, width: csz.width, height: 26)
            qrValueLabel.frame = NSRect(x: 10, y: 9, width: max(40, rightBtnX - 18), height: 18)
            editorH -= (qh + 6)
        }
        textScrollView.frame = NSRect(x: 4, y: 4, width: rightW - 8, height: max(60, editorH))
        textView.frame.size.width = textScrollView.contentSize.width

        statsLabel.sizeToFit()
        statsLabel.frame.origin = NSPoint(x: pad + 2, y: round((botH - statsLabel.frame.height) * 0.5))
        let psz = pinButton.intrinsicContentSize
        pinButton.frame = NSRect(x: statsLabel.frame.maxX + 12, y: round((botH - psz.height) * 0.5), width: psz.width, height: psz.height)
        let cpSz = copyButton.intrinsicContentSize
        copyButton.frame = NSRect(x: W - pad - cpSz.width, y: round((botH - cpSz.height) * 0.5), width: cpSz.width, height: cpSz.height)
    }

    private func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = NSFont.systemFont(ofSize: size, weight: weight)
        lbl.textColor = color
        return lbl
    }

    private func makeCardContainer() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.32).cgColor
        v.layer?.cornerRadius = 10
        v.layer?.borderWidth = 1.0
        v.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        return v
    }
}
