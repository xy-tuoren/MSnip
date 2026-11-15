import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// OCR 结果窗顶栏与底栏使用的精致胶囊按钮
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
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]
        let tw = (title as NSString).size(withAttributes: attrs).width
        let iconW: CGFloat = symbolName != nil ? 17 : 0
        return NSSize(width: ceil(tw + iconW + 22), height: 26)
    }

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
        let path = CGPath(roundedRect: r, cornerWidth: 6.5, cornerHeight: 6.5, transform: nil)

        ctx.saveGState()
        if isPrimaryAccent {
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(hovered ? 1.0 : 0.90).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        } else if isToggledOn {
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor)
            ctx.setLineWidth(1.0)
            ctx.addPath(path)
            ctx.strokePath()
        } else {
            ctx.setFillColor(NSColor.white.withAlphaComponent(hovered ? 0.14 : 0.08).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.15).cgColor)
            ctx.setLineWidth(1.0)
            ctx.addPath(path)
            ctx.strokePath()
        }

        let fg: NSColor = isPrimaryAccent ? .white : (isToggledOn ? .white : NSColor(white: 0.90, alpha: 1))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: isPrimaryAccent ? .semibold : .medium),
            .foregroundColor: fg
        ]
        let tSz = (title as NSString).size(withAttributes: attrs)
        var startX = (bounds.width - tSz.width - (symbolName != nil ? 16 : 0)) * 0.5

        if let sym = symbolName,
           let baseImg = NSImage(systemSymbolName: sym, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 11.5, weight: .semibold)
            if let configured = baseImg.withSymbolConfiguration(cfg),
               let cg = configured.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let sz = configured.size
                let ir = CGRect(x: round(startX), y: round((bounds.height - sz.height) * 0.5), width: sz.width, height: sz.height)
                ctx.saveGState()
                ctx.translateBy(x: 0, y: ir.minY + ir.maxY)
                ctx.scaleBy(x: 1, y: -1)
                ctx.clip(to: ir, mask: cg)
                ctx.setFillColor(fg.cgColor)
                ctx.fill(ir)
                ctx.restoreGState()
                startX += 16
            }
        }
        (title as NSString).draw(
            at: CGPoint(x: round(startX), y: round((bounds.height - tSz.height) * 0.5)),
            withAttributes: attrs
        )
        ctx.restoreGState()
    }
}

/// 保持换行 / 合并段落 双态分段切换控件
final class OCRModeSegmentView: NSView {
    var mode: OCRLayoutMode = .preserveLines { didSet { needsDisplay = true } }
    var onModeChanged: ((OCRLayoutMode) -> Void)?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 148, height: 26) }

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
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.addPath(CGPath(roundedRect: outer, cornerWidth: 6.5, cornerHeight: 6.5, transform: nil))
        ctx.fillPath()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(CGPath(roundedRect: outer, cornerWidth: 6.5, cornerHeight: 6.5, transform: nil))
        ctx.strokePath()

        let halfW = (bounds.width - 4) * 0.5
        let selX: CGFloat = mode == .preserveLines ? 2 : (2 + halfW)
        let selRect = CGRect(x: selX, y: 2, width: halfW, height: bounds.height - 4)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.addPath(CGPath(roundedRect: selRect, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.fillPath()

        let labels: [(String, CGRect, Bool)] = [
            ("保持换行", CGRect(x: 2, y: 0, width: halfW, height: bounds.height), mode == .preserveLines),
            ("合并段落", CGRect(x: 2 + halfW, y: 0, width: halfW, height: bounds.height), mode == .mergeParagraphs)
        ]
        for (txt, rect, active) in labels {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: active ? .semibold : .regular),
                .foregroundColor: active ? NSColor.white : NSColor(white: 0.72, alpha: 1)
            ]
            let sz = (txt as NSString).size(withAttributes: attrs)
            (txt as NSString).draw(
                at: CGPoint(x: rect.minX + (rect.width - sz.width) * 0.5, y: (rect.height - sz.height) * 0.5),
                withAttributes: attrs
            )
        }
        ctx.restoreGState()
    }
}
