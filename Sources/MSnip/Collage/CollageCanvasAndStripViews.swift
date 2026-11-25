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

/// 拼图实时预览画布（支持透明棋盘格、自适应等比显示与外部图片文件直接拖入）
final class CollagePreviewCanvasView: NSView {
    var previewImage: CGImage? { didSet { needsDisplay = true } }
    var showsCheckerboard: Bool = false { didSet { if oldValue != showsCheckerboard { needsDisplay = true } } }
    var onDropImageURLs: (([URL]) -> Void)?

    private var isDragTargeted = false { didSet { if oldValue != isDragTargeted { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
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
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let bgPath = CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil)
        ctx.saveGState()
        ctx.setFillColor((GeekTheme.isDark ? NSColor(white: 0.11, alpha: 1) : NSColor(white: 0.93, alpha: 1)).cgColor)
        ctx.addPath(bgPath); ctx.fillPath()
        ctx.setStrokeColor(GeekTheme.border.cgColor)
        ctx.setLineWidth(1.0); ctx.addPath(bgPath); ctx.strokePath()
        ctx.restoreGState()

        if let cg = previewImage {
            let inset = bounds.insetBy(dx: 16, dy: 16)
            let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
            let sc = min(inset.width / max(1, iw), inset.height / max(1, ih))
            let dw = round(iw * sc), dh = round(ih * sc)
            let dst = CGRect(x: round(inset.midX - dw * 0.5), y: round(inset.midY - dh * 0.5), width: dw, height: dh)

            ctx.saveGState()
            let clip = CGPath(roundedRect: dst, cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 14, color: NSColor.black.withAlphaComponent(GeekTheme.isDark ? 0.42 : 0.16).cgColor)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.addPath(clip); ctx.fillPath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(clip); ctx.clip()
            if showsCheckerboard { drawCheckerboard(in: dst, ctx: ctx) }
            NSImage(cgImage: cg, size: dst.size).draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
            ctx.restoreGState()
        } else {
            let msg = "拖入任意图片文件，或点击下方「+ 加图 / 剪贴板 / 最近截图」开始拼图"
            GeekTheme.drawText(msg, in: bounds.insetBy(dx: 24, dy: 0), font: .systemFont(ofSize: 13, weight: .medium), color: GeekTheme.inkMuted, align: .center)
        }

        if isDragTargeted {
            let dr = bounds.insetBy(dx: 4, dy: 4)
            let dp = CGPath(roundedRect: dr, cornerWidth: 10, cornerHeight: 10, transform: nil)
            ctx.saveGState()
            ctx.setFillColor(GeekTheme.accent.withAlphaComponent(0.10).cgColor)
            ctx.addPath(dp); ctx.fillPath()
            ctx.setStrokeColor(GeekTheme.accent.cgColor)
            ctx.setLineWidth(2.0); ctx.setLineDash(phase: 0, lengths: [6, 4])
            ctx.addPath(dp); ctx.strokePath()
            ctx.restoreGState()
        }
    }

    private func drawCheckerboard(in rect: CGRect, ctx: CGContext) {
        let cell: CGFloat = 10
        let c1 = (GeekTheme.isDark ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.96, alpha: 1)).cgColor
        let c2 = (GeekTheme.isDark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.87, alpha: 1)).cgColor
        ctx.setFillColor(c1); ctx.fill(rect)
        ctx.setFillColor(c2)
        var y = rect.minY, row = 0
        while y < rect.maxY {
            var x = rect.minX + (row % 2 == 0 ? 0 : cell)
            while x < rect.maxX {
                ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
                x += cell * 2
            }
            y += cell; row += 1
        }
    }
}

/// 底部素材条单张可调序缩略卡（悬停展示左移 ‹ / 右移 › / 移除 ✕）
final class CollageFilmstripCardView: NSView {
    static let cardSize = NSSize(width: 92, height: 68)

    let index: Int
    let totalCount: Int
    let item: CollageSourceItem
    var onMoveLeft: ((Int) -> Void)?
    var onMoveRight: ((Int) -> Void)?
    var onRemove: ((Int) -> Void)?

    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    private var hoveredAction: Int? { didSet { if oldValue != hoveredAction { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    init(index: Int, totalCount: Int, item: CollageSourceItem) {
        self.index = index
        self.totalCount = totalCount
        self.item = item
        super.init(frame: NSRect(origin: .zero, size: Self.cardSize))
        self.toolTip = "\(item.title) (\(item.cgImage.width)×\(item.cgImage.height))"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func controlRects() -> [(tag: Int, rect: CGRect, sym: String, danger: Bool)] {
        var list: [(Int, CGRect, String, Bool)] = []
        let y: CGFloat = bounds.height - 22, h: CGFloat = 18
        if index > 0 { list.append((0, CGRect(x: 5, y: y, width: 22, height: h), "chevron.left", false)) }
        if index < totalCount - 1 { list.append((1, CGRect(x: bounds.width - 27, y: y, width: 22, height: h), "chevron.right", false)) }
        list.append((2, CGRect(x: bounds.width - 22, y: 4, width: 18, height: 18), "xmark", true))
        return list
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false; hoveredAction = nil }
    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        hoveredAction = controlRects().first(where: { $0.rect.contains(pt) })?.tag
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard let hit = controlRects().first(where: { $0.rect.contains(pt) }) else { return }
        switch hit.tag {
        case 0: onMoveLeft?(index)
        case 1: onMoveRight?(index)
        case 2: onRemove?(index)
        default: break
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: r, cornerWidth: 8, cornerHeight: 8, transform: nil)

        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.setFillColor((GeekTheme.isDark ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.90, alpha: 1)).cgColor)
        ctx.fill(r)
        let img = item.thumbnail
        let sc = max(r.width / max(1, img.size.width), r.height / max(1, img.size.height))
        let dw = img.size.width * sc, dh = img.size.height * sc
        img.draw(in: NSRect(x: r.midX - dw * 0.5, y: r.midY - dh * 0.5, width: dw, height: dh), from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor((hovered ? GeekTheme.accent : GeekTheme.border).cgColor)
        ctx.setLineWidth(hovered ? 1.6 : 0.8); ctx.addPath(path); ctx.strokePath()

        // 左上角序号角标
        let badge = CGRect(x: 4, y: 4, width: 17, height: 17)
        ctx.setFillColor(GeekTheme.accent.withAlphaComponent(0.92).cgColor)
        ctx.fillEllipse(in: badge)
        GeekTheme.drawText("\(index + 1)", in: badge, font: .monospacedDigitSystemFont(ofSize: 9.5, weight: .bold), color: .white, align: .center)

        if hovered {
            for btn in controlRects() {
                let isHov = (hoveredAction == btn.tag)
                let fill = isHov
                    ? (btn.danger ? NSColor.systemRed.withAlphaComponent(0.92) : GeekTheme.accent.withAlphaComponent(0.92))
                    : NSColor.black.withAlphaComponent(0.72)
                let bp = CGPath(roundedRect: btn.rect, cornerWidth: btn.tag == 2 ? 9 : 5, cornerHeight: btn.tag == 2 ? 9 : 5, transform: nil)
                ctx.setFillColor(fill.cgColor); ctx.addPath(bp); ctx.fillPath()
                ToolbarView.drawSymbol(btn.sym, in: btn.rect.insetBy(dx: 2, dy: 2), alpha: 0.96, tint: .white)
            }
        }
        ctx.restoreGState()
    }
}
