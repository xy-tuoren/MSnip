import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// PixPin 风格截图界面辅助 HUD：
/// 1) 屏幕角落自适应避让的轻量快捷键速查面板 (`ShortcutTipsWidget`)
/// 2) 选区尺寸与状态胶囊 (`drawHUDPill`) 及通用浅色小键帽绘制器 (`drawKeycapTip`)
extension OverlayView {
    private static let hudPillAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
        .foregroundColor: NSColor.white
    ]
    private static let keycapKeyAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10, weight: .bold),
        .foregroundColor: NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1.0)
    ]
    private static let keycapDescAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor(white: 0.90, alpha: 1.0)
    ]
    private static var keycapSizeCache: [String: (kSz: CGSize, dSz: CGSize)] = [:]

    func shortcutTipsBottomTriggerZone() -> CGRect {
        // 覆盖左下角快捷键提示条及 24pt 避让缓冲区
        CGRect(x: 0, y: bounds.height - 98, width: 620, height: 98)
    }

    func drawShortcutTipsHUD(ctx: CGContext, dirtyRect: CGRect) {
        guard showShortcutTips, !isEditingText else { return }
        if let sel = selection, sel.width > bounds.width * 0.88, sel.height > bounds.height * 0.82 {
            return
        }

        let rows: [[(String, String)]]
        if selection == nil {
            rows = [
                [("滚轮", "切层级"), ("F/⇧↩", "纯净窗口阴影"), ("L", "长截图"), ("V", "录动图"), ("⌘⇧S", "一键快存")],
                [("C", "取色"), ("⇧", "色值格式"), ("T", "识字/二维码"), (toolbar.pinHint, "贴图"), ("H", "隐藏提示")]
            ]
        } else {
            rows = [
                [("F", "纯净整窗"), ("L", "长截图"), ("V", "录动图"), ("P", "美化衬底"), ("⌘⇧S", "快存")],
                [("1-9/0", "标注工具"), ("K", "胶囊字"), ("T", "识字"), ("⌥", "按住吸色"), ("H", "隐藏")]
            ]
        }

        let padX: CGFloat = 12
        let padY: CGFloat = 8
        let rowH: CGFloat = 19
        let gapX: CGFloat = 12

        var maxRowW: CGFloat = 0
        for row in rows {
            let w = row.reduce(CGFloat(0)) { acc, pair in
                acc + Self.measureKeycapTipWidth(key: pair.0, desc: pair.1)
            } + CGFloat(max(0, row.count - 1)) * gapX
            maxRowW = max(maxRowW, w)
        }

        let cardW = ceil(maxRowW + padX * 2)
        let cardH = ceil(CGFloat(rows.count) * rowH + padY * 2 + 2)

        var origin = CGPoint(x: 18, y: bounds.height - cardH - 18)
        let candidateBottom = CGRect(origin: origin, size: CGSize(width: cardW, height: cardH)).insetBy(dx: -24, dy: -24)
        let cursorNearBottom = lastMousePoint.map { candidateBottom.contains($0) } ?? false
        let selNearBottom = selection.map { !$0.intersection(candidateBottom).isNull } ?? false
        let barNearBottom = !toolbar.isHidden && !toolbar.frame.intersection(candidateBottom).isNull
        if cursorNearBottom || selNearBottom || barNearBottom {
            origin = CGPoint(x: 18, y: 18)
        }

        let rect = CGRect(origin: origin, size: CGSize(width: cardW, height: cardH))
        guard rect.insetBy(dx: -4, dy: -4).intersects(dirtyRect) else { return }

        let path = CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(NSColor(srgbRed: 0.08, green: 0.085, blue: 0.105, alpha: 0.80).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.15).cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(path)
        ctx.strokePath()

        for (rIdx, row) in rows.enumerated() {
            var cx = rect.minX + padX
            let cy = rect.minY + padY + CGFloat(rIdx) * (rowH + 2)
            for pair in row {
                cx = Self.drawKeycapTip(ctx: ctx, x: cx, y: cy, key: pair.0, desc: pair.1) + gapX
            }
        }
        ctx.restoreGState()
    }

    func drawHUDPill(ctx: CGContext, anchorRect: CGRect, text: String) {
        let nsText = text as NSString
        let textSize = nsText.size(withAttributes: Self.hudPillAttrs)
        let badgeW = ceil(textSize.width + 14)
        let badgeH: CGFloat = 22
        let badgeX = min(max(6, anchorRect.minX), bounds.width - badgeW - 6)
        let badgeY = anchorRect.minY >= (badgeH + 8) ? (anchorRect.minY - badgeH - 6) : (anchorRect.minY + 6)
        let badgeRect = CGRect(x: badgeX, y: badgeY, width: badgeW, height: badgeH)

        ctx.saveGState()
        let pill = CGPath(roundedRect: badgeRect, cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.78).cgColor)
        ctx.addPath(pill)
        ctx.fillPath()
        nsText.draw(
            at: CGPoint(x: badgeRect.minX + 7, y: badgeRect.minY + (badgeH - textSize.height) * 0.5),
            withAttributes: Self.hudPillAttrs
        )
        ctx.restoreGState()
    }

    private static func cachedKeycapMetrics(key: String, desc: String) -> (kSz: CGSize, dSz: CGSize) {
        let token = "\(key)\u{1F}\(desc)"
        if let hit = keycapSizeCache[token] { return hit }
        let kSz = (key as NSString).size(withAttributes: keycapKeyAttrs)
        let dSz = (desc as NSString).size(withAttributes: keycapDescAttrs)
        let pair = (kSz, dSz)
        keycapSizeCache[token] = pair
        return pair
    }

    static func measureKeycapTipWidth(key: String, desc: String) -> CGFloat {
        let m = cachedKeycapMetrics(key: key, desc: desc)
        return max(16, ceil(m.kSz.width + 8)) + 5 + ceil(m.dSz.width)
    }

    @discardableResult
    static func drawKeycapTip(ctx: CGContext, x: CGFloat, y: CGFloat, key: String, desc: String) -> CGFloat {
        let m = cachedKeycapMetrics(key: key, desc: desc)
        let capW = max(16, ceil(m.kSz.width + 8))
        let capH: CGFloat = 15
        let capRect = CGRect(x: x, y: y + 0.5, width: capW, height: capH)
        let capPath = CGPath(roundedRect: capRect, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
        ctx.setFillColor(NSColor(white: 0.93, alpha: 0.96).cgColor)
        ctx.addPath(capPath)
        ctx.fillPath()

        (key as NSString).draw(
            at: CGPoint(x: capRect.minX + (capW - m.kSz.width) * 0.5, y: capRect.minY + (capH - m.kSz.height) * 0.5),
            withAttributes: keycapKeyAttrs
        )
        let descX = capRect.maxX + 5
        (desc as NSString).draw(at: CGPoint(x: descX, y: y + (16 - m.dSz.height) * 0.5), withAttributes: keycapDescAttrs)
        return descX + ceil(m.dSz.width)
    }

    func drawSelectionChrome(ctx: CGContext, sel: CGRect, cornerRadius: CGFloat) {
        ctx.saveGState()
        if backdropStyle != .none, let firstStop = backdropStyle.gradientStops.first {
            let halo = sel.insetBy(dx: -4, dy: -4)
            let haloR = max(10, cornerRadius + 4)
            ctx.setStrokeColor(firstStop.cgColor.copy(alpha: 0.85) ?? NSColor.systemPurple.cgColor)
            ctx.setLineWidth(5.0)
            ctx.addPath(CGPath(roundedRect: halo, cornerWidth: haloR, cornerHeight: haloR, transform: nil))
            ctx.strokePath()
        }

        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5)
        if cornerRadius > 0.5 {
            ctx.addPath(CGPath(roundedRect: sel, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
            ctx.strokePath()
        } else {
            ctx.stroke(sel)
        }

        for handle in ResizeHandle.allCases {
            let p = handle.point(in: sel)
            let hr = CGRect(x: p.x - 4.0, y: p.y - 4.0, width: 8.0, height: 8.0)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: hr)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: hr)
        }
        ctx.restoreGState()

        let pxW = Int((sel.width * snapshot.scaleFactor).rounded())
        let pxH = Int((sel.height * snapshot.scaleFactor).rounded())
        var parts = ["\(pxW) × \(pxH)"]
        if cornerRadius > 0.5 { parts.append("圆角 \(Int(cornerRadiusPt))pt") }
        if backdropStyle != .none { parts.append("衬底：\(backdropStyle.title)") }
        drawHUDPill(ctx: ctx, anchorRect: sel, text: parts.joined(separator: "  ·  "))
    }
}
