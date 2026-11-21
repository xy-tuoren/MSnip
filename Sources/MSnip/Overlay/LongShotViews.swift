import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 采集线程轻量节流闸门：保证 60Hz 高帧率拼接不被缩略图重绘阻塞导致 SCStream 丢帧
final class PreviewThrottleGate: @unchecked Sendable {
    private let minInterval: TimeInterval
    private var lastRenderUptime: TimeInterval = 0

    init(minInterval: TimeInterval) { self.minInterval = minInterval }

    func shouldRender(force: Bool) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if force || (now - lastRenderUptime) >= minInterval {
            lastRenderUptime = now
            return true
        }
        return false
    }
}

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
    var countdownNumber: Int? { didSet { needsDisplay = true } }
    var pinPillInsideTop: Bool = false { didSet { needsDisplay = true } }

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
        case .ready:          accent = MSnipUITheme.accent
        case .stitching:      accent = MSnipUITheme.success
        case .recording:      accent = MSnipUITheme.danger
        case .warning:        accent = MSnipUITheme.warning
        case .finishedBottom: accent = MSnipUITheme.accent
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

        // 2) 顶部清爽浅色白底状态胶囊徽标
        let nsText = statusText as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: MSnipUITheme.inkPrimary
        ]
        let tSz = nsText.size(withAttributes: attrs)
        let pillW = min(bounds.width - 8, ceil(tSz.width + 28))
        let pillH: CGFloat = 24
        let pillY = pinPillInsideTop ? round(frameRect.minY + 8) : max(2, frameRect.minY - pillH - 5)
        let pillX = pinPillInsideTop ? round(frameRect.minX + 8) : frameRect.minX
        let pillRect = CGRect(x: pillX, y: pillY, width: pillW, height: pillH)

        ctx.saveGState()
        let pillPath = CGPath(roundedRect: pillRect, cornerWidth: 6.5, cornerHeight: 6.5, transform: nil)
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: NSColor.black.withAlphaComponent(0.16).cgColor)
        ctx.setFillColor(MSnipUITheme.cardBg.cgColor)
        ctx.addPath(pillPath)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(accent.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(pillPath)
        ctx.strokePath()

        MSnipUITheme.drawStatusDot(ctx: ctx, center: CGPoint(x: pillRect.minX + 11.5, y: pillRect.midY), color: accent, halo: true)

        nsText.draw(
            at: CGPoint(x: round(pillRect.minX + 21), y: round(pillRect.minY + (pillH - tSz.height) * 0.5)),
            withAttributes: attrs
        )
        ctx.restoreGState()

        // 3) 录屏开始前 3-2-1 居中醒目圆形倒计时徽章
        if let n = countdownNumber {
            let side: CGFloat = min(76, max(44, min(captureRect.width, captureRect.height) * 0.45))
            let badgeRect = CGRect(
                x: round(captureRect.midX - side * 0.5),
                y: round(captureRect.midY - side * 0.5),
                width: side,
                height: side
            )
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 4), blur: 14, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            ctx.setFillColor(NSColor(srgbRed: 0.09, green: 0.11, blue: 0.15, alpha: 0.88).cgColor)
            ctx.fillEllipse(in: badgeRect)
            ctx.restoreGState()

            ctx.saveGState()
            ctx.setStrokeColor(MSnipUITheme.danger.cgColor)
            ctx.setLineWidth(2.5)
            ctx.strokeEllipse(in: badgeRect.insetBy(dx: 1.5, dy: 1.5))
            let numStr = "\(n)" as NSString
            let numAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: round(side * 0.48), weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let nSz = numStr.size(withAttributes: numAttrs)
            numStr.draw(
                at: CGPoint(x: round(badgeRect.midX - nSz.width * 0.5), y: round(badgeRect.midY - nSz.height * 0.5)),
                withAttributes: numAttrs
            )
            ctx.restoreGState()
        }
    }
}

/// 右侧实时拼接长图清爽白底缩略预览卡片
final class LongShotPreviewView: NSView {
    var previewImage: CGImage? { didSet { needsDisplay = true } }
    var pixelWidth: Int = 0 { didSet { needsDisplay = true } }
    var pixelHeight: Int = 0 { didSet { needsDisplay = true } }
    var baseHeightPx: Int = 1

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        MSnipUITheme.drawPorcelainBar(ctx: ctx, bounds: bounds, radius: 10)
        ctx.saveGState()

        ("长图预览" as NSString).draw(at: CGPoint(x: 10, y: 7), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: MSnipUITheme.inkPrimary
        ])
        if pixelHeight > 0, baseHeightPx > 0 {
            let ratio = Double(pixelHeight) / Double(max(1, baseHeightPx))
            let badge = String(format: "%.1f×", ratio) as NSString
            let bAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold),
                .foregroundColor: MSnipUITheme.success
            ]
            let bSz = badge.size(withAttributes: bAttrs)
            badge.draw(at: CGPoint(x: round(bounds.width - bSz.width - 10), y: 7.5), withAttributes: bAttrs)
        }

        let viewport = CGRect(x: 9, y: 27, width: bounds.width - 18, height: bounds.height - 52)
        ctx.setFillColor(MSnipUITheme.subtleFill.cgColor)
        ctx.addPath(CGPath(roundedRect: viewport, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()

        if let img = previewImage, img.width > 0, img.height > 0 {
            let aspect = CGFloat(img.height) / CGFloat(img.width)
            var drawW = viewport.width - 6
            var drawH = drawW * aspect
            if drawH > viewport.height - 6 {
                drawH = viewport.height - 6
                drawW = drawH / max(0.05, aspect)
            }
            let dst = CGRect(
                x: round(viewport.midX - drawW * 0.5),
                y: round(viewport.minY + 3),
                width: max(2, round(drawW)),
                height: max(2, round(drawH))
            )
            let nsImg = NSImage(cgImage: img, size: dst.size)
            nsImg.draw(in: dst, from: .zero, operation: .copy, fraction: 1.0, respectFlipped: true, hints: nil)

            ctx.setStrokeColor(MSnipUITheme.borderStrong.cgColor)
            ctx.setLineWidth(1.0)
            ctx.stroke(dst)
        }

        let dimStr = (pixelWidth > 0 ? "\(pixelWidth) × \(pixelHeight)" : "等待画面…") as NSString
        let dAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: MSnipUITheme.inkSecondary
        ]
        let dSz = dimStr.size(withAttributes: dAttrs)
        dimStr.draw(at: CGPoint(x: round((bounds.width - dSz.width) * 0.5), y: bounds.height - 19), withAttributes: dAttrs)
        ctx.restoreGState()
    }
}
