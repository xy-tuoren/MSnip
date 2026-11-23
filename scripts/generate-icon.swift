#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: generate-icon.swift <output.icns | output-iconset-dir> [source.png]\n", stderr)
    exit(1)
}

let outPath = CommandLine.arguments[1]
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let sourcePath = CommandLine.arguments.count >= 3
    ? CommandLine.arguments[2]
    : repoRoot.appendingPathComponent("Assets/AppIcon-Source.png").path

guard let imgSrc = CGImageSourceCreateWithURL(URL(fileURLWithPath: sourcePath) as CFURL, nil),
      let artwork = CGImageSourceCreateImageAtIndex(imgSrc, 0, nil) else {
    fputs("❌ 找不到图标源图: \(sourcePath)\n", stderr)
    exit(1)
}

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

func renderAppIcon(from source: CGImage, px: Int) -> CGImage? {
    let s = CGFloat(px)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let pad = s * 0.098
    let card = CGRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)
    let corner = card.width * 0.228
    let squircle = makeAppleSquircle(in: card, radius: corner)

    // 1) 标准 macOS Dock 投影（小尺寸 16px 跳过防模糊）
    if px >= 32 {
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -s * 0.018),
            blur: s * 0.036,
            color: CGColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.34)
        )
        ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.965, blue: 0.975, alpha: 1.0))
        ctx.addPath(squircle)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 2) 满幅瑞士纸感裁切底图按 Apple 超椭圆精确裁切
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    ctx.draw(source, in: card)

    // 3) 极细内描边，确保浅色纸感底座在亮色访达与暗色 Dock 下均边缘利落
    let inset = max(0.5, s * 0.002)
    ctx.addPath(makeAppleSquircle(in: card.insetBy(dx: inset, dy: inset), radius: corner - inset))
    ctx.setStrokeColor(CGColor(srgbRed: 0.0, green: 0.0, blue: 0.0, alpha: 0.085))
    ctx.setLineWidth(max(1.0, s * 0.004))
    ctx.strokePath()
    ctx.restoreGState()

    return ctx.makeImage()
}

func encodePNG(_ cgImg: CGImage) -> Data? {
    let buf = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(buf, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, cgImg, nil)
    return CGImageDestinationFinalize(dest) ? (buf as Data) : nil
}

let iconsetMapping: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]

func writeIconset(to dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var cache: [Int: Data] = [:]
    for px in [16, 32, 64, 128, 256, 512, 1024] {
        if let img = renderAppIcon(from: artwork, px: px), let png = encodePNG(img) {
            cache[px] = png
        }
    }
    for (name, px) in iconsetMapping {
        if let data = cache[px] {
            try data.write(to: dir.appendingPathComponent(name))
        }
    }
}

if outPath.hasSuffix(".icns") {
    let tmpBase = FileManager.default.temporaryDirectory.appendingPathComponent("msnip-icon-\(UUID().uuidString)")
    let iconsetDir = tmpBase.appendingPathComponent("AppIcon.iconset")
    defer { try? FileManager.default.removeItem(at: tmpBase) }
    try writeIconset(to: iconsetDir)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    proc.arguments = ["-c", "icns", iconsetDir.path, "-o", outPath]
    try proc.run()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else {
        fputs("❌ iconutil 生成 .icns 失败 (exit \(proc.terminationStatus))\n", stderr)
        exit(proc.terminationStatus)
    }
} else {
    try writeIconset(to: URL(fileURLWithPath: outPath))
}
