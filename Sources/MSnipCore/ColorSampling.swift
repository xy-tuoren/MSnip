import AppKit
import CoreGraphics
import Foundation

/// PixPin 风格的屏幕取色复制格式（支持 Shift 循环切换并持久化）
public enum ColorCopyFormat: String, CaseIterable, Codable, Sendable {
    case hex = "hex"
    case rgb = "rgb"
    case hsl = "hsl"
    case hsv = "hsv"

    public var label: String {
        switch self {
        case .hex: return "HEX"
        case .rgb: return "RGB"
        case .hsl: return "HSL"
        case .hsv: return "HSV"
        }
    }

    public var next: ColorCopyFormat {
        let all = Self.allCases
        guard let idx = all.firstIndex(of: self) else { return .hex }
        return all[(idx + 1) % all.count]
    }

    public func format(r: Int, g: Int, b: Int) -> String {
        let cr = min(max(0, r), 255)
        let cg = min(max(0, g), 255)
        let cb = min(max(0, b), 255)
        switch self {
        case .hex:
            return String(format: "#%02X%02X%02X", cr, cg, cb)
        case .rgb:
            return "rgb(\(cr), \(cg), \(cb))"
        case .hsl:
            let (h, s, l) = Self.rgbToHSL(r: cr, g: cg, b: cb)
            return "hsl(\(h), \(s)%, \(l)%)"
        case .hsv:
            let (h, s, v) = Self.rgbToHSV(r: cr, g: cg, b: cb)
            return "hsv(\(h), \(s)%, \(v)%)"
        }
    }

    public static func rgbToHSL(r: Int, g: Int, b: Int) -> (h: Int, s: Int, l: Int) {
        let rf = Double(r) / 255.0, gf = Double(g) / 255.0, bf = Double(b) / 255.0
        let maxC = max(rf, max(gf, bf)), minC = min(rf, min(gf, bf))
        let delta = maxC - minC
        let l = (maxC + minC) * 0.5
        guard delta > 1e-6 else {
            return (0, 0, Int((l * 100.0).rounded()))
        }
        let s = delta / (1.0 - abs(2.0 * l - 1.0))
        let hDeg = computeHueDegrees(rf: rf, gf: gf, bf: bf, maxC: maxC, delta: delta)
        return (Int(hDeg.rounded()) % 360, Int((s * 100.0).rounded()), Int((l * 100.0).rounded()))
    }

    public static func rgbToHSV(r: Int, g: Int, b: Int) -> (h: Int, s: Int, v: Int) {
        let rf = Double(r) / 255.0, gf = Double(g) / 255.0, bf = Double(b) / 255.0
        let maxC = max(rf, max(gf, bf)), minC = min(rf, min(gf, bf))
        let delta = maxC - minC
        guard delta > 1e-6, maxC > 1e-6 else {
            return (0, 0, Int((maxC * 100.0).rounded()))
        }
        let s = delta / maxC
        let hDeg = computeHueDegrees(rf: rf, gf: gf, bf: bf, maxC: maxC, delta: delta)
        return (Int(hDeg.rounded()) % 360, Int((s * 100.0).rounded()), Int((maxC * 100.0).rounded()))
    }

    private static func computeHueDegrees(rf: Double, gf: Double, bf: Double, maxC: Double, delta: Double) -> Double {
        var raw: Double
        if maxC == rf {
            raw = ((gf - bf) / delta).truncatingRemainder(dividingBy: 6.0)
        } else if maxC == gf {
            raw = ((bf - rf) / delta) + 2.0
        } else {
            raw = ((rf - gf) / delta) + 4.0
        }
        raw *= 60.0
        if raw < 0 { raw += 360.0 }
        return raw
    }
}

public extension RGBAColor {
    func formatted(as format: ColorCopyFormat) -> String {
        format.format(r: Int(r), g: Int(g), b: Int(b))
    }

    var relativeLuminance: Double {
        (0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)) / 255.0
    }

    /// 解析剪贴板中的 `#RRGGBB` / `#RGB` / `rgb(r, g, b)` 色值文本（供 `⌘2` 一键生成色彩贴图卡）
    static func parseColorString(_ raw: String) -> RGBAColor? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4, trimmed.count <= 32 else { return nil }

        if trimmed.hasPrefix("#") {
            let hex = String(trimmed.dropFirst())
            if hex.count == 6, let val = UInt32(hex, radix: 16) {
                return RGBAColor(UInt8((val >> 16) & 0xFF), UInt8((val >> 8) & 0xFF), UInt8(val & 0xFF))
            }
            if hex.count == 3, let val = UInt32(hex, radix: 16) {
                let r = UInt8(((val >> 8) & 0xF) * 17)
                let g = UInt8(((val >> 4) & 0xF) * 17)
                let b = UInt8((val & 0xF) * 17)
                return RGBAColor(r, g, b)
            }
            return nil
        }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("rgb("), lower.hasSuffix(")") {
            let body = lower.dropFirst(4).dropLast()
            let parts = body.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 3, parts.allSatisfy({ (0...255).contains($0) }) {
                return RGBAColor(UInt8(parts[0]), UInt8(parts[1]), UInt8(parts[2]))
            }
        }
        return nil
    }

    /// 渲染 PixPin 风格的高清色彩贴图卡片（左侧色块 + 右侧 HEX / RGB / HSL 对照）
    static func renderColorPinCard(_ color: RGBAColor, scale: CGFloat = 2.0) -> CGImage? {
        let wPt: CGFloat = 224
        let hPt: CGFloat = 92
        let s = max(1.0, scale)
        let outW = Int((wPt * s).rounded())
        let outH = Int((hPt * s).rounded())
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.translateBy(x: 0, y: CGFloat(outH))
        ctx.scaleBy(x: s, y: -s)

        let prev = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.current = prev }

        let bg = CGPath(roundedRect: CGRect(x: 0, y: 0, width: wPt, height: hPt), cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.addPath(bg)
        ctx.clip()
        ctx.setFillColor(NSColor(srgbRed: 0.12, green: 0.125, blue: 0.145, alpha: 0.96).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: wPt, height: hPt))

        let swatchRect = CGRect(x: 12, y: 12, width: 68, height: 68)
        let swatchPath = CGPath(roundedRect: swatchRect, cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.addPath(swatchPath)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
        ctx.addPath(swatchPath)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
        ctx.setLineWidth(1.0)
        ctx.strokePath()

        let hexStr = color.formatted(as: .hex) as NSString
        let rgbStr = "RGB: \(color.r), \(color.g), \(color.b)" as NSString
        let (h, sat, lig) = ColorCopyFormat.rgbToHSL(r: Int(color.r), g: Int(color.g), b: Int(color.b))
        let hslStr = "HSL: \(h)°, \(sat)%, \(lig)%" as NSString

        hexStr.draw(at: CGPoint(x: 92, y: 14), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 15, weight: .bold),
            .foregroundColor: NSColor.white
        ])
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor(white: 0.78, alpha: 1.0)
        ]
        rgbStr.draw(at: CGPoint(x: 92, y: 41), withAttributes: subAttrs)
        hslStr.draw(at: CGPoint(x: 92, y: 61), withAttributes: subAttrs)

        return ctx.makeImage()
    }
}
