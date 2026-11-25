import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 拼图工作室单张素材模型
struct CollageSourceItem {
    let id = UUID()
    let title: String
    let cgImage: CGImage
    let scaleFactor: CGFloat
    let thumbnail: NSImage
}

/// 拼图与 PDF 合并实时预览画布（拼图模式展示实时高清合成效果，PDF 模式展示带页码的多页排布，支持直接拖入图片）
final class CollagePreviewCanvasView: NSView {
    var isPDFMode: Bool = false { didSet { if oldValue != isPDFMode { needsDisplay = true } } }
    var previewImage: CGImage? { didSet { needsDisplay = true } }
    var pdfPageItems: [CollageSourceItem] = [] { didSet { if isPDFMode { needsDisplay = true } } }
    var pdfBgStyle: CollageBackgroundStyle = .white { didSet { if isPDFMode { needsDisplay = true } } }
    var showsCheckerboard: Bool = false { didSet { if oldValue != showsCheckerboard { needsDisplay = true } } }
    var statusBadgeText: String = "" { didSet { if oldValue != statusBadgeText { needsDisplay = true } } }
    var onDropImageURLs: (([URL]) -> Void)?
    var onInspectCollage: (() -> Void)?
    var onInspectPDFPage: ((Int) -> Void)?

    private var isDragTargeted = false { didSet { if oldValue != isDragTargeted { needsDisplay = true } } }
    private var lastCollageRect: CGRect = .zero
    private var lastPDFPageRects: [(Int, CGRect)] = []

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        self.toolTip = "点击预览图可打开全尺寸高清大图（支持滚轮缩放与拖拽查看）"
    }

    override func resetCursorRects() {
        if !isPDFMode && previewImage != nil {
            addCursorRect(bounds, cursor: .pointingHand)
        } else if isPDFMode && !pdfPageItems.isEmpty {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if isPDFMode {
            if let hit = lastPDFPageRects.first(where: { $0.1.contains(p) }) {
                onInspectPDFPage?(hit.0)
            }
            return
        }
        if previewImage != nil && lastCollageRect.contains(p) {
            onInspectCollage?()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDragTargeted = true; return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { isDragTargeted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragTargeted = false
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else { return false }
        onDropImageURLs?(urls)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let isDark = GeekTheme.isDark
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let bgPath = CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil)

        ctx.saveGState()
        let boardBg = isDark
            ? NSColor(srgbRed: 0.095, green: 0.106, blue: 0.128, alpha: 1.0)
            : NSColor(srgbRed: 0.918, green: 0.930, blue: 0.952, alpha: 1.0)
        ctx.setFillColor(boardBg.cgColor)
        ctx.addPath(bgPath); ctx.fillPath()
        ctx.setStrokeColor(GeekTheme.border.cgColor)
        ctx.setLineWidth(1.0); ctx.addPath(bgPath); ctx.strokePath()
        ctx.restoreGState()

        if isPDFMode {
            drawPDFPagesPreview(in: ctx, isDark: isDark)
        } else if let cg = previewImage {
            drawCollagePreview(cg, in: ctx, isDark: isDark)
        } else {
            drawEmptyHint(in: ctx)
        }

        if !statusBadgeText.isEmpty {
            drawStatusBadge(statusBadgeText, in: ctx, isDark: isDark)
        }

        if isDragTargeted {
            let dr = bounds.insetBy(dx: 5, dy: 5)
            let dp = CGPath(roundedRect: dr, cornerWidth: 10, cornerHeight: 10, transform: nil)
            ctx.saveGState()
            ctx.setFillColor(GeekTheme.accent.withAlphaComponent(isDark ? 0.18 : 0.10).cgColor)
            ctx.addPath(dp); ctx.fillPath()
            ctx.setStrokeColor(GeekTheme.accent.cgColor)
            ctx.setLineWidth(2.0); ctx.setLineDash(phase: 0, lengths: [6, 4])
            ctx.addPath(dp); ctx.strokePath()
            GeekTheme.drawText("松手即可将图片加入素材列表", in: dr, font: .systemFont(ofSize: 14, weight: .semibold), color: GeekTheme.accent, align: .center)
            ctx.restoreGState()
        }
    }

    private func drawCollagePreview(_ cg: CGImage, in ctx: CGContext, isDark: Bool) {
        let inset = CGRect(x: 20, y: 36, width: bounds.width - 40, height: max(80, bounds.height - 56))
        let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
        let sc = min(inset.width / max(1, iw), inset.height / max(1, ih))
        let dw = round(iw * sc), dh = round(ih * sc)
        let dst = CGRect(x: round(inset.midX - dw * 0.5), y: round(inset.midY - dh * 0.5), width: dw, height: dh)
        lastCollageRect = dst
        let clip = CGPath(roundedRect: dst, cornerWidth: 6, cornerHeight: 6, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 16, color: NSColor.black.withAlphaComponent(isDark ? 0.45 : 0.15).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addPath(clip); ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(clip); ctx.clip()
        if showsCheckerboard { drawCheckerboard(in: dst, ctx: ctx, isDark: isDark) }
        NSImage(cgImage: cg, size: dst.size).draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
        ctx.restoreGState()
    }

    private func drawPDFPagesPreview(in ctx: CGContext, isDark: Bool) {
        guard !pdfPageItems.isEmpty else { drawEmptyHint(in: ctx); return }
        let area = CGRect(x: 22, y: 40, width: bounds.width - 44, height: max(80, bounds.height - 58))
        let maxShown = min(pdfPageItems.count, 8)
        let cols = min(maxShown, maxShown <= 2 ? maxShown : (maxShown <= 4 ? 2 : 4))
        let rows = (maxShown + cols - 1) / cols
        let gap: CGFloat = 14
        let cellW = min(180, (area.width - gap * CGFloat(cols - 1)) / CGFloat(cols))
        let cellH = min(190, (area.height - gap * CGFloat(rows - 1)) / CGFloat(rows))
        let gridW = cellW * CGFloat(cols) + gap * CGFloat(cols - 1)
        let gridH = cellH * CGFloat(rows) + gap * CGFloat(rows - 1)
        let startX = round(area.midX - gridW * 0.5)
        let startY = round(area.midY - gridH * 0.5)
        let pageFill = (pdfBgStyle.rgbaColor ?? RGBAColor(255, 255, 255)).cgColor
        lastPDFPageRects.removeAll()

        for idx in 0..<maxShown {
            let r = idx / cols, c = idx % cols
            let card = CGRect(x: startX + CGFloat(c) * (cellW + gap), y: startY + CGFloat(r) * (cellH + gap), width: cellW, height: cellH)
            lastPDFPageRects.append((idx, card))
            let p = CGPath(roundedRect: card, cornerWidth: 8, cornerHeight: 8, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 3), blur: 10, color: NSColor.black.withAlphaComponent(isDark ? 0.42 : 0.14).cgColor)
            ctx.setFillColor(pageFill); ctx.addPath(p); ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(GeekTheme.border.cgColor); ctx.setLineWidth(0.8); ctx.addPath(p); ctx.strokePath()
            ctx.restoreGState()

            let img = pdfPageItems[idx].thumbnail
            let media = card.insetBy(dx: 8, dy: 8)
            let mediaTop = CGRect(x: media.minX, y: media.minY, width: media.width, height: max(20, media.height - 16))
            let sc = min(mediaTop.width / max(1, img.size.width), mediaTop.height / max(1, img.size.height))
            let dw = img.size.width * sc, dh = img.size.height * sc
            img.draw(in: NSRect(x: mediaTop.midX - dw * 0.5, y: mediaTop.midY - dh * 0.5, width: dw, height: dh), from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)

            let footer = CGRect(x: card.minX + 6, y: card.maxY - 18, width: card.width - 12, height: 14)
            let footerColor = (pdfBgStyle == .dark) ? NSColor(white: 0.78, alpha: 1) : NSColor(white: 0.36, alpha: 1)
            GeekTheme.drawText("第 \(idx + 1) 页", in: footer, font: .monospacedDigitSystemFont(ofSize: 10, weight: .semibold), color: footerColor, align: .center)
        }
    }

    private func drawEmptyHint(in ctx: CGContext) {
        let iconR = CGRect(x: round(bounds.midX - 18), y: round(bounds.midY - 34), width: 36, height: 36)
        GeekTheme.drawSymbol("photo.on.rectangle.angled", pointSize: 26, weight: .light, in: iconR, alpha: 0.48, tint: GeekTheme.inkMuted)
        GeekTheme.drawText(
            "拖入任意图片文件，或点下方「加图 / 剪贴板 / 最近截图」",
            in: CGRect(x: 24, y: round(bounds.midY + 8), width: bounds.width - 48, height: 22),
            font: .systemFont(ofSize: 13, weight: .medium),
            color: GeekTheme.inkMuted, align: .center
        )
    }

    private func drawStatusBadge(_ text: String, in ctx: CGContext, isDark: Bool) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10.8, weight: .medium)
        let tw = ceil(GeekTheme.measureTextWidth(text, font: font)) + 18
        let r = CGRect(x: 12, y: 10, width: min(bounds.width - 24, tw), height: 21)
        let p = CGPath(roundedRect: r, cornerWidth: 10.5, cornerHeight: 10.5, transform: nil)
        ctx.saveGState()
        ctx.setFillColor((isDark ? NSColor(white: 0.16, alpha: 0.90) : NSColor.white.withAlphaComponent(0.88)).cgColor)
        ctx.addPath(p); ctx.fillPath()
        ctx.setStrokeColor(GeekTheme.border.cgColor); ctx.setLineWidth(0.75); ctx.addPath(p); ctx.strokePath()
        GeekTheme.drawText(text, in: r.insetBy(dx: 8, dy: 0), font: font, color: GeekTheme.inkSecondary, align: .center)
        ctx.restoreGState()
    }

    private func drawCheckerboard(in rect: CGRect, ctx: CGContext, isDark: Bool) {
        let cell: CGFloat = 10
        let c1 = (isDark ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.96, alpha: 1)).cgColor
        let c2 = (isDark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.87, alpha: 1)).cgColor
        ctx.setFillColor(c1); ctx.fill(rect)
        ctx.setFillColor(c2)
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
