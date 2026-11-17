import AppKit
import CoreGraphics
import Foundation
import MSnipCore
import QuartzCore

/// 独立 GPU 图层承载的 120fps 零全屏重绘光标放大镜视图（彻底隔离放大镜移动与全屏主画布脏区）
final class OverlayMagnifierLayerView: NSView {
    weak var ownerOverlay: OverlayView?
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: OverlayView.loupeCardW, height: OverlayView.loupeCardH))
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: 4)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let owner = ownerOverlay else { return }
        owner.renderMagnifierContent(in: ctx, cardRect: bounds)
    }
}

/// PixPin 极简风格跟随光标取色放大镜逻辑与局部绘制扩展
extension OverlayView {
    static let loupeCols = 15
    static let loupeRows = 9
    static let loupeCell: CGFloat = 11
    static let loupeCardW: CGFloat = 165
    static let loupeCardH: CGFloat = 187
    private static let loupeSRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private static let coordTextAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
        .foregroundColor: MSnipUITheme.inkSecondary
    ]
    private static let colorValueAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12.0, weight: .bold),
        .foregroundColor: MSnipUITheme.inkPrimary
    ]
    private static let hintLineAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11.0, weight: .medium),
        .foregroundColor: MSnipUITheme.inkMuted
    ]

    var shouldShowMagnifier: Bool {
        isMagnifierVisible(at: lastMousePoint)
    }

    func isMagnifierVisible(at point: CGPoint?) -> Bool {
        guard let pt = point, bounds.contains(pt), !isEditingText else { return false }
        if !toolbar.isHidden && toolbar.frame.insetBy(dx: -4, dy: -4).contains(pt) { return false }
        if !subbar.isHidden && subbar.frame.insetBy(dx: -4, dy: -4).contains(pt) { return false }
        if !sidePills.isHidden && sidePills.frame.insetBy(dx: -4, dy: -4).contains(pt) { return false }
        if !cornerSlider.isHidden && cornerSlider.frame.insetBy(dx: -4, dy: -4).contains(pt) { return false }
        if (toolbar.inPlaceOCRActive || toolbar.inPlaceTranslateActive), let sel = selection, sel.contains(pt) { return false }
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

    /// 零隐式动画同步独立 GPU 放大镜视图位置（避免触发 `OverlayView` 主画布重绘）
    func syncMagnifierView() {
        guard let pt = lastMousePoint, isMagnifierVisible(at: pt) else {
            if !magnifierView.isHidden { magnifierView.isHidden = true }
            return
        }
        let nextFrame = magnifierCardFrame(at: pt)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if magnifierView.isHidden { magnifierView.isHidden = false }
        if magnifierView.frame.origin != nextFrame.origin {
            magnifierView.setFrameOrigin(nextFrame.origin)
        }
        CATransaction.commit()
        magnifierView.needsDisplay = true
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

    func renderMagnifierContent(in ctx: CGContext, cardRect: CGRect) {
        guard let sample = samplePixelAtCursor() else { return }

        let cols = Self.loupeCols
        let rows = Self.loupeRows
        let cell = Self.loupeCell
        let loupeW = Self.loupeCardW
        let loupeH = CGFloat(rows) * cell
        let cardW = cardRect.width
        let x = cardRect.minX
        let y = cardRect.minY

        let cardPath = CGPath(roundedRect: cardRect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 9, cornerHeight: 9, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(MSnipUITheme.cardBg.cgColor)
        ctx.addPath(cardPath)
        ctx.fillPath()
        ctx.addPath(cardPath)
        ctx.clip()

        let halfC = cols / 2, halfR = rows / 2
        let wMax = snapshot.sampler.width, hMax = snapshot.sampler.height
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

        let centerRect = CGRect(x: x + CGFloat(halfC) * cell, y: y + CGFloat(halfR) * cell, width: cell, height: cell)
        let bandColor = (eyedropperActive ? NSColor.systemYellow : NSColor(srgbRed: 0.22, green: 0.56, blue: 0.98, alpha: 1.0))
            .withAlphaComponent(0.32).cgColor
        ctx.setFillColor(bandColor)
        ctx.fill(CGRect(x: centerRect.minX, y: y, width: cell, height: centerRect.minY - y))
        ctx.fill(CGRect(x: centerRect.minX, y: centerRect.maxY, width: cell, height: (y + loupeH) - centerRect.maxY))
        ctx.fill(CGRect(x: x, y: centerRect.minY, width: centerRect.minX - x, height: cell))
        ctx.fill(CGRect(x: centerRect.maxX, y: centerRect.minY, width: (x + loupeW) - centerRect.maxX, height: cell))

        ctx.setStrokeColor(NSColor(white: 0.5, alpha: 0.26).cgColor)
        ctx.setLineWidth(0.5)
        for c in 1..<cols {
            let gx = x + CGFloat(c) * cell
            ctx.move(to: CGPoint(x: gx, y: y)); ctx.addLine(to: CGPoint(x: gx, y: y + loupeH))
        }
        for r in 1..<rows {
            let gy = y + CGFloat(r) * cell
            ctx.move(to: CGPoint(x: x, y: gy)); ctx.addLine(to: CGPoint(x: x + loupeW, y: gy))
        }
        ctx.strokePath()

        ctx.setStrokeColor(MSnipUITheme.borderStrong.cgColor)
        ctx.setLineWidth(1.0)
        ctx.stroke(loupeRect.insetBy(dx: 0.5, dy: 0.5))

        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.92).cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(centerRect.insetBy(dx: -0.75, dy: -0.75))
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.0)
        ctx.stroke(centerRect.insetBy(dx: 0.5, dy: 0.5))

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
        ctx.setStrokeColor(MSnipUITheme.borderStrong.cgColor)
        ctx.setLineWidth(1.0)
        ctx.stroke(swRect)
        colorNs.draw(at: CGPoint(x: round(swRect.maxX + 6), y: round(iy + 24.5)), withAttributes: Self.colorValueAttrs)

        let pickMode = eyedropperActive || (selection != nil && optionPressed)
        Self.drawCenteredString("⇧ 切格式   ·   ` 锁定放大镜", centerX: x + cardW * 0.5, y: round(iy + 45), attrs: Self.hintLineAttrs)
        let copyHint = pickMode ? "单击吸取标注颜色" : "C 复制色值   ·   G 相对坐标"
        Self.drawCenteredString(copyHint, centerX: x + cardW * 0.5, y: round(iy + 64), attrs: Self.hintLineAttrs)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(MSnipUITheme.borderStrong.cgColor)
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
