import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// 长截图平滑自动滚轮控制器：
/// 启动时自动将光标移至选区内侧安静边缘（避免点完按钮光标留在选区外导致滚不动，也避开中央内容 Hover 高亮），
/// 以 30Hz 投递像素级向下滚轮事件；触底停止若用户未挪动鼠标则礼貌还原原光标位，用户反向滚轮时立即中断。
@MainActor
final class AutoScroller {
    var onStateChanged: ((Bool) -> Void)?

    private var timer: Timer?
    private var wheelMonitor: Any?
    private var savedCursorQuartz: CGPoint?
    private var warpedCursorQuartz: CGPoint?
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

        // 记录原始光标并将光标落入目标可滚区域内部，确保 macOS 将 HID 滚轮事件准确路由到目标滚动视图
        savedCursorQuartz = CGEvent(source: nil)?.location
        CGWarpMouseCursorPosition(targetQuartzPoint)
        CGAssociateMouseAndMouseCursorPosition(1)
        warpedCursorQuartz = targetQuartzPoint

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
        // 仅当用户未自行挪动鼠标时还原光标到原按钮位置，绝不与用户抢光标
        if let saved = savedCursorQuartz, let warped = warpedCursorQuartz,
           let cur = CGEvent(source: nil)?.location,
           hypot(cur.x - warped.x, cur.y - warped.y) <= 18.0 {
            CGWarpMouseCursorPosition(saved)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        savedCursorQuartz = nil
        warpedCursorQuartz = nil
        onStateChanged?(false)
    }
}
