#!/usr/bin/env swift
import CoreGraphics
import Foundation
import zlib

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

/// 纯矢量绘制 MSnip 瑞士纸感裁切图标（严格复刻原版几何比例与配色，零栅格噪点，全分辨率锐利）
func renderVectorIconRGBA(px: Int) -> [UInt8] {
    let s = CGFloat(px)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    var pixels = [UInt8](repeating: 0, count: px * px * 4)
    guard let ctx = CGContext(
        data: &pixels, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return pixels }
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

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
            color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.34)
        )
        ctx.setFillColor(CGColor(srgbRed: 242.0 / 255.0, green: 243.0 / 255.0, blue: 246.0 / 255.0, alpha: 1.0))
        ctx.addPath(squircle)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 2) 瑞士纸感纯色底板 + 极细内描边
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    ctx.setFillColor(CGColor(srgbRed: 242.0 / 255.0, green: 243.0 / 255.0, blue: 246.0 / 255.0, alpha: 1.0))
    ctx.fill(card)

    // 坐标系切换至卡片内部 1024×1024 左上角原点标尺，精确绘制裁切双 L 框与钴蓝核心方块
    ctx.saveGState()
    ctx.translateBy(x: card.minX, y: card.maxY)
    ctx.scaleBy(x: card.width / 1024.0, y: -card.height / 1024.0)

    let ink = CGColor(srgbRed: 23.0 / 255.0, green: 25.0 / 255.0, blue: 31.0 / 255.0, alpha: 1.0)
    let cobalt = CGColor(srgbRed: 37.0 / 255.0, green: 105.0 / 255.0, blue: 230.0 / 255.0, alpha: 1.0)
    let sw: CGFloat = 72.0
    let half = sw * 0.5

    ctx.setStrokeColor(ink)
    ctx.setLineWidth(sw)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // 左竖 + 底横连续裁切主 L 臂（外角与右上 L 臂对称圆润过渡）
    let mainL = CGMutablePath()
    mainL.move(to: CGPoint(x: 322, y: 241))
    mainL.addLine(to: CGPoint(x: 322, y: 679))
    mainL.addArc(tangent1End: CGPoint(x: 322, y: 701), tangent2End: CGPoint(x: 344, y: 701), radius: 22)
    mainL.addLine(to: CGPoint(x: 782, y: 701))
    ctx.addPath(mainL)
    ctx.strokePath()

    // 左上水平短伸臂（圆头）
    let leftStub = CGMutablePath()
    leftStub.move(to: CGPoint(x: 241, y: 322))
    leftStub.addLine(to: CGPoint(x: 322, y: 322))
    ctx.addPath(leftStub)
    ctx.strokePath()

    // 右下垂直短伸臂（圆头）
    let bottomStub = CGMutablePath()
    bottomStub.move(to: CGPoint(x: 701, y: 701))
    bottomStub.addLine(to: CGPoint(x: 701, y: 782))
    ctx.addPath(bottomStub)
    ctx.strokePath()

    // 右上独立 L 臂（两端平切留白缝隙、外角圆润过渡）
    ctx.setLineCap(.butt)
    let upperL = CGMutablePath()
    upperL.move(to: CGPoint(x: 393, y: 322))
    upperL.addLine(to: CGPoint(x: 701 - half, y: 322))
    upperL.addArc(tangent1End: CGPoint(x: 701, y: 322), tangent2End: CGPoint(x: 701, y: 322 + half), radius: 22)
    upperL.addLine(to: CGPoint(x: 701, y: 631))
    ctx.addPath(upperL)
    ctx.strokePath()

    // 钴蓝核心焦点方块
    ctx.setFillColor(cobalt)
    ctx.fill(CGRect(x: 538, y: 392, width: 91, height: 91))
    ctx.restoreGState()

    // 3) 极细内描边，确保浅色底座在亮色访达与暗色 Dock 下均边缘利落
    let inset = max(0.5, s * 0.002)
    ctx.addPath(makeAppleSquircle(in: card.insetBy(dx: inset, dy: inset), radius: corner - inset))
    ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.085))
    ctx.setLineWidth(max(1.0, s * 0.004))
    ctx.strokePath()
    ctx.restoreGState()

    // CoreGraphics 输出预乘 Alpha，PNG 规范要求非预乘（Straight Alpha）
    var i = 0
    while i < pixels.count {
        let a = pixels[i + 3]
        if a > 0 && a < 255 {
            let af = Int(a)
            pixels[i]     = UInt8(min(255, (Int(pixels[i]) * 255 + af / 2) / af))
            pixels[i + 1] = UInt8(min(255, (Int(pixels[i + 1]) * 255 + af / 2) / af))
            pixels[i + 2] = UInt8(min(255, (Int(pixels[i + 2]) * 255 + af / 2) / af))
        }
        i += 4
    }
    return pixels
}

@inline(__always)
func paeth(_ a: Int, _ b: Int, _ c: Int) -> Int {
    let p = a + b - c
    let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
    if pa <= pb && pa <= pc { return a }
    return pb <= pc ? b : c
}

/// 零依赖高压缩 PNG 编码器（逐行自适应 5 种 PNG 滤镜 + zlib Level 9，零冗余 ICC/元数据块）
func encodeOptimalPNG(rgba: [UInt8], width: Int, height: Int) -> Data {
    let bpp = 4
    let stride = width * bpp
    var filtered = [UInt8]()
    filtered.reserveCapacity(height * (stride + 1))

    var candidates = Array(repeating: [UInt8](repeating: 0, count: stride), count: 5)
    for y in 0..<height {
        let rowOff = y * stride
        let prevOff = (y - 1) * stride
        var bestType = 0
        var bestScore = Int.max
        for f in 0..<5 {
            var score = 0
            for x in 0..<stride {
                let raw = Int(rgba[rowOff + x])
                let left = x >= bpp ? Int(rgba[rowOff + x - bpp]) : 0
                let up = y > 0 ? Int(rgba[prevOff + x]) : 0
                let upLeft = (y > 0 && x >= bpp) ? Int(rgba[prevOff + x - bpp]) : 0
                let pred: Int
                switch f {
                case 1:  pred = left
                case 2:  pred = up
                case 3:  pred = (left + up) >> 1
                case 4:  pred = paeth(left, up, upLeft)
                default: pred = 0
                }
                let diff = (raw - pred) & 0xFF
                candidates[f][x] = UInt8(diff)
                score += diff < 128 ? diff : (256 - diff)
            }
            if score < bestScore { bestScore = score; bestType = f }
        }
        filtered.append(UInt8(bestType))
        filtered.append(contentsOf: candidates[bestType])
    }

    var destLen = compressBound(uLong(filtered.count))
    var compressed = [UInt8](repeating: 0, count: Int(destLen))
    let rc = compressed.withUnsafeMutableBufferPointer { dst in
        filtered.withUnsafeBufferPointer { src in
            compress2(dst.baseAddress, &destLen, src.baseAddress, uLong(src.count), Z_BEST_COMPRESSION)
        }
    }
    precondition(rc == Z_OK, "zlib compress2 failed (\(rc))")
    compressed.removeSubrange(Int(destLen)..<compressed.count)

    func appendBE32(_ val: UInt32, to d: inout Data) {
        var be = val.bigEndian
        withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
    }
    func appendChunk(_ type: String, payload: Data, to d: inout Data) {
        let typeBytes = Data(type.utf8)
        appendBE32(UInt32(payload.count), to: &d)
        d.append(typeBytes)
        d.append(payload)
        var crc = uLong(crc32(0, nil, 0))
        crc = typeBytes.withUnsafeBytes { crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt(typeBytes.count)) }
        if !payload.isEmpty {
            crc = payload.withUnsafeBytes { crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt(payload.count)) }
        }
        appendBE32(UInt32(crc & 0xFFFF_FFFF), to: &d)
    }

    var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    var ihdr = Data()
    appendBE32(UInt32(width), to: &ihdr)
    appendBE32(UInt32(height), to: &ihdr)
    ihdr.append(contentsOf: [8, 6, 0, 0, 0]) // 8-bit RGBA
    appendChunk("IHDR", payload: ihdr, to: &png)
    appendChunk("sRGB", payload: Data([0]), to: &png) // Perceptual sRGB，避免 macOS 广色域屏幕按未标记色彩空间解码偏移
    appendChunk("IDAT", payload: Data(compressed), to: &png)
    appendChunk("IEND", payload: Data(), to: &png)
    return png
}

var pngCache: [Int: Data] = [:]
for px in [16, 32, 64, 128, 256, 512, 1024] {
    pngCache[px] = encodeOptimalPNG(rgba: renderVectorIconRGBA(px: px), width: px, height: px)
}

if outPath.hasSuffix(".icns") {
    // 严格去重写入 macOS 12+ 全尺寸 PNG 图标块（不重复写入字节相同的 ic13/ic14 冗余副本）
    let icnsChunks: [(String, Int)] = [
        ("icp4", 16), ("icp5", 32), ("ic11", 32), ("ic12", 64),
        ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024)
    ]
    var body = Data()
    for (tag, px) in icnsChunks {
        guard let png = pngCache[px] else { continue }
        body.append(Data(tag.utf8))
        var len = UInt32(png.count + 8).bigEndian
        withUnsafeBytes(of: &len) { body.append(contentsOf: $0) }
        body.append(png)
    }
    var icns = Data("icns".utf8)
    var totalLen = UInt32(body.count + 8).bigEndian
    withUnsafeBytes(of: &totalLen) { icns.append(contentsOf: $0) }
    icns.append(body)
    try icns.write(to: URL(fileURLWithPath: outPath), options: .atomic)
} else {
    let dir = URL(fileURLWithPath: outPath)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let iconsetMapping: [(String, Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
    ]
    for (name, px) in iconsetMapping {
        if let png = pngCache[px] { try png.write(to: dir.appendingPathComponent(name)) }
    }
}
