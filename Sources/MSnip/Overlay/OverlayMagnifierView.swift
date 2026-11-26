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
