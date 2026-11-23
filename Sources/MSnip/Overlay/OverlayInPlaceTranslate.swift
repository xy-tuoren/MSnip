import AppKit
import CoreGraphics
import CoreText
import Foundation
import MSnipCore

/// 截图选区内原位译文覆盖视图（纯画面无遮挡展示译文 + 按住画面即时对比原图，状态提示统一外置到选区外部 HUD）
final class InPlaceTranslationOverlayView: NSView {
    var baseImage: CGImage? { didSet { needsDisplay = true } }
    var translatedImage: CGImage? { didSet { needsDisplay = true; onStateChanged?() } }
    var statusBanner: String? { didSet { needsDisplay = true; onStateChanged?() } }
    var activeTask: Task<Void, Never>?
    var onStateChanged: (() -> Void)?
    private(set) var comparingOriginal = false { didSet { needsDisplay = true; onStateChanged?() } }

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
    }
}

/// 覆盖层页内原位截图翻译 (`译` / `Y`) 扩展：支持导出/复制/贴出已翻译图片
@MainActor
extension OverlayView {
    /// 供选区外部顶部 HUD 胶囊显示翻译进度或对比提示，彻底避免小截图内被气泡遮挡译文
    var inPlaceTranslateHUDTag: String? {
        guard let tr = inPlaceTranslateView, !tr.isHidden else { return nil }
        if let banner = tr.statusBanner, !banner.isEmpty { return banner }
        if tr.translatedImage != nil { return tr.comparingOriginal ? "原图预览中" : "已翻译 · 按住对比原图" }
        return nil
    }
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
            v.onStateChanged = { [weak self] in self?.needsDisplay = true }
            addSubview(v, positioned: .below, relativeTo: toolbar)
            inPlaceTranslateView = v
            return v
        }()
        overlay.frame = sel
        overlay.baseImage = baked
        overlay.translatedImage = nil
        let activeName = TranslationService.shared.settings.resolvedActiveProfile?.name ?? "离线翻译"
        overlay.statusBanner = "正在用「\(activeName)」翻译…"
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
        let cs = (base.colorSpace?.model == .rgb && base.colorSpace?.supportsOutput == true)
            ? base.colorSpace!
            : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
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
        let isSingleLine = (observations.count == 1)
        for (i, obs) in observations.enumerated() where translations.indices.contains(i) {
            let text = translations[i].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let rx = obs.box.minX * CGFloat(w)
            let ry = (1.0 - obs.box.maxY) * CGFloat(h)
            let rw = obs.box.width * CGFloat(w)
            let rh = obs.box.height * CGFloat(h)
            let padX = max(4, rh * 0.20)
            let padY = max(2, rh * 0.14)
            var bx = max(1, rx - padX)
            let by = max(1, ry - padY)
            var bx2 = min(CGFloat(w) - 1, rx + rw + padX)
            let by2 = min(CGFloat(h) - 1, ry + rh + padY)
            var bgRect = CGRect(x: bx, y: by, width: max(4, bx2 - bx), height: max(4, by2 - by))

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
                alpha: 0.98
            )
            let fgColor: NSColor = luma < 138
                ? NSColor(white: 0.97, alpha: 1.0)
                : NSColor(srgbRed: 0.08, green: 0.10, blue: 0.14, alpha: 1.0)

            // 单行小截图若译文比原文略宽，优先利用选区内部留白向两侧延展，避免字号被压成极小字或省略号
            var fontPt = min(max(10, rh * 0.80), 44)
            if isSingleLine {
                let targetFont = NSFont.systemFont(ofSize: fontPt, weight: .medium)
                let neededW = ceil(CGFloat(CTLineGetTypographicBounds(
                    CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: targetFont])),
                    nil, nil, nil
                ))) + 8
                if neededW > bgRect.width && CGFloat(w) - 2 > bgRect.width {
                    let expand = min(CGFloat(w) - 2, neededW)
                    let cx = bgRect.midX
                    bx = max(1, min(CGFloat(w) - 1 - expand, cx - expand * 0.5))
                    bx2 = min(CGFloat(w) - 1, bx + expand)
                    bgRect = CGRect(x: bx, y: by, width: max(4, bx2 - bx), height: max(4, by2 - by))
                }
            }

            let path = CGPath(roundedRect: bgRect, cornerWidth: min(6, bgRect.height * 0.22), cornerHeight: min(6, bgRect.height * 0.22), transform: nil)
            ctx.saveGState()
            ctx.setFillColor(bgColor.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()

            // CoreText 精确缩放与光学居中绘制（绝不因框高略紧被 NSString 丢行裁空）
            let maxW = max(6, bgRect.width - 6)
            let maxH = max(6, bgRect.height - 2)
            var chosenFont = NSFont.systemFont(ofSize: fontPt, weight: .medium)
            var line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: chosenFont, .foregroundColor: fgColor]))
            while fontPt > 8.5 {
                chosenFont = NSFont.systemFont(ofSize: fontPt, weight: .medium)
                let attrs: [NSAttributedString.Key: Any] = [.font: chosenFont, .foregroundColor: fgColor]
                line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
                var asc: CGFloat = 0, desc: CGFloat = 0
                let lw = CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, nil))
                if lw <= maxW && (asc + desc) <= maxH { break }
                fontPt -= 1.0
            }
            let finalAttrs: [NSAttributedString.Key: Any] = [.font: chosenFont, .foregroundColor: fgColor]
            var finalW = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            if finalW > maxW {
                let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: finalAttrs))
                if let trunc = CTLineCreateTruncatedLine(line, Double(maxW), .end, token) {
                    line = trunc
                    finalW = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                }
            }
            let drawX = isSingleLine ? max(bgRect.minX + 3, bgRect.midX - finalW * 0.5) : (bgRect.minX + 3)
            ctx.saveGState()
            ctx.clip(to: bgRect)
            ctx.textMatrix = .identity
            ctx.translateBy(x: 0, y: bgRect.minY + bgRect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textPosition = CGPoint(x: drawX, y: bgRect.midY - chosenFont.capHeight * 0.5)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }
}
