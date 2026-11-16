import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 极简竖排双栏快捷键提示面板 (`ShortcutTipsWidget`) + 顶部选区坐标尺寸胶囊 (`drawHUDPill`)
/// 采用「左列浅色圆角键帽右对齐 + 右列精简说明左对齐」的清爽两列布局，自动避让光标与选区。
extension OverlayView {
    private static let hudPillAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
        .foregroundColor: NSColor.white
    ]
    private static let keycapKeyAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11.5, weight: .bold),
        .foregroundColor: NSColor(srgbRed: 0.09, green: 0.10, blue: 0.12, alpha: 1.0)
    ]
    private static let keycapDescAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
        .foregroundColor: NSColor(white: 0.94, alpha: 1.0)
    ]
    private static var textSizeCache: [String: CGSize] = [:]

    private func currentShortcutTipRows() -> [(key: String, desc: String)] {
        if selection == nil {
            return [
                ("W / A / S / D", "移动光标"),
                ("鼠标滚轮", "切换元素层级"),
                ("T", "识别文字"),
                ("F", "纯净窗口截图"),
                ("L / V", "长截图 / 录视频"),
                ("R", "历史截图区域"),
                (toolbar.pinHint, "贴图")
            ]
        } else {
            return [
                ("1 - 9 / 0", "切换标注工具"),
                ("P / B", "渐变衬底 / 圆角"),
                ("K", "胶囊底色文字"),
                ("⌘⇧S", "一键快存"),
                ("H", "隐藏提示")
            ]
        }
    }

    private func measureTipsCardLayout(rows: [(key: String, desc: String)]) -> (size: CGSize, maxKeyCapW: CGFloat) {
        let padX: CGFloat = 16
        let padY: CGFloat = 13
        let rowStride: CGFloat = 29
        let colGap: CGFloat = 13

        var maxCapW: CGFloat = 0
        var maxDescW: CGFloat = 0
        for row in rows {
            let kSz = Self.cachedSize(row.key, isKey: true)
            let dSz = Self.cachedSize(row.desc, isKey: false)
            maxCapW = max(maxCapW, max(22, ceil(kSz.width + 14)))
            maxDescW = max(maxDescW, ceil(dSz.width))
        }
        let w = ceil(padX * 2 + maxCapW + colGap + maxDescW)
        let h = ceil(padY * 2 + CGFloat(rows.count) * rowStride - 7)
        return (CGSize(width: w, height: h), maxCapW)
    }

    func shortcutTipsBottomTriggerZone() -> CGRect {
        let layout = measureTipsCardLayout(rows: currentShortcutTipRows())
        let base = CGRect(
            x: 20,
            y: bounds.height - layout.size.height - 20,
            width: layout.size.width,
            height: layout.size.height
        )
        return base.insetBy(dx: -24, dy: -24)
    }

    func drawShortcutTipsHUD(ctx: CGContext, dirtyRect: CGRect) {
        guard showShortcutTips, !isEditingText else { return }
        if let sel = selection, sel.width > bounds.width * 0.85, sel.height > bounds.height * 0.80 {
            return
        }

        let rows = currentShortcutTipRows()
        let layout = measureTipsCardLayout(rows: rows)
        let cardW = layout.size.width
        let cardH = layout.size.height

        var origin = CGPoint(x: 20, y: bounds.height - cardH - 20)
        let bottomTrigger = CGRect(origin: origin, size: layout.size).insetBy(dx: -24, dy: -24)
        let cursorNearBottom = lastMousePoint.map { bottomTrigger.contains($0) } ?? false
        let selNearBottom = selection.map { !$0.intersection(bottomTrigger).isNull } ?? false
        let barNearBottom = !toolbar.isHidden && !toolbar.frame.intersection(bottomTrigger).isNull
        if cursorNearBottom || selNearBottom || barNearBottom {
            origin = CGPoint(x: 20, y: 24)
            // 若左上角同样被选区覆盖，则平滑避让至右下角
            let topCandidate = CGRect(origin: origin, size: layout.size).insetBy(dx: -12, dy: -12)
            if let sel = selection, !sel.intersection(topCandidate).isNull {
                origin = CGPoint(x: max(20, bounds.width - cardW - 20), y: bounds.height - cardH - 20)
            }
        }

        let rect = CGRect(origin: origin, size: layout.size)
        guard rect.insetBy(dx: -4, dy: -4).intersects(dirtyRect) else { return }

        let path = CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(NSColor(srgbRed: 0.065, green: 0.07, blue: 0.085, alpha: 0.86).cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(path)
        ctx.strokePath()

        let padX: CGFloat = 16
        let padY: CGFloat = 13
        let rowStride: CGFloat = 29
        let capH: CGFloat = 21
        let keySpineRightX = rect.minX + padX + layout.maxKeyCapW
        let descLeftX = keySpineRightX + 13

        for (idx, row) in rows.enumerated() {
            let rowTopY = rect.minY + padY + CGFloat(idx) * rowStride
            let kSz = Self.cachedSize(row.key, isKey: true)
            let dSz = Self.cachedSize(row.desc, isKey: false)

            let capW = max(22, ceil(kSz.width + 14))
            let capRect = CGRect(x: keySpineRightX - capW, y: rowTopY, width: capW, height: capH)
            let capPath = CGPath(roundedRect: capRect, cornerWidth: 4.5, cornerHeight: 4.5, transform: nil)
            ctx.setFillColor(NSColor(white: 0.93, alpha: 0.96).cgColor)
            ctx.addPath(capPath)
            ctx.fillPath()

            (row.key as NSString).draw(
                at: CGPoint(
                    x: capRect.minX + (capW - kSz.width) * 0.5,
                    y: capRect.minY + (capH - kSz.height) * 0.5
                ),
                withAttributes: Self.keycapKeyAttrs
            )
            (row.desc as NSString).draw(
                at: CGPoint(
                    x: descLeftX,
                    y: rowTopY + (capH - dSz.height) * 0.5
                ),
                withAttributes: Self.keycapDescAttrs
            )
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

    private static func cachedSize(_ str: String, isKey: Bool) -> CGSize {
        let token = isKey ? "K:\(str)" : "D:\(str)"
        if let hit = textSizeCache[token] { return hit }
        let sz = (str as NSString).size(withAttributes: isKey ? keycapKeyAttrs : keycapDescAttrs)
        textSizeCache[token] = sz
        return sz
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

        let pxX = Int((sel.minX * snapshot.scaleFactor).rounded())
        let pxY = Int((sel.minY * snapshot.scaleFactor).rounded())
        let pxW = Int((sel.width * snapshot.scaleFactor).rounded())
        let pxH = Int((sel.height * snapshot.scaleFactor).rounded())
        var parts = ["\(pxX),\(pxY)  \(pxW) × \(pxH) px"]
        if cornerRadius > 0.5 { parts.append("圆角 \(Int(cornerRadiusPt))pt") }
        if backdropStyle != .none { parts.append(backdropStyle.title) }
        drawHUDPill(ctx: ctx, anchorRect: sel, text: parts.joined(separator: "  ·  "))
    }
}
