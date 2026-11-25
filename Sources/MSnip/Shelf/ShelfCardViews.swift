import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 顶部暂存架单张条目卡片（点击即复制、直接拖拽文件/图片/文本到任意应用、悬停显露微操作按钮）
final class ShelfCardView: NSView, NSDraggingSource {
    static let cardSize = NSSize(width: 114, height: 96)

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
        self.toolTip = "\(title)\n点击复制 · 拖拽分享到其他应用"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func actionRects() -> [(tag: Int, rect: CGRect, sym: String, danger: Bool)] {
        let sz: CGFloat = 19, gap: CGFloat = 4, y: CGFloat = 5
        var x = bounds.width - 5 - sz
        var list: [(Int, CGRect, String, Bool)] = [(2, CGRect(x: x, y: y, width: sz, height: sz), "xmark", true)]
        if canOCR {
            x -= (sz + gap)
            list.append((1, CGRect(x: x, y: y, width: sz, height: sz), "text.viewfinder", false))
        }
        x -= (sz + gap)
        list.append((0, CGRect(x: x, y: y, width: sz, height: sz), "pin", false))
        return list
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
        let dragImg = thumbnail ?? NSImage(size: NSSize(width: 64, height: 48))
        di.setDraggingFrame(NSRect(x: cur.x - 32, y: cur.y - 24, width: 64, height: 48), contents: dragImg)
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
        let cardR = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: cardR, cornerWidth: 9.5, cornerHeight: 9.5, transform: nil)

        ctx.saveGState()
        let bg = isDark
            ? NSColor(white: hovered ? 0.22 : 0.16, alpha: 0.92)
            : NSColor(white: hovered ? 0.98 : 0.94, alpha: 0.95)
        ctx.setFillColor(bg.cgColor)
        ctx.addPath(path); ctx.fillPath()
        ctx.setStrokeColor((hovered ? GeekTheme.accent : (isDark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.10))).cgColor)
        ctx.setLineWidth(hovered ? 1.4 : 0.8)
        ctx.addPath(path); ctx.strokePath()
        ctx.restoreGState()

        // 预览区（顶部 66pt）
        let mediaR = CGRect(x: 5, y: 5, width: bounds.width - 10, height: 62)
        let mediaClip = CGPath(roundedRect: mediaR, cornerWidth: 6.5, cornerHeight: 6.5, transform: nil)
        ctx.saveGState()
        ctx.addPath(mediaClip); ctx.clip()
        ctx.setFillColor((isDark ? NSColor(white: 0.10, alpha: 1) : NSColor(white: 0.89, alpha: 1)).cgColor)
        ctx.fill(mediaR)

        if let img = thumbnail {
            let iw = max(1, img.size.width), ih = max(1, img.size.height)
            let scale = max(mediaR.width / iw, mediaR.height / ih)
            let dw = iw * scale, dh = ih * scale
            let dst = NSRect(x: mediaR.midX - dw * 0.5, y: mediaR.midY - dh * 0.5, width: dw, height: dh)
            img.draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
        } else if let snippet = textSnippet {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 9.2, weight: .regular),
                .foregroundColor: isDark ? NSColor(white: 0.86, alpha: 1) : NSColor(white: 0.20, alpha: 1)
            ]
            (snippet as NSString).draw(in: mediaR.insetBy(dx: 5, dy: 4), withAttributes: attrs)
        } else if let sym = symbolName, let icon = NSImage(systemSymbolName: sym, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 22, weight: .regular)
            if let tinted = icon.withSymbolConfiguration(cfg) {
                let sz = tinted.size
                let ir = NSRect(x: mediaR.midX - sz.width * 0.5, y: mediaR.midY - sz.height * 0.5, width: sz.width, height: sz.height)
                tinted.draw(in: ir, from: .zero, operation: .sourceOver, fraction: 0.85, respectFlipped: true, hints: nil)
            }
        }
        ctx.restoreGState()

        // 底部标题与副标
        let pStyle = NSMutableParagraphStyle(); pStyle.lineBreakMode = .byTruncatingMiddle
        (titleText as NSString).draw(in: CGRect(x: 7, y: 69, width: bounds.width - 14, height: 13), withAttributes: [
            .font: NSFont.systemFont(ofSize: 10.2, weight: .medium),
            .foregroundColor: GeekTheme.inkPrimary,
            .paragraphStyle: pStyle
        ])
        (subtitleText as NSString).draw(in: CGRect(x: 7, y: 81.5, width: bounds.width - 14, height: 12), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.0, weight: .regular),
            .foregroundColor: GeekTheme.inkMuted,
            .paragraphStyle: pStyle
        ])

        // 悬停右上角微操作胶囊
        if hovered {
            for btn in actionRects() {
                let isHov = (hoveredBtn == btn.tag)
                let fill = isHov
                    ? (btn.danger ? NSColor.systemRed.withAlphaComponent(0.92) : GeekTheme.accent.withAlphaComponent(0.92))
                    : NSColor.black.withAlphaComponent(0.68)
                ctx.setFillColor(fill.cgColor)
                ctx.fillEllipse(in: btn.rect)
                ToolbarView.drawSymbol(btn.sym, in: btn.rect, alpha: 0.96, tint: .white)
            }
        }
    }
}

/// 顶部暂存架可拖入接收容器（支持直接从桌面/访达/浏览器拖入文件、图片或文本挂上暂存架）
final class ShelfDropContainerView: NSView {
    var onDropFiles: (([URL]) -> Void)?
    var onDropText: ((String) -> Void)?
    private var isDragTargeted = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .string])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDragTargeted = true; return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { isDragTargeted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragTargeted = false
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onDropFiles?(urls); return true
        }
        if let txt = pb.string(forType: .string), !txt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onDropText?(txt); return true
        }
        return false
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isDragTargeted, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 3, dy: 3)
        let path = CGPath(roundedRect: r, cornerWidth: 13, cornerHeight: 13, transform: nil)
        ctx.setFillColor(GeekTheme.accent.withAlphaComponent(0.10).cgColor)
        ctx.addPath(path); ctx.fillPath()
        ctx.setStrokeColor(GeekTheme.accent.withAlphaComponent(0.90).cgColor)
        ctx.setLineWidth(2.0); ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.addPath(path); ctx.strokePath()
    }
}
