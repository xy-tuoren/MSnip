import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// PixPin 风格跟随光标的高清像素网格放大镜 + 实时坐标/色值 + 浅色键帽提示 (`PointInfoWidget`)
extension OverlayView {
    var shouldShowMagnifier: Bool {
        guard let pt = lastMousePoint, bounds.contains(pt), !isEditingText else { return false }
        if !toolbar.isHidden && toolbar.frame.insetBy(dx: -4, dy: -4).contains(pt) { return false }
        if eyedropperActive { return true }
        if selection == nil { return true }
        if let op = dragOp {
            switch op {
            case .pendingSnapOrCreate, .creatingSelection, .resizingSelection:
                return true
            case .movingSelection, .drawingAnnotation, .movingAnnotation:
                return optionPressed
            }
        }
        return optionPressed || magnifierPinned
    }

    func samplePixelAtCursor() -> (px: Int, py: Int, color: RGBAColor)? {
        guard let pt = lastMousePoint else { return nil }
        let px = min(max(0, Int((pt.x * snapshot.scaleFactor).rounded(.down))), max(0, snapshot.sampler.width - 1))
        let py = min(max(0, Int((pt.y * snapshot.scaleFactor).rounded(.down))), max(0, snapshot.sampler.height - 1))
        let (r, g, b) = snapshot.sampler.sampleRGB(px: px, py: py)
        return (px, py, RGBAColor(UInt8(r), UInt8(g), UInt8(b)))
    }

    func formattedCoordinateAtCursor(px: Int, py: Int) -> (tag: String, text: String, copyValue: String) {
        if useRelativeCoordinates, let ref = selection ?? hoveredAutoRect {
            let rx = px - Int((ref.minX * snapshot.scaleFactor).rounded())
            let ry = py - Int((ref.minY * snapshot.scaleFactor).rounded())
            return ("REL", "(\(rx), \(ry))", "\(rx), \(ry)")
        }
        return ("POS", "(\(px), \(py))", "\(px), \(py)")
    }

    func drawCursorMagnifier(ctx: CGContext) {
        guard shouldShowMagnifier, let pt = lastMousePoint, let sample = samplePixelAtCursor() else { return }

        let cols = 15
        let rows = 9
        let cell: CGFloat = 11
        let loupeW = CGFloat(cols) * cell   // 165pt
        let loupeH = CGFloat(rows) * cell   // 99pt
        let infoH: CGFloat = 93
        let cardW = loupeW
        let cardH = loupeH + infoH          // 192pt

        var x = round(pt.x + 20)
        var y = round(pt.y + 22)
        if x + cardW + 10 > bounds.width { x = round(pt.x - cardW - 20) }
        if y + cardH + 10 > bounds.height { y = round(pt.y - cardH - 20) }
        x = min(max(8, x), bounds.width - cardW - 8)
        y = min(max(8, y), bounds.height - cardH - 8)
        let cardRect = CGRect(x: x, y: y, width: cardW, height: cardH)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 14, color: NSColor.black.withAlphaComponent(0.42).cgColor)
        let cardPath = CGPath(roundedRect: cardRect, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.setFillColor(NSColor(srgbRed: 0.09, green: 0.095, blue: 0.115, alpha: 0.94).cgColor)
        ctx.addPath(cardPath)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(cardPath)
        ctx.clip()

        // 1) 绘制 15 × 9 硬边缘物理像素放大网格
        let halfC = cols / 2
        let halfR = rows / 2
        let wMax = snapshot.sampler.width
        let hMax = snapshot.sampler.height

        for r in 0..<rows {
            let sy = sample.py + (r - halfR)
            for c in 0..<cols {
                let sx = sample.px + (c - halfC)
                let cellRect = CGRect(x: x + CGFloat(c) * cell, y: y + CGFloat(r) * cell, width: cell, height: cell)
                if sx >= 0, sx < wMax, sy >= 0, sy < hMax {
                    ctx.setFillColor(snapshot.sampler.sampleColor(px: sx, py: sy))
                } else {
                    ctx.setFillColor(NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1.0).cgColor)
                }
                ctx.fill(cellRect)
            }
        }

        // 像素细网格线
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.11).cgColor)
        ctx.setLineWidth(0.5)
        for c in 1..<cols {
            let gx = x + CGFloat(c) * cell
            ctx.move(to: CGPoint(x: gx, y: y))
            ctx.addLine(to: CGPoint(x: gx, y: y + loupeH))
        }
        for r in 1..<rows {
            let gy = y + CGFloat(r) * cell
            ctx.move(to: CGPoint(x: x, y: gy))
            ctx.addLine(to: CGPoint(x: x + loupeW, y: gy))
        }
        ctx.strokePath()

        // 中心十字准星引导线 + 中心像素双色高对比瞄准框
        let centerRect = CGRect(x: x + CGFloat(halfC) * cell, y: y + CGFloat(halfR) * cell, width: cell, height: cell)
        let crossTint = (eyedropperActive ? NSColor.systemYellow : NSColor.systemCyan).withAlphaComponent(0.50).cgColor
        ctx.setStrokeColor(crossTint)
        ctx.setLineWidth(1.0)
        ctx.move(to: CGPoint(x: centerRect.midX, y: y))
        ctx.addLine(to: CGPoint(x: centerRect.midX, y: centerRect.minY - 1))
        ctx.move(to: CGPoint(x: centerRect.midX, y: centerRect.maxY + 1))
        ctx.addLine(to: CGPoint(x: centerRect.midX, y: y + loupeH))
        ctx.move(to: CGPoint(x: x, y: centerRect.midY))
        ctx.addLine(to: CGPoint(x: centerRect.minX - 1, y: centerRect.midY))
        ctx.move(to: CGPoint(x: centerRect.maxX + 1, y: centerRect.midY))
        ctx.addLine(to: CGPoint(x: x + loupeW, y: centerRect.midY))
        ctx.strokePath()

        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.88).cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(centerRect.insetBy(dx: -0.75, dy: -0.75))
        ctx.setStrokeColor((eyedropperActive ? NSColor.systemYellow : NSColor.white).cgColor)
        ctx.setLineWidth(1.2)
        ctx.stroke(centerRect.insetBy(dx: 0.6, dy: 0.6))

        // 放大镜与底部信息面板分隔线
        let iy = y + loupeH
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.15).cgColor)
        ctx.fill(CGRect(x: x, y: iy, width: cardW, height: 1))

        // 2) 坐标行 + 当前色值格式角标
        let coord = formattedCoordinateAtCursor(px: sample.px, py: sample.py)
        let tagColor = (coord.tag == "REL") ? NSColor.systemCyan : NSColor(white: 0.62, alpha: 1.0)
        (coord.tag as NSString).draw(at: CGPoint(x: x + 9, y: iy + 7), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: tagColor
        ])
        (coord.text as NSString).draw(at: CGPoint(x: x + 36, y: iy + 6), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor(white: 0.92, alpha: 1.0)
        ])

        let fmtBadge = colorCopyFormat.label as NSString
        let fmtAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .bold),
            .foregroundColor: NSColor.systemCyan
        ]
        let fmtSz = fmtBadge.size(withAttributes: fmtAttrs)
        let fmtRect = CGRect(x: x + cardW - fmtSz.width - 15, y: iy + 6.5, width: fmtSz.width + 7, height: 14)
        ctx.setFillColor(NSColor.systemCyan.withAlphaComponent(0.16).cgColor)
        ctx.addPath(CGPath(roundedRect: fmtRect, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
        ctx.fillPath()
        fmtBadge.draw(at: CGPoint(x: fmtRect.minX + 3.5, y: fmtRect.minY + (fmtRect.height - fmtSz.height) * 0.5), withAttributes: fmtAttrs)

        // 3) 实时色块 + 色值文本行
        let swRect = CGRect(x: x + 9, y: iy + 27, width: 13, height: 13)
        let swPath = CGPath(roundedRect: swRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.setFillColor(sample.color.cgColor)
        ctx.addPath(swPath)
        ctx.fillPath()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(swPath)
        ctx.strokePath()

        let colorStr = sample.color.formatted(as: colorCopyFormat) as NSString
        colorStr.draw(at: CGPoint(x: swRect.maxX + 6, y: iy + 26), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.white
        ])

        ctx.setFillColor(NSColor.white.withAlphaComponent(0.10).cgColor)
        ctx.fill(CGRect(x: x + 9, y: iy + 47, width: cardW - 18, height: 1))

        // 4) PixPin 标志性浅色小键帽提示行
        let pickMode = eyedropperActive || (selection != nil && optionPressed)
        if pickMode {
            let nextX = Self.drawKeycapTip(ctx: ctx, x: x + 9, y: iy + 53, key: "单击", desc: "吸取标注色") + 8
            _ = Self.drawKeycapTip(ctx: ctx, x: nextX, y: iy + 53, key: "C", desc: "复制")
        } else {
            let nextX = Self.drawKeycapTip(ctx: ctx, x: x + 9, y: iy + 53, key: "C", desc: "复制色值") + 10
            _ = Self.drawKeycapTip(ctx: ctx, x: nextX, y: iy + 53, key: "X", desc: "坐标")
        }
        let nextX2 = Self.drawKeycapTip(ctx: ctx, x: x + 9, y: iy + 72, key: "⇧", desc: "切 \(colorCopyFormat.next.label)") + 10
        _ = Self.drawKeycapTip(ctx: ctx, x: nextX2, y: iy + 72, key: "T", desc: "识字")

        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.20).cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(cardPath)
        ctx.strokePath()
        ctx.restoreGState()
    }
}
