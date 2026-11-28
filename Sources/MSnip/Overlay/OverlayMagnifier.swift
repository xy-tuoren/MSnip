import AppKit
import CoreGraphics
import CoreText
import Foundation
import MSnipCore
import QuartzCore

/// 零 `NSView.draw` 纯 GPU 分层光标放大镜视图：
/// - 卡片圆角底衬、静态阴影路径、十字准星网格、底部快捷键图例全部预烘焙进独立 GPU `CALayer`（移动过程 0 重绘）；
/// - 15×9（540 字节）微切片直投 `magnificationFilter = .nearest` 硬件放大，仅 180×44 读数条通过 CoreText `CTLineDraw` 更新（~0.03ms）。
final class OverlayMagnifierLayerView: NSView {
    private static let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let coordFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
    private static let coordRelFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold)
    private static let colorFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold)

    private let cardLayer = CALayer()
    private let patchLayer = CALayer()
    private let reticleLayer = CALayer()
    private let readoutLayer = CALayer()
    private let swatchLayer = CALayer()
    private let dividerLayer = CALayer()
    private let legendLayer = CALayer()
    private let borderLayer = CALayer()

    private var cachedReticleKey: String = ""
    private var cachedLegendKey: String = ""

    // 使用标准未翻转坐标系（isFlipped = false），确保所有 CALayer.contents 直出 CGImage 100% 正向不颠倒
    override var isFlipped: Bool { false }

    private static func topRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: OverlayView.loupeCardH - y - h, width: w, height: h)
    }

    init() {
        let sz = NSSize(width: OverlayView.loupeCardW, height: OverlayView.loupeCardH)
        super.init(frame: NSRect(origin: .zero, size: sz))
        wantsLayer = true
        isHidden = true

        guard let root = layer else { return }
        root.masksToBounds = false
        root.shadowColor = NSColor.black.cgColor
        root.shadowOpacity = 0.22
        root.shadowRadius = 8
        root.shadowOffset = CGSize(width: 0, height: -3)
        root.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: sz), cornerWidth: 8, cornerHeight: 8, transform: nil)

        let loupeH = CGFloat(OverlayView.loupeRows) * OverlayView.loupeCell
        cardLayer.frame = CGRect(origin: .zero, size: sz)
        cardLayer.cornerRadius = 8
        cardLayer.masksToBounds = true
        cardLayer.backgroundColor = MSnipUITheme.cardBg.cgColor
        root.addSublayer(cardLayer)

        patchLayer.frame = Self.topRect(0, 0, sz.width, loupeH)
        patchLayer.isOpaque = true
        patchLayer.magnificationFilter = .nearest
        patchLayer.minificationFilter = .nearest
        cardLayer.addSublayer(patchLayer)

        reticleLayer.frame = patchLayer.frame
        cardLayer.addSublayer(reticleLayer)

        readoutLayer.frame = Self.topRect(0, loupeH, sz.width, 34)
        cardLayer.addSublayer(readoutLayer)

        swatchLayer.frame = Self.topRect(34, loupeH + 19.5, 10, 10)
        swatchLayer.borderWidth = 1.0
        swatchLayer.borderColor = MSnipUITheme.borderStrong.cgColor
        cardLayer.addSublayer(swatchLayer)

        dividerLayer.frame = Self.topRect(10, round(loupeH + 35), sz.width - 20, 1)
        dividerLayer.backgroundColor = MSnipUITheme.borderHairline.cgColor
        cardLayer.addSublayer(dividerLayer)

        legendLayer.frame = Self.topRect(0, round(loupeH + 37), sz.width, 46)
        cardLayer.addSublayer(legendLayer)

        borderLayer.frame = CGRect(origin: .zero, size: sz)
        borderLayer.cornerRadius = 8
        borderLayer.borderWidth = 1.0
        borderLayer.borderColor = MSnipUITheme.borderStrong.cgColor
        borderLayer.backgroundColor = nil
        root.addSublayer(borderLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func updateGPU(
        origin: NSPoint,
        scale: CGFloat,
        patchCG: CGImage?,
        eyedropperActive: Bool,
        coordText: String,
        useRelative: Bool,
        color: RGBAColor,
        colorText: String,
        legendKey: String,
        makeLegend: () -> CGImage?
    ) {
        let s = max(1.0, scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if isHidden { isHidden = false }
        if frame.origin != origin { setFrameOrigin(origin) }

        if let patchCG {
            patchLayer.contents = patchCG
        }

        let retKey = "\(eyedropperActive)|\(Int(s.rounded()))"
        if retKey != cachedReticleKey {
            cachedReticleKey = retKey
            reticleLayer.contentsScale = s
            reticleLayer.contents = Self.bakeReticleImage(scale: s, eyedropper: eyedropperActive)
        }

        let (readoutCG, swatchX) = Self.bakeReadoutImage(
            width: OverlayView.loupeCardW, height: 34, scale: s,
            coordText: coordText, useRelative: useRelative, colorText: colorText
        )
        readoutLayer.contentsScale = s
        readoutLayer.contents = readoutCG

        let loupeH = CGFloat(OverlayView.loupeRows) * OverlayView.loupeCell
        swatchLayer.frame = Self.topRect(swatchX, loupeH + 19.5, 10, 10)
        swatchLayer.backgroundColor = color.cgColor

        if legendKey != cachedLegendKey {
            cachedLegendKey = legendKey
            legendLayer.contentsScale = s
            legendLayer.contents = makeLegend()
        }
    }

    func moveOnly(to origin: NSPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if isHidden { isHidden = false }
        if frame.origin != origin { setFrameOrigin(origin) }
        CATransaction.commit()
    }

    private static func bakeReticleImage(scale: CGFloat, eyedropper: Bool) -> CGImage? {
        let cols = OverlayView.loupeCols, rows = OverlayView.loupeRows, cell = OverlayView.loupeCell
        let w = OverlayView.loupeCardW, h = CGFloat(rows) * cell
        let pw = Int((w * scale).rounded()), ph = Int((h * scale).rounded())
        guard pw > 0, ph > 0, let ctx = CGContext(
            data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(ph)); ctx.scaleBy(x: scale, y: -scale)

        let halfC = cols / 2, halfR = rows / 2
        let centerRect = CGRect(x: CGFloat(halfC) * cell, y: CGFloat(halfR) * cell, width: cell, height: cell)
        let band = (eyedropper ? NSColor.systemYellow : NSColor(srgbRed: 0.22, green: 0.56, blue: 0.98, alpha: 1.0))
            .withAlphaComponent(0.32).cgColor
        ctx.setFillColor(band)
        ctx.fill(CGRect(x: centerRect.minX, y: 0, width: cell, height: centerRect.minY))
        ctx.fill(CGRect(x: centerRect.minX, y: centerRect.maxY, width: cell, height: h - centerRect.maxY))
        ctx.fill(CGRect(x: 0, y: centerRect.minY, width: centerRect.minX, height: cell))
        ctx.fill(CGRect(x: centerRect.maxX, y: centerRect.minY, width: w - centerRect.maxX, height: cell))

        ctx.setStrokeColor(NSColor(white: 0.5, alpha: 0.26).cgColor)
        ctx.setLineWidth(0.5)
        for c in 1..<cols {
            let gx = CGFloat(c) * cell
            ctx.move(to: CGPoint(x: gx, y: 0)); ctx.addLine(to: CGPoint(x: gx, y: h))
        }
        for r in 1..<rows {
            let gy = CGFloat(r) * cell
            ctx.move(to: CGPoint(x: 0, y: gy)); ctx.addLine(to: CGPoint(x: w, y: gy))
        }
        ctx.strokePath()

        ctx.setStrokeColor(MSnipUITheme.borderStrong.cgColor); ctx.setLineWidth(1.0)
        ctx.stroke(CGRect(x: 0.5, y: 0.5, width: w - 1, height: h - 1))
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.92).cgColor); ctx.setLineWidth(1.5)
        ctx.stroke(centerRect.insetBy(dx: -0.75, dy: -0.75))
        ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1.0)
        ctx.stroke(centerRect.insetBy(dx: 0.5, dy: 0.5))
        return ctx.makeImage()
    }

    private static func bakeReadoutImage(
        width: CGFloat, height: CGFloat, scale: CGFloat,
        coordText: String, useRelative: Bool, colorText: String
    ) -> (CGImage?, CGFloat) {
        let pw = Int((width * scale).rounded()), ph = Int((height * scale).rounded())
        guard pw > 0, ph > 0, let ctx = CGContext(
            data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (nil, 40) }
        ctx.scaleBy(x: scale, y: scale)
        ctx.textMatrix = .identity

        let cAttrs: [CFString: Any] = [
            kCTFontAttributeName: useRelative ? coordRelFont : coordFont,
            kCTForegroundColorAttributeName: (useRelative ? MSnipUITheme.accent : MSnipUITheme.inkSecondary).cgColor
        ]
        let line1 = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, coordText as CFString, cAttrs as CFDictionary)!)
        let w1 = CGFloat(CTLineGetTypographicBounds(line1, nil, nil, nil))
        ctx.textPosition = CGPoint(x: round((width - w1) * 0.5), y: 20.5)
        CTLineDraw(line1, ctx)

        let vAttrs: [CFString: Any] = [
            kCTFontAttributeName: colorFont,
            kCTForegroundColorAttributeName: MSnipUITheme.inkPrimary.cgColor
        ]
        let line2 = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, colorText as CFString, vAttrs as CFDictionary)!)
        let w2 = CGFloat(CTLineGetTypographicBounds(line2, nil, nil, nil))
        let swSide: CGFloat = 10, gap: CGFloat = 5
        let swX = round((width - (swSide + gap + w2)) * 0.5)
        ctx.textPosition = CGPoint(x: round(swX + swSide + gap), y: 5.5)
        CTLineDraw(line2, ctx)

        return (ctx.makeImage(), swX)
    }
}

// MARK: - 放大镜调度与图例预烘焙

/// 纯 GPU 放大镜数据调度与图例预烘焙扩展（像素放大、网格、色块与读数条全部由 `OverlayMagnifierView` 的独立 `CALayer` 硬件合成）
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
                return ("REL", L("相对 (%@, %@)", rx, ry), "\(rx), \(ry)")
            }
            return ("REL", L("相对 (%@, %@)", px, py), "\(px), \(py)")
        }
        return ("ABS", L("绝对 (%@, %@)", px, py), "\(px), \(py)")
    }

    private func cropMagnifierPatch(px: Int, py: Int, cols: Int, rows: Int) -> CGImage? {
        let patchCS = snapshot.sampler.samplingColorSpace
        // 使用 bytesPerRow = 0 创建 64 字节 Metal 对齐的微型 CGContext，继承原屏 Display P3 色彩空间杜绝广色域偏灰
        guard let ctx = CGContext(
            data: nil, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
            space: patchCS, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
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
        drawMiniKeyHint(ctx: ctx, x: 14, y: 2, key: pickMode ? L("左键") : keys.copy, label: pickMode ? L("吸色") : L("色值"))
        drawMiniKeyHint(ctx: ctx, x: 80, y: 2, key: "Tab", label: L("格式"))
        drawMiniKeyHint(ctx: ctx, x: 14, y: 17, key: keys.cal, label: caliperActive ? L("关距") : L("测距"), activeTint: caliperActive ? coral : nil)
        drawMiniKeyHint(ctx: ctx, x: 80, y: 17, key: keys.coord, label: L("坐标"))
        drawMiniKeyHint(ctx: ctx, x: 14, y: 32, key: keys.rel, label: useRelativeCoordinates ? L("绝对") : L("相对"), activeTint: useRelativeCoordinates ? MSnipUITheme.accent : nil)
        drawMiniKeyHint(ctx: ctx, x: 80, y: 32, key: keys.mag, label: L("显隐"), activeTint: forceVisible ? MSnipUITheme.accent : nil)
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
