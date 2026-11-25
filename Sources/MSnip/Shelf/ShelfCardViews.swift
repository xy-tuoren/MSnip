import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 晾衣绳悬挂卡片（顶部长出精巧小夹子卡在细绳上，点击复制、拖出分享、悬停轻浮并显露微操作按钮）
final class ShelfCardView: NSView, NSDraggingSource {
    static let cardSize = NSSize(width: 118, height: 112)
    static let clipTopHeight: CGFloat = 12.0

    let item: ShelfCardItem
    private let thumbnail: NSImage?
    private let titleText: String
    private let subtitleText: String
    private let symbolName: String?
    private let textSnippet: String?
    private let canOCR: Bool

    var onCopy: ((ShelfCardItem) -> Void)?
    var onPin: ((ShelfCardItem) -> Void)?
    var onOCR: ((ShelfCardItem) -> Void)?
    var onRemove: ((ShelfCardItem) -> Void)?
    var dragWriterProvider: ((ShelfCardItem) -> NSPasteboardWriting?)?

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
        self.toolTip = "\(title)\n点击复制 · 拖出分享到任意应用"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var cardBodyRect: CGRect {
        let lift: CGFloat = hovered ? -2.0 : 0.0
        return CGRect(x: 4, y: Self.clipTopHeight + lift, width: bounds.width - 8, height: bounds.height - Self.clipTopHeight - 6)
    }

    private func actionRects() -> [(tag: Int, rect: CGRect, sym: String, danger: Bool)] {
        let body = cardBodyRect
        let sz: CGFloat = 19, gap: CGFloat = 4, y: CGFloat = body.minY + 5
        var x = body.maxX - 5 - sz
        var list: [(Int, CGRect, String, Bool)] = [(2, CGRect(x: x, y: y, width: sz, height: sz), "xmark", true)]
        if canOCR {
            x -= (sz + gap)
            list.append((1, CGRect(x: x, y: y, width: sz, height: sz), "text.viewfinder", false))
        }
        x -= (sz + gap)
        list.append((0, CGRect(x: x, y: y, width: sz, height: sz), "pin", false))
        return list
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let clipHit = CGRect(x: bounds.midX - 9, y: 0, width: 18, height: Self.clipTopHeight + 6)
        return (cardBodyRect.contains(local) || clipHit.contains(local)) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; hoveredBtn = nil; needsDisplay = true }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let hit = actionRects().first(where: { $0.rect.contains(p) })?.tag
        if hit != hoveredBtn { hoveredBtn = hit; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = actionRects().first(where: { $0.rect.contains(p) }) {
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
        let dragImg = thumbnail ?? NSImage(size: NSSize(width: 68, height: 50))
        di.setDraggingFrame(NSRect(x: cur.x - 34, y: cur.y - 25, width: 68, height: 50), contents: dragImg)
        beginDraggingSession(with: [di], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartPoint != nil else { return }
        dragStartPoint = nil
        onCopy?(item)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .generic]
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let isDark = GeekTheme.isDark
        let body = cardBodyRect
        let path = CGPath(roundedRect: body, cornerWidth: 10.0, cornerHeight: 10.0, transform: nil)

        // 1) 轻盈纸感投影 + 卡片底板
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: hovered ? -5 : -3),
            blur: hovered ? 11 : 7,
            color: NSColor.black.withAlphaComponent(isDark ? 0.45 : 0.18).cgColor
        )
        let cardBg: NSColor = {
            if textSnippet != nil {
                return isDark
                    ? NSColor(srgbRed: 0.19, green: 0.18, blue: 0.15, alpha: 0.96)
                    : NSColor(srgbRed: 1.00, green: 0.985, blue: 0.94, alpha: 0.98)
            }
            return isDark
                ? NSColor(srgbRed: 0.15, green: 0.16, blue: 0.19, alpha: 0.96)
                : NSColor(srgbRed: 0.99, green: 0.99, blue: 1.00, alpha: 0.98)
        }()
        ctx.setFillColor(cardBg.cgColor)
        ctx.addPath(path); ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setStrokeColor((hovered ? GeekTheme.accent : (isDark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.10))).cgColor)
        ctx.setLineWidth(hovered ? 1.5 : 0.8)
        ctx.addPath(path); ctx.strokePath()
        ctx.restoreGState()

        // 2) 内容预览区
        let mediaR = CGRect(x: body.minX + 4.5, y: body.minY + 5, width: body.width - 9, height: 61)
        let mediaClip = CGPath(roundedRect: mediaR, cornerWidth: 6.5, cornerHeight: 6.5, transform: nil)
        ctx.saveGState()
        ctx.addPath(mediaClip); ctx.clip()
        if textSnippet == nil {
            ctx.setFillColor((isDark ? NSColor(white: 0.10, alpha: 1) : NSColor(white: 0.92, alpha: 1)).cgColor)
            ctx.fill(mediaR)
        }
        if let img = thumbnail {
            let iw = max(1, img.size.width), ih = max(1, img.size.height)
            let scale = max(mediaR.width / iw, mediaR.height / ih)
            let dw = iw * scale, dh = ih * scale
            let dst = NSRect(x: mediaR.midX - dw * 0.5, y: mediaR.midY - dh * 0.5, width: dw, height: dh)
            img.draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
        } else if let snippet = textSnippet {
            ctx.setFillColor(GeekTheme.accent.withAlphaComponent(isDark ? 0.20 : 0.14).cgColor)
            ctx.fill(CGRect(x: mediaR.minX, y: mediaR.minY, width: mediaR.width, height: 3))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 9.0, weight: .regular),
                .foregroundColor: isDark ? NSColor(white: 0.88, alpha: 1) : NSColor(white: 0.20, alpha: 1)
            ]
            (snippet as NSString).draw(in: mediaR.insetBy(dx: 4, dy: 6), withAttributes: attrs)
        } else if let sym = symbolName, let icon = NSImage(systemSymbolName: sym, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
            if let tinted = icon.withSymbolConfiguration(cfg) {
                let sz = tinted.size
                let ir = NSRect(x: mediaR.midX - sz.width * 0.5, y: mediaR.midY - sz.height * 0.5, width: sz.width, height: sz.height)
                tinted.draw(in: ir, from: .zero, operation: .sourceOver, fraction: 0.86, respectFlipped: true, hints: nil)
            }
        }
        ctx.restoreGState()

        // 3) 底部精简标题与尺寸/类型副标
        let pStyle = NSMutableParagraphStyle(); pStyle.lineBreakMode = .byTruncatingMiddle
        (titleText as NSString).draw(in: CGRect(x: body.minX + 6, y: mediaR.maxY + 3, width: body.width - 12, height: 12.5), withAttributes: [
            .font: NSFont.systemFont(ofSize: 10.0, weight: .medium),
            .foregroundColor: GeekTheme.inkPrimary,
            .paragraphStyle: pStyle
        ])
        (subtitleText as NSString).draw(in: CGRect(x: body.minX + 6, y: mediaR.maxY + 15, width: body.width - 12, height: 11.5), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8.8, weight: .regular),
            .foregroundColor: GeekTheme.inkMuted,
            .paragraphStyle: pStyle
        ])

        // 4) 顶部小夹子（视觉咬合在悬链细绳上）
        drawClothespin(in: ctx, centerX: body.midX, topY: body.minY - 10, isDark: isDark)

        // 5) 悬停右上角微操作胶囊
        if hovered {
            for btn in actionRects() {
                let isHov = (hoveredBtn == btn.tag)
                let fill = isHov
                    ? (btn.danger ? NSColor.systemRed.withAlphaComponent(0.92) : GeekTheme.accent.withAlphaComponent(0.92))
                    : NSColor.black.withAlphaComponent(0.70)
                ctx.setFillColor(fill.cgColor)
                ctx.fillEllipse(in: btn.rect)
                ToolbarView.drawSymbol(btn.sym, in: btn.rect, alpha: 0.96, tint: .white)
            }
        }
    }

    private func drawClothespin(in ctx: CGContext, centerX: CGFloat, topY: CGFloat, isDark: Bool) {
        let clipR = CGRect(x: round(centerX - 5.0), y: topY, width: 10.0, height: 16.0)
        let path = CGPath(roundedRect: clipR, cornerWidth: 3.2, cornerHeight: 3.2, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2.5, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        let fill = isDark
            ? NSColor(srgbRed: 0.56, green: 0.60, blue: 0.68, alpha: 1.0)
            : NSColor(srgbRed: 0.85, green: 0.77, blue: 0.65, alpha: 1.0)
        ctx.setFillColor(fill.cgColor)
        ctx.addPath(path); ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setStrokeColor((isDark ? NSColor.white.withAlphaComponent(0.32) : NSColor.black.withAlphaComponent(0.18)).cgColor)
        ctx.setLineWidth(0.7)
        ctx.addPath(path); ctx.strokePath()
        // 中部金属弹簧小横杠
        let springY = clipR.minY + 7.5
        ctx.setStrokeColor((isDark ? NSColor(white: 0.22, alpha: 0.85) : NSColor(white: 0.36, alpha: 0.65)).cgColor)
        ctx.setLineWidth(1.2)
        ctx.move(to: CGPoint(x: clipR.minX + 1.5, y: springY))
        ctx.addLine(to: CGPoint(x: clipR.maxX - 1.5, y: springY))
        ctx.strokePath()
        ctx.restoreGState()
    }
}

/// 支持「普通鼠标上下滚轮直接左右滚动 + 触控板双指横向轻扫 + 空白缝隙透明穿透」的晾衣绳横向滚动容器
final class ShelfHorizontalScrollView: NSScrollView {
    var onScrollOffsetChanged: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let doc = documentView else { return nil }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for sub in doc.subviews {
            let ptInSub = sub.convert(point, from: superview)
            if let hit = sub.hitTest(ptInSub) { return hit }
        }
        return nil
    }

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
            ctx.duration = 0.20
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
