import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 截图选区内原位译文覆盖视图（纯画面无遮挡展示段落级译文 + 按住对比原图 + 右键即时切换目标语言重译）
final class InPlaceTranslationOverlayView: NSView {
    var baseImage: CGImage? { didSet { needsDisplay = true } }
    var translatedImage: CGImage? { didSet { needsDisplay = true; onStateChanged?() } }
    var statusBanner: String? { didSet { needsDisplay = true; onStateChanged?() } }
    var activeTask: Task<Void, Never>?
    var onStateChanged: (() -> Void)?
    var onSwitchTargetLang: ((TranslationTargetLang) -> Void)?
    var onOpenDualPane: (() -> Void)?
    var onExitInPlace: (() -> Void)?
    private(set) var comparingOriginal = false { didSet { needsDisplay = true; onStateChanged?() } }

    private static let quickLangs: [TranslationTargetLang] = [
        .zhHans, .zhHant, .en, .ja, .ko, .fr, .de, .es
    ]

    deinit { activeTask?.cancel() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if translatedImage != nil { comparingOriginal = true }
    }

    override func mouseUp(with event: NSEvent) {
        comparingOriginal = false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        let curLang = TranslationService.shared.settings.targetLang
        let header = NSMenuItem(title: "切换目标语种并原位重译", action: nil, keyEquivalent: "")
        header.isEnabled = false
        m.addItem(header)
        for (i, lang) in Self.quickLangs.enumerated() {
            let item = NSMenuItem(title: lang.displayName, action: #selector(pickTargetLang(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            item.state = (lang == curLang) ? .on : .off
            m.addItem(item)
        }
        m.addItem(.separator())
        let dual = NSMenuItem(title: "打开双栏流式对照窗…", action: #selector(openDual), keyEquivalent: "")
        dual.target = self
        m.addItem(dual)
        let exitItem = NSMenuItem(title: "退出原位翻译", action: #selector(exitTranslate), keyEquivalent: "")
        exitItem.target = self
        m.addItem(exitItem)
        return m
    }

    @objc private func pickTargetLang(_ sender: NSMenuItem) {
        guard Self.quickLangs.indices.contains(sender.tag) else { return }
        onSwitchTargetLang?(Self.quickLangs[sender.tag])
    }

    @objc private func openDual() { onOpenDualPane?() }
    @objc private func exitTranslate() { onExitInPlace?() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let activeCG = comparingOriginal ? baseImage : (translatedImage ?? baseImage)
        if let cg = activeCG {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cg, in: bounds)
            ctx.restoreGState()
        }
    }
}

/// 覆盖层页内段落级原位截图翻译 (`译` / `Y`) 扩展：支持导出/复制/贴出已翻译图片及右键快速切换目标语言
@MainActor
extension OverlayView {
    /// 供选区外部顶部 HUD 胶囊显示翻译进度或对比提示，彻底避免小截图内被气泡遮挡译文
    var inPlaceTranslateHUDTag: String? {
        guard let tr = inPlaceTranslateView, !tr.isHidden else { return nil }
        if let banner = tr.statusBanner, !banner.isEmpty { return banner }
        if tr.translatedImage != nil { return tr.comparingOriginal ? "原图预览中" : "已翻译 · 按住对比 · 右键切语种" }
        return nil
    }

    func toggleInPlaceTranslate() {
        if toolbar.inPlaceTranslateActive {
            deactivateInPlaceTranslate()
        } else {
            activateInPlaceTranslate()
        }
    }

    func activateInPlaceTranslate(targetLangOverride: TranslationTargetLang? = nil) {
        commitTextEditing()
        deactivateInPlaceOCR()
        if selection == nil, let snap = hoveredAutoRect { selection = snap }
        guard let sel = selection, sel.width >= 12, sel.height >= 12 else {
            ToastHUD.show(message: "请先框选需要原位翻译的区域")
            return
        }
        guard let baked = AnnotationRenderer.bakeExportImage(
            sampler: snapshot.sampler,
            selection: sel,
            imageScale: snapshot.scaleFactor,
            annotations: doc.objects
        ) else { return }

        if let lang = targetLangOverride {
            TranslationService.shared.updateSettings { $0.targetLang = lang }
        }

        activeTool = nil
        eyedropperActive = false
        selectedObjectIndex = nil
        toolbar.inPlaceTranslateActive = true

        let overlay = inPlaceTranslateView ?? {
            let v = InPlaceTranslationOverlayView(frame: sel)
            v.onStateChanged = { [weak self] in self?.needsDisplay = true }
            v.onSwitchTargetLang = { [weak self] lang in self?.activateInPlaceTranslate(targetLangOverride: lang) }
            v.onOpenDualPane = { [weak self] in self?.exportAndFinish(mode: .translateWindow) }
            v.onExitInPlace = { [weak self] in self?.deactivateInPlaceTranslate() }
            addSubview(v, positioned: .below, relativeTo: toolbar)
            inPlaceTranslateView = v
            return v
        }()
        overlay.frame = sel
        overlay.baseImage = baked
        overlay.translatedImage = nil
        let cfg = TranslationService.shared.settings
        let activeName = cfg.resolvedActiveProfile?.name ?? "离线翻译"
        let targetLang = targetLangOverride ?? cfg.targetLang
        overlay.statusBanner = "正在用「\(activeName)」译为\(targetLang.displayName)…"
        overlay.isHidden = false
        updateToolbarLayout()
        needsDisplay = true

        let hostWin = self.window
        overlay.activeTask?.cancel()
        overlay.activeTask = Task { @MainActor [weak self, weak overlay] in
            guard let self, let overlay, !Task.isCancelled, self.toolbar.inPlaceTranslateActive else { return }
            let blocks = await VisionTextExtractor.recognizeParagraphsOffMain(cgImage: baked)
            guard !Task.isCancelled, self.toolbar.inPlaceTranslateActive else { return }
            guard !blocks.isEmpty else {
                overlay.statusBanner = nil
                self.deactivateInPlaceTranslate()
                ToastHUD.show(message: "选区内未检测到可翻译的文字")
                return
            }

            do {
                let srcTexts = blocks.map(\.text)
                let (translatedLines, usedProvider) = try await TranslationService.shared.translateBatchLines(
                    lines: srcTexts,
                    targetOverride: targetLang,
                    hostWindow: hostWin
                )
                guard !Task.isCancelled, self.toolbar.inPlaceTranslateActive else { return }
                let imgScale = max(1.0, self.snapshot.scaleFactor)
                let rendered = await Task.detached(priority: .userInitiated) {
                    InPlaceTranslateRenderer.bakeParagraphBlocks(onto: baked, blocks: blocks, translations: translatedLines, scaleFactor: imgScale)
                }.value
                guard !Task.isCancelled, self.toolbar.inPlaceTranslateActive else { return }
                overlay.statusBanner = nil
                overlay.translatedImage = rendered
                let joined = translatedLines.joined(separator: "\n")
                if TranslationService.shared.settings.autoCopyTranslation, !joined.isEmpty {
                    ClipboardAndSave.copyText(joined)
                }
                let pinKey = self.toolbar.pinHint.isEmpty ? self.keyUpper(.pin) : self.toolbar.pinHint
                ToastHUD.show(
                    message: "✓ 已用「\(usedProvider)」译为\(targetLang.displayName) · ↩ 复制 / \(pinKey) 贴图 / 右键切语种",
                    actionTitle: "双栏流式对照 ›",
                    onAction: { [weak self] in
                        self?.exportAndFinish(mode: .translateWindow)
                    }
                )
            } catch {
                guard !Task.isCancelled else { return }
                overlay.statusBanner = nil
                self.deactivateInPlaceTranslate()
                ToastHUD.show(
                    message: "翻译失败：\(error.localizedDescription)",
                    actionTitle: "配置翻译接口 ›",
                    onAction: { [weak self] in
                        self?.onOpenTranslationSettings?()
                    }
                )
            }
        }
    }

    func deactivateInPlaceTranslate() {
        guard toolbar.inPlaceTranslateActive || inPlaceTranslateView != nil else { return }
        toolbar.inPlaceTranslateActive = false
        inPlaceTranslateView?.activeTask?.cancel()
        inPlaceTranslateView?.activeTask = nil
        inPlaceTranslateView?.baseImage = nil
        inPlaceTranslateView?.translatedImage = nil
        inPlaceTranslateView?.removeFromSuperview()
        inPlaceTranslateView = nil
        updateToolbarLayout()
        needsDisplay = true
    }
}
