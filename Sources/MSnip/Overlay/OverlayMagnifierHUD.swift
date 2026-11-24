import AppKit
import CoreGraphics
import Foundation
import MSnipCore
import QuartzCore

/// 极简风格跟随光标取色放大镜逻辑与局部绘制扩展（图层宿主视图位于 `OverlayStateModels.swift`）
extension OverlayView {
    static let loupeCols = 15, loupeRows = 9
    static let loupeCell: CGFloat = 12, loupeCardW: CGFloat = 180, loupeCardH: CGFloat = 229
    private static let loupeSRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private static let coordTextAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12.0, weight: .semibold),
        .foregroundColor: MSnipUITheme.inkSecondary
    ]
    private static let coordRelativeTextAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12.0, weight: .bold),
        .foregroundColor: MSnipUITheme.accent
    ]
    private static let colorValueAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12.0, weight: .bold),
        .foregroundColor: MSnipUITheme.inkPrimary
    ]
    private static let miniKeyAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10.5, weight: .bold),
        .foregroundColor: MSnipUITheme.inkPrimary
    ]
    private static let miniLabelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11.0, weight: .medium),
        .foregroundColor: MSnipUITheme.inkSecondary
    ]

    var shouldShowMagnifier: Bool { isMagnifierVisible(at: lastMousePoint) }

    func isMagnifierVisible(at point: CGPoint?) -> Bool {
        guard let pt = point, snapshot.isSamplerReady, bounds.contains(pt), !isEditingText else { return false }
        let floatingPanels: [NSView] = [toolbar, subbar, sidePills, cornerSlider, saveMenu]
        if floatingPanels.contains(where: { !$0.isHidden && $0.frame.insetBy(dx: -4, dy: -4).contains(pt) }) { return false }
        if (toolbar.inPlaceOCRActive || toolbar.inPlaceTranslateActive), let sel = selection, sel.contains(pt) { return false }
        if eyedropperActive { return true }
        if let forced = magnifierVisibilityOverride { return forced || optionPressed }
        if caliperActive || selection == nil { return true }
        if let op = dragOp {
            switch op {
            case .pendingSnapOrCreate, .creatingSelection, .resizingSelection: return true
            case .movingSelection, .drawingAnnotation, .erasing, .movingAnnotation, .resizingAnnotation: return optionPressed
            }
        }
        return optionPressed
    }

    func magnifierCardFrame(at pt: CGPoint) -> CGRect {
        let cardW = Self.loupeCardW, cardH = Self.loupeCardH
        var x = round(pt.x + 20), y = round(pt.y + 22)
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
        if magnifierView.frame.origin != nextFrame.origin { magnifierView.setFrameOrigin(nextFrame.origin) }
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
        if useRelativeCoordinates {
            if let ref = selection ?? hoveredAutoRect {
                let rx = px - Int((ref.minX * snapshot.scaleFactor).rounded())
                let ry = py - Int((ref.minY * snapshot.scaleFactor).rounded())
                return ("REL", "相对 (\(rx), \(ry))", "\(rx), \(ry)")
            }
            return ("REL", "相对 (\(px), \(py))", "\(px), \(py)")
        }
        return ("ABS", "绝对 (\(px), \(py))", "\(px), \(py)")
    }

    func renderMagnifierContent(in ctx: CGContext, cardRect: CGRect) {
        guard let sample = samplePixelAtCursor() else { return }
        let cols = Self.loupeCols, rows = Self.loupeRows, cell = Self.loupeCell
        let loupeW = Self.loupeCardW, loupeH = CGFloat(rows) * cell
        let cardW = cardRect.width, x = cardRect.minX, y = cardRect.minY

        let cardPath = CGPath(roundedRect: cardRect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 9, cornerHeight: 9, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(MSnipUITheme.cardBg.cgColor)
        ctx.addPath(cardPath); ctx.fillPath()
        ctx.addPath(cardPath); ctx.clip()

        let halfC = cols / 2, halfR = rows / 2
        let loupeRect = CGRect(x: x, y: y, width: loupeW, height: loupeH)
        if let patchCG = cropMagnifierPatch(px: sample.px, py: sample.py, cols: cols, rows: rows) {
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

        ctx.setStrokeColor(MSnipUITheme.borderStrong.cgColor); ctx.setLineWidth(1.0)
        ctx.stroke(loupeRect.insetBy(dx: 0.5, dy: 0.5))
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.92).cgColor); ctx.setLineWidth(1.5)
        ctx.stroke(centerRect.insetBy(dx: -0.75, dy: -0.75))
        ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1.0)
        ctx.stroke(centerRect.insetBy(dx: 0.5, dy: 0.5))

        let iy = y + loupeH
        let coord = formattedCoordinateAtCursor(px: sample.px, py: sample.py)
        let coordAttrs = useRelativeCoordinates ? Self.coordRelativeTextAttrs : Self.coordTextAttrs
        Self.drawCenteredString(coord.text, centerX: x + cardW * 0.5, y: iy + 6, attrs: coordAttrs)

        let colorNs = sample.color.formatted(as: colorCopyFormat) as NSString
        let colorSz = colorNs.size(withAttributes: Self.colorValueAttrs)
        let swSide: CGFloat = 12
        let swX = round(x + (cardW - (swSide + 6 + colorSz.width)) * 0.5)
        let swRect = CGRect(x: swX, y: iy + 26, width: swSide, height: swSide)
        ctx.setFillColor(sample.color.cgColor); ctx.fill(swRect)
        ctx.setStrokeColor(MSnipUITheme.borderStrong.cgColor); ctx.setLineWidth(1.0); ctx.stroke(swRect)
        colorNs.draw(at: CGPoint(x: round(swRect.maxX + 6), y: round(iy + 24.5)), withAttributes: Self.colorValueAttrs)

        ctx.setFillColor(MSnipUITheme.borderHairline.cgColor)
        ctx.fill(CGRect(x: x + 12, y: round(iy + 45), width: cardW - 24, height: 1))
        drawCachedLegendStrip(in: ctx, x: x, y: round(iy + 48), width: cardW)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(MSnipUITheme.borderStrong.cgColor); ctx.setLineWidth(1.0)
        ctx.addPath(cardPath); ctx.strokePath()
        ctx.restoreGState()
    }

    private func cropMagnifierPatch(px: Int, py: Int, cols: Int, rows: Int) -> CGImage? {
        let halfC = cols / 2, halfR = rows / 2
        let wMax = snapshot.cgImage.width, hMax = snapshot.cgImage.height
        let cropX = px - halfC, cropY = py - halfR
        if cropX >= 0, cropY >= 0, cropX + cols <= wMax, cropY + rows <= hMax {
            // 屏幕内部区域零拷贝直切原生 CGImage（保留显示器 P3 ICC，120Hz 零堆分配）
            return snapshot.cgImage.cropping(to: CGRect(x: cropX, y: cropY, width: cols, height: rows))
        }
        var patch = [UInt8](repeating: 255, count: cols * rows * 4)
        patch.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for r in 0..<rows {
                let sy = py + (r - halfR), rowOff = r * cols * 4
                for c in 0..<cols {
                    let sx = px + (c - halfC), idx = rowOff + c * 4
                    if sx >= 0, sx < wMax, sy >= 0, sy < hMax {
                        let (cr, cg, cb) = snapshot.sampler.sampleRGB(px: sx, py: sy)
                        base[idx] = UInt8(cr); base[idx + 1] = UInt8(cg); base[idx + 2] = UInt8(cb)
                    } else {
                        base[idx] = 24; base[idx + 1] = 26; base[idx + 2] = 32
                    }
                }
            }
        }
        return CGDataProvider(data: Data(patch) as CFData).flatMap {
            CGImage(
                width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cols * 4,
                space: Self.loupeSRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: $0, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            )
        }
    }

    private func drawCachedLegendStrip(in ctx: CGContext, x: CGFloat, y: CGFloat, width: CGFloat) {
        let pickMode = eyedropperActive || (selection != nil && optionPressed)
        let forceVisible = (selection != nil && magnifierVisibilityOverride == true)
        let kCopy = keyUpper(.copy), kCal = keyUpper(.caliper), kCoord = keyUpper(.copyCoord)
        let kRel = keyUpper(.backdropOrCoord), kMag = keyUpper(.toggleMagnifier)
        let legendKey = "\(pickMode)|\(caliperActive)|\(useRelativeCoordinates)|\(forceVisible)|\(kCopy)\(kCal)\(kCoord)\(kRel)\(kMag)"
        let legendH: CGFloat = 68
        let legendImg: CGImage?
        if let cached = magnifierLegendCache, cached.key == legendKey {
            legendImg = cached.image
        } else {
            legendImg = Self.renderLegendCache(
                width: width, height: legendH, scale: max(1.0, snapshot.scaleFactor),
                pickMode: pickMode, caliperActive: caliperActive,
                useRelativeCoordinates: useRelativeCoordinates, forceVisible: forceVisible,
                keys: (kCopy, kCal, kCoord, kRel, kMag)
            )
            if let legendImg { magnifierLegendCache = (legendKey, legendImg) }
        }
        guard let legendImg else { return }
        let lr = CGRect(x: x, y: y, width: width, height: legendH)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: lr.minY + lr.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(legendImg, in: lr)
        ctx.restoreGState()
    }

    private static func renderLegendCache(
        width: CGFloat, height: CGFloat, scale: CGFloat,
        pickMode: Bool, caliperActive: Bool, useRelativeCoordinates: Bool, forceVisible: Bool,
        keys: (copy: String, cal: String, coord: String, rel: String, mag: String)
    ) -> CGImage? {
        let pw = Int((width * scale).rounded()), ph = Int((height * scale).rounded())
        guard pw > 0, ph > 0, let ctx = CGContext(
            data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
            space: loupeSRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(ph)); ctx.scaleBy(x: scale, y: -scale)
        let prev = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.current = prev }
        let coral = NSColor(srgbRed: 0.965, green: 0.255, blue: 0.376, alpha: 1.0)
        drawMiniKeyHint(ctx: ctx, x: 14, y: 4, key: pickMode ? "左键" : keys.copy, label: pickMode ? "吸色" : "复制色值")
        drawMiniKeyHint(ctx: ctx, x: 98, y: 4, key: "Tab", label: "切格式")
        drawMiniKeyHint(ctx: ctx, x: 14, y: 25, key: keys.cal, label: caliperActive ? "关闭测距" : "像素测距", activeTint: caliperActive ? coral : nil)
        drawMiniKeyHint(ctx: ctx, x: 98, y: 25, key: keys.coord, label: "复制坐标")
        drawMiniKeyHint(ctx: ctx, x: 14, y: 46, key: keys.rel, label: useRelativeCoordinates ? "绝对坐标" : "相对坐标", activeTint: useRelativeCoordinates ? MSnipUITheme.accent : nil)
        drawMiniKeyHint(ctx: ctx, x: 98, y: 46, key: keys.mag, label: "显示隐藏", activeTint: forceVisible ? MSnipUITheme.accent : nil)
        return ctx.makeImage()
    }

    private static func drawMiniKeyHint(ctx: CGContext, x: CGFloat, y: CGFloat, key: String, label: String, activeTint: NSColor? = nil) {
        let keyAttrs = activeTint.map { [.font: NSFont.systemFont(ofSize: 10.5, weight: .bold), .foregroundColor: $0] as [NSAttributedString.Key: Any] } ?? miniKeyAttrs
        let lblAttrs = activeTint.map { [.font: NSFont.systemFont(ofSize: 11.0, weight: .semibold), .foregroundColor: $0] as [NSAttributedString.Key: Any] } ?? miniLabelAttrs
        let kNs = key as NSString, kSz = kNs.size(withAttributes: keyAttrs)
        let capRect = CGRect(x: x, y: y, width: max(18, ceil(kSz.width + 8)), height: 17)
        let capPath = CGPath(roundedRect: capRect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
        ctx.setFillColor((activeTint?.withAlphaComponent(0.14) ?? MSnipUITheme.subtleFill).cgColor)
        ctx.addPath(capPath); ctx.fillPath()
        ctx.setStrokeColor((activeTint?.withAlphaComponent(0.75) ?? MSnipUITheme.borderStrong).cgColor)
        ctx.setLineWidth(1.0); ctx.addPath(capPath); ctx.strokePath()
        kNs.draw(at: CGPoint(x: round(capRect.midX - kSz.width * 0.5), y: round(capRect.midY - kSz.height * 0.5)), withAttributes: keyAttrs)
        let lNs = label as NSString, lSz = lNs.size(withAttributes: lblAttrs)
        lNs.draw(at: CGPoint(x: round(capRect.maxX + 4), y: round(capRect.midY - lSz.height * 0.5)), withAttributes: lblAttrs)
    }

    private static func drawCenteredString(_ text: String, centerX: CGFloat, y: CGFloat, attrs: [NSAttributedString.Key: Any]) {
        let ns = text as NSString, sz = ns.size(withAttributes: attrs)
        ns.draw(at: CGPoint(x: round(centerX - sz.width * 0.5), y: round(y)), withAttributes: attrs)
    }
}
