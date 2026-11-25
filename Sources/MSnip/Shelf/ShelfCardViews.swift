import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 高密度实用型暂存卡片（`106 × 84pt`）：
/// - 缩略图自带 `0.6pt` 内描边防止纯白截图隐身；底部单行对齐「标题 + 尺寸/字数」零空间浪费；
/// - 严格单卡高亮互斥，悬停仅在右上角浮出精巧半透明微操作胶囊（贴图 / 识字 / 删除），不遮挡预览内容。
final class ShelfCardView: NSView, NSDraggingSource {
    static let cardSize = NSSize(width: 106, height: 84)

    let item: ShelfCardItem
    private let thumbnail: NSImage?
    private let titleText: String
    private let subtitleText: String
    private let symbolName: String?
    private let textSnippet: String?
    private let canOCR: Bool

    var onHoverStart: ((ShelfCardView) -> Void)?
    var onToggleSelect: ((ShelfCardItem) -> Void)?
    var onCopy: ((ShelfCardItem) -> Void)?
    var onPin: ((ShelfCardItem) -> Void)?
    var onOCR: ((ShelfCardItem) -> Void)?
    var onRemove: ((ShelfCardItem) -> Void)?
    var dragWriterProvider: ((ShelfCardItem) -> NSPasteboardWriting?)?

    var selectionOrder: Int? { didSet { if oldValue != selectionOrder { needsDisplay = true } } }
    private var hovered = false
    private var hoveredBtn: Int? // 0 = pin, 1 = ocr, 2 = remove
    private var dragStartPoint: NSPoint?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(item: ShelfCardItem, thumbnail: NSImage?, title: String, subtitle: String, symbol: String?, textSnippet: String?, canOCR: Bool) {
        self.item = item
        self.thumbnail = thumbnail
        self.titleText = title
        self.subtitleText = subtitle
        self.symbolName = symbol
        self.textSnippet = textSnippet
        self.canOCR = canOCR
        super.init(frame: NSRect(origin: .zero, size: Self.cardSize))
        self.toolTip = "\(title) · \(subtitle)\n单击复制 · ⌘+单击多选拼图 · 拖出分享"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func clearHover() {
        guard hovered || hoveredBtn != nil else { return }
        hovered = false
        hoveredBtn = nil
        needsDisplay = true
    }

    private func actionSlots() -> (pill: CGRect, slots: [(tag: Int, rect: CGRect, sym: String, danger: Bool)]) {
        var defs: [(Int, String, Bool)] = [(0, "pin", false)]
        if canOCR { defs.append((1, "text.viewfinder", false)) }
        defs.append((2, "xmark", true))
        let slotW: CGFloat = 19, slotH: CGFloat = 18, padX: CGFloat = 2
        let pillW = CGFloat(defs.count) * slotW + padX * 2
        let pill = CGRect(x: bounds.width - 5 - pillW, y: 5, width: pillW, height: slotH + 2)
        var slots: [(Int, CGRect, String, Bool)] = []
        var x = pill.minX + padX
        for (tag, sym, danger) in defs {
            slots.append((tag, CGRect(x: x, y: pill.minY + 1, width: slotW, height: slotH), sym, danger))
            x += slotW
        }
        return (pill, slots)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        onHoverStart?(self)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) { clearHover() }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !hovered { hovered = true; onHoverStart?(self); needsDisplay = true }
        let hit = actionSlots().slots.first(where: { $0.rect.contains(p) })?.tag
        if hit != hoveredBtn { hoveredBtn = hit; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = actionSlots().slots.first(where: { $0.rect.contains(p) }) {
            switch hit.tag {
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
        if event.modifierFlags.contains(.command) {
            onToggleSelect?(item)
            return
        }
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

        // 1) 规整卡片底板
        ctx.saveGState()
        let bg: NSColor = {
            if textSnippet != nil {
                return isDark
                    ? NSColor(srgbRed: 0.21, green: 0.20, blue: 0.16, alpha: hovered ? 0.98 : 0.92)
                    : NSColor(srgbRed: 0.99, green: 0.975, blue: 0.93, alpha: 0.98)
            }
            return isDark
                ? NSColor(white: hovered ? 0.22 : 0.16, alpha: 0.94)
                : NSColor(white: hovered ? 1.00 : 0.96, alpha: 0.98)
        }()
        ctx.setFillColor(bg.cgColor)
        ctx.addPath(path); ctx.fillPath()
        let isSelected = (selectionOrder != nil)
        ctx.setStrokeColor(((isSelected || hovered) ? GeekTheme.accent : (isDark ? NSColor.white.withAlphaComponent(0.11) : NSColor.black.withAlphaComponent(0.10))).cgColor)
        ctx.setLineWidth(isSelected ? 1.8 : (hovered ? 1.4 : 0.8))
        ctx.addPath(path); ctx.strokePath()
        ctx.restoreGState()

        // 2) 高屏占比预览区（61pt 高 + 0.6pt 内细边防止纯白图隐身）
        let mediaR = CGRect(x: 3.5, y: 3.5, width: bounds.width - 7, height: 61)
        let mediaClip = CGPath(roundedRect: mediaR, cornerWidth: 5.5, cornerHeight: 5.5, transform: nil)
        ctx.saveGState()
        ctx.addPath(mediaClip); ctx.clip()
        if textSnippet == nil {
            ctx.setFillColor((isDark ? NSColor(white: 0.10, alpha: 1) : NSColor(white: 0.91, alpha: 1)).cgColor)
            ctx.fill(mediaR)
        }
        if let img = thumbnail {
            let iw = max(1, img.size.width), ih = max(1, img.size.height)
            let scale = max(mediaR.width / iw, mediaR.height / ih)
            let dw = iw * scale, dh = ih * scale
            let dst = NSRect(x: mediaR.midX - dw * 0.5, y: mediaR.midY - dh * 0.5, width: dw, height: dh)
            img.draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
        } else if let snippet = textSnippet {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 9.0, weight: .regular),
                .foregroundColor: isDark ? NSColor(white: 0.88, alpha: 1) : NSColor(white: 0.20, alpha: 1)
            ]
            (snippet as NSString).draw(in: mediaR.insetBy(dx: 4, dy: 3), withAttributes: attrs)
        } else if let sym = symbolName, let icon = NSImage(systemSymbolName: sym, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
            if let tinted = icon.withSymbolConfiguration(cfg) {
                let sz = tinted.size
                let ir = NSRect(x: mediaR.midX - sz.width * 0.5, y: mediaR.midY - sz.height * 0.5, width: sz.width, height: sz.height)
                tinted.draw(in: ir, from: .zero, operation: .sourceOver, fraction: 0.85, respectFlipped: true, hints: nil)
            }
        }
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor((isDark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.09)).cgColor)
        ctx.setLineWidth(0.6)
        ctx.addPath(mediaClip); ctx.strokePath()
        ctx.restoreGState()

        // 3) 底部单行紧凑信息栏（左侧时间/标题，右侧尺寸/字数）
        let footY: CGFloat = 67.5
        let metaAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular),
            .foregroundColor: GeekTheme.inkMuted
        ]
        let metaW = min(50.0, ceil((subtitleText as NSString).size(withAttributes: metaAttrs).width))
        let pStyle = NSMutableParagraphStyle(); pStyle.lineBreakMode = .byTruncatingMiddle
        let titleW = max(24.0, bounds.width - 12.0 - metaW - 4.0)
        (titleText as NSString).draw(in: CGRect(x: 5.5, y: footY, width: titleW, height: 13), withAttributes: [
            .font: NSFont.systemFont(ofSize: 9.8, weight: .medium),
            .foregroundColor: GeekTheme.inkPrimary,
            .paragraphStyle: pStyle
        ])
        (subtitleText as NSString).draw(in: CGRect(x: bounds.width - 5.5 - metaW, y: footY + 0.8, width: metaW, height: 12), withAttributes: metaAttrs)

        // 4) 多选拼图序号角标（⌘+点击勾选）
        if let order = selectionOrder {
            let badge = CGRect(x: 5, y: 5, width: 17, height: 17)
            ctx.saveGState()
            ctx.setFillColor(GeekTheme.accent.cgColor)
            ctx.fillEllipse(in: badge)
            GeekTheme.drawText("\(order)", in: badge, font: .monospacedDigitSystemFont(ofSize: 9.5, weight: .bold), color: .white, align: .center)
            ctx.restoreGState()
        }

        // 5) 悬停右上角紧凑一体化微胶囊（零遮挡预览）
        if hovered {
            let (pill, slots) = actionSlots()
            let pillPath = CGPath(roundedRect: pill, cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.saveGState()
            ctx.setFillColor(NSColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 0.78).cgColor)
            ctx.addPath(pillPath); ctx.fillPath()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
            ctx.setLineWidth(0.6); ctx.addPath(pillPath); ctx.strokePath()
            for btn in slots {
                if hoveredBtn == btn.tag {
                    let hiPath = CGPath(roundedRect: btn.rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 4.5, cornerHeight: 4.5, transform: nil)
                    ctx.setFillColor((btn.danger ? NSColor.systemRed : GeekTheme.accent).withAlphaComponent(0.92).cgColor)
                    ctx.addPath(hiPath); ctx.fillPath()
                }
                ToolbarView.drawSymbol(btn.sym, in: btn.rect.insetBy(dx: 1.5, dy: 1.5), alpha: 0.96, tint: .white)
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
            super.scrollWheel(with: event)
            onScrollOffsetChanged?()
            return
        }
        let curX = contentView.bounds.origin.x
        let nextX = ShelfTriggerGeometry.nextHorizontalScrollX(
            currentX: curX,
            maxX: maxX,
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas
        )
        contentView.scroll(to: NSPoint(x: nextX, y: 0))
        reflectScrolledClipView(contentView)
        onScrollOffsetChanged?()
    }

    func scrollBy(deltaX: CGFloat) {
        guard let doc = documentView else { return }
        let maxX = max(0, doc.frame.width - contentView.bounds.width)
        guard maxX > 0.5 else { return }
        let targetX = min(max(0, contentView.bounds.origin.x + deltaX), maxX)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            contentView.animator().setBoundsOrigin(NSPoint(x: targetX, y: 0))
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reflectScrolledClipView(self.contentView)
                self.onScrollOffsetChanged?()
            }
        })
    }
}
