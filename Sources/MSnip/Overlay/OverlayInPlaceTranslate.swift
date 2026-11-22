import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 截图选区内原位译文覆盖视图（自适应背景取色抹除原文 + 清晰中文译文排版 + 按住左下角对比原图）
final class InPlaceTranslationOverlayView: NSView {
    var baseImage: CGImage? { didSet { needsDisplay = true } }
    var translatedImage: CGImage? { didSet { needsDisplay = true } }
    var statusBanner: String? { didSet { needsDisplay = true } }
    var activeTask: Task<Void, Never>?
    private var comparingOriginal = false { didSet { needsDisplay = true } }

    deinit {
        activeTask?.cancel()
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if translatedImage != nil { comparingOriginal = true }
    }

    override func mouseUp(with event: NSEvent) {
        comparingOriginal = false
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let activeCG = (comparingOriginal ? baseImage : (translatedImage ?? baseImage))
        if let cg = activeCG {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cg, in: bounds)
            ctx.restoreGState()
        }

        if let banner = statusBanner, !banner.isEmpty {
            let ns = banner as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: MSnipUITheme.inkPrimary
            ]
            let sz = ns.size(withAttributes: attrs)
            let w = min(bounds.width - 12, ceil(sz.width + 26))
            let h: CGFloat = 28
            let r = CGRect(x: round((bounds.width - w) * 0.5), y: 8, width: w, height: h)
            MSnipUITheme.drawPorcelainBar(ctx: ctx, bounds: r, radius: 7.5)
            ns.draw(at: CGPoint(x: round(r.minX + 13), y: round(r.minY + (h - sz.height) * 0.5)), withAttributes: attrs)
        } else if translatedImage != nil {
            let hint = (comparingOriginal ? "原图预览中" : "按住画面对比原图") as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: MSnipUITheme.inkPrimary
            ]
            let sz = hint.size(withAttributes: attrs)
            let r = CGRect(x: 8, y: max(6, bounds.height - 28), width: ceil(sz.width + 16), height: 22)
            MSnipUITheme.drawPorcelainBar(ctx: ctx, bounds: r, radius: 6)
            hint.draw(at: CGPoint(x: round(r.minX + 8), y: round(r.minY + (22 - sz.height) * 0.5)), withAttributes: attrs)
        }
    }
}

/// 覆盖层页内原位截图翻译 (`译` / `Y`) 扩展：支持导出/复制/贴出已翻译图片
@MainActor
extension OverlayView {
    func toggleInPlaceTranslate() {
        if toolbar.inPlaceTranslateActive {
            deactivateInPlaceTranslate()
        } else {
            activateInPlaceTranslate()
        }
    }

    func activateInPlaceTranslate() {
        commitTextEditing()
        deactivateInPlaceOCR()
        if selection == nil, let snap = hoveredAutoRect {
            selection = snap
        }
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

        activeTool = nil
        eyedropperActive = false
        selectedObjectIndex = nil
        toolbar.inPlaceTranslateActive = true

        let overlay = inPlaceTranslateView ?? {
            let v = InPlaceTranslationOverlayView(frame: sel)
            addSubview(v, positioned: .below, relativeTo: toolbar)
            inPlaceTranslateView = v
            return v
        }()
        overlay.frame = sel
        overlay.baseImage = baked
        overlay.translatedImage = nil
        let activeName = TranslationService.shared.settings.resolvedActiveProfile?.name ?? "离线翻译"
        overlay.statusBanner = "正在识别并使用「\(activeName)」翻译…"
        overlay.isHidden = false
        updateToolbarLayout()
        needsDisplay = true

        let hostWin = self.window
        overlay.activeTask?.cancel()
        overlay.activeTask = Task { @MainActor [weak self, weak overlay] in
            guard let self, let overlay, !Task.isCancelled, self.toolbar.inPlaceTranslateActive else { return }
            let lines = await VisionTextExtractor.recognizeVisualLinesOffMain(cgImage: baked)
            guard !Task.isCancelled, self.toolbar.inPlaceTranslateActive else { return }
            guard !lines.isEmpty else {
                overlay.statusBanner = nil
                self.deactivateInPlaceTranslate()
                ToastHUD.show(message: "选区内未检测到可翻译的文字")
                return
            }

            do {
                let srcTexts = lines.map(\.text)
                let (translatedLines, usedProvider) = try await TranslationService.shared.translateBatchLines(
                    lines: srcTexts,
                    hostWindow: hostWin
                )
                guard !Task.isCancelled, self.toolbar.inPlaceTranslateActive else { return }
                let rendered = Self.bakeTranslatedBlocks(
                    onto: baked,
                    observations: lines,
                    translations: translatedLines
                )
                overlay.statusBanner = nil
                overlay.translatedImage = rendered
                let joined = translatedLines.joined(separator: "\n")
                if TranslationService.shared.settings.autoCopyTranslation, !joined.isEmpty {
                    ClipboardAndSave.copyText(joined)
                }
                ToastHUD.show(
                    message: "✓ 已通过「\(usedProvider)」原位翻译 · 按 ↩ 复制翻译图或 ⌘2 贴图",
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

    /// 将译文按原文字块位置自适应底色烘焙到高清位图，支持直接导出、保存或贴图
    private static func bakeTranslatedBlocks(
        onto base: CGImage,
        observations: [OCRLineObservation],
        translations: [String]
    ) -> CGImage? {
        let w = base.width, h = base.height
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))

        // 切换为左上角坐标系进行排版绘制
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        defer { NSGraphicsContext.restoreGraphicsState() }

        let sampler = PixelSampler(cgImage: base)
        for (i, obs) in observations.enumerated() where translations.indices.contains(i) {
            let text = translations[i].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let rx = obs.box.minX * CGFloat(w)
            let ry = (1.0 - obs.box.maxY) * CGFloat(h)
            let rw = obs.box.width * CGFloat(w)
            let rh = obs.box.height * CGFloat(h)
            let padX = max(4, rh * 0.18)
            let padY = max(2, rh * 0.12)
            let bgRect = CGRect(
                x: max(2, rx - padX),
                y: max(2, ry - padY),
                width: min(CGFloat(w) - 4, rw + padX * 2),
                height: min(CGFloat(h) - 4, rh + padY * 2)
            )

            // 采样文字框边缘四点推算原界面局部底色与亮暗对比文字色
            let c1 = sampler.sampleRGB(px: Int(bgRect.minX), py: Int(bgRect.midY))
            let c2 = sampler.sampleRGB(px: Int(bgRect.maxX), py: Int(bgRect.midY))
            let c3 = sampler.sampleRGB(px: Int(bgRect.midX), py: Int(bgRect.minY))
            let c4 = sampler.sampleRGB(px: Int(bgRect.midX), py: Int(bgRect.maxY))
            let avgR = (c1.0 + c2.0 + c3.0 + c4.0) / 4
            let avgG = (c1.1 + c2.1 + c3.1 + c4.1) / 4
            let avgB = (c1.2 + c2.2 + c3.2 + c4.2) / 4
            let luma = (avgR * 299 + avgG * 587 + avgB * 114) / 1000

            let bgColor = NSColor(
                srgbRed: CGFloat(avgR) / 255.0,
                green: CGFloat(avgG) / 255.0,
                blue: CGFloat(avgB) / 255.0,
                alpha: 0.96
            )
            let fgColor: NSColor = luma < 138
                ? NSColor(white: 0.97, alpha: 1.0)
                : NSColor(srgbRed: 0.08, green: 0.10, blue: 0.14, alpha: 1.0)

            let path = CGPath(roundedRect: bgRect, cornerWidth: min(6, bgRect.height * 0.22), cornerHeight: min(6, bgRect.height * 0.22), transform: nil)
            ctx.saveGState()
            ctx.setFillColor(bgColor.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()

            // 自适应缩放字号，保证译文完整落入原位框
            var fontPt = min(max(11, rh * 0.76), 44)
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            var attrs: [NSAttributedString.Key: Any] = [:]
            let nsStr = text as NSString
            while fontPt > 9.5 {
                attrs = [
                    .font: NSFont.systemFont(ofSize: fontPt, weight: .medium),
                    .foregroundColor: fgColor,
                    .paragraphStyle: para
                ]
                if nsStr.size(withAttributes: attrs).width <= bgRect.width - 6 { break }
                fontPt -= 1.0
            }
            let measured = nsStr.size(withAttributes: attrs)
            let drawRect = CGRect(
                x: bgRect.minX + 3,
                y: bgRect.minY + max(0, (bgRect.height - measured.height) * 0.5),
                width: bgRect.width - 6,
                height: min(bgRect.height, measured.height + 2)
            )
            nsStr.draw(in: drawRect, withAttributes: attrs)
        }
        return ctx.makeImage()
    }
}
