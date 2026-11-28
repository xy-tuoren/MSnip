import AppKit
import CoreGraphics
import CoreText
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
        .autoZhEn, .zhHans, .zhHant, .en, .ja, .ko, .fr, .de, .es
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
        let header = NSMenuItem(title: L("切换目标语种并原位重译"), action: nil, keyEquivalent: "")
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
        let dual = NSMenuItem(title: L("打开双栏流式对照窗…"), action: #selector(openDual), keyEquivalent: "")
        dual.target = self
        m.addItem(dual)
        let exitItem = NSMenuItem(title: L("退出原位翻译"), action: #selector(exitTranslate), keyEquivalent: "")
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
        if tr.translatedImage != nil { return tr.comparingOriginal ? L("原图预览中") : L("已翻译 · 按住对比 · 右键切语种") }
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
            ToastHUD.show(message: L("请先框选需要原位翻译的区域"))
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
            v.onStateChanged = { [weak self] in self?.syncGPUChromeLayers(); self?.needsDisplay = true }
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
        let activeName = cfg.resolvedActiveProfile?.displayName ?? L("离线翻译")
        let targetLang = targetLangOverride ?? cfg.targetLang
        overlay.statusBanner = L("正在用「%@」译为%@…", activeName, targetLang.displayName)
        overlay.isHidden = false
        updateToolbarLayout(); syncGPUChromeLayers()
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
                ToastHUD.show(message: L("选区内未检测到可翻译的文字"))
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
                self.syncGPUChromeLayers()
                let joined = translatedLines.joined(separator: "\n")
                if TranslationService.shared.settings.autoCopyTranslation, !joined.isEmpty {
                    ClipboardAndSave.copyText(joined)
                }
                let pinKey = self.toolbar.pinHint.isEmpty ? self.keyUpper(.pin) : self.toolbar.pinHint
                ToastHUD.show(
                    message: L("✓ 已用「%@」译为%@ · ↩ 复制 / %@ 贴图 / 右键切语种", usedProvider, targetLang.displayName, pinKey),
                    actionTitle: L("双栏流式对照 ›"),
                    onAction: { [weak self] in
                        self?.exportAndFinish(mode: .translateWindow)
                    }
                )
            } catch {
                guard !Task.isCancelled else { return }
                overlay.statusBanner = nil
                self.deactivateInPlaceTranslate()
                ToastHUD.show(
                    message: L("翻译失败：%@", error.localizedDescription),
                    actionTitle: L("配置翻译接口 ›"),
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
        updateToolbarLayout(); syncGPUChromeLayers()
        needsDisplay = true
    }
}

// MARK: - 原位译文抹底与贴合渲染器

/// 纯 CoreGraphics + CoreText 段落级原位翻译位图烘焙器（100% 后台线程安全，支持多行自然折行与自适应底色融合）
private enum InPlaceTranslateRenderer {
    static func bakeParagraphBlocks(
        onto base: CGImage,
        blocks: [OCRParagraphBlock],
        translations: [String],
        scaleFactor: CGFloat = 2.0
    ) -> CGImage? {
        let w = base.width, h = base.height, sc = max(1.0, scaleFactor)
        let cs = (base.colorSpace?.model == .rgb && base.colorSpace?.supportsOutput == true)
            ? base.colorSpace!
            : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // 先在原生左下角坐标系绘制原图（CTFramesetter 亦原生工作于左下角坐标系，无需反复翻转 Y 轴）
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        let sampler = PixelSampler(cgImage: base)
        let isSingleShort = (blocks.count == 1 && blocks[0].lineCount == 1)

        for (i, blk) in blocks.enumerated() where translations.indices.contains(i) {
            let text = translations[i].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let lineHPx = max(12, blk.avgLineHeight * CGFloat(h))
            let padX = max(5, lineHPx * 0.22)
            let padY = max(3, lineHPx * 0.16)
            var bx = max(2, blk.box.minX * CGFloat(w) - padX)
            let by = max(2, blk.box.minY * CGFloat(h) - padY)
            var bx2 = min(CGFloat(w) - 2, blk.box.maxX * CGFloat(w) + padX)
            let by2 = min(CGFloat(h) - 2, blk.box.maxY * CGFloat(h) + padY)
            var rect = CGRect(x: bx, y: by, width: max(8, bx2 - bx), height: max(8, by2 - by))

            // 采样外沿 8 点中位底色，抗文字边缘色污染，自动决定深/浅对比字色
            let bgRGB = samplePerimeterColor(sampler: sampler, rectBottomLeft: rect, imgW: w, imgH: h)
            let luma = (bgRGB.0 * 299 + bgRGB.1 * 587 + bgRGB.2 * 114) / 1000
            let bgColor = CGColor(
                srgbRed: CGFloat(bgRGB.0) / 255.0,
                green: CGFloat(bgRGB.1) / 255.0,
                blue: CGFloat(bgRGB.2) / 255.0,
                alpha: 0.96
            )
            let fgColor = luma < 138
                ? CGColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1.0)
                : CGColor(srgbRed: 0.08, green: 0.10, blue: 0.14, alpha: 1.0)

            // 独立单行小标签优先水平适度外扩，避免字号被过度压缩
            if isSingleShort {
                let targetPt = min(max(11 * sc, lineHPx * 0.78), 44 * sc)
                let font = NSFont.systemFont(ofSize: targetPt, weight: .medium)
                let neededW = ceil(CGFloat(CTLineGetTypographicBounds(
                    CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font])),
                    nil, nil, nil
                ))) + 12 * sc
                if neededW > rect.width && CGFloat(w) - 4 > rect.width {
                    let expand = min(CGFloat(w) - 4, neededW)
                    bx = max(2, min(CGFloat(w) - 2 - expand, rect.midX - expand * 0.5))
                    bx2 = min(CGFloat(w) - 2, bx + expand)
                    rect = CGRect(x: bx, y: by, width: max(8, bx2 - bx), height: max(8, by2 - by))
                }
            }

            let radius = min(8 * sc, min(rect.width, rect.height) * 0.18)
            let bgPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.saveGState()
            ctx.setFillColor(bgColor)
            ctx.addPath(bgPath); ctx.fillPath()
            let rimAlpha: CGFloat = (luma < 138) ? 0.10 : 0.06
            let rimGray: CGFloat = (luma < 138) ? 1.0 : 0.0
            ctx.setStrokeColor(CGColor(srgbRed: rimGray, green: rimGray, blue: rimGray, alpha: rimAlpha))
            ctx.setLineWidth(sc)
            ctx.addPath(bgPath); ctx.strokePath()
            ctx.restoreGState()

            drawFittedParagraph(
                text: text,
                in: rect.insetBy(dx: 4 * sc, dy: 2 * sc),
                baseLineHeight: lineHPx,
                scale: sc,
                fgColor: fgColor,
                centered: isSingleShort,
                ctx: ctx
            )
        }
        return ctx.makeImage()
    }

    private static func drawFittedParagraph(
        text: String,
        in box: CGRect,
        baseLineHeight: CGFloat,
        scale sc: CGFloat,
        fgColor: CGColor,
        centered: Bool,
        ctx: CGContext
    ) {
        guard box.width >= 6 * sc, box.height >= 6 * sc else { return }
        let maxPt = min(max(11.0 * sc, baseLineHeight * 0.80), 44.0 * sc)
        let minPt: CGFloat = 8.5 * sc
        let fgKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)

        func makeAttr(_ pt: CGFloat) -> NSAttributedString {
            let pStyle = NSMutableParagraphStyle()
            pStyle.lineBreakMode = .byWordWrapping
            pStyle.lineSpacing = max(1.5, pt * 0.16)
            pStyle.alignment = centered ? .center : .left
            return NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: pt, weight: .medium),
                fgKey: fgColor,
                .paragraphStyle: pStyle
            ])
        }

        // 二分查找可完整容纳于段落框内的最大字号
        var lo = minPt, hi = maxPt, bestPt = minPt
        for _ in 0..<8 {
            let mid = (lo + hi) * 0.5
            let fs = CTFramesetterCreateWithAttributedString(makeAttr(mid))
            let fit = CTFramesetterSuggestFrameSizeWithConstraints(
                fs, CFRange(location: 0, length: 0), nil,
                CGSize(width: box.width, height: .greatestFiniteMagnitude), nil
            )
            if fit.height <= box.height + 1.5 {
                bestPt = mid
                lo = mid
            } else {
                hi = mid
            }
        }

        let finalAttr = makeAttr(bestPt)
        let fs = CTFramesetterCreateWithAttributedString(finalAttr)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(
            fs, CFRange(location: 0, length: 0), nil,
            CGSize(width: box.width, height: .greatestFiniteMagnitude), nil
        )
        let drawH = min(box.height, ceil(fit.height) + 2)
        let yOffset = max(0, (box.height - drawH) * 0.5)
        let frameRect = CGRect(x: box.minX, y: box.minY + yOffset, width: box.width, height: drawH)
        let framePath = CGPath(rect: frameRect, transform: nil)
        let ctFrame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), framePath, nil)

        ctx.saveGState()
        ctx.clip(to: box)
        ctx.textMatrix = .identity
        CTFrameDraw(ctFrame, ctx)
        ctx.restoreGState()
    }

    private static func samplePerimeterColor(
        sampler: PixelSampler,
        rectBottomLeft r: CGRect,
        imgW: Int,
        imgH: Int
    ) -> (Int, Int, Int) {
        // PixelSampler 使用左上角原点 Y 轴
        let topY = max(0, min(imgH - 1, imgH - 1 - Int(r.maxY.rounded())))
        let botY = max(0, min(imgH - 1, imgH - 1 - Int(r.minY.rounded())))
        let midY = (topY + botY) / 2
        let leftX = max(0, min(imgW - 1, Int(r.minX.rounded())))
        let rightX = max(0, min(imgW - 1, Int(r.maxX.rounded())))
        let midX = (leftX + rightX) / 2

        let pts = [
            (leftX, topY), (midX, topY), (rightX, topY),
            (leftX, midY), (rightX, midY),
            (leftX, botY), (midX, botY), (rightX, botY)
        ]
        var rs: [Int] = [], gs: [Int] = [], bs: [Int] = []
        for (px, py) in pts {
            let c = sampler.sampleRGB(px: px, py: py)
            rs.append(c.0); gs.append(c.1); bs.append(c.2)
        }
        rs.sort(); gs.sort(); bs.sort()
        let m = rs.count / 2
        return (rs[m], gs[m], bs[m])
    }
}
