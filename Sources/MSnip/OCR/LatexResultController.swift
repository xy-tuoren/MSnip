import AppKit
import CoreGraphics
import Foundation
import MSnipCore
import WebKit

/// 商业级双栏 LaTeX 数学公式识别与实时预览浮窗控制器
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
    var appearanceObserver: NSObjectProtocol?
    var codeFontSize: CGFloat = 13.5
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
        statusBadgeLabel.stringValue = L("正在识别 LaTeX 公式…")
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
                    self.noticeLabel.toolTip = note
                    self.noticeBanner.isHidden = false
                } else {
                    self.noticeLabel.toolTip = nil
                    self.noticeBanner.isHidden = true
                }

                if res.rawLatex.isEmpty {
                    self.statusBadgeLabel.stringValue = L("未识别到公式内容")
                    self.statusBadgeLabel.textColor = MSnipUITheme.warning
                } else if self.config.autoCopy {
                    ClipboardAndSave.copyText(self.config.preferredWrap.wrap(res.rawLatex))
                    self.statusBadgeLabel.stringValue = L("✓ %@ · %@ms · 已复制", res.providerName, res.elapsedMs)
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
                self.noticeLabel.toolTip = error.localizedDescription
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
        statusBadgeLabel.stringValue = L("✓ 已复制（%@）", format.shortTitle)
        statusBadgeLabel.textColor = MSnipUITheme.success
        relayout()
    }

    func syncFormatPills() {
        for (idx, fmt) in LatexWrapFormat.allCases.enumerated() where formatButtons.indices.contains(idx) {
            formatButtons[idx].isToggledOn = (fmt == config.preferredWrap)
        }
        copyButton?.title = L("复制 %@ (⌘↩)", config.preferredWrap.shortTitle)
    }

    func adjustCodeFontSize(step: Int) {
        codeFontSize = (step == 0) ? 13.5 : min(24.0, max(11.0, codeFontSize + CGFloat(step)))
        let font = NSFont.monospacedSystemFont(ofSize: codeFontSize, weight: .regular)
        codeTextView?.font = font
        if var attrs = codeTextView?.typingAttributes { attrs[.font] = font; codeTextView?.typingAttributes = attrs }
    }

    func updateStatsLabel() {
        let len = codeTextView?.string.count ?? 0
        statsLabel?.stringValue = L("%@ 字符 · 编辑源码实时预览", len)
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
        if let obs = appearanceObserver { NotificationCenter.default.removeObserver(obs); appearanceObserver = nil }
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

// MARK: - 视图树组装与自适应布局

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
        ResultWindowChrome.applyWindowLevel(to: win, alwaysOnTop: ResultWindowKind.latex.isAlwaysOnTop)
        win.minSize = NSSize(width: 720, height: 440)
        win.delegate = self
        win.onEscape = { [weak win] in win?.close() }
        win.onQuickCopy = { [weak self] in
            guard let self else { return }
            self.copyFormula(as: self.config.preferredWrap)
        }
        win.onFontZoom = { [weak self] step in self?.adjustCodeFontSize(step: step) }

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 840, height: 540))
        root.wantsLayer = true
        root.autoresizingMask = [.width, .height]
        win.contentView = root
        buildUI(in: root)
        self.window = win
        applyWindowTheme(dark: ResultWindowChrome.prefersDarkAppearance)
        configObserver = NotificationCenter.default.addObserver(forName: .msnipOCRLatexConfigChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.config = LatexRecognitionConfig.load()
                self.enginePill?.selectedIndex = LatexEngineKind.allCases.firstIndex(of: self.config.engineKind) ?? 0
                self.syncFormatPills()
            }
        }
        appearanceObserver = NotificationCenter.default.addObserver(forName: .msnipAppearanceDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applyWindowTheme(dark: ResultWindowChrome.prefersDarkAppearance) }
        }
    }

    func applyWindowTheme(dark: Bool) {
        guard let win = window, let root = win.contentView else { return }
        ResultWindowChrome.applyAppearance(to: win, dark: dark)
        if let themeButton { ResultWindowChrome.syncThemeButton(themeButton, dark: dark) }
        ResultWindowChrome.styleCardLayer(leftCard, dark: dark)
        ResultWindowChrome.styleCardLayer(rightCard, dark: dark)
        imgWell?.layer?.backgroundColor = ResultTheme.cgColor(ResultTheme.subtleFill, dark: dark)
        noticeBanner?.layer?.backgroundColor = ResultTheme.cgColor(ResultTheme.activeSoftFill, dark: dark)
        codeScrollView?.layer?.backgroundColor = ResultTheme.cgColor(ResultTheme.subtleFill, dark: dark)
        previewView?.setDarkMode(dark)
        ResultWindowChrome.invalidateSubtree(root)
    }

    private func buildUI(in root: NSView) {
        titleLabel = makeLabel(L("LaTeX 公式识别"), size: 14, weight: .bold, color: ResultTheme.inkPrimary)
        root.addSubview(titleLabel)
        statusBadgeLabel = makeLabel("", size: 11.5, weight: .medium, color: MSnipUITheme.success)
        statusBadgeLabel.lineBreakMode = .byTruncatingTail
        root.addSubview(statusBadgeLabel)

        enginePill = LightDropdownPill(symbol: "function", items: LatexEngineKind.allCases.map(\.shortName))
        enginePill.onSelect = { [weak self] idx in
            guard let self, LatexEngineKind.allCases.indices.contains(idx) else { return }
            self.config.engineKind = LatexEngineKind.allCases[idx]
            self.config.save()
            NotificationCenter.default.post(name: .msnipOCRLatexConfigChanged, object: nil)
            self.runRecognition()
        }
        root.addSubview(enginePill)

        retryButton = OCRPillButton(title: L("重识"), symbol: "arrow.clockwise")
        retryButton.onClick = { [weak self] in self?.runRecognition() }
        root.addSubview(retryButton)

        configButton = OCRPillButton(title: L("设置"), symbol: "slider.horizontal.3")
        configButton.toolTip = L("前往「设置 → 识字与翻译」配置公式引擎与密钥")
        configButton.onClick = { [weak self] in self?.onOpenLatexSettings?() }
        root.addSubview(configButton)

        themeButton = ResultWindowChrome.makeThemeButton { [weak self] dark in self?.applyWindowTheme(dark: dark) }
        root.addSubview(themeButton)

        pinTopButton = ResultWindowChrome.makePinButton(kind: .latex) { [weak self] in self?.window }
        root.addSubview(pinTopButton)

        leftCard = makeCard()
        imgWell = NSView(); imgWell.wantsLayer = true
        imgWell.layer?.cornerRadius = 8
        leftCard.addSubview(imgWell)
        imageView = NSImageView(); imageView.imageScaling = .scaleProportionallyDown
        leftCard.addSubview(imageView)
        leftTipLabel = makeLabel(L("左侧原图对照 · 右侧源码实时联动预览"), size: 11, weight: .medium, color: ResultTheme.inkMuted)
        leftCard.addSubview(leftTipLabel)
        root.addSubview(leftCard)

        rightCard = makeCard()
        previewTitleLabel = makeLabel(L("公式渲染预览"), size: 11.5, weight: .semibold, color: ResultTheme.inkSecondary)
        rightCard.addSubview(previewTitleLabel)
        previewView = LatexPreviewWebView(frame: .zero)
        rightCard.addSubview(previewView)

        noticeBanner = NSView(); noticeBanner.wantsLayer = true
        noticeBanner.layer?.cornerRadius = 7
        noticeLabel = makeLabel("", size: 11, weight: .medium, color: ResultTheme.inkPrimary)
        noticeLabel.lineBreakMode = .byTruncatingTail
        noticeBanner.addSubview(noticeLabel)
        noticeActionBtn = OCRPillButton(title: L("去设置"))
        noticeActionBtn.onClick = { [weak self] in self?.onOpenLatexSettings?() }
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
        codeScrollView.hasVerticalScroller = true; codeScrollView.hasHorizontalScroller = false; codeScrollView.autohidesScrollers = true; codeScrollView.scrollerStyle = .overlay; codeScrollView.horizontalScrollElasticity = .none
        codeScrollView.wantsLayer = true; codeScrollView.layer?.backgroundColor = MSnipUITheme.subtleFill.cgColor; codeScrollView.layer?.cornerRadius = 8
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 180))
        tv.isVerticallyResizable = true; tv.isHorizontallyResizable = false; tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true; tv.drawsBackground = false
        tv.isRichText = false; tv.allowsUndo = true; tv.delegate = self
        tv.font = .monospacedSystemFont(ofSize: 13.5, weight: .regular)
        tv.textColor = ResultTheme.inkPrimary; tv.insertionPointColor = ResultTheme.accent
        tv.textContainerInset = NSSize(width: 10, height: 10)
        codeScrollView.documentView = tv; self.codeTextView = tv
        rightCard.addSubview(codeScrollView)
        root.addSubview(rightCard)

        statsLabel = makeLabel(L("0 字符"), size: 11.5, weight: .medium, color: ResultTheme.inkSecondary)
        root.addSubview(statsLabel)
        pinButton = OCRPillButton(title: L("贴原图到桌面"), symbol: "pin")
        pinButton.onClick = { [weak self] in
            guard let self, let img = self.currentImage, let scr = self.currentScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
            self.onPinImage?(img, self.currentScale, scr)
        }
        root.addSubview(pinButton)
        copyButton = OCRPillButton(title: L("复制公式 (⌘↩)"), symbol: "doc.on.doc", primary: true)
        copyButton.onClick = { [weak self] in
            guard let self else { return }
            self.copyFormula(as: self.config.preferredWrap)
        }
        root.addSubview(copyButton)
    }

    func relayout() {
        guard let root = window?.contentView else { return }
        let W = root.bounds.width, H = root.bounds.height, pad: CGFloat = 14, topH: CGFloat = 48, botH: CGFloat = 48

        let pinTopSz = pinTopButton.intrinsicContentSize
        let topY = round(H - topH + (topH - pinTopSz.height) * 0.5)
        pinTopButton.frame = NSRect(x: W - pad - pinTopSz.width, y: topY, width: pinTopSz.width, height: pinTopSz.height)
        let thSz = themeButton.intrinsicContentSize
        themeButton.frame = NSRect(x: pinTopButton.frame.minX - thSz.width - 6, y: topY, width: thSz.width, height: thSz.height)
        let cfgSz = configButton.intrinsicContentSize
        configButton.frame = NSRect(x: themeButton.frame.minX - cfgSz.width - 8, y: round(H - topH + (topH - cfgSz.height) * 0.5), width: cfgSz.width, height: cfgSz.height)
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
        ResultWindowChrome.makeLabel(text, size: size, weight: weight, color: color)
    }

    private func makeCard() -> NSView {
        ResultWindowChrome.makeCardContainer(cornerRadius: 10)
    }
}

// MARK: - 实时公式渲染预览视图

/// 基于 Apple 原生 `WKWebView` 的实时 LaTeX 数学公式预览视图：
/// - 离线零等待直出 macOS WebKit 原生 C++ MathML 排版（支持分式、根号、上下标、积分求和、矩阵/方程组、希腊字母）；
/// - 在线环境下自动渐进增强为 KaTeX 出版级精排（固定版本 + SRI 完整性校验，CDN 文件被篡改时拒绝执行并保留 MathML）。
final class LatexPreviewWebView: NSView, WKNavigationDelegate {
    private var webView: WKWebView?
    private var isPageLoaded = false
    private var pendingLatex: String = ""
    private var isDarkMode = false

    override init(frame frameRect: NSRect) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let wv = WKWebView(frame: .zero, configuration: cfg)
        self.webView = wv
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = MSnipUITheme.cardSolid.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = MSnipUITheme.borderHairline.cgColor
        layer?.masksToBounds = true

        wv.setValue(false, forKey: "drawsBackground")
        wv.navigationDelegate = self
        wv.autoresizingMask = [.width, .height]
        wv.frame = bounds
        addSubview(wv)
        wv.loadHTMLString(Self.shellHTML, baseURL: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isPageLoaded = true
        setDarkMode(isDarkMode)
        render(latex: pendingLatex)
    }

    func setDarkMode(_ dark: Bool) {
        isDarkMode = dark
        layer?.backgroundColor = ResultTheme.cgColor(ResultTheme.cardSolid, dark: dark)
        layer?.borderColor = ResultTheme.cgColor(ResultTheme.borderHairline, dark: dark)
        if isPageLoaded { webView?.evaluateJavaScript("document.documentElement.dataset.theme='\(dark ? "dark" : "light")';", completionHandler: nil) }
    }

    /// 彻底销毁 WKWebView 渲染内容并断开代理，触发系统立即回收 WebKit XPC 子进程
    func teardown() {
        isPageLoaded = false
        pendingLatex = ""
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.loadHTMLString("", baseURL: nil)
        webView?.removeFromSuperview()
        webView = nil
    }

    func render(latex: String) {
        pendingLatex = latex
        guard isPageLoaded, let webView else { return }
        let clean = LatexPostProcessor.stripFencesAndDelimiters(latex)
        guard let jsonData = try? JSONSerialization.data(withJSONObject: [clean]),
              let arrStr = String(data: jsonData, encoding: .utf8),
              arrStr.count >= 2 else { return }
        let jsLiteral = String(arrStr.dropFirst().dropLast())
        webView.evaluateJavaScript("window.renderMSnipLatex(\(jsLiteral));", completionHandler: nil)
    }

    private static let shellHTML = #"""
    <!doctype html><html><head><meta charset="utf-8">
    <style>
      *{box-sizing:border-box;margin:0;padding:0}
      html,body{width:100%;height:100%;background:transparent;font-family:-apple-system,BlinkMacSystemFont,sans-serif;overflow:auto;}
      #wrap{min-height:100%;display:flex;align-items:center;justify-content:center;padding:12px 16px;color:#141923;}
      .katex-display{margin:0 !important;}
      .katex,math{font-size:1.36em;}
      .empty{font-size:12px;color:#798395;}
      html[data-theme="dark"] #wrap{color:#eef2f7;}
      html[data-theme="dark"] .empty{color:#8b95a5;}
    </style></head><body><div id="wrap"><span class="empty">公式渲染预览</span></div>
    <script>
      (function(){
        // 离线本地壳 0ms 直出原生 MathML，再后台异步按需注入 KaTeX，杜绝 CDN 超时阻塞 didFinish
        setTimeout(function(){
          // SRI 哈希取自 npm 官方 katex-0.16.11.tgz（已与 registry sha512 及 CDN 实际内容交叉核对），升级版本时必须同步重算
          var css=document.createElement('link');css.rel='stylesheet';css.href='https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css';
          css.integrity='sha384-nB0miv6/jRmo5UMMR1wu3Gz6NLsoTkbqJghGIsx//Rlm+ZU03BU6SQNC66uf4l5+';css.crossOrigin='anonymous';document.head.appendChild(css);
          var js=document.createElement('script');js.src='https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js';js.async=true;
          js.integrity='sha384-7zkQWkzuo3B5mTepMUcHkMB5jZaolc2xDwL6VFqjFALcbeS9Ggm/Yr2r3Dy4lfFg';js.crossOrigin='anonymous';
          js.onload=function(){if(window._last!==undefined)window.renderMSnipLatex(window._last);};document.head.appendChild(js);
        }, 0);
        const SYM={alpha:'α',beta:'β',gamma:'γ',delta:'δ',epsilon:'ϵ',varepsilon:'ε',zeta:'ζ',eta:'η',theta:'θ',vartheta:'ϑ',iota:'ι',kappa:'κ',lambda:'λ',mu:'μ',nu:'ν',xi:'ξ',pi:'π',rho:'ρ',sigma:'σ',tau:'τ',upsilon:'υ',phi:'ϕ',varphi:'φ',chi:'χ',psi:'ψ',omega:'ω',Gamma:'Γ',Delta:'Δ',Theta:'Θ',Lambda:'Λ',Xi:'Ξ',Pi:'Π',Sigma:'Σ',Upsilon:'Υ',Phi:'Φ',Psi:'Ψ',Omega:'Ω',infty:'∞',partial:'∂',nabla:'∇',pm:'±',mp:'∓',times:'×',div:'÷',cdot:'⋅',cdots:'⋯',ldots:'…',dots:'…',vdots:'⋮',ddots:'⋱',leq:'≤',le:'≤',geq:'≥',ge:'≥',neq:'≠',ne:'≠',approx:'≈',equiv:'≡',sim:'∼',simeq:'≃',propto:'∝',in:'∈',notin:'∉',subset:'⊂',subseteq:'⊆',supset:'⊃',supseteq:'⊇',cup:'∪',cap:'∩',emptyset:'∅',forall:'∀',exists:'∃',neg:'¬',land:'∧',lor:'∨',to:'→',rightarrow:'→',leftarrow:'←',leftrightarrow:'↔',Rightarrow:'⇒',Leftarrow:'⇐',Leftrightarrow:'⇔',mapsto:'↦',sum:'∑',prod:'∏',coprod:'∐',int:'∫',iint:'∬',iiint:'∭',oint:'∮',prime:'′',angle:'∠',perp:'⊥',parallel:'∥',triangle:'△',star:'⋆',circ:'∘',bullet:'∙',oplus:'⊕',otimes:'⊗'};
        const BIG=new Set(['sum','prod','coprod','lim','sup','inf','max','min']);
        const FN=new Set(['sin','cos','tan','cot','sec','csc','arcsin','arccos','arctan','sinh','cosh','tanh','ln','log','exp','lim','max','min','sup','inf','det','gcd','deg','dim','ker','arg','mod']);
        const ACC={hat:'^',widehat:'^',bar:'¯',overline:'¯',vec:'→',overrightarrow:'→',tilde:'~',widetilde:'~',dot:'˙',ddot:'¨'};
        function esc(s){return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');}
        function texToMathML(src){
          let i=0,n=src.length;
          function skip(){while(i<n&&/\s/.test(src[i]))i++;}
          function grp(){
            skip();if(i>=n)return '<mrow></mrow>';
            if(src[i]==='{'){i++;let r=seq('}');if(src[i]==='}')i++;return '<mrow>'+r+'</mrow>';}
            return atom(false);
          }
          function brk(){
            skip();if(src[i]!=='[')return null;i++;let s='';
            while(i<n&&src[i]!==']')s+=src[i++];if(src[i]===']')i++;
            return '<mrow>'+texInner(s)+'</mrow>';
          }
          function env(name){
            const tag='\\end{'+name+'}',idx=src.indexOf(tag,i);
            const body=idx>=0?src.slice(i,idx):src.slice(i);
            i=idx>=0?idx+tag.length:n;
            const rows=body.split(/\\\\/).filter(r=>r.trim().length>0).map(r=>'<mtr>'+r.split('&').map(c=>'<mtd>'+texInner(c)+'</mtd>').join('')+'</mtr>').join('');
            const tbl='<mtable>'+rows+'</mtable>';
            if(name==='pmatrix')return '<mrow><mo>(</mo>'+tbl+'<mo>)</mo></mrow>';
            if(name==='bmatrix')return '<mrow><mo>[</mo>'+tbl+'<mo>]</mo></mrow>';
            if(name==='vmatrix')return '<mrow><mo>|</mo>'+tbl+'<mo>|</mo></mrow>';
            if(name==='cases')return '<mrow><mo>{</mo>'+tbl+'</mrow>';
            return tbl;
          }
          function atom(withScripts){
            skip();if(i>=n)return '';
            let base='',isBig=false,c=src[i];
            if(c==='{'){base=grp();}
            else if(c==='\\'){
              i++;if(i>=n)return '';
              if(!/[a-zA-Z]/.test(src[i])){
                const ch=src[i++];
                base=(ch===' '||ch===','||ch===';'||ch===':')?'<mspace width="0.22em"/>':(ch==='{'||ch==='}'||ch==='|')?'<mo>'+esc(ch)+'</mo>':'<mtext>'+esc(ch)+'</mtext>';
              }else{
                let cmd='';while(i<n&&/[a-zA-Z]/.test(src[i]))cmd+=src[i++];
                if(cmd==='left'||cmd==='right'){skip();let d=i<n?src[i++]:'';if(d==='\\'&&i<n)d=src[i++];base=(d==='.')?'':'<mo stretchy="true">'+esc(d)+'</mo>';}
                else if(cmd==='frac'||cmd==='dfrac'||cmd==='tfrac'){let a=grp(),b=grp();base='<mfrac>'+a+b+'</mfrac>';}
                else if(cmd==='binom'){let a=grp(),b=grp();base='<mrow><mo>(</mo><mfrac linethickness="0">'+a+b+'</mfrac><mo>)</mo></mrow>';}
                else if(cmd==='sqrt'){let deg=brk(),rad=grp();base=deg?'<mroot>'+rad+deg+'</mroot>':'<msqrt>'+rad+'</msqrt>';}
                else if(cmd==='text'||cmd==='mathrm'||cmd==='operatorname'){skip();if(src[i]==='{'){i++;let t='';while(i<n&&src[i]!=='}')t+=src[i++];if(src[i]==='}')i++;base='<mtext>'+esc(t)+'</mtext>';}else base=grp();}
                else if(cmd==='mathbf'||cmd==='boldsymbol'||cmd==='mathbb'||cmd==='mathcal'){base='<mstyle mathvariant="'+(cmd==='mathbb'?'double-struck':cmd==='mathcal'?'script':'bold')+'">'+grp()+'</mstyle>';}
                else if(cmd==='begin'){skip();let en='';if(src[i]==='{'){i++;while(i<n&&src[i]!=='}')en+=src[i++];if(src[i]==='}')i++;}base=env(en);}
                else if(ACC[cmd]){base='<mover accent="true">'+grp()+'<mo>'+ACC[cmd]+'</mo></mover>';}
                else if(FN.has(cmd)){isBig=BIG.has(cmd);base='<mo movablelimits="false">'+cmd+'</mo>';}
                else if(SYM[cmd]){isBig=BIG.has(cmd);const v=SYM[cmd];base=/[α-ωΑ-Ω∂∇∞]/.test(v)?'<mi>'+v+'</mi>':'<mo>'+v+'</mo>';}
                else base='<mi>'+esc(cmd)+'</mi>';
              }
            }else if(/[0-9]/.test(c)){
              let num='';while(i<n&&/[0-9.]/.test(src[i]))num+=src[i++];base='<mn>'+num+'</mn>';
            }else if(/[a-zA-Z]/.test(c)){
              i++;base='<mi>'+c+'</mi>';
            }else{
              i++;base='<mo>'+esc(c)+'</mo>';
            }
            if(!withScripts)return base;
            let sub=null,sup=null;
            for(let k=0;k<2;k++){
              skip();
              if(src[i]==='_'&&!sub){i++;sub=grp();}
              else if(src[i]==='^'&&!sup){i++;sup=grp();}
              else if(src[i]==="'"&&!sup){let p='';while(src[i]==="'"){p+='′';i++;}sup='<mo>'+p+'</mo>';}
            }
            if(sub&&sup)return isBig?'<munderover>'+base+sub+sup+'</munderover>':'<msubsup>'+base+sub+sup+'</msubsup>';
            if(sub)return isBig?'<munder>'+base+sub+'</munder>':'<msub>'+base+sub+'</msub>';
            if(sup)return isBig?'<mover>'+base+sup+'</mover>':'<msup>'+base+sup+'</msup>';
            return base;
          }
          function seq(stop){
            let out='';
            while(i<n){skip();if(i>=n||(stop&&src[i]===stop))break;out+=atom(true);}
            return out;
          }
          return seq(null);
        }
        function texInner(s){return texToMathML(s);}
        window.renderMSnipLatex=function(tex){
          window._last=tex;
          const el=document.getElementById('wrap');
          if(!tex||!tex.trim()){el.innerHTML='<span class="empty">公式渲染预览</span>';return;}
          if(window.katex){
            try{el.innerHTML=window.katex.renderToString(tex,{displayMode:true,throwOnError:false,strict:false});return;}catch(e){}
          }
          try{
            el.innerHTML='<math xmlns="http://www.w3.org/1998/Math/MathML" display="block"><mrow>'+texToMathML(tex)+'</mrow></math>';
          }catch(e){
            el.textContent=tex;
          }
        };
      })();
    </script></body></html>
    """#
}
