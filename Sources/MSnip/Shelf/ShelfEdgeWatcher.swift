import AppKit
import Foundation
import MSnipCore

/// 顶部晾衣架（暂存架）零闲置开销交互状态机：
/// - 先做纯几何顶边带预筛，远离顶边时零 `Task` 分配、零 `NSPasteboard(.drag)` IPC 查询；
/// - 严格隔离全局 `Esc` 监听，绝不误关「常驻显示」或已「钉住」的暂存架。
@MainActor
final class ShelfEdgeWatcher {
    var onTriggerShow: (() -> Void)?
    var onTriggerHide: (() -> Void)?
    var isSuppressed: (() -> Bool)?
    var hasItemsProvider: (() -> Bool)?
    var panelFrameProvider: (() -> NSRect?)?
    var panelScreenFrameProvider: (() -> NSRect?)?
    var isPinnedProvider: (() -> Bool)?
    var isVisibleProvider: (() -> Bool)?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var escMonitor: Any?
    private var topClickMonitor: Any?
    private var hoverShowTimer: Timer?
    private var autoHideTimer: Timer?

    private var lastInsideUptime: TimeInterval = 0
    private var peekUntilUptime: TimeInterval = 0
    private var hotkeyPinned: Bool = false
    private var topBarSuppressed: Bool = false
    private var baselineDragCount: Int = 0

    var triggerMode: TopShelfTriggerMode = .topEdgeHover {
        didSet { syncMonitors() }
    }

    func startAutoHideWatch(peekDuration: TimeInterval = 0, fromHotkey: Bool = false) {
        autoHideTimer?.invalidate(); autoHideTimer = nil
        guard triggerMode != .alwaysShown else {
            stopTransientMonitors()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        lastInsideUptime = now
        peekUntilUptime = peekDuration > 0 ? (now + peekDuration) : 0
        hotkeyPinned = fromHotkey

        installEscAndTopBarDismissMonitors()

        let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickAutoHide() }
        }
        RunLoop.main.add(t, forMode: .common)
        autoHideTimer = t
    }

    func extendPeek(duration: TimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        peekUntilUptime = max(peekUntilUptime, now + duration)
        lastInsideUptime = max(lastInsideUptime, now)
    }

    func stopTransientTimers() {
        autoHideTimer?.invalidate(); autoHideTimer = nil
        hoverShowTimer?.invalidate(); hoverShowTimer = nil
        hotkeyPinned = false
        peekUntilUptime = 0
        stopTransientMonitors()
    }

    private func stopTransientMonitors() {
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        if let m = topClickMonitor { NSEvent.removeMonitor(m); topClickMonitor = nil }
    }

    private func tickAutoHide() {
        guard isVisibleProvider?() == true,
              triggerMode != .alwaysShown,
              isPinnedProvider?() == false,
              let frame = panelFrameProvider?() else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let pt = NSEvent.mouseLocation
        let scrFrame = panelScreenFrameProvider?() ?? frame
        let safe = ShelfTriggerGeometry.safeKeepRect(panelFrame: frame, screenFrame: scrFrame)
        if ShelfTriggerGeometry.containsInclusive(frame, point: pt) { hotkeyPinned = false }
        if ShelfTriggerGeometry.containsInclusive(safe, point: pt) || NSEvent.pressedMouseButtons != 0 {
            lastInsideUptime = now; return
        }
        if hotkeyPinned { return }
        if now >= max(peekUntilUptime, lastInsideUptime + 0.50) { onTriggerHide?() }
    }

    private func installEscAndTopBarDismissMonitors() {
        stopTransientMonitors()
        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard ev.keyCode == 53 else { return }
            MainActor.assumeIsolated {
                guard let self, self.isVisibleProvider?() == true,
                      self.triggerMode != .alwaysShown, self.isPinnedProvider?() == false else { return }
                self.onTriggerHide?()
            }
        }
        topClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleGlobalTopBarClick() }
        }
    }

    private func handleGlobalTopBarClick() {
        guard isVisibleProvider?() == true,
              triggerMode == .topEdgeHover,
              isPinnedProvider?() == false else { return }
        let pt = NSEvent.mouseLocation
        if let frame = panelFrameProvider?(), ShelfTriggerGeometry.containsInclusive(frame, point: pt) { return }
        guard let scr = NSScreen.screens.first(where: { ShelfTriggerGeometry.containsInclusive($0.frame, point: pt) }),
              ShelfTriggerGeometry.hitsTopBarDismissBand(point: pt, screenFrame: scr.frame) else { return }
        topBarSuppressed = true
        onTriggerHide?()
    }

    private func syncMonitors() {
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        hoverShowTimer?.invalidate(); hoverShowTimer = nil
        topBarSuppressed = false
        guard triggerMode == .topEdgeHover else { return }

        baselineDragCount = NSPasteboard(name: .drag).changeCount
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] ev in
            let type = ev.type, mods = ev.modifierFlags
            MainActor.assumeIsolated { self?.handlePointer(type: type, modifiers: mods) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] ev in
            self?.handlePointer(type: ev.type, modifiers: ev.modifierFlags)
            return ev
        }
    }

    private func handlePointer(type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags) {
        if type == .leftMouseDown {
            baselineDragCount = NSPasteboard(name: .drag).changeCount
            return
        }
        if isVisibleProvider?() == true || isSuppressed?() == true {
            if hoverShowTimer != nil { hoverShowTimer?.invalidate(); hoverShowTimer = nil }
            return
        }
        let pt = NSEvent.mouseLocation
        guard let scr = NSScreen.screens.first(where: { ShelfTriggerGeometry.containsInclusive($0.frame, point: pt) }) else { return }

        // 纯几何快速预筛：离开菜单栏区重置抑制标记，且未真正贴紧屏幕最顶边（≤ 3pt）时零 IPC 直接返回
        if pt.y < scr.frame.maxY - 32.0, topBarSuppressed { topBarSuppressed = false }
        if pt.y < scr.frame.maxY - 3.0 {
            if hoverShowTimer != nil { hoverShowTimer?.invalidate(); hoverShowTimer = nil }
            return
        }

        let isDragging = (type == .leftMouseDragged)
        let isRealDrag = isDragging && (NSPasteboard(name: .drag).changeCount != baselineDragCount)
        let inTopZone = ShelfTriggerGeometry.hitsTopCenterTrigger(point: pt, screenFrame: scr.frame, isDragging: isRealDrag)
        if !inTopZone {
            topBarSuppressed = false
            hoverShowTimer?.invalidate(); hoverShowTimer = nil
            return
        }
        guard isVisibleProvider?() != true, !(isSuppressed?() ?? false), !topBarSuppressed else {
            hoverShowTimer?.invalidate(); hoverShowTimer = nil; return
        }
        if isDragging && !isRealDrag {
            hoverShowTimer?.invalidate(); hoverShowTimer = nil; return
        }
        let optionHeld = modifiers.contains(.option)
        if !isRealDrag && !optionHeld && (hasItemsProvider?() == false) {
            hoverShowTimer?.invalidate(); hoverShowTimer = nil; return
        }

        let delay: TimeInterval = (isRealDrag || optionHeld) ? 0.08 : 0.55
        if hoverShowTimer == nil {
            let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.hoverShowTimer = nil
                    guard let self, self.isVisibleProvider?() != true,
                          !(self.isSuppressed?() ?? false), !self.topBarSuppressed else { return }
                    let nowPt = NSEvent.mouseLocation
                    if NSScreen.screens.contains(where: {
                        ShelfTriggerGeometry.hitsTopCenterTrigger(point: nowPt, screenFrame: $0.frame, isDragging: isRealDrag)
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
