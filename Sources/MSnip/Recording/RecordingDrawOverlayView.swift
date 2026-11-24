import AppKit
import CoreGraphics
import Foundation
import QuartzCore

/// 录屏实时演示画笔浮层视图（默认穿透，开启「画笔」后在录制选区内绘制高亮激光/常驻红笔，右键一键清屏）
final class RecordingDrawOverlayView: NSView {
    struct LocalStroke {
        var points: [CGPoint]
        let isLaser: Bool
        var updatedAt: TimeInterval
    }

    var onBeginStroke: ((CGPoint, Bool) -> Void)?
    var onAppendStrokePoint: ((CGPoint) -> Void)?
    var onClearStrokes: (() -> Void)?

    private var strokes: [LocalStroke] = []
    private var fadeTimer: Timer?
    private let laserDuration: TimeInterval = 2.6

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    deinit { fadeTimer?.invalidate() }

    func clearAll(notify: Bool = true) {
        strokes.removeAll()
        stopFadeTimerIfIdle()
        needsDisplay = true
        if notify { onClearStrokes?() }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let isLaser = !event.modifierFlags.contains(.shift)
        let now = CACurrentMediaTime()
        if strokes.count >= 40 { strokes.removeFirst() }
        strokes.append(LocalStroke(points: [p], isLaser: isLaser, updatedAt: now))
        if isLaser { ensureFadeTimer() }
        onBeginStroke?(normalized(p), isLaser)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard !strokes.isEmpty else { return }
        if let last = strokes[strokes.count - 1].points.last, hypot(p.x - last.x, p.y - last.y) < 2.0 { return }
        strokes[strokes.count - 1].points.append(p)
        strokes[strokes.count - 1].updatedAt = CACurrentMediaTime()
        onAppendStrokePoint?(normalized(p))
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        clearAll(notify: true)
    }

    private func normalized(_ p: CGPoint) -> CGPoint {
        let w = max(1, bounds.width), h = max(1, bounds.height)
        return CGPoint(x: min(1, max(0, p.x / w)), y: min(1, max(0, p.y / h)))
    }

    private func ensureFadeTimer() {
        guard fadeTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickFade() }
        }
        RunLoop.main.add(t, forMode: .common)
        fadeTimer = t
    }

    private func tickFade() {
        let now = CACurrentMediaTime()
        strokes.removeAll { $0.isLaser && (now - $0.updatedAt > laserDuration) }
        needsDisplay = true
        stopFadeTimerIfIdle()
    }

    private func stopFadeTimerIfIdle() {
        if !strokes.contains(where: \.isLaser) {
            fadeTimer?.invalidate()
            fadeTimer = nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !strokes.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let now = CACurrentMediaTime()
        for stroke in strokes where stroke.points.count >= 2 {
            let alpha: CGFloat
            if stroke.isLaser {
                let age = max(0, now - stroke.updatedAt)
                let fadeStart = laserDuration - 0.75
                alpha = age > fadeStart ? CGFloat(max(0, (laserDuration - age) / 0.75)) : 1.0
            } else {
                alpha = 1.0
            }
            guard alpha > 0.02 else { continue }
            ctx.saveGState()
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            let path = CGMutablePath()
            for (i, pt) in stroke.points.enumerated() {
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.75 * alpha).cgColor)
            ctx.setLineWidth(5.5); ctx.addPath(path); ctx.strokePath()
            ctx.setStrokeColor(NSColor(srgbRed: 0.96, green: 0.23, blue: 0.35, alpha: alpha).cgColor)
            ctx.setLineWidth(3.0); ctx.addPath(path); ctx.strokePath()
            ctx.restoreGState()
        }
    }
}
