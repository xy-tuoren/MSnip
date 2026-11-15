import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 长截图镂空穿透取景框视图（完全鼠标穿透 `ignoresMouseEvents = true`，不遮挡下方窗口滚轮）
final class LongShotBorderView: NSView {
    enum StatusStyle {
        case ready
        case stitching
        case recording
        case warning
        case finishedBottom
    }

    static let sidePad: CGFloat = 6
    static let topBadgeSpace: CGFloat = 32

    var statusText: String = "长截图 · 请在框内向下滚动滚轮" { didSet { needsDisplay = true } }
    var statusStyle: StatusStyle = .ready { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let captureRect = CGRect(
            x: Self.sidePad,
            y: Self.topBadgeSpace,
            width: bounds.width - Self.sidePad * 2,
            height: bounds.height - Self.topBadgeSpace - Self.sidePad
        )
        guard captureRect.width > 8, captureRect.height > 8 else { return }

        let accent: NSColor
        switch statusStyle {
        case .ready:          accent = .systemCyan
        case .stitching:      accent = .systemGreen
        case .recording:      accent = .systemRed
        case .warning:        accent = .systemOrange
        case .finishedBottom: accent = .controlAccentColor
        }

        // 1) 外侧镂空高光边框（严丝合缝贴在采集区外沿，不污染内部像素）
        let frameRect = captureRect.insetBy(dx: -1.5, dy: -1.5)
        ctx.saveGState()
        ctx.setStrokeColor(accent.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(2.0)
        ctx.setLineDash(phase: 0, lengths: statusStyle == .warning ? [6, 4] : [])
        ctx.stroke(frameRect)

        let arm: CGFloat = min(14, min(frameRect.width, frameRect.height) * 0.2)
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setLineWidth(3.2)
        ctx.setLineCap(.round)
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: frameRect.minX, y: frameRect.minY), 1, 1),
            (CGPoint(x: frameRect.maxX, y: frameRect.minY), -1, 1),
            (CGPoint(x: frameRect.minX, y: frameRect.maxY), 1, -1),
            (CGPoint(x: frameRect.maxX, y: frameRect.maxY), -1, -1)
        ]
        for (pt, sx, sy) in corners {
            ctx.move(to: CGPoint(x: pt.x + sx * arm, y: pt.y))
            ctx.addLine(to: pt)
            ctx.addLine(to: CGPoint(x: pt.x, y: pt.y + sy * arm))
        }
        ctx.strokePath()
        ctx.restoreGState()

        // 2) 顶部状态胶囊徽标
        let nsText = statusText as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let tSz = nsText.size(withAttributes: attrs)
        let pillW = min(bounds.width - 8, ceil(tSz.width + 26))
        let pillH: CGFloat = 23
        let pillRect = CGRect(x: frameRect.minX, y: max(2, frameRect.minY - pillH - 5), width: pillW, height: pillH)

        ctx.saveGState()
        let pillPath = CGPath(roundedRect: pillRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.setFillColor(NSColor(srgbRed: 0.08, green: 0.09, blue: 0.11, alpha: 0.88).cgColor)
        ctx.addPath(pillPath)
        ctx.fillPath()
        ctx.setStrokeColor(accent.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(pillPath)
        ctx.strokePath()

        let dotRect = CGRect(x: pillRect.minX + 8, y: pillRect.midY - 3.5, width: 7, height: 7)
        ctx.setFillColor(accent.cgColor)
        ctx.fillEllipse(in: dotRect)

        nsText.draw(
            at: CGPoint(x: dotRect.maxX + 6, y: pillRect.minY + (pillH - tSz.height) * 0.5),
            withAttributes: attrs
        )
        ctx.restoreGState()
    }
}

/// 右侧实时拼接长图缩略预览卡片
final class LongShotPreviewView: NSView {
    var previewImage: CGImage? { didSet { needsDisplay = true } }
    var pixelWidth: Int = 0 { didSet { needsDisplay = true } }
    var pixelHeight: Int = 0 { didSet { needsDisplay = true } }
    var baseHeightPx: Int = 1

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let bgRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(NSColor(srgbRed: 0.09, green: 0.095, blue: 0.115, alpha: 0.92).cgColor)
        ctx.addPath(bgPath)
        ctx.fillPath()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(bgPath)
        ctx.strokePath()

        ("长图预览" as NSString).draw(at: CGPoint(x: 10, y: 7), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor(white: 0.88, alpha: 1.0)
        ])
        if pixelHeight > 0, baseHeightPx > 0 {
            let ratio = Double(pixelHeight) / Double(max(1, baseHeightPx))
            let badge = String(format: "%.1f×", ratio) as NSString
            let bAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
                .foregroundColor: NSColor.systemGreen
            ]
            let bSz = badge.size(withAttributes: bAttrs)
            badge.draw(at: CGPoint(x: bounds.width - bSz.width - 10, y: 7.5), withAttributes: bAttrs)
        }

        let viewport = CGRect(x: 9, y: 27, width: bounds.width - 18, height: bounds.height - 52)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.32).cgColor)
        ctx.addPath(CGPath(roundedRect: viewport, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.fillPath()

        if let img = previewImage, img.width > 0, img.height > 0 {
            let aspect = CGFloat(img.height) / CGFloat(img.width)
            var drawW = viewport.width - 4
            var drawH = drawW * aspect
            if drawH > viewport.height - 4 {
                drawH = viewport.height - 4
                drawW = drawH / max(0.05, aspect)
            }
            let dst = CGRect(
                x: round(viewport.midX - drawW * 0.5),
                y: round(viewport.minY + 2),
                width: max(2, round(drawW)),
                height: max(2, round(drawH))
            )
            let nsImg = NSImage(cgImage: img, size: dst.size)
            nsImg.draw(in: dst, from: .zero, operation: .copy, fraction: 1.0, respectFlipped: true, hints: nil)

            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.26).cgColor)
            ctx.setLineWidth(0.8)
            ctx.stroke(dst)
        }

        let dimStr = (pixelWidth > 0 ? "\(pixelWidth) × \(pixelHeight)" : "等待画面…") as NSString
        let dAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor(white: 0.78, alpha: 1.0)
        ]
        let dSz = dimStr.size(withAttributes: dAttrs)
        dimStr.draw(at: CGPoint(x: (bounds.width - dSz.width) * 0.5, y: bounds.height - 19), withAttributes: dAttrs)
        ctx.restoreGState()
    }
}
