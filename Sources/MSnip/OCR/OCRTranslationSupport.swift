import AppKit
import Foundation
import MSnipCore

/// 双栏对照浮窗流式翻译控制条（自定义清爽胶囊下拉选择器 + 实时流式译文输出）扩展
@MainActor
extension OCRResultController {
    func buildTranslationSubtree(in rightCard: NSView) {
        let strip = NSView()
        strip.wantsLayer = true
        strip.layer?.backgroundColor = MSnipUITheme.subtleFill.cgColor
        strip.layer?.cornerRadius = 8
        strip.layer?.borderWidth = 1.0
        strip.layer?.borderColor = MSnipUITheme.borderHairline.cgColor

        let badge = NSTextField(labelWithString: "实时译文")
        badge.font = .systemFont(ofSize: 11.5, weight: .semibold)
        badge.textColor = MSnipUITheme.accent
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

        let langPill = LightDropdownPill(
            symbol: "globe",
            items: TranslationTargetLang.allCases.map(\.displayName)
        )
        langPill.onSelect = { [weak self] idx in
            guard let self, TranslationTargetLang.allCases.indices.contains(idx) else { return }
            let lang = TranslationTargetLang.allCases[idx]
            self.selectedTargetLang = lang
            TranslationService.shared.updateSettings { $0.targetLang = lang }
            self.triggerStreamingTranslation()
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
        tv.textColor = MSnipUITheme.inkTrans
        tv.insertionPointColor = MSnipUITheme.accent
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
        if let idx = TranslationTargetLang.allCases.firstIndex(of: target) {
            targetLangPill.selectedIndex = idx
        }
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
