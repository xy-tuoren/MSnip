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
    var onDropImages: (([CGImage]) -> Void)?
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
        registerForDraggedTypes([.fileURL, .png, .tiff])
        self.toolTip = L("点击预览图可打开全尺寸高清大图（滚轮缩放 · 拖拽平移）")
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
        let editIt = NSMenuItem(title: L("编辑 / 标注合成拼图…"), action: #selector(triggerEditMenu), keyEquivalent: "")
        let zoomIt = NSMenuItem(title: L("全尺寸大图预览"), action: #selector(triggerZoomMenu), keyEquivalent: "")
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
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onDropImageURLs?(urls); return true
        }
        if let raw = pb.data(forType: .png) ?? pb.data(forType: .tiff),
           let ns = NSImage(data: raw), let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            onDropImages?([ImageTransform.detachedCopy(cg)]); return true
        }
        return false
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
            GeekTheme.drawText(L("松手即可加入拼图素材"), in: dr, font: .systemFont(ofSize: 13.0, weight: .semibold), color: GeekTheme.accent, align: .center)
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
        GeekTheme.drawText(L("大图"), in: CGRect(x: pill.minX + 19, y: pill.minY, width: 28, height: pill.height), font: .systemFont(ofSize: 10.5, weight: .semibold), color: .white)
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
        if pdfPageItems.count > maxShown {
            let extra = pdfPageItems.count - maxShown
            let pill = CGRect(x: bounds.width - 148, y: bounds.height - 28, width: 138, height: 20)
            let pp = CGPath(roundedRect: pill, cornerWidth: 10, cornerHeight: 10, transform: nil)
            ctx.saveGState()
            ctx.setFillColor(GeekTheme.accent.withAlphaComponent(0.90).cgColor); ctx.addPath(pp); ctx.fillPath()
            GeekTheme.drawText(L("另有 +%@ 页（导出包含全部）", extra), in: pill, font: .systemFont(ofSize: 9.8, weight: .semibold), color: .white, align: .center)
            ctx.restoreGState()
        }
    }

    private func drawEmptyHint(in ctx: CGContext) {
        let iconR = CGRect(x: round(bounds.midX - 15), y: round(bounds.midY - 28), width: 30, height: 30)
        GeekTheme.drawSymbol("photo.on.rectangle.angled", pointSize: 22, weight: .light, in: iconR, alpha: 0.46, tint: GeekTheme.inkMuted)
        GeekTheme.drawText(L("拖入图片 · ⌘V 粘贴 · 点击下方加图"), in: CGRect(x: 20, y: round(bounds.midY + 6), width: bounds.width - 40, height: 20), font: .systemFont(ofSize: 12.2, weight: .medium), color: GeekTheme.inkMuted, align: .center)
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

// MARK: - 拼接画布与胶片缩略图视图

/// 底部紧凑单行素材缩略卡（支持单击看大图、左下角 ✎ 编辑裁剪/打码、右键快捷旋转/还原、直接拖拽换序、右上角 ✕ 移除）
private final class CollageFilmstripCardView: NSView {
    static let cardSize = NSSize(width: 68, height: 48)
    static let spacing: CGFloat = 6
    static let step: CGFloat = cardSize.width + spacing

    let index: Int
    let totalCount: Int
    let item: CollageSourceItem
    var onInspect: ((Int) -> Void)?
    var onEdit: ((Int) -> Void)?
    var onRotate90: ((Int) -> Void)?
    var onFlipH: ((Int) -> Void)?
    var onRevert: ((Int) -> Void)?
    var onRemove: ((Int) -> Void)?
    var onDragMove: ((Int, CGFloat) -> Void)?
    var onDragEnd: ((Int) -> Void)?

    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    private var hoveredRemove = false { didSet { if oldValue != hoveredRemove { needsDisplay = true } } }
    private var hoveredEdit = false { didSet { if oldValue != hoveredEdit { needsDisplay = true } } }
    private var isDragging = false { didSet { if oldValue != isDragging { needsDisplay = true } } }
    private var dragDownInParent: CGPoint?
    private var origOriginX: CGFloat = 0

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: isDragging ? .closedHand : .pointingHand) }

    init(index: Int, totalCount: Int, item: CollageSourceItem) {
        self.index = index; self.totalCount = totalCount; self.item = item
        super.init(frame: NSRect(origin: .zero, size: Self.cardSize))
        self.toolTip = L("%@ · %@×%@\n单击看大图 · 左下 ✎ 编辑/裁剪 · 拖拽换序 · 右键更多", item.title, item.cgImage.width, item.cgImage.height)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var removeRect: CGRect { CGRect(x: bounds.width - 17, y: 3, width: 14, height: 14) }
    private var editRect: CGRect { CGRect(x: 3, y: bounds.height - 17, width: 15, height: 14) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false; hoveredRemove = false; hoveredEdit = false }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoveredRemove = removeRect.contains(p)
        hoveredEdit = editRect.contains(p)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if removeRect.contains(p) { onRemove?(index); return }
        if editRect.contains(p) { onEdit?(index); return }
        dragDownInParent = superview?.convert(event.locationInWindow, from: nil)
        origOriginX = frame.origin.x; isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragDownInParent, let parent = superview, totalCount > 1 else { return }
        let cur = parent.convert(event.locationInWindow, from: nil), dx = cur.x - start.x
        if !isDragging && hypot(dx, cur.y - start.y) > 5 {
            isDragging = true; parent.addSubview(self, positioned: .above, relativeTo: nil)
            alphaValue = 0.92; window?.invalidateCursorRects(for: self)
        }
        guard isDragging else { return }
        frame.origin.x = min(CGFloat(max(0, totalCount - 1)) * Self.step, max(0, origOriginX + dx))
        onDragMove?(index, frame.midX)
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = isDragging, hadDown = (dragDownInParent != nil)
        dragDownInParent = nil; isDragging = false; alphaValue = 1.0
        if wasDragging { onDragEnd?(index) }
        else if hadDown && bounds.contains(convert(event.locationInWindow, from: nil)) { onInspect?(index) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        func add(_ t: String, _ sel: Selector) { let i = NSMenuItem(title: t, action: sel, keyEquivalent: ""); i.target = self; m.addItem(i) }
        add(L("编辑 / 裁剪 / 标注此图…"), #selector(actEdit))
        add(L("顺时针旋转 90°"), #selector(actRot))
        add(L("水平镜像翻转"), #selector(actFlip))
        if item.originalBackup != nil { add(L("还原初始原图"), #selector(actRevert)) }
        m.addItem(.separator())
        add(L("全尺寸大图预览"), #selector(actInspect))
        add(L("从列表中移除"), #selector(actRemove))
        return m
    }

    @objc private func actEdit() { onEdit?(index) }
    @objc private func actRot() { onRotate90?(index) }
    @objc private func actFlip() { onFlipH?(index) }
    @objc private func actRevert() { onRevert?(index) }
    @objc private func actInspect() { onInspect?(index) }
    @objc private func actRemove() { onRemove?(index) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: r, cornerWidth: 7.5, cornerHeight: 7.5, transform: nil)
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        ctx.setFillColor((GeekTheme.isDark ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.93, alpha: 1)).cgColor)
        ctx.fill(r)
        let img = item.thumbnail
        let sc = max(r.width / max(1, img.size.width), r.height / max(1, img.size.height))
        let dw = img.size.width * sc, dh = img.size.height * sc
        img.draw(in: NSRect(x: r.midX - dw * 0.5, y: r.midY - dh * 0.5, width: dw, height: dh), from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(((hovered || isDragging) ? GeekTheme.accent : GeekTheme.borderStrong).cgColor)
        ctx.setLineWidth(isDragging ? 2.0 : (hovered ? 1.4 : 0.75)); ctx.addPath(path); ctx.strokePath()

        let badge = CGRect(x: 3.5, y: 3.5, width: 15, height: 14)
        let bp = CGPath(roundedRect: badge, cornerWidth: 7, cornerHeight: 7, transform: nil)
        ctx.setFillColor((item.originalBackup != nil ? GeekTheme.accent : NSColor.black).withAlphaComponent(0.68).cgColor)
        ctx.addPath(bp); ctx.fillPath()
        GeekTheme.drawText("\(index + 1)", in: badge, font: .monospacedDigitSystemFont(ofSize: 8.8, weight: .bold), color: .white, align: .center)

        if hovered && !isDragging {
            let rr = removeRect, rp = CGPath(roundedRect: rr, cornerWidth: 7, cornerHeight: 7, transform: nil)
            ctx.setFillColor((hoveredRemove ? NSColor.systemRed.withAlphaComponent(0.92) : NSColor.black.withAlphaComponent(0.68)).cgColor)
            ctx.addPath(rp); ctx.fillPath()
            ToolbarView.drawSymbol("xmark", in: rr.insetBy(dx: 2, dy: 2), alpha: 0.96, tint: .white)

            let er = editRect, ep = CGPath(roundedRect: er, cornerWidth: 7, cornerHeight: 7, transform: nil)
            ctx.setFillColor((hoveredEdit ? GeekTheme.accent.withAlphaComponent(0.95) : NSColor.black.withAlphaComponent(0.68)).cgColor)
            ctx.addPath(ep); ctx.fillPath()
            ToolbarView.drawSymbol("pencil", in: er.insetBy(dx: 2.2, dy: 2.0), alpha: 0.96, tint: .white)

            let mag = CGRect(x: bounds.width - 17, y: bounds.height - 17, width: 14, height: 14)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.54).cgColor); ctx.fillEllipse(in: mag)
            ToolbarView.drawSymbol("magnifyingglass", in: mag.insetBy(dx: 2.2, dy: 2.2), alpha: 0.94, tint: .white)
        }
        ctx.restoreGState()
    }
}

/// 拼图工作室紧凑左右分栏布局与拖拽排序扩展
extension CollageStudioController {
    func layoutUI() {
        guard let root = rootView else { return }
        let w = root.bounds.width, h = root.bounds.height
        // 英文标签更长：侧栏略放宽，其余控件再按文字实际宽度排布
        let barH: CGFloat = 38, pad: CGFloat = 10, gap: CGFloat = 9, sideW: CGFloat = MSnipL10n.usesEnglish ? 256 : 228
        topBarView?.frame = NSRect(x: 0, y: 0, width: w, height: barH)
        topBarDivider?.frame = NSRect(x: 0, y: barH, width: w, height: 1)
        layoutTopBarMeta()

        if inlineEditor.isActive {
            [canvasView, stripCard, inspectorCard].forEach { $0?.isHidden = true }
            inlineEditor.isHidden = false
            inlineEditor.frame = NSRect(x: 0, y: barH + 1, width: w, height: max(200, h - barH - 1))
            inlineEditor.layoutEditor()
            return
        }
        inlineEditor.isHidden = true
        [canvasView, stripCard, inspectorCard].forEach { $0?.isHidden = false }

        let workY = barH + 1 + pad, workH = max(340, h - workY - pad)
        let leftW = max(420, w - sideW - pad * 2 - gap), stripH: CGFloat = 66
        let canvasH = max(240, workH - stripH - 8)

        canvasView?.frame = NSRect(x: pad, y: workY, width: leftW, height: canvasH)
        stripCard?.frame = NSRect(x: pad, y: workY + canvasH + 8, width: leftW, height: stripH)
        let railW = max(100, addClipBtn?.fittingWidth ?? 0, (addRecentBtn?.fittingWidth ?? 0) + 32), railX = leftW - railW - 8
        stripDivider?.frame = NSRect(x: railX - 8, y: 9, width: 1, height: stripH - 18)
        stripScrollView?.frame = NSRect(x: 8, y: 7, width: max(120, railX - 24), height: 52)
        addClipBtn?.frame = NSRect(x: railX, y: 7, width: railW, height: 24)
        addRecentBtn?.frame = NSRect(x: railX, y: 35, width: railW - 32, height: 24)
        clearBtn?.frame = NSRect(x: railX + railW - 28, y: 35, width: 28, height: 24)

        let rx = pad + leftW + gap, isPDF = (studioMode == .pdfMerge)
        inspectorCard?.frame = NSRect(x: rx, y: workY, width: sideW, height: workH)
        let ix: CGFloat = 10, inW = sideW - 20
        var cy: CGFloat = 10

        let showCols = (!isPDF && options.layout == .grid)
        let showWMInput = (options.watermark != .none)
        [layoutSeg, div1, styleHeaderLabel, presetBar, gapRow, radiusRow, shadowPill, alignLabel, alignSeg, aspectLabel, aspectSeg, div3, badgeSeg].forEach { $0?.isHidden = isPDF }
        colsSeg?.isHidden = !showCols; pdfPageNumSeg?.isHidden = !isPDF; pdfHintLabel?.isHidden = !isPDF
        watermarkBox?.isHidden = !showWMInput
        badgeLabel?.stringValue = isPDF ? L("页码") : L("角标")
        // 行标题列按最宽标题统一放宽，右侧分段控件随之收窄
        let rowLabels = [alignLabel, aspectLabel, badgeLabel, watermarkLabel].compactMap { $0 }
        let labelW = max(30, rowLabels.map { ceil($0.intrinsicContentSize.width) + 2 }.max() ?? 30)
        let segX = ix + labelW + 3, segW = inW - labelW - 3
        let sliders = [gapRow, padRow, radiusRow].compactMap { $0 }
        let sliderTitleW = max(34, sliders.map(\.titleFittingWidth).max() ?? 34)
        sliders.forEach { $0.titleColumnWidth = sliderTitleW }
        let bgLabelW = max(28, ceil(bgLabel?.intrinsicContentSize.width ?? 0) + 2)

        if !isPDF {
            layoutSeg?.frame = NSRect(x: ix, y: cy, width: inW, height: 25); cy += 30
            if showCols { colsSeg?.frame = NSRect(x: ix, y: cy, width: inW, height: 22); cy += 27 }
            div1?.frame = NSRect(x: ix, y: cy, width: inW, height: 1); cy += 8
            let presetW = min(inW - 60, max(110, presetBar?.fittingWidth ?? 110))
            styleHeaderLabel?.frame = NSRect(x: ix, y: cy + 1.5, width: inW - presetW - 4, height: 16)
            presetBar?.frame = NSRect(x: ix + inW - presetW, y: cy, width: presetW, height: 19); cy += 23
            gapRow?.frame = NSRect(x: ix, y: cy, width: inW, height: 21); cy += 23
            padRow?.frame = NSRect(x: ix, y: cy, width: inW, height: 21); cy += 23
            radiusRow?.frame = NSRect(x: ix, y: cy, width: inW, height: 21); cy += 25
            let shadowW = max(53, shadowPill?.fittingWidth ?? 53)
            bgLabel?.frame = NSRect(x: ix, y: cy + 3, width: bgLabelW, height: 16)
            bgTrigger?.frame = NSRect(x: ix + bgLabelW + 1, y: cy, width: 95, height: 22)
            bgEyedropperBtn?.frame = NSRect(x: ix + bgLabelW + 99, y: cy, width: 24, height: 22)
            shadowPill?.frame = NSRect(x: ix + inW - shadowW, y: cy + 0.5, width: shadowW, height: 21); cy += 28
            div2?.frame = NSRect(x: ix, y: cy, width: inW, height: 1); cy += 8
            alignLabel?.frame = NSRect(x: ix, y: cy + 3, width: labelW, height: 16)
            alignSeg?.frame = NSRect(x: segX, y: cy, width: segW, height: 22); cy += 27
            aspectLabel?.frame = NSRect(x: ix, y: cy + 3, width: labelW, height: 16)
            aspectSeg?.frame = NSRect(x: segX, y: cy, width: segW, height: 22); cy += 28
            div3?.frame = NSRect(x: ix, y: cy, width: inW, height: 1); cy += 8
            badgeLabel?.frame = NSRect(x: ix, y: cy + 3, width: labelW, height: 16)
            badgeSeg?.frame = NSRect(x: segX, y: cy, width: segW, height: 22); cy += 27
            watermarkLabel?.frame = NSRect(x: ix, y: cy + 3, width: labelW, height: 16)
            watermarkSeg?.frame = NSRect(x: segX, y: cy, width: segW, height: 22); cy += 27
            if showWMInput { watermarkBox?.frame = NSRect(x: ix, y: cy, width: inW, height: 25) }
        } else {
            padRow?.frame = NSRect(x: ix, y: cy, width: inW, height: 22); cy += 28
            bgLabel?.frame = NSRect(x: ix, y: cy + 3, width: bgLabelW, height: 16)
            bgTrigger?.frame = NSRect(x: ix + bgLabelW + 1, y: cy, width: inW - bgLabelW - 33, height: 22)
            bgEyedropperBtn?.frame = NSRect(x: ix + inW - 28, y: cy, width: 28, height: 22); cy += 30
            div2?.frame = NSRect(x: ix, y: cy, width: inW, height: 1); cy += 9
            badgeLabel?.frame = NSRect(x: ix, y: cy + 3, width: labelW, height: 16)
            pdfPageNumSeg?.frame = NSRect(x: segX, y: cy, width: segW, height: 23); cy += 29
            watermarkLabel?.frame = NSRect(x: ix, y: cy + 3, width: labelW, height: 16)
            watermarkSeg?.frame = NSRect(x: segX, y: cy, width: segW, height: 23); cy += 29
            if showWMInput { watermarkBox?.frame = NSRect(x: ix, y: cy, width: inW, height: 26); cy += 32 }
            pdfHintLabel?.frame = NSRect(x: ix, y: cy + 2, width: inW, height: 38)
        }

        [copyBtn, annotateBtn, pinBtn, saveBtn].forEach { $0?.isHidden = isPDF }
        pdfBtn?.isHidden = !isPDF
        if isPDF {
            let py = workH - 10 - 32
            pdfBtn?.frame = NSRect(x: ix, y: py, width: inW, height: 32)
            divExport?.frame = NSRect(x: ix, y: py - 9, width: inW, height: 1)
        } else {
            let row2Y = workH - 10 - 27, row1Y = row2Y - 5 - 30, thirdW = floor((inW - 10) / 3.0)
            copyBtn?.frame = NSRect(x: ix, y: row1Y, width: inW, height: 30)
            // 三等分放不下较长译文时按各自所需宽度比例分配
            let trio = [annotateBtn, pinBtn, saveBtn].compactMap { $0 }
            let needs = trio.map(\.fittingWidth)
            let widths = needs.contains(where: { $0 > thirdW }) && !needs.isEmpty
                ? needs.map { floor($0 * (inW - 10) / needs.reduce(0, +)) }
                : Array(repeating: thirdW, count: trio.count)
            var bx = ix
            for (i, btn) in trio.enumerated() {
                let bw = (i == trio.count - 1) ? (ix + inW - bx) : widths[i]
                btn.frame = NSRect(x: bx, y: row2Y, width: bw, height: 27)
                bx += bw + 5
            }
            divExport?.frame = NSRect(x: ix, y: row1Y - 8, width: inW, height: 1)
        }
    }

    func reloadFilmstrip() {
        guard let doc = stripDocView, let sv = stripScrollView else { return }
        doc.subviews.forEach { $0.removeFromSuperview() }
        let hasItems = !items.isEmpty
        [copyBtn, annotateBtn, pinBtn, saveBtn, pdfBtn, clearBtn].forEach { $0?.isEnabled = hasItems }

        let step = CollageFilmstripCardView.step
        for (i, item) in items.enumerated() {
            let card = CollageFilmstripCardView(index: i, totalCount: items.count, item: item)
            card.frame = NSRect(x: CGFloat(i) * step, y: 2, width: CollageFilmstripCardView.cardSize.width, height: CollageFilmstripCardView.cardSize.height)
            card.onInspect = { [weak self] idx in self?.openSourceLightbox(startIndex: idx) }
            card.onEdit = { [weak self] idx in self?.openSourceEditor(at: idx) }
            card.onRotate90 = { [weak self] idx in self?.transformSourceItem(at: idx, using: ImageTransform.rotateClockwise90) }
            card.onFlipH = { [weak self] idx in self?.transformSourceItem(at: idx, using: ImageTransform.flipHorizontal) }
            card.onRevert = { [weak self] idx in self?.revertSourceItem(at: idx) }
            card.onRemove = { [weak self] idx in
                guard let self, self.items.indices.contains(idx) else { return }
                self.items.remove(at: idx); self.reloadFilmstrip(); self.invalidateCollageEditsAndRender()
            }
            card.onDragMove = { [weak self] from, midX in self?.handleCardDragMove(from: from, midX: midX) }
            card.onDragEnd = { [weak self] from in self?.handleCardDragEnd(from: from) }
            doc.addSubview(card)
        }
        let addX = CGFloat(items.count) * step
        let addTile = CollageAddTileView(frame: NSRect(x: addX, y: 2, width: 50, height: CollageFilmstripCardView.cardSize.height))
        addTile.onClick = { [weak self] in self?.pickImageFiles() }
        doc.addSubview(addTile)
        doc.frame = NSRect(x: 0, y: 0, width: max(sv.bounds.width, addX + 54), height: sv.bounds.height)
    }

    func handleCardDragMove(from: Int, midX: CGFloat) {
        guard let doc = stripDocView, items.count > 1 else { return }
        let step = CollageFilmstripCardView.step
        let target = min(items.count - 1, max(0, Int(floor(midX / step))))
        guard target != dragTargetIndex else { return }
        dragTargetIndex = target
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            for case let card as CollageFilmstripCardView in doc.subviews where card.index != from {
                let slot = (from < target && card.index > from && card.index <= target) ? card.index - 1
                    : (from > target && card.index >= target && card.index < from) ? card.index + 1 : card.index
                card.animator().frame.origin.x = CGFloat(slot) * step
            }
        }
    }

    func handleCardDragEnd(from: Int) {
        let target = dragTargetIndex; dragTargetIndex = nil
        if let target, target != from, items.indices.contains(from), items.indices.contains(target) {
            items.insert(items.remove(at: from), at: target); reloadFilmstrip(); invalidateCollageEditsAndRender()
        } else { reloadFilmstrip() }
    }
}
