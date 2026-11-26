import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 立体陶瓷白通知卡片视图（兼顾深色编辑器极亮反差与浅色网页多层环境深阴影，支持真实截图等比裁切缩略图）
final class ToastCardView: NSView {
    static let shadowPadX: CGFloat = 24
    static let shadowPadTop: CGFloat = 16
    static let shadowPadBot: CGFloat = 28

    private let cleanMessage: String
    private let subtitle: String?
    private let preview: CGImage?
    private let swatch: RGBAColor?
    private let statusSymbol: String
    private let badgeColor: NSColor
    private let actionTitle: String?
    private let onTrigger: (() -> Void)?
    private let onClose: (() -> Void)?
    private let onHoverChanged: ((Bool) -> Void)?

    var hasAction: Bool { actionTitle != nil }
    var remainingProgress: CGFloat = 1.0 {
        didSet {
            guard hasAction, cardRect.width > 0 else { return }
            setNeedsDisplay(CGRect(x: cardRect.minX, y: cardRect.maxY - 4, width: cardRect.width, height: 4))
        }
    }
    private var cardRect: CGRect = .zero
    private var actionBtnRect: CGRect = .zero
    private var closeBtnRect: CGRect = .zero
    private var hoveredAction = false { didSet { if oldValue != hoveredAction { needsDisplay = true } } }
    private var hoveredClose = false { didSet { if oldValue != hoveredClose { needsDisplay = true } } }

    let panelSize: NSSize
    override var isFlipped: Bool { true }

    init(
        rawMessage: String,
        subtitle: String?,
        preview: CGImage?,
        swatch: RGBAColor?,
        actionTitle: String?,
        onTrigger: (() -> Void)?,
        onClose: (() -> Void)?,
        onHoverChanged: ((Bool) -> Void)?
    ) {
        var trimmed = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let isWarn = trimmed.hasPrefix("⚠") || trimmed.contains("失败") || trimmed.contains("未") || trimmed.contains("请先")
        let isOK = trimmed.hasPrefix("✓") || trimmed.contains("已")
        if trimmed.hasPrefix("✓") || trimmed.hasPrefix("⚠") {
            trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        self.cleanMessage = trimmed
        self.subtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.preview = preview.flatMap { Self.makeCompactThumb($0) }
        self.swatch = swatch
        self.actionTitle = actionTitle
        self.onTrigger = onTrigger
        self.onClose = onClose
        self.onHoverChanged = onHoverChanged
        self.statusSymbol = isWarn ? "exclamationmark" : (isOK ? "checkmark" : "info")
        self.badgeColor = isWarn
            ? NSColor(srgbRed: 0.95, green: 0.55, blue: 0.08, alpha: 1.0)
            : (isOK ? NSColor(srgbRed: 0.06, green: 0.68, blue: 0.44, alpha: 1.0) : MSnipUITheme.accent)

        let interactive = (actionTitle != nil)
        let hasSub = !(self.subtitle ?? "").isEmpty
        let titleW = (trimmed as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: interactive ? 14.0 : 13.5, weight: .semibold)]).width
        let subW: CGFloat = hasSub
            ? ((self.subtitle! as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .regular)]).width)
            : 0
        let textW = min(380, ceil(max(titleW, subW)))
        let leftW: CGFloat = (preview != nil) ? 78 : (interactive ? 58 : 48)
        let rightW: CGFloat = actionTitle.map {
            ceil(($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold)]).width + 32) + 46
        } ?? 20
        let cardW = max(interactive ? 440 : 216, leftW + textW + rightW)
        let cardH: CGFloat = interactive ? 64 : 44
        self.panelSize = NSSize(
            width: cardW + Self.shadowPadX * 2,
            height: cardH + Self.shadowPadTop + Self.shadowPadBot
        )
        super.init(frame: NSRect(origin: .zero, size: self.panelSize))
        recomputeRects()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); recomputeRects() }

    private func recomputeRects() {
        cardRect = CGRect(
            x: Self.shadowPadX,
            y: Self.shadowPadTop,
            width: bounds.width - Self.shadowPadX * 2,
            height: bounds.height - Self.shadowPadTop - Self.shadowPadBot
        )
        guard let act = actionTitle, cardRect.width > 0 else { return }
        let actSz = (act as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold)])
        let btnW = ceil(actSz.width + 28), btnH: CGFloat = 34
        closeBtnRect = CGRect(x: cardRect.maxX - 34, y: round(cardRect.midY - 12), width: 24, height: 24)
        actionBtnRect = CGRect(x: closeBtnRect.minX - btnW - 8, y: round(cardRect.midY - btnH * 0.5), width: btnW, height: btnH)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        guard hasAction else { return }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true); updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) {
        hoveredAction = false; hoveredClose = false; NSCursor.arrow.set(); onHoverChanged?(false)
    }

    private func updateHover(at pt: CGPoint) {
        guard cardRect.contains(pt) else {
            hoveredAction = false; hoveredClose = false; NSCursor.arrow.set(); return
        }
        hoveredClose = closeBtnRect.contains(pt)
        hoveredAction = !hoveredClose
        NSCursor.pointingHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard hasAction else { return }
        let pt = convert(event.locationInWindow, from: nil)
        guard cardRect.contains(pt) else { return }
        if closeBtnRect.contains(pt) { onClose?() } else { onTrigger?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        recomputeRects()
        guard let ctx = NSGraphicsContext.current?.cgContext, cardRect.width > 10 else { return }
        let radius: CGFloat = hasAction ? 15.5 : 12.0
        let cardPath = CGPath(roundedRect: cardRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // 1) 真实向下多层环境投影（CGContext 阴影设备坐标 -Y 朝下）+ 纯白陶瓷卡片面
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -7),
            blur: 22,
            color: NSColor(srgbRed: 0.03, green: 0.07, blue: 0.16, alpha: 0.28).cgColor
        )
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addPath(cardPath)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(cardPath)
        ctx.clip()
        if hasAction, remainingProgress > 0.01 {
            ctx.setFillColor(MSnipUITheme.accent.withAlphaComponent(0.24).cgColor)
            ctx.fill(CGRect(x: cardRect.minX, y: cardRect.maxY - 2.5, width: cardRect.width * remainingProgress, height: 2.5))
        }
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(NSColor(srgbRed: 0.06, green: 0.10, blue: 0.18, alpha: 0.16).cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(CGPath(roundedRect: cardRect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.strokePath()
        ctx.restoreGState()

        // 2) 左侧：真实截图等比填充微缩略图（带绿色完成小圆章）或实心圆角状态章
        let textX = drawLeadingVisual(in: ctx)

        // 3) 中间主副文案
        let maxTextW = max(40, (hasAction ? actionBtnRect.minX - 14 : cardRect.maxX - 16) - textX)
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingMiddle
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: hasAction ? 14.0 : 13.5, weight: .semibold),
            .foregroundColor: MSnipUITheme.inkPrimary,
            .paragraphStyle: para
        ]
        let titleNs = cleanMessage as NSString
        let titleSz = titleNs.size(withAttributes: titleAttrs)
        if let sub = subtitle, !sub.isEmpty {
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
                .foregroundColor: MSnipUITheme.inkSecondary,
                .paragraphStyle: para
            ]
            let subNs = sub as NSString
            let subSz = subNs.size(withAttributes: subAttrs)
            let topY = round(cardRect.midY - (titleSz.height + 2 + subSz.height) * 0.5)
            titleNs.draw(in: CGRect(x: textX, y: topY, width: maxTextW, height: titleSz.height + 2), withAttributes: titleAttrs)
            subNs.draw(in: CGRect(x: textX, y: topY + titleSz.height + 2, width: maxTextW, height: subSz.height + 2), withAttributes: subAttrs)
        } else {
            titleNs.draw(in: CGRect(x: textX, y: round(cardRect.midY - titleSz.height * 0.5), width: maxTextW, height: titleSz.height + 2), withAttributes: titleAttrs)
        }

        // 4) 右侧醒目圆角主按钮 + 轻量关闭钮
        if let act = actionTitle {
            MSnipUITheme.drawPrimaryCTA(ctx: ctx, rect: actionBtnRect, radius: 8.5, hovered: hoveredAction)
            let actAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: NSColor.white]
            let actNs = act as NSString
            let actSz = actNs.size(withAttributes: actAttrs)
            actNs.draw(at: CGPoint(x: round(actionBtnRect.midX - actSz.width * 0.5), y: round(actionBtnRect.midY - actSz.height * 0.5)), withAttributes: actAttrs)
            if hoveredClose {
                ctx.setFillColor(MSnipUITheme.hoverFill.cgColor)
                ctx.fillEllipse(in: closeBtnRect)
            }
            ToolbarView.drawSymbol("xmark", in: closeBtnRect.insetBy(dx: 6.5, dy: 6.5), alpha: hoveredClose ? 0.90 : 0.45, tint: MSnipUITheme.inkSecondary)
        }
    }

    private func drawLeadingVisual(in ctx: CGContext) -> CGFloat {
        if let cg = preview, cg.width > 0, cg.height > 0 {
            let thumbRect = CGRect(x: cardRect.minX + 13, y: round(cardRect.midY - 20), width: 50, height: 40)
            let thumbPath = CGPath(roundedRect: thumbRect, cornerWidth: 7.0, cornerHeight: 7.0, transform: nil)
            ctx.saveGState()
            ctx.setFillColor(MSnipUITheme.subtleFill.cgColor)
            ctx.addPath(thumbPath); ctx.fillPath()
            ctx.addPath(thumbPath); ctx.clip()
            let scale = max(thumbRect.width / CGFloat(cg.width), thumbRect.height / CGFloat(cg.height))
            let dw = CGFloat(cg.width) * scale, dh = CGFloat(cg.height) * scale
            let drawR = CGRect(x: thumbRect.midX - dw * 0.5, y: thumbRect.midY - dh * 0.5, width: dw, height: dh)
            NSImage(cgImage: cg, size: drawR.size).draw(in: drawR, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
            ctx.restoreGState()
            ctx.setStrokeColor(MSnipUITheme.borderStrong.cgColor); ctx.setLineWidth(1.0); ctx.addPath(thumbPath); ctx.strokePath()

            let dot = CGRect(x: thumbRect.maxX - 9, y: thumbRect.maxY - 9, width: 15, height: 15)
            ctx.setFillColor(NSColor.white.cgColor); ctx.fillEllipse(in: dot.insetBy(dx: -1.5, dy: -1.5))
            ctx.setFillColor(badgeColor.cgColor); ctx.fillEllipse(in: dot)
            ToolbarView.drawSymbol("checkmark", in: dot.insetBy(dx: 3.2, dy: 3.2), alpha: 1.0, tint: .white)
            return thumbRect.maxX + 14
        }
        if let sw = swatch {
            let swRect = CGRect(x: cardRect.minX + 14, y: round(cardRect.midY - 11), width: 22, height: 22)
            let swPath = CGPath(roundedRect: swRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.setFillColor(sw.cgColor); ctx.addPath(swPath); ctx.fillPath()
            ctx.setStrokeColor(MSnipUITheme.borderStrong.cgColor); ctx.setLineWidth(1.0); ctx.addPath(swPath); ctx.strokePath()
            return swRect.maxX + 11
        }
        let sz: CGFloat = hasAction ? 32 : 24
        let bRect = CGRect(x: cardRect.minX + 14, y: round(cardRect.midY - sz * 0.5), width: sz, height: sz)
        let bPath = CGPath(roundedRect: bRect, cornerWidth: sz * 0.30, cornerHeight: sz * 0.30, transform: nil)
        ctx.setFillColor(badgeColor.cgColor); ctx.addPath(bPath); ctx.fillPath()
        ToolbarView.drawSymbol(statusSymbol, in: bRect.insetBy(dx: sz * 0.24, dy: sz * 0.24), alpha: 1.0, tint: .white)
        return bRect.maxX + 12
    }

    /// 初始化时一次性降采样为 `100×80 px` 微缩略图，立即释放外部传入的 5K 全屏 `CGImage`（省去 ~60 MB 驻留与 30fps 重缩放开销）
    private static func makeCompactThumb(_ src: CGImage) -> CGImage? {
        guard src.width > 120 || src.height > 96 else { return src }
        let w = 100, h = 80
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return src }
        let sc = max(CGFloat(w) / CGFloat(src.width), CGFloat(h) / CGFloat(src.height))
        let dw = CGFloat(src.width) * sc, dh = CGFloat(src.height) * sc
        ctx.interpolationQuality = .medium
        ctx.draw(src, in: CGRect(x: (CGFloat(w) - dw) * 0.5, y: (CGFloat(h) - dh) * 0.5, width: dw, height: dh))
        return ctx.makeImage() ?? src
    }
}
