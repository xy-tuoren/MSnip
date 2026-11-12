import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// PixPin 风格截图界面辅助 HUD：
/// 1) 屏幕角落自适应避让的轻量快捷键速查面板 (`ShortcutTipsWidget`)
/// 2) 选区尺寸与状态胶囊 (`drawHUDPill`) 及通用浅色小键帽绘制器 (`drawKeycapTip`)
extension OverlayView {
    func drawShortcutTipsHUD(ctx: CGContext) {
        guard showShortcutTips, !isEditingText else { return }
        if let sel = selection, sel.width > bounds.width * 0.88, sel.height > bounds.height * 0.82 {
            return
        }

        let rows: [[(String, String)]]
        if selection == nil {
            rows = [
                [("滚轮", "切换元素层级"), ("WASD", "1px 移光标"), ("R", "上次选区"), ("⌘A", "全屏")],
                [("C", "取色"), ("⇧", "色值格式"), ("T", "识字/二维码"), (toolbar.pinHint, "贴图"), ("H", "隐藏提示")]
            ]
        } else {
            rows = [
                [("⌥", "按住取色/吸管"), ("↑↓←→", "移动"), ("⌃/⇧+方向", "扩缩边"), ("B", "圆角")],
                [("1-7", "标注"), ("T", "识字/二维码"), ("G", "相对坐标"), ("⌘⇧⌫", "清空标注"), ("H", "隐藏")]
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
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = nsText.size(withAttributes: attrs)
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
            withAttributes: attrs
        )
        ctx.restoreGState()
    }

    static func measureKeycapTipWidth(key: String, desc: String) -> CGFloat {
        let kSz = (key as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: .bold)])
        let dSz = (desc as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)])
        return max(16, ceil(kSz.width + 8)) + 5 + ceil(dSz.width)
    }

    @discardableResult
    static func drawKeycapTip(ctx: CGContext, x: CGFloat, y: CGFloat, key: String, desc: String) -> CGFloat {
        let keyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1.0)
        ]
        let descAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(white: 0.90, alpha: 1.0)
        ]
        let kNs = key as NSString
        let dNs = desc as NSString
        let kSz = kNs.size(withAttributes: keyAttrs)
        let dSz = dNs.size(withAttributes: descAttrs)

        let capW = max(16, ceil(kSz.width + 8))
        let capH: CGFloat = 15
        let capRect = CGRect(x: x, y: y + 0.5, width: capW, height: capH)
        let capPath = CGPath(roundedRect: capRect, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
        ctx.setFillColor(NSColor(white: 0.93, alpha: 0.96).cgColor)
        ctx.addPath(capPath)
        ctx.fillPath()

        kNs.draw(
            at: CGPoint(x: capRect.minX + (capW - kSz.width) * 0.5, y: capRect.minY + (capH - kSz.height) * 0.5),
            withAttributes: keyAttrs
        )
        let descX = capRect.maxX + 5
        dNs.draw(at: CGPoint(x: descX, y: y + (16 - dSz.height) * 0.5), withAttributes: descAttrs)
        return descX + ceil(dSz.width)
    }
}
