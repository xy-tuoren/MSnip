import AppKit
import CoreGraphics
import Foundation
import MSnipCore
import QuartzCore

/// 纯 GPU 放大镜数据调度与图例预烘焙扩展（像素放大、网格、色块与读数条全部由 `OverlayMagnifierView.swift` 的独立 `CALayer` 硬件合成）
extension OverlayView {
    static let loupeCols = 15, loupeRows = 7
    static let loupeCell: CGFloat = 10, loupeCardW: CGFloat = 150, loupeCardH: CGFloat = 156
    private static let loupeSRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private static let miniKeyAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9.5, weight: .bold),
        .foregroundColor: MSnipUITheme.inkPrimary
    ]
    private static let miniLabelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10.0, weight: .medium),
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
        var x = round(pt.x + 16), y = round(pt.y + 18)
        if x + cardW + 8 > bounds.width { x = round(pt.x - cardW - 16) }
        if y + cardH + 8 > bounds.height { y = round(pt.y - cardH - 16) }
        x = min(max(8, x), bounds.width - cardW - 8)
        y = min(max(8, y), bounds.height - cardH - 8)
        return CGRect(x: x, y: y, width: cardW, height: cardH)
    }

    /// 零 `NSView.draw` 同步纯 GPU 放大镜位置、15×9 硬件放大微切片与 CoreText 读数条
    func syncMagnifierView() {
        guard let pt = lastMousePoint, isMagnifierVisible(at: pt), let sample = samplePixelAtCursor() else {
            if !magnifierView.isHidden { magnifierView.isHidden = true; lastMagnifierKey = "" }
            return
        }
        let origin = magnifierCardFrame(at: pt).origin
        let refMinX = useRelativeCoordinates ? Int(((selection ?? hoveredAutoRect)?.minX ?? 0) * snapshot.scaleFactor) : 0
        let refMinY = useRelativeCoordinates ? Int(((selection ?? hoveredAutoRect)?.minY ?? 0) * snapshot.scaleFactor) : 0
        let key = "\(sample.px),\(sample.py)|\(refMinX),\(refMinY)|\(colorCopyFormat.rawValue)|\(useRelativeCoordinates)|\(eyedropperActive)|\(caliperActive)|\(optionPressed)|\(selection != nil)|\(magnifierVisibilityOverride == true)"
        if key == lastMagnifierKey {
            magnifierView.moveOnly(to: origin)
            return
        }
        lastMagnifierKey = key

        let coord = formattedCoordinateAtCursor(px: sample.px, py: sample.py)
        let colorText = sample.color.formatted(as: colorCopyFormat)
        let patchCG = cropMagnifierPatch(px: sample.px, py: sample.py, cols: Self.loupeCols, rows: Self.loupeRows)

        let pickMode = eyedropperActive || (selection != nil && optionPressed)
        let forceVisible = (selection != nil && magnifierVisibilityOverride == true)
        let kCopy = keyUpper(.copy), kCal = keyUpper(.caliper), kCoord = keyUpper(.copyCoord)
        let kRel = keyUpper(.backdropOrCoord), kMag = keyUpper(.toggleMagnifier)
        let legendKey = "\(pickMode)|\(caliperActive)|\(useRelativeCoordinates)|\(forceVisible)|\(kCopy)\(kCal)\(kCoord)\(kRel)\(kMag)"

        magnifierView.updateGPU(
            origin: origin,
            scale: snapshot.scaleFactor,
            patchCG: patchCG,
            eyedropperActive: eyedropperActive,
            coordText: coord.text,
            useRelative: useRelativeCoordinates,
            color: sample.color,
            colorText: colorText,
            legendKey: legendKey
        ) { [weak self] in
            guard let self else { return nil }
            if let cached = self.magnifierLegendCache, cached.key == legendKey { return cached.image }
            let img = Self.renderLegendCache(
                width: Self.loupeCardW, height: 46, scale: max(1.0, self.snapshot.scaleFactor),
                pickMode: pickMode, caliperActive: self.caliperActive,
                useRelativeCoordinates: self.useRelativeCoordinates, forceVisible: forceVisible,
                keys: (kCopy, kCal, kCoord, kRel, kMag)
            )
            if let img { self.magnifierLegendCache = (legendKey, img) }
            return img
        }
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

    private func cropMagnifierPatch(px: Int, py: Int, cols: Int, rows: Int) -> CGImage? {
        // 使用 bytesPerRow = 0 创建 64 字节 Metal 对齐的微型 CGContext，直写像素后生成标准 CGImage，杜绝 Apple Silicon 纹理步长错位产生坏点
        guard let ctx = CGContext(
            data: nil, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
            space: Self.loupeSRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let raw = ctx.data else { return nil }
        let base = raw.assumingMemoryBound(to: UInt8.self)
        let bpr = ctx.bytesPerRow
        let halfC = cols / 2, halfR = rows / 2
        let wMax = snapshot.sampler.width, hMax = snapshot.sampler.height
        for r in 0..<rows {
            let sy = py + (r - halfR), rowOff = r * bpr
            for c in 0..<cols {
                let sx = px + (c - halfC), idx = rowOff + c * 4
                if sx >= 0, sx < wMax, sy >= 0, sy < hMax {
                    let (cr, cg, cb) = snapshot.sampler.sampleRGB(px: sx, py: sy)
                    base[idx] = UInt8(cr); base[idx + 1] = UInt8(cg); base[idx + 2] = UInt8(cb); base[idx + 3] = 255
                } else {
                    base[idx] = 24; base[idx + 1] = 26; base[idx + 2] = 32; base[idx + 3] = 255
                }
            }
        }
        return ctx.makeImage()
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
        drawMiniKeyHint(ctx: ctx, x: 14, y: 2, key: pickMode ? "左键" : keys.copy, label: pickMode ? "吸色" : "色值")
        drawMiniKeyHint(ctx: ctx, x: 80, y: 2, key: "Tab", label: "格式")
        drawMiniKeyHint(ctx: ctx, x: 14, y: 17, key: keys.cal, label: caliperActive ? "关距" : "测距", activeTint: caliperActive ? coral : nil)
        drawMiniKeyHint(ctx: ctx, x: 80, y: 17, key: keys.coord, label: "坐标")
        drawMiniKeyHint(ctx: ctx, x: 14, y: 32, key: keys.rel, label: useRelativeCoordinates ? "绝对" : "相对", activeTint: useRelativeCoordinates ? MSnipUITheme.accent : nil)
        drawMiniKeyHint(ctx: ctx, x: 80, y: 32, key: keys.mag, label: "显隐", activeTint: forceVisible ? MSnipUITheme.accent : nil)
        return ctx.makeImage()
    }

    private static func drawMiniKeyHint(ctx: CGContext, x: CGFloat, y: CGFloat, key: String, label: String, activeTint: NSColor? = nil) {
        let keyAttrs = activeTint.map { [.font: NSFont.systemFont(ofSize: 9.5, weight: .bold), .foregroundColor: $0] as [NSAttributedString.Key: Any] } ?? miniKeyAttrs
        let lblAttrs = activeTint.map { [.font: NSFont.systemFont(ofSize: 10.0, weight: .semibold), .foregroundColor: $0] as [NSAttributedString.Key: Any] } ?? miniLabelAttrs
        let kNs = key as NSString, kSz = kNs.size(withAttributes: keyAttrs)
        let capRect = CGRect(x: x, y: y, width: max(16, ceil(kSz.width + 6)), height: 13.5)
        let capPath = CGPath(roundedRect: capRect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 3.0, cornerHeight: 3.0, transform: nil)
        ctx.setFillColor((activeTint?.withAlphaComponent(0.14) ?? MSnipUITheme.subtleFill).cgColor)
        ctx.addPath(capPath); ctx.fillPath()
        ctx.setStrokeColor((activeTint?.withAlphaComponent(0.75) ?? MSnipUITheme.borderStrong).cgColor)
        ctx.setLineWidth(0.8); ctx.addPath(capPath); ctx.strokePath()
        kNs.draw(at: CGPoint(x: round(capRect.midX - kSz.width * 0.5), y: round(capRect.midY - kSz.height * 0.5)), withAttributes: keyAttrs)
        let lNs = label as NSString, lSz = lNs.size(withAttributes: lblAttrs)
        lNs.draw(at: CGPoint(x: round(capRect.maxX + 3.5), y: round(capRect.midY - lSz.height * 0.5)), withAttributes: lblAttrs)
    }
}
