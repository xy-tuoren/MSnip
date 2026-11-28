import AppKit
import CoreGraphics
import Foundation
import MSnipCore
import QuartzCore

/// 延时截图悬浮倒计时控制器（支持 1–60s 自定义倒计时捕获菜单与悬停态，Esc 随时取消，点击圆环立即抓屏）
@MainActor
final class DelayedCaptureController {
    private var panel: NSPanel?
    private var ringView: DelayedCountdownRingView?
    private var timer: Timer?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var totalSeconds: TimeInterval = 3.0
    private var startedAt: TimeInterval = 0
    private var onFire: (@MainActor () -> Void)?

    var isRunning: Bool { panel != nil }

    func start(seconds: Int, onFire: @escaping @MainActor () -> Void) {
        cancel()
        let secs = DelayedCaptureSettings.clampedSeconds(seconds)
        self.totalSeconds = TimeInterval(secs)
        self.startedAt = CACurrentMediaTime()
        self.onFire = onFire

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let sz = DelayedCountdownRingView.cardSize
        let origin = NSPoint(x: round(vf.midX - sz.width * 0.5), y: round(vf.midY - sz.height * 0.5))

        let view = DelayedCountdownRingView(frame: NSRect(origin: .zero, size: sz))
        view.remainingSeconds = secs
        view.progress = 1.0
        view.onTriggerNow = { [weak self] in self?.fireNow() }
        view.onCancel = { [weak self] in self?.cancel(showToast: true) }

        let p = NSPanel(
            contentRect: NSRect(origin: origin, size: sz),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.animationBehavior = .none
        p.isFloatingPanel = true
        p.level = NSWindow.Level(rawValue: max(NSWindow.Level.screenSaver.rawValue, Int(CGShieldingWindowLevel())))
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = view
        p.orderFrontRegardless()

        self.panel = p
        self.ringView = view
        installKeyMonitors()

        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t
    }

    func cancel(showToast: Bool = false) {
        let wasRunning = (panel != nil || timer != nil)
        teardown()
        if showToast && wasRunning {
            ToastHUD.show(message: L("已取消延时截图"))
        }
    }

    private func tick() {
        let elapsed = max(0, CACurrentMediaTime() - startedAt)
        let left = max(0, totalSeconds - elapsed)
        if left <= 0.01 {
            fireNow()
            return
        }
        ringView?.remainingSeconds = max(1, Int(ceil(left)))
        ringView?.progress = CGFloat(left / max(0.1, totalSeconds))
    }

    private func fireNow() {
        let callback = onFire
        teardown()
        // 留出 50ms 确保倒计时悬浮窗从合成器彻底消失后再冻结抓屏，画面绝不残影
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            callback?()
        }
    }

    private func teardown() {
        timer?.invalidate(); timer = nil
        if let lm = localKeyMonitor { NSEvent.removeMonitor(lm); localKeyMonitor = nil }
        if let gm = globalKeyMonitor { NSEvent.removeMonitor(gm); globalKeyMonitor = nil }
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        ringView = nil
        onFire = nil
    }

    private func installKeyMonitors() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            if ev.keyCode == 53 { self?.cancel(showToast: true); return nil }
            return ev
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            if ev.keyCode == 53 {
                Task { @MainActor [weak self] in self?.cancel(showToast: true) }
            }
        }
    }
}

private final class DelayedCountdownRingView: NSView {
    static let cardSize = NSSize(width: 152, height: 156)
    var remainingSeconds: Int = 3 { didSet { if oldValue != remainingSeconds { needsDisplay = true } } }
    var progress: CGFloat = 1.0 { didSet { needsDisplay = true } }
    var onTriggerNow: (() -> Void)?
    var onCancel: (() -> Void)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) { onTriggerNow?() }
    override func rightMouseDown(with event: NSEvent) { onCancel?() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let card = bounds.insetBy(dx: 2, dy: 2)
        let bgPath = CGPath(roundedRect: card, cornerWidth: 22, cornerHeight: 22, transform: nil)
        ctx.setFillColor(NSColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 0.86).cgColor)
        ctx.addPath(bgPath); ctx.fillPath()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        ctx.setLineWidth(1.0); ctx.addPath(bgPath); ctx.strokePath()

        let center = CGPoint(x: bounds.midX, y: 66)
        let radius: CGFloat = 38
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        ctx.setLineWidth(4.5)
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()

        let startA = -CGFloat.pi / 2.0
        let endA = startA + CGFloat.pi * 2.0 * max(0, min(1, progress))
        ctx.setStrokeColor(MSnipUITheme.accent.cgColor)
        ctx.setLineWidth(4.5)
        ctx.setLineCap(.round)
        ctx.addArc(center: center, radius: radius, startAngle: startA, endAngle: endA, clockwise: false)
        ctx.strokePath()

        let numStr = "\(remainingSeconds)" as NSString
        let numAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 38, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let nSz = numStr.size(withAttributes: numAttrs)
        numStr.draw(at: CGPoint(x: round(center.x - nSz.width * 0.5), y: round(center.y - nSz.height * 0.5)), withAttributes: numAttrs)

        let tip = L("点击立即截图 · Esc 取消") as NSString
        let tipAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.72)
        ]
        let tSz = tip.size(withAttributes: tipAttrs)
        tip.draw(at: CGPoint(x: round(bounds.midX - tSz.width * 0.5), y: round(bounds.height - 26)), withAttributes: tipAttrs)
    }
}
