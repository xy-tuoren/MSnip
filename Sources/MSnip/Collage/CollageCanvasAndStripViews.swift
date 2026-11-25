import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 底部素材条单张可调序缩略卡（悬停展示左移 ‹ / 右移 › / 移除 ✕）
final class CollageFilmstripCardView: NSView {
    static let cardSize = NSSize(width: 88, height: 64)

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
        self.index = index; self.totalCount = totalCount; self.item = item
        super.init(frame: NSRect(origin: .zero, size: Self.cardSize))
        self.toolTip = "\(item.title) · \(item.cgImage.width)×\(item.cgImage.height)\n悬停可左右调序或移除"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func controlRects() -> [(tag: Int, rect: CGRect, sym: String, danger: Bool)] {
        var list: [(Int, CGRect, String, Bool)] = []
        let y: CGFloat = bounds.height - 21, h: CGFloat = 17
        if index > 0 { list.append((0, CGRect(x: 4, y: y, width: 22, height: h), "chevron.left", false)) }
        if index < totalCount - 1 { list.append((1, CGRect(x: bounds.width - 26, y: y, width: 22, height: h), "chevron.right", false)) }
        list.append((2, CGRect(x: bounds.width - 21, y: 4, width: 17, height: 17), "xmark", true))
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
        hoveredAction = controlRects().first(where: { $0.rect.contains(convert(event.locationInWindow, from: nil)) })?.tag
    }

    override func mouseDown(with event: NSEvent) {
        guard let hit = controlRects().first(where: { $0.rect.contains(convert(event.locationInWindow, from: nil)) }) else { return }
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
        ctx.setFillColor((GeekTheme.isDark ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.92, alpha: 1)).cgColor)
        ctx.fill(r)
        let img = item.thumbnail
        let sc = max(r.width / max(1, img.size.width), r.height / max(1, img.size.height))
        let dw = img.size.width * sc, dh = img.size.height * sc
        img.draw(in: NSRect(x: r.midX - dw * 0.5, y: r.midY - dh * 0.5, width: dw, height: dh), from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor((hovered ? GeekTheme.accent : GeekTheme.borderStrong).cgColor)
        ctx.setLineWidth(hovered ? 1.5 : 0.8); ctx.addPath(path); ctx.strokePath()

        let badge = CGRect(x: 4, y: 4, width: 17, height: 17)
        ctx.setFillColor(GeekTheme.accent.withAlphaComponent(0.92).cgColor)
        ctx.fillEllipse(in: badge)
        GeekTheme.drawText("\(index + 1)", in: badge, font: .monospacedDigitSystemFont(ofSize: 9.5, weight: .bold), color: .white, align: .center)

        if hovered {
            for btn in controlRects() {
                let isHov = (hoveredAction == btn.tag)
                let fill = isHov
                    ? (btn.danger ? NSColor.systemRed.withAlphaComponent(0.92) : GeekTheme.accent.withAlphaComponent(0.92))
                    : NSColor.black.withAlphaComponent(0.74)
                let bp = CGPath(roundedRect: btn.rect, cornerWidth: btn.tag == 2 ? 8.5 : 5, cornerHeight: btn.tag == 2 ? 8.5 : 5, transform: nil)
                ctx.setFillColor(fill.cgColor); ctx.addPath(bp); ctx.fillPath()
                ToolbarView.drawSymbol(btn.sym, in: btn.rect.insetBy(dx: 2, dy: 2), alpha: 0.96, tint: .white)
            }
        }
        ctx.restoreGState()
    }
}

/// 素材条末尾虚线「+ 添加」卡片：无需找按钮，一眼看懂如何继续加图
final class CollageAddTileView: NSView {
    var onClick: (() -> Void)?
    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 1, dy: 1)
        let p = CGPath(roundedRect: r, cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.saveGState()
        ctx.setFillColor((hovered ? GeekTheme.hoverSoft : GeekTheme.segTrackBg).cgColor)
        ctx.addPath(p); ctx.fillPath()
        ctx.setStrokeColor((hovered ? GeekTheme.accent : GeekTheme.borderStrong).cgColor)
        ctx.setLineWidth(1.0); ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.addPath(p); ctx.strokePath()
        let tint = hovered ? GeekTheme.accent : GeekTheme.inkSecondary
        GeekTheme.drawSymbol("plus", pointSize: 14, weight: .semibold, in: CGRect(x: 0, y: 12, width: bounds.width, height: 20), alpha: 0.92, tint: tint)
        GeekTheme.drawText("加图", in: CGRect(x: 0, y: 36, width: bounds.width, height: 16), font: .systemFont(ofSize: 10.5, weight: .medium), color: tint, align: .center)
        ctx.restoreGState()
    }
}

/// 拼图工作室响应式布局与主题刷新扩展
extension CollageStudioController {
    func layoutUI() {
        guard let root = rootView else { return }
        let w = root.bounds.width, h = root.bounds.height
        let pad: CGFloat = 16, gap: CGFloat = 14, sideW: CGFloat = 278
        let leftW = max(380, w - sideW - pad * 2 - gap)
        let stripCardH: CGFloat = 112
        let canvasH = max(240, h - pad * 2 - stripCardH - 12)

        canvasView?.frame = NSRect(x: pad, y: pad, width: leftW, height: canvasH)

        let sy = pad + canvasH + 12
        stripCard?.frame = NSRect(x: pad, y: sy, width: leftW, height: stripCardH)
        stripHeaderLabel?.frame = NSRect(x: 12, y: 10, width: 250, height: 18)
        clearBtn?.frame = NSRect(x: leftW - 56, y: 7, width: 46, height: 24)
        addRecentBtn?.frame = NSRect(x: leftW - 146, y: 7, width: 84, height: 24)
        addClipBtn?.frame = NSRect(x: leftW - 224, y: 7, width: 72, height: 24)
        stripScrollView?.frame = NSRect(x: 10, y: 36, width: leftW - 20, height: 68)

        let rx = pad + leftW + gap, isPDF = (studioMode == .pdfMerge)
        var cy: CGFloat = pad
        modeSeg?.frame = NSRect(x: rx, y: cy, width: sideW, height: 32); cy += 44

        layoutCard?.isHidden = isPDF
        if !isPDF {
            let showCols = (options.layout == .grid)
            let lh: CGFloat = showCols ? 132 : 76
            layoutCard?.frame = NSRect(x: rx, y: cy, width: sideW, height: lh)
            layoutHeader?.frame = NSRect(x: 12, y: 10, width: sideW - 24, height: 16)
            layoutSeg?.frame = NSRect(x: 12, y: 32, width: sideW - 24, height: 30)
            colsHeader?.isHidden = !showCols; colsSeg?.isHidden = !showCols
            if showCols {
                colsHeader?.frame = NSRect(x: 12, y: 72, width: sideW - 24, height: 16)
                colsSeg?.frame = NSRect(x: 12, y: 94, width: sideW - 24, height: 26)
            }
            cy += lh + 12
        }

        let inW = sideW - 24
        gapRow?.isHidden = isPDF; radiusRow?.isHidden = isPDF; pdfHintLabel?.isHidden = !isPDF
        paramsHeader?.stringValue = isPDF ? "页面设置" : "画布参数"
        var py: CGFloat = 10
        paramsHeader?.frame = NSRect(x: 12, y: py, width: inW, height: 16); py += 24
        if !isPDF { gapRow?.frame = NSRect(x: 12, y: py, width: inW, height: 40); py += 44 }
        padRow?.frame = NSRect(x: 12, y: py, width: inW, height: 40); py += 44
        if !isPDF { radiusRow?.frame = NSRect(x: 12, y: py, width: inW, height: 40); py += 46 }
        bgHeader?.frame = NSRect(x: 12, y: py, width: inW, height: 16); py += 22
        bgSwatch?.frame = NSRect(x: 12, y: py, width: inW, height: 30); py += 40
        if isPDF { pdfHintLabel?.frame = NSRect(x: 12, y: py, width: inW, height: 36); py += 44 }
        paramsCard?.frame = NSRect(x: rx, y: cy, width: sideW, height: py + 4)

        let btnH: CGFloat = 34, row2Y = h - pad - btnH, row1Y = row2Y - btnH - 8
        copyBtn?.isHidden = isPDF; pinBtn?.isHidden = isPDF; saveBtn?.isHidden = isPDF; pdfBtn?.isHidden = !isPDF
        if isPDF {
            pdfBtn?.frame = NSRect(x: rx, y: row2Y, width: sideW, height: 38)
        } else {
            copyBtn?.frame = NSRect(x: rx, y: row1Y, width: sideW, height: btnH)
            let halfW = (sideW - 8) * 0.5
            pinBtn?.frame = NSRect(x: rx, y: row2Y, width: halfW, height: btnH)
            saveBtn?.frame = NSRect(x: rx + halfW + 8, y: row2Y, width: halfW, height: btnH)
        }
    }

    func applyTheme() {
        window?.appearance = GeekTheme.windowAppearance
        window?.backgroundColor = GeekTheme.windowBg
        stripHeaderLabel?.textColor = GeekTheme.inkPrimary
        [layoutHeader, colsHeader, paramsHeader, bgHeader].forEach { $0?.textColor = GeekTheme.inkSecondary }
        pdfHintLabel?.textColor = GeekTheme.inkMuted
        [gapRow, padRow, radiusRow].forEach { $0?.applyTheme() }
        rootView?.needsDisplay = true
        canvasView?.needsDisplay = true
    }
}
