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
    var transControlStrip: NSView!
    var transHeaderLabel: NSTextField!
    var enginePill: LightDropdownPill!
    var targetLangPill: LightDropdownPill!
    var transConfigBtn: OCRPillButton!
    var transScrollView: NSScrollView!
    var transTextView: NSTextView!

    var statsLabel: NSTextField!
    var exactModeButton: OCRPillButton!
    var tableCopyButton: OCRPillButton!
    var pinButton: OCRPillButton!
    var copyButton: OCRPillButton!

    var currentCGImage: CGImage?
    var currentScale: CGFloat = 2.0
    var currentScreen: NSScreen?
    var currentOutput: OCRRecognitionOutput?
    var layoutMode: OCRLayoutMode = .preserveLines
    var exactCodeMode: Bool = false
    var isTranslationActive: Bool = false
    var selectedEngineID: UUID?
    var selectedTargetLang: TranslationTargetLang?
    var translationTask: Task<Void, Never>?
    var userEditedManually = false
    var editorFontSize: CGFloat = 13.5
    private var requestToken: UInt64 = 0

    func present(cgImage: CGImage, scaleFactor: CGFloat, screen: NSScreen, autoTranslate: Bool = false) {
        self.requestToken &+= 1
        let token = self.requestToken
        translationTask?.cancel()
        self.currentCGImage = cgImage
        self.currentScale = max(1.0, scaleFactor)
        self.currentScreen = screen
        self.currentOutput = nil
        self.userEditedManually = false
        self.isTranslationActive = autoTranslate
        if autoTranslate { self.layoutMode = .mergeParagraphs }

        ensureWindowCreated()
        guard let win = window else { return }

        modeSwitch.mode = layoutMode
        translateButton.isToggledOn = isTranslationActive
        titleLabel.stringValue = isTranslationActive ? "截图识字与翻译" : "截图提取文字"
        copyButton.title = isTranslationActive ? "复制译文 (⌘↩)" : "复制文本 (⌘↩)"
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
        runOCRPass(on: targetImg, token: token)
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

    private func runOCRPass(on image: CGImage, token: UInt64) {
        VisionTextExtractor.recognizeAsync(from: image, exactCodeMode: exactCodeMode) { [weak self] output in
            guard let self, self.requestToken == token else { return }
            self.applyRecognitionOutput(output)
            self.liveImageView.applyPrecomputedAnalysis(output.liveAnalysisObject, highlightBlocks: self.highlightButton.isToggledOn)
        }
    }

    private func applyRecognitionOutput(_ output: OCRRecognitionOutput) {
        self.currentOutput = output
        if output.isEmpty {
            statusBadgeLabel.stringValue = "未识别到文字或二维码"
            statusBadgeLabel.textColor = MSnipUITheme.warning
            textView.string = ""
            transTextView.string = ""
            qrBannerBox.isHidden = true
            updateStatsLabel()
            relayoutContent()
            return
        }

        let body = output.formattedText(for: layoutMode)
        textView.string = body

        if !isTranslationActive {
            let autoClip = output.initialClipboardText
            if ocrAutoCopyProvider?() ?? true {
                ClipboardAndSave.copyText(autoClip)
                statusBadgeLabel.stringValue = "✓ 已自动复制 · \(autoClip.count) 字"
            } else {
                statusBadgeLabel.stringValue = "✓ 识别完成 · \(autoClip.count) 字"
            }
            statusBadgeLabel.textColor = MSnipUITheme.success
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
        if liveImageView.hasSelection, !liveImageView.selectedText.isEmpty {
            let sel = liveImageView.selectedText
            ClipboardAndSave.copyText(sel)
            statusBadgeLabel.stringValue = "✓ 已复制左图划选（\(sel.count) 字）"
            statusBadgeLabel.textColor = MSnipUITheme.success
            relayoutContent()
            return
        }
        if isTranslationActive {
            let selTrans = transTextView.selectedRange()
            if selTrans.length > 0, let sub = (transTextView.string as NSString?)?.substring(with: selTrans) {
                ClipboardAndSave.copyText(sub)
                statusBadgeLabel.stringValue = "✓ 已复制选中译文（\(sub.count) 字）"
                statusBadgeLabel.textColor = MSnipUITheme.success
                relayoutContent()
                return
            }
            let fullTrans = transTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fullTrans.isEmpty {
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
        translationTask?.cancel()
        translationTask = nil
        currentCGImage = nil
        currentScreen = nil
        currentOutput = nil
        liveImageView?.clearAll()
        textView?.string = ""
        transTextView?.string = ""
    }

    func textDidChange(_ notification: Notification) { userEditedManually = true; updateStatsLabel() }
}
