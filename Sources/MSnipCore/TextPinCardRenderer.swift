import AppKit
import CoreGraphics
import Foundation

/// 将剪贴板纯文本渲染为 Retina 清晰度桌面便签贴图卡片（自动识别代码/普通段落字号与合理尺寸上限）
public enum TextPinCardRenderer {
    public static func render(text raw: String, scale: CGFloat = 2.0) -> CGImage? {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let allLines = normalized.components(separatedBy: "\n")
        let maxLines = 28
        let truncated = allLines.count > maxLines
        var displayText = allLines.prefix(maxLines).joined(separator: "\n")
        if displayText.count > 2200 {
            displayText = String(displayText.prefix(2200)) + "…"
        }
        if truncated {
            displayText += L("\n… (共 %@ 行)", allLines.count)
        }

        let isCodeLike = looksLikeCode(normalized)
        let font = isCodeLike
            ? NSFont.monospacedSystemFont(ofSize: 13.0, weight: .regular)
            : NSFont.systemFont(ofSize: 14.0, weight: .regular)
        let para = NSMutableParagraphStyle()
        para.lineSpacing = isCodeLike ? 4.0 : 5.0
        para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1.0),
            .paragraphStyle: para
        ]

        let padX: CGFloat = 18
        let padTop: CGFloat = 16
        let footerH: CGFloat = 26
        let minCardW: CGFloat = 240
        let maxCardW: CGFloat = 520
        let maxBodyH: CGFloat = 560

        let naturalSingleLineW = allLines.prefix(maxLines).reduce(CGFloat(0)) { acc, line in
            let w = (line as NSString).size(withAttributes: [.font: font]).width
            return max(acc, w)
        }
        let cardW = min(maxCardW, max(minCardW, ceil(naturalSingleLineW) + padX * 2 + 8))
        let textW = cardW - padX * 2

        let attrStr = NSAttributedString(string: displayText, attributes: attrs)
        let bounds = attrStr.boundingRect(
            with: NSSize(width: textW, height: maxBodyH),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let bodyH = min(maxBodyH, max(26, ceil(bounds.height)))
        let cardH = padTop + bodyH + 14 + footerH

        let s = max(1.0, scale)
        let outW = Int((cardW * s).rounded())
        let outH = Int((cardH * s).rounded())
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

        ctx.setFillColor(NSColor(srgbRed: 0.11, green: 0.12, blue: 0.145, alpha: 0.98).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: cardW, height: cardH))

        // 顶部柔和蓝色细强调条
        ctx.setFillColor(NSColor(srgbRed: 0.25, green: 0.56, blue: 0.98, alpha: 0.90).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: cardW, height: 3))

        // 细微内描边
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.11).cgColor)
        ctx.setLineWidth(1.0)
        ctx.stroke(CGRect(x: 0.5, y: 0.5, width: cardW - 1, height: cardH - 1))

        attrStr.draw(
            with: NSRect(x: padX, y: padTop, width: textW, height: bodyH + 4),
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine]
        )

        // 底部元数据分隔线与统计信息
        let divY = cardH - footerH
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.08).cgColor)
        ctx.fill(CGRect(x: padX, y: divY, width: textW, height: 1))

        let tag = isCodeLike ? L("代码便签") : L("文本便签")
        let meta = L("%@  ·  %@ 行 · %@ 字", tag, allLines.count, normalized.count) as NSString
        let metaAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor(white: 0.58, alpha: 1.0)
        ]
        meta.draw(at: CGPoint(x: padX, y: divY + 6), withAttributes: metaAttrs)
        return ctx.makeImage()
    }

    public static func looksLikeCode(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
            return true
        }
        let codeTokens = ["func ", "def ", "const ", "import ", "class ", "struct ", "=>", "->", "http://", "https://", "Error:", "Exception"]
        if codeTokens.contains(where: { trimmed.contains($0) }) { return true }
        let symbolCount = trimmed.filter { "{}[]();=<>`".contains($0) }.count
        return symbolCount >= 6 && Double(symbolCount) / Double(max(1, trimmed.count)) >= 0.045
    }
}
