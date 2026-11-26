import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 拼图工作室单张素材模型（支持原位二次编辑/裁剪/旋转，按需懒存初始原图备份以便一键无损还原）
struct CollageSourceItem {
    let id = UUID()
    let title: String
    var cgImage: CGImage
    let scaleFactor: CGFloat
    var thumbnail: NSImage
    var originalBackup: CGImage?
}

/// 拼图与 PDF 合并点阵暗房画布（微点阵舞台背景 + 悬停放大微标 + 点击大图预览 + 右键快捷进入标注编辑）
final class CollagePreviewCanvasView: NSView {
    var isPDFMode: Bool = false { didSet { if oldValue != isPDFMode { hoveredPDFIdx = nil; isHoveringCollage = false; needsDisplay = true } } }
    var previewImage: CGImage? { didSet { needsDisplay = true } }
    var pdfPadPx: Int = 32 { didSet { if isPDFMode && oldValue != pdfPadPx { needsDisplay = true } } }
    var pdfPageItems: [CollageSourceItem] = [] { didSet { if isPDFMode { needsDisplay = true } } }
    var pdfBgStyle: CollageBackgroundStyle = .white { didSet { if isPDFMode { needsDisplay = true } } }
    var pdfCustomBgColor: RGBAColor? { didSet { if isPDFMode { needsDisplay = true } } }
    var pdfGradientPreset: CollageGradientPreset = .aurora { didSet { if isPDFMode { needsDisplay = true } } }
    var pdfPageNumStyle: CollagePDFPageNumberStyle = .chinese { didSet { if isPDFMode { needsDisplay = true } } }
    var pdfWatermarkStyle: CollageWatermarkStyle = .none { didSet { if isPDFMode { needsDisplay = true } } }
    var pdfWatermarkText: String = "" { didSet { if isPDFMode { needsDisplay = true } } }
    var showsCheckerboard: Bool = false { didSet { if oldValue != showsCheckerboard { needsDisplay = true } } }
    var onDropImageURLs: (([URL]) -> Void)?
    var onInspectCollage: (() -> Void)?
    var onEditCollage: (() -> Void)?
    var onInspectPDFPage: ((Int) -> Void)?

    private var isDragTargeted = false { didSet { if oldValue != isDragTargeted { needsDisplay = true } } }
    private var isHoveringCollage = false { didSet { if oldValue != isHoveringCollage { needsDisplay = true } } }
    private var hoveredPDFIdx: Int? { didSet { if oldValue != hoveredPDFIdx { needsDisplay = true } } }
    private var lastCollageRect: CGRect = .zero
    private var lastPDFPageRects: [(Int, CGRect)] = []

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        self.toolTip = "点击预览图可打开全尺寸高清大图（滚轮缩放 · 拖拽平移）"
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func resetCursorRects() {
        if (!isPDFMode && previewImage != nil) || (isPDFMode && !pdfPageItems.isEmpty) {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if isPDFMode { isHoveringCollage = false; hoveredPDFIdx = lastPDFPageRects.first(where: { $0.1.contains(p) })?.0 }
        else { hoveredPDFIdx = nil; isHoveringCollage = (previewImage != nil && lastCollageRect.contains(p)) }
    }

    override func mouseExited(with event: NSEvent) { isHoveringCollage = false; hoveredPDFIdx = nil }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if isPDFMode { if let hit = lastPDFPageRects.first(where: { $0.1.contains(p) }) { onInspectPDFPage?(hit.0) }; return }
        if previewImage != nil && lastCollageRect.contains(p) { onInspectCollage?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !isPDFMode, previewImage != nil else { return nil }
        let m = NSMenu()
        let editIt = NSMenuItem(title: "编辑 / 标注合成拼图…", action: #selector(triggerEditMenu), keyEquivalent: "")
        let zoomIt = NSMenuItem(title: "全尺寸大图预览", action: #selector(triggerZoomMenu), keyEquivalent: "")
        editIt.target = self; zoomIt.target = self
        m.addItem(editIt); m.addItem(zoomIt)
        return m
    }

    @objc private func triggerEditMenu() { onEditCollage?() }
    @objc private func triggerZoomMenu() { onInspectCollage?() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { isDragTargeted = true; return .copy }
    override func draggingExited(_ sender: NSDraggingInfo?) { isDragTargeted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragTargeted = false
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
        onDropImageURLs?(urls); return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let isDark = GeekTheme.isDark
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let bgPath = CGPath(roundedRect: r, cornerWidth: 11.5, cornerHeight: 11.5, transform: nil)

        ctx.saveGState()
        let boardBg = isDark
            ? NSColor(srgbRed: 0.088, green: 0.098, blue: 0.120, alpha: 1.0)
            : NSColor(srgbRed: 0.925, green: 0.936, blue: 0.956, alpha: 1.0)
        ctx.setFillColor(boardBg.cgColor)
        ctx.addPath(bgPath); ctx.fillPath()
        ctx.addPath(bgPath); ctx.clip()

        // 细腻点阵暗房底纹（16pt 栅格微点，增强成品卡片悬浮层次）
        ctx.setFillColor((isDark ? NSColor(white: 1, alpha: 0.055) : NSColor(srgbRed: 0.1, green: 0.16, blue: 0.28, alpha: 0.065)).cgColor)
        let step: CGFloat = 16
        var gy: CGFloat = 12
        while gy < bounds.height - 6 {
            var gx: CGFloat = 12
            while gx < bounds.width - 6 {
                ctx.fillEllipse(in: CGRect(x: gx, y: gy, width: 1.3, height: 1.3))
                gx += step
            }
            gy += step
        }
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(GeekTheme.border.cgColor)
        ctx.setLineWidth(1.0); ctx.addPath(bgPath); ctx.strokePath()
        ctx.restoreGState()

        if isPDFMode { drawPDFPagesPreview(in: ctx, isDark: isDark) }
        else if let cg = previewImage { drawCollagePreview(cg, in: ctx, isDark: isDark) }
        else { drawEmptyHint(in: ctx) }

        if isDragTargeted {
            let dr = bounds.insetBy(dx: 5, dy: 5)
            let dp = CGPath(roundedRect: dr, cornerWidth: 9, cornerHeight: 9, transform: nil)
            ctx.saveGState()
            ctx.setFillColor(GeekTheme.accent.withAlphaComponent(isDark ? 0.18 : 0.10).cgColor)
            ctx.addPath(dp); ctx.fillPath()
            ctx.setStrokeColor(GeekTheme.accent.cgColor)
            ctx.setLineWidth(1.8); ctx.setLineDash(phase: 0, lengths: [6, 4])
            ctx.addPath(dp); ctx.strokePath()
            GeekTheme.drawText("松手即可加入拼图素材", in: dr, font: .systemFont(ofSize: 13.0, weight: .semibold), color: GeekTheme.accent, align: .center)
            ctx.restoreGState()
        }
    }

    private func drawCollagePreview(_ cg: CGImage, in ctx: CGContext, isDark: Bool) {
        let inset = bounds.insetBy(dx: 8, dy: 8)
        let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
        let sc = min(inset.width / max(1, iw), inset.height / max(1, ih))
        let dw = round(iw * sc), dh = round(ih * sc)
        let dst = CGRect(x: round(inset.midX - dw * 0.5), y: round(inset.midY - dh * 0.5), width: dw, height: dh)
        lastCollageRect = dst
        let clip = CGPath(roundedRect: dst, cornerWidth: 6.5, cornerHeight: 6.5, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 14, color: NSColor.black.withAlphaComponent(isDark ? 0.46 : 0.15).cgColor)
        ctx.setFillColor(NSColor.white.cgColor); ctx.addPath(clip); ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(clip); ctx.clip()
        if showsCheckerboard { drawCheckerboard(in: dst, ctx: ctx, isDark: isDark) }
        NSImage(cgImage: cg, size: dst.size).draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(isDark ? 0.35 : 0.08).cgColor)
        ctx.setLineWidth(0.75); ctx.addPath(clip); ctx.strokePath()
        ctx.restoreGState()

        if isHoveringCollage && dst.width >= 68 && dst.height >= 28 { drawZoomHintPill(in: ctx, anchorRect: dst) }
    }

    private func drawZoomHintPill(in ctx: CGContext, anchorRect: CGRect) {
        let pill = CGRect(x: anchorRect.maxX - 58, y: anchorRect.maxY - 26, width: 52, height: 20)
        let pp = CGPath(roundedRect: pill, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.64).cgColor); ctx.addPath(pp); ctx.fillPath()
        ToolbarView.drawSymbol("magnifyingglass", in: CGRect(x: pill.minX + 6, y: pill.minY + 4, width: 11, height: 11), alpha: 0.95, tint: .white)
        GeekTheme.drawText("大图", in: CGRect(x: pill.minX + 19, y: pill.minY, width: 28, height: pill.height), font: .systemFont(ofSize: 10.5, weight: .semibold), color: .white)
        ctx.restoreGState()
    }

    private func drawPDFPagesPreview(in ctx: CGContext, isDark: Bool) {
        guard !pdfPageItems.isEmpty else { drawEmptyHint(in: ctx); return }
        let area = bounds.insetBy(dx: 10, dy: 10)
        let maxShown = min(pdfPageItems.count, 8)
        let cols = min(maxShown, maxShown <= 2 ? maxShown : (maxShown <= 4 ? 2 : 4))
        let rows = (maxShown + cols - 1) / cols
        let gap: CGFloat = 12
        let cellW = min(250, (area.width - gap * CGFloat(cols - 1)) / CGFloat(cols))
        let cellH = min(290, (area.height - gap * CGFloat(rows - 1)) / CGFloat(rows))
        let gridW = cellW * CGFloat(cols) + gap * CGFloat(cols - 1), gridH = cellH * CGFloat(rows) + gap * CGFloat(rows - 1)
        let startX = round(area.midX - gridW * 0.5), startY = round(area.midY - gridH * 0.5)
        let solidColor = pdfCustomBgColor ?? pdfBgStyle.rgbaColor ?? RGBAColor(255, 255, 255)
        let pageFill = solidColor.cgColor
        let pageIsDark = (pdfBgStyle == .gradient) ? pdfGradientPreset.isDarkVisual : (solidColor.relativeLuminance < 0.42)
        lastPDFPageRects.removeAll()

        for idx in 0..<maxShown {
            let r = idx / cols, c = idx % cols
            let card = CGRect(x: startX + CGFloat(c) * (cellW + gap), y: startY + CGFloat(r) * (cellH + gap), width: cellW, height: cellH)
            lastPDFPageRects.append((idx, card))
            let isHov = (hoveredPDFIdx == idx)
            let p = CGPath(roundedRect: card, cornerWidth: 7, cornerHeight: 7, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 9, color: NSColor.black.withAlphaComponent(isDark ? 0.42 : 0.14).cgColor)
            ctx.setFillColor(pageFill); ctx.addPath(p); ctx.fillPath()
            ctx.restoreGState()

            if pdfBgStyle == .gradient {
                ctx.saveGState(); ctx.addPath(p); ctx.clip()
                CollageOverlaysRenderer.drawGradient(pdfGradientPreset, in: card, ctx: ctx, topLeftToBottomRightInBottomUpCG: false)
                ctx.restoreGState()
            }
            ctx.saveGState()
            ctx.setStrokeColor((isHov ? GeekTheme.accent : GeekTheme.border).cgColor)
            ctx.setLineWidth(isHov ? 1.5 : 0.8); ctx.addPath(p); ctx.strokePath()
            ctx.restoreGState()

            let padInset = min(min(card.width, card.height) * 0.28, round(2.0 + CGFloat(max(0, pdfPadPx)) * 0.20))
            let img = pdfPageItems[idx].thumbnail, media = card.insetBy(dx: padInset, dy: padInset)
            let mediaTop = CGRect(x: media.minX, y: media.minY, width: media.width, height: max(20, media.height - (pdfPageNumStyle != .none ? 15 : 0)))
            let sc = min(mediaTop.width / max(1, img.size.width), mediaTop.height / max(1, img.size.height))
            let dw = img.size.width * sc, dh = img.size.height * sc
            img.draw(in: NSRect(x: mediaTop.midX - dw * 0.5, y: mediaTop.midY - dh * 0.5, width: dw, height: dh), from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)

            if let label = pdfPageNumStyle.label(index: idx, total: pdfPageItems.count) {
                let footerColor = pageIsDark ? NSColor(white: 0.92, alpha: 0.88) : NSColor(white: 0.36, alpha: 1)
                GeekTheme.drawText(label, in: CGRect(x: card.minX + 6, y: card.maxY - 17, width: card.width - 12, height: 13), font: .monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold), color: footerColor, align: .center)
            }
            if pdfWatermarkStyle != .none {
                let wm = pdfWatermarkText.trimmingCharacters(in: .whitespacesAndNewlines)
                let tagColor = pageIsDark ? NSColor.white.withAlphaComponent(0.55) : NSColor.black.withAlphaComponent(0.35)
                GeekTheme.drawText(wm.isEmpty ? "MSnip" : wm, in: CGRect(x: card.minX + 6, y: card.minY + 4, width: card.width - 12, height: 12), font: .systemFont(ofSize: 8.5, weight: .semibold), color: tagColor, align: pdfWatermarkStyle == .tiled ? .center : .right)
            }
            if isHov { drawZoomHintPill(in: ctx, anchorRect: card) }
        }
    }

    private func drawEmptyHint(in ctx: CGContext) {
        let iconR = CGRect(x: round(bounds.midX - 15), y: round(bounds.midY - 28), width: 30, height: 30)
        GeekTheme.drawSymbol("photo.on.rectangle.angled", pointSize: 22, weight: .light, in: iconR, alpha: 0.46, tint: GeekTheme.inkMuted)
        GeekTheme.drawText("拖入图片 · ⌘V 粘贴 · 点击下方加图", in: CGRect(x: 20, y: round(bounds.midY + 6), width: bounds.width - 40, height: 20), font: .systemFont(ofSize: 12.2, weight: .medium), color: GeekTheme.inkMuted, align: .center)
    }

    private func drawCheckerboard(in rect: CGRect, ctx: CGContext, isDark: Bool) {
        let cell: CGFloat = 10
        ctx.setFillColor((isDark ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.96, alpha: 1)).cgColor); ctx.fill(rect)
        ctx.setFillColor((isDark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.87, alpha: 1)).cgColor)
        var y = rect.minY, row = 0
        while y < rect.maxY {
            var x = rect.minX + (row % 2 == 0 ? 0 : cell)
            while x < rect.maxX { ctx.fill(CGRect(x: x, y: y, width: cell, height: cell)); x += cell * 2 }
            y += cell; row += 1
        }
    }
}

/// 大图查看器无边框窗口（支持 Esc/Space 关闭、←/→ 切图、0/1 适应与 1:1、⌘C 复制）
final class CollageLightboxWindow: NSWindow {
    enum KeyAction { case close, prev, next, fit, actual100, copy }
    var onKeyAction: ((KeyAction) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53, 49: onKeyAction?(.close)
        case 123:    onKeyAction?(.prev)
        case 124:    onKeyAction?(.next)
        case 29:     onKeyAction?(.fit)
        case 18:     onKeyAction?(.actual100)
        default:     super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command && ch == "c" { onKeyAction?(.copy); return true }
        if flags == .command && ch == "0" { onKeyAction?(.fit); return true }
        if flags == .command && ch == "1" { onKeyAction?(.actual100); return true }
        if flags.isEmpty && event.keyCode == 53 { onKeyAction?(.close); return true }
        return super.performKeyEquivalent(with: event)
    }
}
