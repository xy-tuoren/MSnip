import AppKit
import CoreGraphics
import Foundation

/// 极客设置页连续可拖拽进度滑条（`0%` 显示为「关闭」，支持点击/拖拽实时预览、松手提交、滚轮微调与双击复位默认）
final class GeekProgressSlider: NSView {
    var value: CGFloat = 0.45 {
        didSet {
            let c = min(1.0, max(0.0, value))
            if abs(c - value) > 0.0001 { value = c; return }
            if abs(oldValue - value) > 0.0005 { needsDisplay = true }
        }
    }
    var defaultValue: CGFloat = 0.45
    var zeroLabel: String = "关闭"
    var onChange: ((CGFloat) -> Void)?
    var onCommit: ((CGFloat) -> Void)?

    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    private var dragging = false { didSet { if oldValue != dragging { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(value: CGFloat = 0.45, defaultValue: CGFloat = 0.45, zeroLabel: String = "关闭") {
        self.value = min(1.0, max(0.0, value))
        self.defaultValue = defaultValue
        self.zeroLabel = zeroLabel
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    private var trackRange: (minX: CGFloat, maxX: CGFloat) {
        let labelW: CGFloat = 44
        let left: CGFloat = 7
        let right = max(left + 40, bounds.width - labelW - 10)
        return (left, right)
    }

    private func valueFromPoint(_ pt: NSPoint) -> CGFloat {
        let r = trackRange
        let raw = (pt.x - r.minX) / max(1, r.maxX - r.minX)
        let pct = (min(1.0, max(0.0, raw)) * 100.0).rounded()
        return pct <= 1.0 ? 0.0 : pct / 100.0
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            value = defaultValue
            onChange?(value)
            onCommit?(value)
            return
        }
        dragging = true
        let next = valueFromPoint(convert(event.locationInWindow, from: nil))
        value = next
        onChange?(next)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        let next = valueFromPoint(convert(event.locationInWindow, from: nil))
        if abs(next - value) > 0.001 {
            value = next
            onChange?(next)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        let next = valueFromPoint(convert(event.locationInWindow, from: nil))
        value = next
        onChange?(next)
        onCommit?(next)
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        guard abs(delta) > 0.01 else { return }
        let step: CGFloat = delta > 0 ? 0.02 : -0.02
        let pct = (min(1.0, max(0.0, value + step)) * 100.0).rounded()
        let next = pct <= 1.0 ? 0.0 : pct / 100.0
        if abs(next - value) > 0.001 {
            value = next
            onChange?(next)
            onCommit?(next)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = trackRange
        let trackH: CGFloat = 4.0
        let trackY = round((bounds.height - trackH) * 0.5)
        let trackRect = CGRect(x: r.minX, y: trackY, width: r.maxX - r.minX, height: trackH)
        let trackPath = CGPath(roundedRect: trackRect, cornerWidth: 2.0, cornerHeight: 2.0, transform: nil)

        ctx.saveGState()
        // 1) 背景轨道
        ctx.setFillColor(GeekTheme.segTrackBg.cgColor)
        ctx.addPath(trackPath); ctx.fillPath()
        ctx.setStrokeColor(GeekTheme.border.cgColor)
        ctx.setLineWidth(0.75)
        ctx.addPath(trackPath); ctx.strokePath()

        // 2) 默认刻度微提示线（45%）
        let defX = round(r.minX + (r.maxX - r.minX) * defaultValue)
        ctx.setFillColor(GeekTheme.inkMuted.withAlphaComponent(0.32).cgColor)
        ctx.fill(CGRect(x: defX, y: trackY - 2, width: 1, height: trackH + 4))

        // 3) 蓝色高亮进度填充
        let fillW = max(0, (r.maxX - r.minX) * value)
        if fillW > 0.5 {
            let fillRect = CGRect(x: r.minX, y: trackY, width: fillW, height: trackH)
            let fillPath = CGPath(roundedRect: fillRect, cornerWidth: 2.0, cornerHeight: 2.0, transform: nil)
            ctx.setFillColor(GeekTheme.accent.cgColor)
            ctx.addPath(fillPath); ctx.fillPath()
        }

        // 4) 圆形滑块手柄
        let knobD: CGFloat = (dragging || hovered) ? 15.0 : 13.5
        let knobX = r.minX + fillW - knobD * 0.5
        let knobY = round((bounds.height - knobD) * 0.5)
        let knobRect = CGRect(x: knobX, y: knobY, width: knobD, height: knobD)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.0), blur: 3.0, color: NSColor.black.withAlphaComponent(dragging ? 0.28 : 0.18).cgColor)
        ctx.setFillColor(GeekTheme.segActiveBg.cgColor)
        ctx.fillEllipse(in: knobRect)
        ctx.restoreGState()
        ctx.setStrokeColor((dragging ? GeekTheme.accent : GeekTheme.borderStrong).cgColor)
        ctx.setLineWidth(dragging ? 1.4 : 0.9)
        ctx.strokeEllipse(in: knobRect.insetBy(dx: 0.45, dy: 0.45))

        // 5) 右侧等宽数值读数（0% 显示「关闭」）
        let pct = Int((value * 100.0).rounded())
        let text = pct == 0 ? zeroLabel : "\(pct)%"
        let font: NSFont = pct == 0
            ? .systemFont(ofSize: 12.0, weight: .medium)
            : .monospacedDigitSystemFont(ofSize: 12.0, weight: .semibold)
        let color: NSColor = dragging ? GeekTheme.accent : (pct == 0 ? GeekTheme.inkMuted : GeekTheme.inkPrimary)
        let labelRect = CGRect(x: r.maxX + 6, y: 0, width: bounds.width - r.maxX - 6, height: bounds.height)
        GeekTheme.drawText(text, in: labelRect, font: font, color: color, align: .right)
        ctx.restoreGState()
    }
}
