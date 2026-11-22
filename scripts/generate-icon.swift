#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: generate-icon.swift <output.icns | output-iconset-dir>\n", stderr)
    exit(1)
}
let outPath = CommandLine.arguments[1]

func makeAppleSquircle(in rect: CGRect, radius: CGFloat) -> CGPath {
    let r = min(radius, min(rect.width, rect.height) * 0.5)
    let c: CGFloat = 0.445
    let p = CGMutablePath()
    let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
    p.move(to: CGPoint(x: minX + r, y: minY))
    p.addLine(to: CGPoint(x: maxX - r, y: minY))
    p.addCurve(to: CGPoint(x: maxX, y: minY + r),
               control1: CGPoint(x: maxX - r * (1 - c), y: minY),
               control2: CGPoint(x: maxX, y: minY + r * (1 - c)))
    p.addLine(to: CGPoint(x: maxX, y: maxY - r))
    p.addCurve(to: CGPoint(x: maxX - r, y: maxY),
               control1: CGPoint(x: maxX, y: maxY - r * (1 - c)),
               control2: CGPoint(x: maxX - r * (1 - c), y: maxY))
    p.addLine(to: CGPoint(x: minX + r, y: maxY))
    p.addCurve(to: CGPoint(x: minX, y: maxY - r),
               control1: CGPoint(x: minX + r * (1 - c), y: maxY),
               control2: CGPoint(x: minX, y: maxY - r * (1 - c)))
    p.addLine(to: CGPoint(x: minX, y: minY + r))
    p.addCurve(to: CGPoint(x: minX + r, y: minY),
               control1: CGPoint(x: minX, y: minY + r * (1 - c)),
               control2: CGPoint(x: minX + r * (1 - c), y: minY))
    p.closeSubpath()
    return p
}

func renderCommercialAppIcon(px: Int) -> CGImage? {
    let s = CGFloat(px)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let pad = s * 0.098
    let card = CGRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)
    let corner = card.width * 0.228
    let squircle = makeAppleSquircle(in: card, radius: corner)

    // 0) Grounded macOS Dock shadow
    if px >= 32 {
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -s * 0.020),
            blur: s * 0.042,
            color: CGColor(srgbRed: 0.01, green: 0.02, blue: 0.08, alpha: 0.44)
        )
        ctx.setFillColor(CGColor(srgbRed: 0.06, green: 0.10, blue: 0.20, alpha: 1.0))
        ctx.addPath(squircle)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 1) Deep Titanium-Midnight Chassis + Luminous Sapphire Studio Aura
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    let baseCols = [
        CGColor(srgbRed: 0.118, green: 0.172, blue: 0.302, alpha: 1.0),
        CGColor(srgbRed: 0.063, green: 0.094, blue: 0.180, alpha: 1.0),
        CGColor(srgbRed: 0.035, green: 0.055, blue: 0.114, alpha: 1.0)
    ] as CFArray
    if let g = CGGradient(colorsSpace: cs, colors: baseCols, locations: [0.0, 0.55, 1.0]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: card.minX, y: card.maxY), end: CGPoint(x: card.maxX, y: card.minY), options: [])
    }

    let auraCols = [
        CGColor(srgbRed: 0.16, green: 0.68, blue: 1.00, alpha: 0.50),
        CGColor(srgbRed: 0.07, green: 0.38, blue: 0.96, alpha: 0.24),
        CGColor(srgbRed: 0.04, green: 0.12, blue: 0.35, alpha: 0.0)
    ] as CFArray
    if let rg = CGGradient(colorsSpace: cs, colors: auraCols, locations: [0.0, 0.50, 1.0]) {
        ctx.drawRadialGradient(
            rg,
            startCenter: CGPoint(x: s * 0.44, y: s * 0.56), startRadius: 0,
            endCenter: CGPoint(x: s * 0.50, y: s * 0.50), endRadius: card.width * 0.62,
            options: [.drawsAfterEndLocation]
        )
    }

    // Specular top glass bezel rim
    let rimCols = [
        CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.28),
        CGColor(srgbRed: 0.72, green: 0.86, blue: 1.0, alpha: 0.08),
        CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.0)
    ] as CFArray
    if let rimG = CGGradient(colorsSpace: cs, colors: rimCols, locations: [0.0, 0.28, 0.65]) {
        ctx.saveGState()
        ctx.addPath(makeAppleSquircle(in: card.insetBy(dx: s * 0.005, dy: s * 0.005), radius: corner - s * 0.005))
        ctx.setLineWidth(max(1.0, s * 0.010))
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(rimG, start: CGPoint(x: card.midX, y: card.maxY), end: CGPoint(x: card.midX, y: card.minY), options: [])
        ctx.restoreGState()
    }

    // 2) Precision Machined Viewfinder Brackets with Vertical Metallic Sheen
    let bInset = s * 0.195
    let bBox = CGRect(x: bInset, y: bInset, width: s - bInset * 2, height: s - bInset * 2)
    let bArm = bBox.width * 0.22
    let bArcR = bBox.width * 0.125
    let bStroke = max(1.5, s * 0.032)

    let brackets = CGMutablePath()
    brackets.move(to: CGPoint(x: bBox.minX, y: bBox.maxY - bArm))
    brackets.addArc(tangent1End: CGPoint(x: bBox.minX, y: bBox.maxY), tangent2End: CGPoint(x: bBox.minX + bArm, y: bBox.maxY), radius: bArcR)
    brackets.addLine(to: CGPoint(x: bBox.minX + bArm, y: bBox.maxY))

    brackets.move(to: CGPoint(x: bBox.maxX - bArm, y: bBox.maxY))
    brackets.addArc(tangent1End: CGPoint(x: bBox.maxX, y: bBox.maxY), tangent2End: CGPoint(x: bBox.maxX, y: bBox.maxY - bArm), radius: bArcR)
    brackets.addLine(to: CGPoint(x: bBox.maxX, y: bBox.maxY - bArm))

    brackets.move(to: CGPoint(x: bBox.maxX, y: bBox.minY + bArm))
    brackets.addArc(tangent1End: CGPoint(x: bBox.maxX, y: bBox.minY), tangent2End: CGPoint(x: bBox.maxX - bArm, y: bBox.minY), radius: bArcR)
    brackets.addLine(to: CGPoint(x: bBox.maxX - bArm, y: bBox.minY))

    brackets.move(to: CGPoint(x: bBox.minX + bArm, y: bBox.minY))
    brackets.addArc(tangent1End: CGPoint(x: bBox.minX, y: bBox.minY), tangent2End: CGPoint(x: bBox.minX, y: bBox.minY + bArm), radius: bArcR)
    brackets.addLine(to: CGPoint(x: bBox.minX, y: bBox.minY + bArm))

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.010), blur: s * 0.022, color: CGColor(srgbRed: 0.0, green: 0.02, blue: 0.10, alpha: 0.55))
    ctx.addPath(brackets)
    ctx.setLineWidth(bStroke); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setStrokeColor(CGColor(srgbRed: 0.94, green: 0.97, blue: 1.0, alpha: 0.95))
    ctx.strokePath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(brackets)
    ctx.setLineWidth(bStroke); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let metalCols = [
        CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1.0),
        CGColor(srgbRed: 0.84, green: 0.91, blue: 1.00, alpha: 1.0)
    ] as CFArray
    if let mg = CGGradient(colorsSpace: cs, colors: metalCols, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(mg, start: CGPoint(x: bBox.midX, y: bBox.maxY), end: CGPoint(x: bBox.midX, y: bBox.minY), options: [])
    }
    ctx.restoreGState()

    // 3) Floating Luminous Sapphire-Cyan Capture Glass Card
    let paneInset = s * 0.270
    let paneRect = CGRect(x: paneInset, y: paneInset, width: s - paneInset * 2, height: s - paneInset * 2)
    let paneRadius = paneRect.width * 0.225
    let panePath = makeAppleSquircle(in: paneRect, radius: paneRadius)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.020), blur: s * 0.048, color: CGColor(srgbRed: 0.01, green: 0.04, blue: 0.18, alpha: 0.62))
    ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.38, blue: 0.96, alpha: 1.0))
    ctx.addPath(panePath); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(panePath); ctx.clip()
    let paneCols = [
        CGColor(srgbRed: 0.30, green: 0.80, blue: 1.00, alpha: 1.0),
        CGColor(srgbRed: 0.09, green: 0.49, blue: 0.99, alpha: 1.0),
        CGColor(srgbRed: 0.08, green: 0.24, blue: 0.76, alpha: 1.0)
    ] as CFArray
    if let pg = CGGradient(colorsSpace: cs, colors: paneCols, locations: [0.0, 0.48, 1.0]) {
        ctx.drawLinearGradient(pg, start: CGPoint(x: paneRect.minX, y: paneRect.maxY), end: CGPoint(x: paneRect.maxX, y: paneRect.minY), options: [])
    }

    let sweepCols = [
        CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.30),
        CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.0)
    ] as CFArray
    if let sg = CGGradient(colorsSpace: cs, colors: sweepCols, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(
            sg,
            startCenter: CGPoint(x: paneRect.minX + paneRect.width * 0.18, y: paneRect.maxY - paneRect.height * 0.14), startRadius: 0,
            endCenter: CGPoint(x: paneRect.minX + paneRect.width * 0.25, y: paneRect.maxY - paneRect.height * 0.20), endRadius: paneRect.width * 0.72,
            options: []
        )
    }
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(makeAppleSquircle(in: paneRect.insetBy(dx: s * 0.004, dy: s * 0.004), radius: paneRadius - s * 0.004))
    ctx.setStrokeColor(CGColor(srgbRed: 0.86, green: 0.96, blue: 1.0, alpha: 0.62))
    ctx.setLineWidth(max(1.0, s * 0.0085))
    ctx.strokePath()
    ctx.restoreGState()

    // 4) Precision Sculpted Optical Lens Assembly
    let c = CGPoint(x: s * 0.5, y: s * 0.5)
    let outerLensR = paneRect.width * 0.305
    let innerGlassR = paneRect.width * 0.215

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.026, color: CGColor(srgbRed: 0.02, green: 0.10, blue: 0.34, alpha: 0.48))
    ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.98, blue: 1.0, alpha: 1.0))
    ctx.fillEllipse(in: CGRect(x: c.x - outerLensR, y: c.y - outerLensR, width: outerLensR * 2, height: outerLensR * 2))
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - outerLensR, y: c.y - outerLensR, width: outerLensR * 2, height: outerLensR * 2))
    ctx.clip()
    let ringMetal = [
        CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1.0),
        CGColor(srgbRed: 0.84, green: 0.90, blue: 0.99, alpha: 1.0)
    ] as CFArray
    if let rmg = CGGradient(colorsSpace: cs, colors: ringMetal, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(rmg, start: CGPoint(x: c.x, y: c.y + outerLensR), end: CGPoint(x: c.x, y: c.y - outerLensR), options: [])
    }
    ctx.restoreGState()

    // Machined dark lens barrel chamfer ring
    let barrelR = innerGlassR + max(1.0, s * 0.006)
    ctx.setStrokeColor(CGColor(srgbRed: 0.06, green: 0.14, blue: 0.32, alpha: 0.55))
    ctx.setLineWidth(max(1.0, s * 0.008))
    ctx.strokeEllipse(in: CGRect(x: c.x - barrelR, y: c.y - barrelR, width: barrelR * 2, height: barrelR * 2))

    // Deep sapphire optical glass chamber
    let innerRect = CGRect(x: c.x - innerGlassR, y: c.y - innerGlassR, width: innerGlassR * 2, height: innerGlassR * 2)
    ctx.saveGState()
    ctx.addEllipse(in: innerRect); ctx.clip()
    let chamberCols = [
        CGColor(srgbRed: 0.05, green: 0.12, blue: 0.28, alpha: 1.0),
        CGColor(srgbRed: 0.08, green: 0.26, blue: 0.62, alpha: 1.0),
        CGColor(srgbRed: 0.16, green: 0.56, blue: 0.98, alpha: 1.0)
    ] as CFArray
    if let chg = CGGradient(colorsSpace: cs, colors: chamberCols, locations: [0.0, 0.58, 1.0]) {
        ctx.drawLinearGradient(chg, start: CGPoint(x: c.x - innerGlassR * 0.4, y: c.y + innerGlassR), end: CGPoint(x: c.x + innerGlassR * 0.5, y: c.y - innerGlassR), options: [])
    }
    let coatCols = [
        CGColor(srgbRed: 0.35, green: 0.94, blue: 1.00, alpha: 0.58),
        CGColor(srgbRed: 0.20, green: 0.60, blue: 1.00, alpha: 0.0)
    ] as CFArray
    if let cg = CGGradient(colorsSpace: cs, colors: coatCols, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(
            cg,
            startCenter: CGPoint(x: c.x + innerGlassR * 0.42, y: c.y - innerGlassR * 0.42), startRadius: 0,
            endCenter: CGPoint(x: c.x + innerGlassR * 0.30, y: c.y - innerGlassR * 0.30), endRadius: innerGlassR * 0.72,
            options: []
        )
    }
    let pupilR = innerGlassR * 0.42
    ctx.setFillColor(CGColor(srgbRed: 0.03, green: 0.06, blue: 0.15, alpha: 0.84))
    ctx.fillEllipse(in: CGRect(x: c.x - pupilR, y: c.y - pupilR, width: pupilR * 2, height: pupilR * 2))

    // Dual optical catchlights
    let glint1R = innerGlassR * 0.23
    ctx.setFillColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.92))
    ctx.fillEllipse(in: CGRect(x: c.x - innerGlassR * 0.42 - glint1R * 0.5, y: c.y + innerGlassR * 0.36 - glint1R * 0.5, width: glint1R * 1.15, height: glint1R * 0.85))
    let glint2R = innerGlassR * 0.10
    ctx.setFillColor(CGColor(srgbRed: 0.76, green: 0.96, blue: 1.0, alpha: 0.72))
    ctx.fillEllipse(in: CGRect(x: c.x + innerGlassR * 0.32 - glint2R, y: c.y - innerGlassR * 0.32 - glint2R, width: glint2R * 2, height: glint2R * 2))
    ctx.restoreGState()

    // 5) Embedded Coral-Red Live Capture Jewel with Subtle Recessed Collar & Specular Glint
    let dotR = max(1.5, s * 0.033)
    let dotCenter = CGPoint(x: paneRect.maxX - paneRect.width * 0.145, y: paneRect.maxY - paneRect.height * 0.145)
    let collarR = dotR * 1.28
    ctx.setFillColor(CGColor(srgbRed: 0.04, green: 0.14, blue: 0.42, alpha: 0.42))
    ctx.fillEllipse(in: CGRect(x: dotCenter.x - collarR, y: dotCenter.y - collarR, width: collarR * 2, height: collarR * 2))

    let dotRect = CGRect(x: dotCenter.x - dotR, y: dotCenter.y - dotR, width: dotR * 2, height: dotR * 2)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.022, color: CGColor(srgbRed: 1.0, green: 0.28, blue: 0.40, alpha: 0.80))
    ctx.setFillColor(CGColor(srgbRed: 1.0, green: 0.28, blue: 0.38, alpha: 1.0))
    ctx.fillEllipse(in: dotRect)
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addEllipse(in: dotRect); ctx.clip()
    let jewelCols = [
        CGColor(srgbRed: 1.00, green: 0.56, blue: 0.50, alpha: 1.0),
        CGColor(srgbRed: 0.98, green: 0.22, blue: 0.35, alpha: 1.0),
        CGColor(srgbRed: 0.76, green: 0.08, blue: 0.22, alpha: 1.0)
    ] as CFArray
    if let jg = CGGradient(colorsSpace: cs, colors: jewelCols, locations: [0.0, 0.52, 1.0]) {
        ctx.drawRadialGradient(
            jg,
            startCenter: CGPoint(x: dotCenter.x - dotR * 0.30, y: dotCenter.y + dotR * 0.30), startRadius: 0,
            endCenter: dotCenter, endRadius: dotR * 1.15,
            options: []
        )
    }
    let pinR = dotR * 0.22
    ctx.setFillColor(CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.85))
    ctx.fillEllipse(in: CGRect(x: dotCenter.x - dotR * 0.35 - pinR, y: dotCenter.y + dotR * 0.35 - pinR, width: pinR * 2, height: pinR * 2))
    ctx.restoreGState()

    ctx.restoreGState()
    return ctx.makeImage()
}

func encodePNG(_ cgImg: CGImage) -> Data? {
    let buf = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(buf, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, cgImg, nil)
    return CGImageDestinationFinalize(dest) ? (buf as Data) : nil
}

/// 利用 Apple ImageIO 视觉无损 JPEG 2000 (PSNR ~55 dB) 压缩高分辨率光滑渐变图标，体积缩小 70%+
func encodeOptimizedJP2(_ cgImg: CGImage) -> Data? {
    let buf = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(buf, "public.jpeg-2000" as CFString, 1, nil) else { return nil }
    let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.90]
    CGImageDestinationAddImage(dest, cgImg, opts as CFDictionary)
    return CGImageDestinationFinalize(dest) ? (buf as Data) : nil
}

if outPath.hasSuffix(".icns") {
    var cache: [Int: Data] = [:]
    for px in [16, 32, 64, 128, 256, 512, 1024] {
        guard let img = renderCommercialAppIcon(px: px) else { continue }
        if px >= 256, let jp2 = encodeOptimizedJP2(img) {
            cache[px] = jp2
        } else if let png = encodePNG(img) {
            cache[px] = png
        }
    }
    let slots: [(String, Int)] = [
        ("icp4", 16), ("ic11", 32), ("icp5", 32), ("ic12", 64),
        ("ic07", 128), ("ic13", 256), ("ic08", 256),
        ("ic14", 512), ("ic09", 512), ("ic10", 1024)
    ]
    var body = Data()
    for (tag, px) in slots {
        guard let payload = cache[px] else { continue }
        body.append(contentsOf: tag.utf8)
        var chunkLen = UInt32(payload.count + 8).bigEndian
        body.append(Data(bytes: &chunkLen, count: 4))
        body.append(payload)
    }
    var icns = Data("icns".utf8)
    var totalLen = UInt32(body.count + 8).bigEndian
    icns.append(Data(bytes: &totalLen, count: 4))
    icns.append(body)
    try icns.write(to: URL(fileURLWithPath: outPath))
} else {
    let mapping: [(String, Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
    ]
    for (name, px) in mapping {
        if let img = renderCommercialAppIcon(px: px), let data = encodePNG(img) {
            try data.write(to: URL(fileURLWithPath: "\(outPath)/\(name)"))
        }
    }
}
