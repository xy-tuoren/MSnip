import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 高密度实用型暂存卡片（`106 × 84pt`）：
/// - 静态底图与文字层独立缓存于 GPU 图层，鼠标快速滑过时零缩略图重采样、零 CoreText 重排；
/// - 动态高亮边框与右上角微操作胶囊（贴图 / 识字 / 删除）由轻量 `ShelfCardOverlayView` 独立瞬时绘制。
final class ShelfCardView: NSView, NSDraggingSource {
    static let cardSize = NSSize(width: 106, height: 84)

    let item: ShelfCardItem
    private let thumbnail: NSImage?
    private let thumbCG: CGImage?
    private let titleText: String
    private let subtitleText: String
    private let symbolName: String?
    private let textSnippet: String?
    private let canOCR: Bool
    private let overlayView = ShelfCardOverlayView(frame: NSRect(origin: .zero, size: ShelfCardView.cardSize))

    var onHoverStart: ((ShelfCardView) -> Void)?
    var onToggleSelect: ((ShelfCardItem) -> Void)?
    var onCopy: ((ShelfCardItem) -> Void)?
    var onEdit: ((ShelfCardItem) -> Void)?
    var onPin: ((ShelfCardItem) -> Void)?
    var onOCR: ((ShelfCardItem) -> Void)?
    var onRemove: ((ShelfCardItem) -> Void)?
    var dragWriterProvider: ((ShelfCardItem) -> NSPasteboardWriting?)?

    var selectionOrder: Int? { didSet { overlayView.selectionOrder = selectionOrder } }
    private var dragStartPoint: NSPoint?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(item: ShelfCardItem, thumbnail: NSImage?, title: String, subtitle: String, symbol: String?, textSnippet: String?, canOCR: Bool) {
        self.item = item
        self.thumbnail = thumbnail
        self.thumbCG = thumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        self.titleText = title
        self.subtitleText = subtitle
        self.symbolName = symbol
        self.textSnippet = textSnippet
        self.canOCR = canOCR
        super.init(frame: NSRect(origin: .zero, size: Self.cardSize))
        self.wantsLayer = true
        self.layerContentsRedrawPolicy = .onSetNeedsDisplay
        overlayView.canOCR = canOCR
        addSubview(overlayView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    func clearHover() {
        overlayView.setHover(active: false, btnTag: nil)
    }

    func updateHover(at localPoint: CGPoint) {
        guard bounds.contains(localPoint) else { clearHover(); return }
        onHoverStart?(self)
        let hit = overlayView.actionSlots().slots.first(where: { $0.rect.contains(localPoint) })?.tag
        overlayView.setHover(active: true, btnTag: hit)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) { clearHover() }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = overlayView.actionSlots().slots.first(where: { $0.rect.contains(p) }) {
            switch hit.tag {
            case 3: onEdit?(item)
            case 0: onPin?(item)
            case 1: onOCR?(item)
            case 2: onRemove?(item)
            default: break
            }
            return
        }
        dragStartPoint = p
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartPoint else { return }
        let cur = convert(event.locationInWindow, from: nil)
        guard hypot(cur.x - start.x, cur.y - start.y) >= 5.0 else { return }
        dragStartPoint = nil
        guard let writer = dragWriterProvider?(item) else { return }
        let di = NSDraggingItem(pasteboardWriter: writer)
        let dragImg = thumbnail ?? NSImage(size: NSSize(width: 64, height: 46))
        di.setDraggingFrame(NSRect(x: cur.x - 32, y: cur.y - 23, width: 64, height: 46), contents: dragImg)
        beginDraggingSession(with: [di], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartPoint != nil else { return }
        dragStartPoint = nil
        if event.modifierFlags.contains(.command) { onToggleSelect?(item); return }
        onCopy?(item)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .generic]
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let isDark = GeekTheme.isDark
        let cardR = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: cardR, cornerWidth: 8.5, cornerHeight: 8.5, transform: nil)

        ctx.saveGState()
        let bg: NSColor = (textSnippet != nil)
            ? (isDark ? NSColor(srgbRed: 0.21, green: 0.20, blue: 0.16, alpha: 0.94) : NSColor(srgbRed: 0.99, green: 0.975, blue: 0.93, alpha: 0.98))
            : (isDark ? NSColor(white: 0.16, alpha: 0.94) : NSColor(white: 0.96, alpha: 0.98))
        ctx.setFillColor(bg.cgColor); ctx.addPath(path); ctx.fillPath()
        ctx.setStrokeColor((isDark ? NSColor.white.withAlphaComponent(0.11) : NSColor.black.withAlphaComponent(0.10)).cgColor)
        ctx.setLineWidth(0.8); ctx.addPath(path); ctx.strokePath()
        ctx.restoreGState()

        let mediaR = CGRect(x: 3.5, y: 3.5, width: bounds.width - 7, height: 61)
        let mediaClip = CGPath(roundedRect: mediaR, cornerWidth: 5.5, cornerHeight: 5.5, transform: nil)
        ctx.saveGState()
        ctx.addPath(mediaClip); ctx.clip()
        if textSnippet == nil {
            ctx.setFillColor((isDark ? NSColor(white: 0.10, alpha: 1) : NSColor(white: 0.91, alpha: 1)).cgColor)
            ctx.fill(mediaR)
        }
        if let cg = thumbCG {
            let iw = max(1, CGFloat(cg.width)), ih = max(1, CGFloat(cg.height))
            let sc = max(mediaR.width / iw, mediaR.height / ih)
            let dw = iw * sc, dh = ih * sc
            let dst = CGRect(x: mediaR.midX - dw * 0.5, y: mediaR.midY - dh * 0.5, width: dw, height: dh)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: dst.minY + dst.maxY); ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .medium; ctx.draw(cg, in: dst)
            ctx.restoreGState()
        } else if let snippet = textSnippet {
            (snippet as NSString).draw(in: mediaR.insetBy(dx: 4, dy: 3), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9.0, weight: .regular),
                .foregroundColor: isDark ? NSColor(white: 0.88, alpha: 1) : NSColor(white: 0.20, alpha: 1)
            ])
        } else if let sym = symbolName {
            GeekTheme.drawSymbol(sym, pointSize: 20, weight: .regular, in: mediaR, alpha: 0.82, tint: GeekTheme.inkSecondary)
        }
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor((isDark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.09)).cgColor)
        ctx.setLineWidth(0.6); ctx.addPath(mediaClip); ctx.strokePath()
        ctx.restoreGState()

        let footY: CGFloat = 67.5
        let metaFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular)
        let metaW = min(50.0, ceil(GeekTheme.measureTextWidth(subtitleText, font: metaFont)))
        let titleW = max(24.0, bounds.width - 12.0 - metaW - 4.0)
        GeekTheme.drawText(titleText, in: CGRect(x: 5.5, y: footY - 0.5, width: titleW, height: 13), font: .systemFont(ofSize: 9.8, weight: .medium), color: GeekTheme.inkPrimary)
        GeekTheme.drawText(subtitleText, in: CGRect(x: bounds.width - 5.5 - metaW, y: footY, width: metaW, height: 12), font: metaFont, color: GeekTheme.inkMuted, align: .right)
    }
}

/// 卡片顶层轻量交互覆盖层（仅重绘悬停边框、选中角标与右上角微胶囊，零触碰底层缩略图）
private final class ShelfCardOverlayView: NSView {
    var canOCR: Bool = true
    var selectionOrder: Int? { didSet { if oldValue != selectionOrder { needsDisplay = true } } }
    private(set) var hovered = false
    private(set) var hoveredBtn: Int?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func setHover(active: Bool, btnTag: Int?) {
        guard hovered != active || hoveredBtn != btnTag else { return }
        hovered = active; hoveredBtn = btnTag
        needsDisplay = true
    }

    func actionSlots() -> (pill: CGRect, slots: [(tag: Int, rect: CGRect, sym: String, danger: Bool)]) {
        var defs: [(Int, String, Bool)] = []
        if canOCR { defs.append((3, "pencil", false)) }
        defs.append((0, "pin", false))
        if canOCR { defs.append((1, "text.viewfinder", false)) }
        defs.append((2, "xmark", true))
        let slotW: CGFloat = 18, slotH: CGFloat = 18, padX: CGFloat = 2
        let pillW = CGFloat(defs.count) * slotW + padX * 2
        let pill = CGRect(x: bounds.width - 4 - pillW, y: 5, width: pillW, height: slotH + 2)
        var slots: [(Int, CGRect, String, Bool)] = []
        var x = pill.minX + padX
        for (tag, sym, danger) in defs {
            slots.append((tag, CGRect(x: x, y: pill.minY + 1, width: slotW, height: slotH), sym, danger))
            x += slotW
        }
        return (pill, slots)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered || selectionOrder != nil, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let cardR = bounds.insetBy(dx: 0.7, dy: 0.7)
        let path = CGPath(roundedRect: cardR, cornerWidth: 8.5, cornerHeight: 8.5, transform: nil)

        ctx.saveGState()
        if hovered {
            ctx.setFillColor((GeekTheme.isDark ? NSColor.white.withAlphaComponent(0.045) : NSColor.white.withAlphaComponent(0.30)).cgColor)
            ctx.addPath(path); ctx.fillPath()
        }
        ctx.setStrokeColor(GeekTheme.accent.cgColor)
        ctx.setLineWidth(selectionOrder != nil ? 1.8 : 1.45)
        ctx.addPath(path); ctx.strokePath()
        ctx.restoreGState()

        if let order = selectionOrder {
            let badge = CGRect(x: 5, y: 5, width: 17, height: 17)
            ctx.saveGState()
            ctx.setFillColor(GeekTheme.accent.cgColor); ctx.fillEllipse(in: badge)
            GeekTheme.drawText("\(order)", in: badge, font: .monospacedDigitSystemFont(ofSize: 9.5, weight: .bold), color: .white, align: .center)
            ctx.restoreGState()
        }

        if hovered {
            let (pill, slots) = actionSlots()
            let pillPath = CGPath(roundedRect: pill, cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.saveGState()
            ctx.setFillColor(NSColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 0.82).cgColor)
            ctx.addPath(pillPath); ctx.fillPath()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.20).cgColor)
            ctx.setLineWidth(0.6); ctx.addPath(pillPath); ctx.strokePath()
            for btn in slots {
                if hoveredBtn == btn.tag {
                    let hi = CGPath(roundedRect: btn.rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 4.5, cornerHeight: 4.5, transform: nil)
                    ctx.setFillColor((btn.danger ? NSColor.systemRed : GeekTheme.accent).withAlphaComponent(0.94).cgColor)
                    ctx.addPath(hi); ctx.fillPath()
                }
                ToolbarView.drawSymbol(btn.sym, in: btn.rect.insetBy(dx: 1.5, dy: 1.5), alpha: 0.98, tint: .white)
            }
            ctx.restoreGState()
        }
    }
}

/// 支持「普通鼠标上下滚轮直接左右滚动 + 触控板双指横向轻扫 + 一键平滑翻页」的横向滚动容器
final class ShelfHorizontalScrollView: NSScrollView {
    var onScrollOffsetChanged: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        guard let doc = documentView else { super.scrollWheel(with: event); return }
        let maxX = max(0, doc.frame.width - contentView.bounds.width)
        guard maxX > 0.5 else { return }
        if event.hasPreciseScrollingDeltas && abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event); onScrollOffsetChanged?(); return
        }
        let nextX = ShelfTriggerGeometry.nextHorizontalScrollX(
            currentX: contentView.bounds.origin.x, maxX: maxX,
            deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, hasPreciseDeltas: event.hasPreciseScrollingDeltas
        )
        contentView.scroll(to: NSPoint(x: nextX, y: 0))
        reflectScrolledClipView(contentView); onScrollOffsetChanged?()
    }

    func scrollBy(deltaX: CGFloat) {
        guard let doc = documentView else { return }
        let maxX = max(0, doc.frame.width - contentView.bounds.width)
        guard maxX > 0.5 else { return }
        let targetX = min(max(0, contentView.bounds.origin.x + deltaX), maxX)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18; ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            contentView.animator().setBoundsOrigin(NSPoint(x: targetX, y: 0))
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reflectScrolledClipView(self.contentView); self.onScrollOffsetChanged?()
            }
        })
    }
}
