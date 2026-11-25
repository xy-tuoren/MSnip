import AppKit
import Foundation

/// 顶部暂存架事件驱动边缘悬停探测器（无轮询定时器，停用时 0 监听 0% CPU；拖文件滑向屏幕顶部中央也会自动展开）
@MainActor
final class ShelfEdgeWatcher {
    var onTriggerShow: (() -> Void)?
    var onTriggerHide: (() -> Void)?
    var isSuppressed: (() -> Bool)?
    var panelFrameProvider: (() -> NSRect?)?
    var isPinnedProvider: (() -> Bool)?
    var isVisibleProvider: (() -> Bool)?

    private var edgeMonitor: Any?
    private var hoverShowTimer: Timer?
    private var autoHideTimer: Timer?

    var isEnabled: Bool = false {
        didSet { syncMonitor() }
    }

    func startAutoHideWatch() {
        autoHideTimer?.invalidate()
        let t = Timer(timeInterval: 0.24, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      self.isVisibleProvider?() == true,
                      self.isPinnedProvider?() == false,
                      let frame = self.panelFrameProvider?() else { return }
                let pt = NSEvent.mouseLocation
                if !frame.insetBy(dx: -24, dy: -22).contains(pt) && NSEvent.pressedMouseButtons == 0 {
                    self.onTriggerHide?()
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        autoHideTimer = t
    }

    func stopTransientTimers() {
        autoHideTimer?.invalidate(); autoHideTimer = nil
        hoverShowTimer?.invalidate(); hoverShowTimer = nil
    }

    private func syncMonitor() {
        if let m = edgeMonitor { NSEvent.removeMonitor(m); edgeMonitor = nil }
        hoverShowTimer?.invalidate(); hoverShowTimer = nil
        guard isEnabled else { return }
        edgeMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] ev in
            let isDrag = (ev.type == .leftMouseDragged)
            Task { @MainActor [weak self] in self?.handlePointer(isDragging: isDrag) }
        }
    }

    private func handlePointer(isDragging: Bool) {
        guard isVisibleProvider?() != true, !(isSuppressed?() ?? false) else { return }
        let pt = NSEvent.mouseLocation
        guard let scr = NSScreen.screens.first(where: { $0.frame.contains(pt) }) else { return }
        let nearTop = (scr.frame.maxY - pt.y) <= (isDragging ? 8.0 : 3.0)
        let inCenterBand = abs(pt.x - scr.frame.midX) <= 160.0
        if nearTop && inCenterBand {
            if hoverShowTimer == nil {
                let delay: TimeInterval = isDragging ? 0.08 : 0.18
                let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.hoverShowTimer = nil
                        self?.onTriggerShow?()
                    }
                }
                RunLoop.main.add(t, forMode: .common)
                hoverShowTimer = t
            }
        } else {
            hoverShowTimer?.invalidate(); hoverShowTimer = nil
        }
    }
}
