import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 商业级双栏 LaTeX 数学公式识别与实时预览浮窗控制器（视图组装与布局位于 `LatexResultLayout.swift`）
@MainActor
final class LatexResultController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    var onPinImage: ((CGImage, CGFloat, NSScreen) -> Void)?
    var onOpenLatexSettings: (() -> Void)?

    var window: OCRFloatingWindow?
    var titleLabel: NSTextField!
    var statusBadgeLabel: NSTextField!
    var enginePill: LightDropdownPill!
    var retryButton: OCRPillButton!
    var configButton: OCRPillButton!
    var themeButton: OCRPillButton!
    var pinTopButton: OCRPillButton!

    var leftCard: NSView!
    var imgWell: NSView!
    var imageView: NSImageView!
    var leftTipLabel: NSTextField!

    var rightCard: NSView!
    var previewTitleLabel: NSTextField!
    var previewView: LatexPreviewWebView!
    var noticeBanner: NSView!
    var noticeLabel: NSTextField!
    var noticeActionBtn: OCRPillButton!
    var formatButtons: [OCRPillButton] = []
    var codeScrollView: NSScrollView!
    var codeTextView: NSTextView!

    var statsLabel: NSTextField!
    var pinButton: OCRPillButton!
    var copyButton: OCRPillButton!

    lazy var config = LatexRecognitionConfig.load()
    var configObserver: NSObjectProtocol?
    var currentImage: CGImage?
    var currentScale: CGFloat = 2.0
    var currentScreen: NSScreen?
    private var recognitionTask: Task<Void, Never>?
    private var renderDebounceWork: DispatchWorkItem?

    func present(cgImage: CGImage, scaleFactor: CGFloat, screen: NSScreen) {
        config = LatexRecognitionConfig.load()
        currentImage = cgImage
        currentScale = max(1.0, scaleFactor)
        currentScreen = screen
        ensureWindowCreated()
        guard let win = window else { return }

        let logical = NSSize(width: CGFloat(cgImage.width) / currentScale, height: CGFloat(cgImage.height) / currentScale)
        imageView.image = NSImage(cgImage: cgImage, size: logical)
        enginePill.selectedIndex = LatexEngineKind.allCases.firstIndex(of: config.engineKind) ?? 0
        syncFormatPills()
        noticeBanner.isHidden = true
        codeTextView.string = ""
        previewView.render(latex: "")
        updateStatsLabel()
        relayout()

        if !win.isVisible {
            let frame = ResultWindowKind.latex.resolveInitialFrame(
                defaultSize: NSSize(width: 840, height: 540),
                minSize: win.minSize,
                on: screen
            )
            win.setFrame(frame, display: true)
        }
        let pinned = ResultWindowKind.latex.isAlwaysOnTop
        ResultWindowChrome.applyWindowLevel(to: win, alwaysOnTop: pinned)
        if let pinTopButton { ResultWindowChrome.syncPinButton(pinTopButton, alwaysOnTop: pinned) }
        applyWindowTheme(dark: ResultWindowChrome.prefersDarkAppearance)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        runRecognition()
    }

    func runRecognition() {
        guard let img = currentImage else { return }
        recognitionTask?.cancel()
        statusBadgeLabel.stringValue = "正在识别 LaTeX 公式…"
        statusBadgeLabel.textColor = MSnipUITheme.accent
        noticeBanner.isHidden = true
        relayout()

        let cfg = self.config
        let activeID = TranslationService.shared.settings.activeProfileID
        let profiles = LatexRecognitionService.availableVisionLLMProfiles()
        recognitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let res = try await LatexRecognitionService.recognize(image: img, config: cfg, activeProfileID: activeID, visionProfiles: profiles)
                guard !Task.isCancelled else { return }
                self.codeTextView.string = res.rawLatex
                self.previewView.render(latex: res.rawLatex)
                self.updateStatsLabel()

                if let note = res.notice {
                    self.noticeLabel.stringValue = note
                    self.noticeBanner.isHidden = false
                } else {
                    self.noticeBanner.isHidden = true
                }

                if res.rawLatex.isEmpty {
                    self.statusBadgeLabel.stringValue = "未识别到公式内容"
                    self.statusBadgeLabel.textColor = MSnipUITheme.warning
                } else if self.config.autoCopy {
                    ClipboardAndSave.copyText(self.config.preferredWrap.wrap(res.rawLatex))
                    self.statusBadgeLabel.stringValue = "✓ \(res.providerName) · \(res.elapsedMs)ms · 已复制"
                    self.statusBadgeLabel.textColor = MSnipUITheme.success
                } else {
                    self.statusBadgeLabel.stringValue = "✓ \(res.providerName) · \(res.elapsedMs)ms"
                    self.statusBadgeLabel.textColor = MSnipUITheme.success
                }
                self.relayout()
            } catch {
                guard !Task.isCancelled else { return }
                self.statusBadgeLabel.stringValue = "⚠ \(error.localizedDescription)"
                self.statusBadgeLabel.textColor = MSnipUITheme.danger
                self.noticeLabel.stringValue = error.localizedDescription
                self.noticeBanner.isHidden = false
                self.relayout()
            }
        }
    }

    func copyFormula(as format: LatexWrapFormat) {
        let raw = codeTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        config.preferredWrap = format
        config.save()
        syncFormatPills()
        ClipboardAndSave.copyText(format.wrap(raw))
        statusBadgeLabel.stringValue = "✓ 已复制（\(format.shortTitle)）"
        statusBadgeLabel.textColor = MSnipUITheme.success
        relayout()
    }

    func syncFormatPills() {
        for (idx, fmt) in LatexWrapFormat.allCases.enumerated() where formatButtons.indices.contains(idx) {
            formatButtons[idx].isToggledOn = (fmt == config.preferredWrap)
        }
        copyButton?.title = "复制 \(config.preferredWrap.shortTitle) (⌘↩)"
    }

    func updateStatsLabel() {
        let len = codeTextView?.string.count ?? 0
        statsLabel?.stringValue = "\(len) 字符 · 编辑源码实时预览"
    }

    func windowDidResize(_ notification: Notification) { relayout() }

    func windowDidEndLiveResize(_ notification: Notification) {
        if let f = window?.frame { ResultWindowKind.latex.saveFrame(f) }
    }

    func windowDidMove(_ notification: Notification) {
        if let f = window?.frame { ResultWindowKind.latex.saveFrame(f) }
    }

    func windowWillClose(_ notification: Notification) {
        if let f = window?.frame { ResultWindowKind.latex.saveFrame(f) }
        recognitionTask?.cancel()
        recognitionTask = nil
        renderDebounceWork?.cancel()
        renderDebounceWork = nil
        if let obs = configObserver { NotificationCenter.default.removeObserver(obs); configObserver = nil }
        previewView?.teardown()
        previewView = nil
        imageView?.image = nil
        imageView = nil
        currentImage = nil
        currentScreen = nil
        codeTextView?.string = ""
        codeTextView = nil; leftCard = nil; rightCard = nil
        formatButtons.removeAll()
        window?.delegate = nil; window?.contentView = nil; window = nil
    }

    func textDidChange(_ notification: Notification) {
        updateStatsLabel()
        renderDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let tv = self.codeTextView else { return }
                self.previewView?.render(latex: tv.string)
            }
        }
        renderDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }
}
