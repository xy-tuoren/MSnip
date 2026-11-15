import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// 长截图平滑自动滚轮控制器：
/// 以 30Hz 向选区几何中心投递像素级向下滚轮事件，无需鼠标一直停留在选框内；用户手动反向滚轮时自动中断。
@MainActor
final class AutoScroller {
    var onStateChanged: ((Bool) -> Void)?

    private var timer: Timer?
    private var wheelMonitor: Any?
    private(set) var isRunning = false

    func toggle(targetQuartzPoint: CGPoint, onRequireAccessibility: () -> Void) {
        if isRunning {
            stop()
        } else {
            start(targetQuartzPoint: targetQuartzPoint, onRequireAccessibility: onRequireAccessibility)
        }
    }

    func start(targetQuartzPoint: CGPoint, onRequireAccessibility: () -> Void) {
        guard !isRunning else { return }
        guard AXIsProcessTrusted() else {
            onRequireAccessibility()
            return
        }

        isRunning = true
        onStateChanged?(true)

        // 若用户自己向上拨动滚轮，立即礼貌停止自动滚动，不与手指抢控制权
        wheelMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] ev in
            if ev.scrollingDeltaY > 4.0 {
                Task { @MainActor [weak self] in self?.stop() }
            }
        }

        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in
            guard let ev = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 1,
                wheel1: -11,
                wheel2: 0,
                wheel3: 0
            ) else { return }
            ev.location = targetQuartzPoint
            ev.post(tap: .cghidEventTap)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
        if let m = wheelMonitor {
            NSEvent.removeMonitor(m)
            wheelMonitor = nil
        }
        onStateChanged?(false)
    }
}
