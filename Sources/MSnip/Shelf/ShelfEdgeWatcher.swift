import AppKit
import Foundation
import MSnipCore

/// 顶部暂存架事件驱动边缘悬停探测器：
/// - 同时监听全局与本地鼠标移动/拖拽（无轮询定时器，停用时 0 监听 0% CPU）；
/// - 严格采用闭区间顶边判定（兼容 `pt.y == screen.maxY` 顶边贴屏与刘海屏），且安全保持区向上贯通至屏幕顶边，绝不刚弹出就误收。
@MainActor
final class ShelfEdgeWatcher {
    var onTriggerShow: (() -> Void)?
    var onTriggerHide: (() -> Void)?
    var isSuppressed: (() -> Bool)?
    var panelFrameProvider: (() -> NSRect?)?
    var panelScreenFrameProvider: (() -> NSRect?)?
    var isPinnedProvider: (() -> Bool)?
    var isVisibleProvider: (() -> Bool)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var hoverShowTimer: Timer?
    private var autoHideTimer: Timer?
    private var graceUntilUptime: TimeInterval = 0

    var isEnabled: Bool = false {
        didSet { syncMonitors() }
    }

    func startAutoHideWatch() {
        autoHideTimer?.invalidate()
        graceUntilUptime = ProcessInfo.processInfo.systemUptime + 0.45
        let t = Timer(timeInterval: 0.20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      self.isVisibleProvider?() == true,
                      self.isPinnedProvider?() == false,
                      ProcessInfo.processInfo.systemUptime >= self.graceUntilUptime,
                      let frame = self.panelFrameProvider?() else { return }
                let pt = NSEvent.mouseLocation
                let scrFrame = self.panelScreenFrameProvider?() ?? frame
                let safe = ShelfTriggerGeometry.safeKeepRect(panelFrame: frame, screenFrame: scrFrame)
                if !ShelfTriggerGeometry.containsInclusive(safe, point: pt) && NSEvent.pressedMouseButtons == 0 {
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

    private func syncMonitors() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        hoverShowTimer?.invalidate(); hoverShowTimer = nil
        guard isEnabled else { return }

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] ev in
            let isDrag = (ev.type == .leftMouseDragged)
            Task { @MainActor [weak self] in self?.handlePointer(isDragging: isDrag) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] ev in
            let isDrag = (ev.type == .leftMouseDragged)
            self?.handlePointer(isDragging: isDrag)
            return ev
        }
    }

    private func handlePointer(isDragging: Bool) {
        guard isVisibleProvider?() != true, !(isSuppressed?() ?? false) else { return }
        let pt = NSEvent.mouseLocation
        guard let scr = NSScreen.screens.first(where: { ShelfTriggerGeometry.containsInclusive($0.frame, point: pt) }) else {
            hoverShowTimer?.invalidate(); hoverShowTimer = nil
            return
        }
        if ShelfTriggerGeometry.hitsTopCenterTrigger(point: pt, screenFrame: scr.frame, isDragging: isDragging) {
            if hoverShowTimer == nil {
                let delay: TimeInterval = isDragging ? 0.05 : 0.10
                let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.hoverShowTimer = nil
                        guard let self, self.isVisibleProvider?() != true, !(self.isSuppressed?() ?? false) else { return }
                        let nowPt = NSEvent.mouseLocation
                        if NSScreen.screens.contains(where: {
                            ShelfTriggerGeometry.hitsTopCenterTrigger(point: nowPt, screenFrame: $0.frame, isDragging: isDragging)
                        }) {
                            self.onTriggerShow?()
                        }
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
