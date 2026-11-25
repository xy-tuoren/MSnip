import AppKit
import Foundation
import MSnipCore

/// 顶部暂存架智能防误触边缘探测器：
/// - `smartDragAndOption`（默认）：平时空手移鼠标经过顶栏/浏览器标签页绝不误触；仅当真正拖着文件/图片/文本
///   （通过 `NSPasteboard(.drag).changeCount` 精确排除窗口标题栏拖动与划选文本）滑至顶边，或按住 `⌥` 顶边时才展开；
/// - `topEdgeHover`：空手顶边悬停也可展开；`manualOnly`：零事件监听 0% CPU；
/// - 展开期间自动挂接临时 Esc 快速收起监听，收起后立即移除。
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
    private var escMonitor: Any?
    private var hoverShowTimer: Timer?
    private var autoHideTimer: Timer?
    private var graceUntilUptime: TimeInterval = 0
    private var baselineDragCount: Int = NSPasteboard(name: .drag).changeCount

    var triggerMode: TopShelfTriggerMode = .smartDragAndOption {
        didSet { syncMonitors() }
    }

    func startAutoHideWatch() {
        autoHideTimer?.invalidate()
        graceUntilUptime = ProcessInfo.processInfo.systemUptime + 0.45
        installEscMonitor()
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
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
    }

    private func installEscMonitor() {
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            if ev.keyCode == 53 { Task { @MainActor [weak self] in self?.onTriggerHide?() } }
        }
    }

    private func syncMonitors() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        hoverShowTimer?.invalidate(); hoverShowTimer = nil
        guard triggerMode != .manualOnly else { return }

        baselineDragCount = NSPasteboard(name: .drag).changeCount
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] ev in
            let type = ev.type, mods = ev.modifierFlags
            Task { @MainActor [weak self] in self?.handlePointer(type: type, modifiers: mods) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] ev in
            self?.handlePointer(type: ev.type, modifiers: ev.modifierFlags)
            return ev
        }
    }

    private func handlePointer(type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags) {
        if type == .leftMouseDown || type == .leftMouseUp {
            baselineDragCount = NSPasteboard(name: .drag).changeCount
            return
        }
        guard isVisibleProvider?() != true, !(isSuppressed?() ?? false) else { return }

        let isDragging = (type == .leftMouseDragged)
        let isRealPasteboardDrag = isDragging && (NSPasteboard(name: .drag).changeCount != baselineDragCount)
        let optionHeld = modifiers.contains(.option)

        let eligible: Bool
        switch triggerMode {
        case .manualOnly:         eligible = false
        case .smartDragAndOption: eligible = isRealPasteboardDrag || (!isDragging && optionHeld)
        case .topEdgeHover:       eligible = isRealPasteboardDrag || !isDragging
        }
        guard eligible else {
            hoverShowTimer?.invalidate(); hoverShowTimer = nil
            return
        }

        let pt = NSEvent.mouseLocation
        guard let scr = NSScreen.screens.first(where: { ShelfTriggerGeometry.containsInclusive($0.frame, point: pt) }),
              ShelfTriggerGeometry.hitsTopCenterTrigger(point: pt, screenFrame: scr.frame, isDragging: isRealPasteboardDrag) else {
            hoverShowTimer?.invalidate(); hoverShowTimer = nil
            return
        }

        if hoverShowTimer == nil {
            let delay: TimeInterval = isRealPasteboardDrag ? 0.05 : (optionHeld ? 0.08 : 0.14)
            let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.hoverShowTimer = nil
                    guard let self, self.isVisibleProvider?() != true, !(self.isSuppressed?() ?? false) else { return }
                    let nowPt = NSEvent.mouseLocation
                    if NSScreen.screens.contains(where: {
                        ShelfTriggerGeometry.hitsTopCenterTrigger(point: nowPt, screenFrame: $0.frame, isDragging: isRealPasteboardDrag)
                    }) {
                        self.onTriggerShow?()
                    }
                }
            }
            RunLoop.main.add(t, forMode: .common)
            hoverShowTimer = t
        }
    }
}
