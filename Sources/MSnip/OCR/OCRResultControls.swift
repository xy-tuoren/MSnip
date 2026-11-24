import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// OCR 与翻译对照窗使用的清爽浅色白底胶囊按钮（支持高亮激活态、主色调 CTA 态及手指光标）
final class OCRPillButton: NSView {
    var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var symbolName: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var isToggledOn: Bool = false { didSet { needsDisplay = true } }
    var isPrimaryAccent: Bool = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    private var hovered = false

    override var isFlipped: Bool { true }

    init(title: String, symbol: String? = nil, primary: Bool = false) {
        self.title = title
        self.symbolName = symbol
        self.isPrimaryAccent = primary
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        if title.isEmpty, symbolName != nil {
            return NSSize(width: 28, height: 28)
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]
        let tw = (title as NSString).size(withAttributes: attrs).width
        let iconW: CGFloat = symbolName != nil ? 17 : 0
        return NSSize(width: ceil(tw + iconW + 22), height: 28)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: r, cornerWidth: 7.0, cornerHeight: 7.0, transform: nil)

        ctx.saveGState()
        let fg: NSColor
        if isPrimaryAccent {
            MSnipUITheme.drawPrimaryCTA(ctx: ctx, rect: r, radius: 7.0, hovered: hovered)
            fg = .white
        } else if isToggledOn {
            ctx.setFillColor(ResultTheme.activeSoftFill.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setStrokeColor(ResultTheme.accent.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(1.0)
            ctx.addPath(path)
            ctx.strokePath()
            fg = ResultTheme.accent
        } else {
            ctx.setFillColor((hovered ? ResultTheme.subtleFill : ResultTheme.cardSolid).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setStrokeColor(ResultTheme.borderStrong.cgColor)
            ctx.setLineWidth(1.0)
            ctx.addPath(path)
            ctx.strokePath()
            fg = ResultTheme.inkPrimary
        }

        if title.isEmpty, let sym = symbolName {
            let ir = CGRect(x: round((bounds.width - 14) * 0.5), y: 0, width: 14, height: bounds.height)
            ToolbarView.drawSymbol(sym, in: ir, alpha: 0.96, tint: fg)
            ctx.restoreGState()
            return
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: (isPrimaryAccent || isToggledOn) ? .semibold : .medium),
            .foregroundColor: fg
        ]
        let tSz = (title as NSString).size(withAttributes: attrs)
        var startX = (bounds.width - tSz.width - (symbolName != nil ? 16 : 0)) * 0.5

        if let sym = symbolName {
            let ir = CGRect(x: round(startX), y: 0, width: 14, height: bounds.height)
            ToolbarView.drawSymbol(sym, in: ir, alpha: 0.96, tint: fg)
            startX += 16
        }
        (title as NSString).draw(
            at: CGPoint(x: round(startX), y: round((bounds.height - tSz.height) * 0.5)),
            withAttributes: attrs
        )
        ctx.restoreGState()
    }
}

/// 清爽浅色白底「保持换行 / 合并段落」双态分段切换控件
final class OCRModeSegmentView: NSView {
    var mode: OCRLayoutMode = .preserveLines { didSet { needsDisplay = true } }
    var onModeChanged: ((OCRLayoutMode) -> Void)?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 28) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let target: OCRLayoutMode = p.x < bounds.width * 0.5 ? .preserveLines : .mergeParagraphs
        if target != mode {
            mode = target
            onModeChanged?(target)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let outer = bounds.insetBy(dx: 0.5, dy: 0.5)
        ctx.saveGState()
        ctx.setFillColor(ResultTheme.sidebarBg.cgColor)
        ctx.addPath(CGPath(roundedRect: outer, cornerWidth: 7.0, cornerHeight: 7.0, transform: nil))
        ctx.fillPath()
        ctx.setStrokeColor(ResultTheme.borderHairline.cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(CGPath(roundedRect: outer, cornerWidth: 7.0, cornerHeight: 7.0, transform: nil))
        ctx.strokePath()

        let halfW = (bounds.width - 4) * 0.5
        let selX: CGFloat = mode == .preserveLines ? 2 : (2 + halfW)
        let selRect = CGRect(x: selX, y: 2, width: halfW, height: bounds.height - 4)
        let thumbPath = CGPath(roundedRect: selRect, cornerWidth: 5.5, cornerHeight: 5.5, transform: nil)
        ctx.setFillColor(ResultTheme.cardSolid.cgColor)
        ctx.addPath(thumbPath)
        ctx.fillPath()
        ctx.setStrokeColor(ResultTheme.borderHairline.cgColor)
        ctx.addPath(thumbPath)
        ctx.strokePath()

        let labels: [(String, CGRect, Bool)] = [
            ("保持换行", CGRect(x: 2, y: 0, width: halfW, height: bounds.height), mode == .preserveLines),
            ("合并段落", CGRect(x: 2 + halfW, y: 0, width: halfW, height: bounds.height), mode == .mergeParagraphs)
        ]
        for (txt, rect, active) in labels {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: active ? .semibold : .medium),
                .foregroundColor: active ? ResultTheme.inkPrimary : ResultTheme.inkSecondary
            ]
            let sz = (txt as NSString).size(withAttributes: attrs)
            (txt as NSString).draw(
                at: CGPoint(x: round(rect.minX + (rect.width - sz.width) * 0.5), y: round((rect.height - sz.height) * 0.5)),
                withAttributes: attrs
            )
        }
        ctx.restoreGState()
    }
}
