import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// PixPin 极简风格跟随光标取色放大镜 (`PointInfoWidget`)：
/// 上半部为带十字蓝色高亮条带的 15×9 物理像素网格，下半部为居中的简洁坐标、色值与无边框轻提示。
extension OverlayView {
    private static let loupeCols = 15
    private static let loupeRows = 9
    private static let loupeCell: CGFloat = 11
    private static let loupeCardW: CGFloat = 165
    private static let loupeCardH: CGFloat = 187
    private static let loupeSRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private static let coordTextAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
        .foregroundColor: NSColor(white: 0.96, alpha: 1.0)
    ]
    private static let colorValueAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .bold),
        .foregroundColor: NSColor.white
    ]
    private static let hintLineAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11.0, weight: .medium),
        .foregroundColor: NSColor(white: 0.88, alpha: 1.0)
    ]

    var shouldShowMagnifier: Bool {
        isMagnifierVisible(at: lastMousePoint)
    }

    func isMagnifierVisible(at point: CGPoint?) -> Bool {
        guard let pt = point, bounds.contains(pt), !isEditingText else { return false }
        if !toolbar.isHidden && toolbar.frame.insetBy(dx: -4, dy: -4).contains(pt) { return false }
        if !subbar.isHidden && subbar.frame.insetBy(dx: -4, dy: -4).contains(pt) { return false }
        if !sidePills.isHidden && sidePills.frame.insetBy(dx: -4, dy: -4).contains(pt) { return false }
        if toolbar.inPlaceOCRActive, let sel = selection, sel.contains(pt) { return false }
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

    func magnifierCardFrame(at pt: CGPoint) -> CGRect {
        let cardW = Self.loupeCardW
        let cardH = Self.loupeCardH
        var x = round(pt.x + 20)
        var y = round(pt.y + 22)
        if x + cardW + 10 > bounds.width { x = round(pt.x - cardW - 20) }
        if y + cardH + 10 > bounds.height { y = round(pt.y - cardH - 20) }
        x = min(max(8, x), bounds.width - cardW - 8)
        y = min(max(8, y), bounds.height - cardH - 8)
        return CGRect(x: x, y: y, width: cardW, height: cardH)
    }

    func magnifierDirtyRectIfVisible(at point: CGPoint?) -> CGRect? {
        guard let pt = point, isMagnifierVisible(at: pt) else { return nil }
        return magnifierCardFrame(at: pt).insetBy(dx: -22, dy: -24)
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
            return ("REL", "REL (\(rx), \(ry))", "\(rx), \(ry)")
        }
        return ("POS", "(\(px), \(py))", "\(px), \(py)")
    }

    func drawCursorMagnifier(ctx: CGContext, dirtyRect: CGRect) {
        guard shouldShowMagnifier, let pt = lastMousePoint else { return }
        let cardRect = magnifierCardFrame(at: pt)
        guard cardRect.insetBy(dx: -22, dy: -24).intersects(dirtyRect),
              let sample = samplePixelAtCursor() else { return }

        let cols = Self.loupeCols
        let rows = Self.loupeRows
        let cell = Self.loupeCell
        let loupeW = Self.loupeCardW
        let loupeH = CGFloat(rows) * cell
        let cardW = cardRect.width
        let x = cardRect.minX
        let y = cardRect.minY

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 12, color: NSColor.black.withAlphaComponent(0.40).cgColor)
        let cardPath = CGPath(roundedRect: cardRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.setFillColor(NSColor(srgbRed: 0.055, green: 0.06, blue: 0.075, alpha: 0.90).cgColor)
        ctx.addPath(cardPath)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(cardPath)
        ctx.clip()

        // 1) 单次位图块拷贝渲染 15 × 9 物理像素放大网格
        let halfC = cols / 2
        let halfR = rows / 2
        let wMax = snapshot.sampler.width
        let hMax = snapshot.sampler.height
        var patch = [UInt8](repeating: 255, count: cols * rows * 4)
        patch.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for r in 0..<rows {
                let sy = sample.py + (r - halfR)
                let rowOff = r * cols * 4
                for c in 0..<cols {
                    let sx = sample.px + (c - halfC)
                    let idx = rowOff + c * 4
                    if sx >= 0, sx < wMax, sy >= 0, sy < hMax {
                        let (cr, cg, cb) = snapshot.sampler.sampleRGB(px: sx, py: sy)
                        base[idx] = UInt8(cr); base[idx + 1] = UInt8(cg); base[idx + 2] = UInt8(cb)
                    } else {
                        base[idx] = 24; base[idx + 1] = 26; base[idx + 2] = 32
                    }
                }
            }
        }
        let loupeRect = CGRect(x: x, y: y, width: loupeW, height: loupeH)
        if let provider = CGDataProvider(data: Data(patch) as CFData),
           let patchCG = CGImage(
               width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4,
               space: Self.loupeSRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
           ) {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.translateBy(x: 0, y: loupeRect.minY + loupeRect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(patchCG, in: loupeRect)
            ctx.restoreGState()
        }

        // 中心行列半透明天蓝十字高亮条带（复刻参考图视觉风格）
        let centerRect = CGRect(x: x + CGFloat(halfC) * cell, y: y + CGFloat(halfR) * cell, width: cell, height: cell)
        let bandColor = (eyedropperActive ? NSColor.systemYellow : NSColor(srgbRed: 0.22, green: 0.56, blue: 0.98, alpha: 1.0))
            .withAlphaComponent(0.32).cgColor
        ctx.setFillColor(bandColor)
        ctx.fill(CGRect(x: centerRect.minX, y: y, width: cell, height: centerRect.minY - y))
        ctx.fill(CGRect(x: centerRect.minX, y: centerRect.maxY, width: cell, height: (y + loupeH) - centerRect.maxY))
        ctx.fill(CGRect(x: x, y: centerRect.minY, width: centerRect.minX - x, height: cell))
        ctx.fill(CGRect(x: centerRect.maxX, y: centerRect.minY, width: (x + loupeW) - centerRect.maxX, height: cell))

        // 像素细网格线
        ctx.setStrokeColor(NSColor(white: 0.5, alpha: 0.28).cgColor)
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

        // 网格白色外框 + 中心像素高对比瞄准框
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.82).cgColor)
        ctx.setLineWidth(1.0)
        ctx.stroke(loupeRect.insetBy(dx: 0.5, dy: 0.5))

        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.92).cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(centerRect.insetBy(dx: -0.75, dy: -0.75))
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.0)
        ctx.stroke(centerRect.insetBy(dx: 0.5, dy: 0.5))

        // 2) 底部居中极简信息区：坐标 + 色块色值 + 两行轻量文字提示
        let iy = y + loupeH
        let coord = formattedCoordinateAtCursor(px: sample.px, py: sample.py)
        Self.drawCenteredString(coord.text, centerX: x + cardW * 0.5, y: iy + 6, attrs: Self.coordTextAttrs)

        let colorText = sample.color.formatted(as: colorCopyFormat)
        let colorNs = colorText as NSString
        let colorSz = colorNs.size(withAttributes: Self.colorValueAttrs)
        let swSide: CGFloat = 12
        let rowTotalW = swSide + 6 + colorSz.width
        let swX = round(x + (cardW - rowTotalW) * 0.5)
        let swRect = CGRect(x: swX, y: iy + 26, width: swSide, height: swSide)
        ctx.setFillColor(sample.color.cgColor)
        ctx.fill(swRect)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1.0)
        ctx.stroke(swRect)
        colorNs.draw(at: CGPoint(x: round(swRect.maxX + 6), y: round(iy + 24.5)), withAttributes: Self.colorValueAttrs)

        let pickMode = eyedropperActive || (selection != nil && optionPressed)
        Self.drawCenteredString("⇧: 切换颜色格式", centerX: x + cardW * 0.5, y: round(iy + 45), attrs: Self.hintLineAttrs)
        let copyHint = pickMode ? "单击: 吸取标注色" : "C: 复制色值   G: 相对坐标"
        Self.drawCenteredString(copyHint, centerX: x + cardW * 0.5, y: round(iy + 64), attrs: Self.hintLineAttrs)

        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(cardPath)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawCenteredString(_ text: String, centerX: CGFloat, y: CGFloat, attrs: [NSAttributedString.Key: Any]) {
        let ns = text as NSString
        let sz = ns.size(withAttributes: attrs)
        ns.draw(at: CGPoint(x: round(centerX - sz.width * 0.5), y: round(y)), withAttributes: attrs)
    }
}
