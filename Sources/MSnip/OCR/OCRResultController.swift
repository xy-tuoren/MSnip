import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 支持 Esc 键快速关闭与 ⌘↩ 一键复制的 OCR 对照浮窗面板
final class OCRFloatingWindow: NSPanel {
    var onEscape: (() -> Void)?
    var onQuickCopy: (() -> Void)?

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
        return super.performKeyEquivalent(with: event)
    }
}

/// 左图（原生 Live Text 实况划词）+ 右文（可编辑 / 保持换行与合并段落切换 / 二维码提取）对照窗口控制器
@MainActor
final class OCRResultController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    var onPinImage: ((CGImage, CGFloat, NSScreen) -> Void)?

    var window: OCRFloatingWindow?
    var titleLabel: NSTextField!
    var leftCard: NSView!
    var leftTipLabel: NSTextField!
    var liveImageView: LiveTextImageView!
    var statusBadgeLabel: NSTextField!
    var highlightButton: OCRPillButton!
    var modeSwitch: OCRModeSegmentView!
    var rightCard: NSView!
    var qrBannerBox: NSView!
    var qrValueLabel: NSTextField!
    var qrCopyBtn: OCRPillButton!
    var qrOpenBtn: OCRPillButton!
    var textScrollView: NSScrollView!
    var textView: NSTextView!
    var statsLabel: NSTextField!
    var pinButton: OCRPillButton!
    var copyButton: OCRPillButton!

    var currentCGImage: CGImage?
    var currentScale: CGFloat = 2.0
    var currentScreen: NSScreen?
    var currentOutput: OCRRecognitionOutput?
    var layoutMode: OCRLayoutMode = .preserveLines
    var userEditedManually = false
    private var requestToken: UInt64 = 0

    func present(cgImage: CGImage, scaleFactor: CGFloat, screen: NSScreen) {
        self.requestToken &+= 1
        let token = self.requestToken
        self.currentCGImage = cgImage
        self.currentScale = max(1.0, scaleFactor)
        self.currentScreen = screen
        self.currentOutput = nil
        self.userEditedManually = false

        ensureWindowCreated()
        guard let win = window else { return }

        let logicalSize = NSSize(
            width: CGFloat(cgImage.width) / currentScale,
            height: CGFloat(cgImage.height) / currentScale
        )
        liveImageView.setPreviewImageOnly(cgImage: cgImage, logicalSize: logicalSize, highlightBlocks: highlightButton.isToggledOn)
        statusBadgeLabel.stringValue = "正在离线识别…"
        statusBadgeLabel.textColor = NSColor(white: 0.72, alpha: 1)
        textView.string = ""
        qrBannerBox.isHidden = true
        updateStatsLabel()
        relayoutContent()

        if !win.isVisible {
            let vf = screen.visibleFrame
            let w: CGFloat = 750, h: CGFloat = 468
            win.setFrame(NSRect(x: round(vf.midX - w * 0.5), y: round(vf.midY - h * 0.5), width: w, height: h), display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)

        let targetImg = cgImage
        VisionTextExtractor.recognizeAsync(from: targetImg) { [weak self] output in
            guard let self, self.requestToken == token else { return }
            self.applyRecognitionOutput(output)
            self.liveImageView.applyPrecomputedAnalysis(output.liveAnalysisObject, highlightBlocks: self.highlightButton.isToggledOn)
        }
    }

    private func applyRecognitionOutput(_ output: OCRRecognitionOutput) {
        self.currentOutput = output
        if output.isEmpty {
            statusBadgeLabel.stringValue = "未识别到文字或二维码"
            statusBadgeLabel.textColor = .systemOrange
            textView.string = ""
            qrBannerBox.isHidden = true
            updateStatsLabel()
            relayoutContent()
            return
        }

        let body = output.formattedText(for: layoutMode)
        textView.string = body

        let autoClip = output.initialClipboardText
        ClipboardAndSave.copyText(autoClip)
        statusBadgeLabel.stringValue = "✓ 已自动复制 · \(autoClip.count) 字"
        statusBadgeLabel.textColor = .systemGreen

        if let firstQR = output.qrPayloads.first {
            qrBannerBox.isHidden = false
            qrValueLabel.stringValue = "二维码：\(firstQR)"
            let isLink = firstQR.lowercased().hasPrefix("http://") || firstQR.lowercased().hasPrefix("https://")
            qrOpenBtn.isHidden = !isLink
        } else {
            qrBannerBox.isHidden = true
        }
        updateStatsLabel()
        relayoutContent()
    }

    func copyPreferredText() {
        if liveImageView.hasSelection, !liveImageView.selectedText.isEmpty {
            let sel = liveImageView.selectedText
            ClipboardAndSave.copyText(sel)
            statusBadgeLabel.stringValue = "✓ 已复制左图划选（\(sel.count) 字）"
            statusBadgeLabel.textColor = .systemGreen
            return
        }
        let selectedRange = textView.selectedRange()
        if selectedRange.length > 0, let sub = (textView.string as NSString?)?.substring(with: selectedRange) {
            ClipboardAndSave.copyText(sub)
            statusBadgeLabel.stringValue = "✓ 已复制选中文本（\(sub.count) 字）"
            statusBadgeLabel.textColor = .systemGreen
            return
        }
        ClipboardAndSave.copyText(textView.string)
        statusBadgeLabel.stringValue = "✓ 已复制全文（\(textView.string.count) 字）"
        statusBadgeLabel.textColor = .systemGreen
    }

    func updateStatsLabel() {
        let s = textView?.string ?? ""
        let lines = s.isEmpty ? 0 : s.components(separatedBy: .newlines).filter { !$0.isEmpty }.count
        statsLabel?.stringValue = "\(lines) 行 · \(s.count) 字"
    }

    func windowDidResize(_ notification: Notification) { relayoutContent() }
    func textDidChange(_ notification: Notification) { userEditedManually = true; updateStatsLabel() }
}
