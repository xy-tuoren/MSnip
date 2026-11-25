import AppKit
import Foundation
import MSnipCore

/// 顶部晾衣架（暂存架）交互状态机：
/// - `topEdgeHover`（悬停展开，默认）：空手贴顶停留 `550ms` 展开（路过菜单栏/选应用绝不误触）；
///   拖文件/图片到顶边或按 `⌥` 顶边 `80ms` 秒弹；展开后点顶栏秒收且离开顶边前不再重弹；离开后 `500ms` 缓收；
/// - `manualOnly`（快捷键切换）：平时零监听 0% CPU，热键呼出后若光标进过内容区，移开时按常规 `500ms` 自动收起；
/// - `alwaysShown`（常驻显示）：默认常驻展开，不自动收起，可随时热键暂藏。
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
    private var baselineDragCount: Int = NSPasteboard(name: .drag).changeCount

    var triggerMode: TopShelfTriggerMode = .topEdgeHover {
        didSet { syncMonitors() }
    }

    func startAutoHideWatch(peekDuration: TimeInterval = 0, fromHotkey: Bool = false) {
        autoHideTimer?.invalidate()
        let now = ProcessInfo.processInfo.systemUptime
        lastInsideUptime = now
        peekUntilUptime = peekDuration > 0 ? (now + peekDuration) : 0
        hotkeyPinned = fromHotkey

        installEscAndTopBarDismissMonitors()

        guard triggerMode != .alwaysShown else { return }
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
        let insideSafe = ShelfTriggerGeometry.containsInclusive(safe, point: pt)
        let insidePanel = ShelfTriggerGeometry.containsInclusive(frame, point: pt)

        if insidePanel {
            // 快捷键打开的晾衣架，一旦鼠标真正进入卡片区，就转入常规移出自动收回流（对齐轻雪原稿）
            hotkeyPinned = false
        }
        if insideSafe || NSEvent.pressedMouseButtons != 0 {
            lastInsideUptime = now
            return
        }
        if hotkeyPinned { return }

        let hideAt = max(peekUntilUptime, lastInsideUptime + 0.50)
        if now >= hideAt {
            onTriggerHide?()
        }
    }

    private func installEscAndTopBarDismissMonitors() {
        if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
        if let m = topClickMonitor { NSEvent.removeMonitor(m); topClickMonitor = nil }

        escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            if ev.keyCode == 53 { Task { @MainActor [weak self] in self?.onTriggerHide?() } }
        }
        topClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleGlobalTopBarClick() }
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
        // 点一下顶栏秒收，并在指针离开顶边前锁死防重弹（对齐 SnowAir-Rack topBarSuppressed_）
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
        let pt = NSEvent.mouseLocation
        let scr = NSScreen.screens.first(where: { ShelfTriggerGeometry.containsInclusive($0.frame, point: pt) })
        let isDragging = (type == .leftMouseDragged)
        let isRealDrag = isDragging && (NSPasteboard(name: .drag).changeCount != baselineDragCount)
        let inTopZone = scr.map {
            ShelfTriggerGeometry.hitsTopCenterTrigger(point: pt, screenFrame: $0.frame, isDragging: isRealDrag)
        } ?? false

        if !inTopZone {
            topBarSuppressed = false
            hoverShowTimer?.invalidate(); hoverShowTimer = nil
            return
        }
        guard isVisibleProvider?() != true, !(isSuppressed?() ?? false), !topBarSuppressed else {
            hoverShowTimer?.invalidate(); hoverShowTimer = nil
            return
        }
        // 正在拖普通窗口标题栏或划选文字时绝不触发
        if isDragging && !isRealDrag {
            hoverShowTimer?.invalidate(); hoverShowTimer = nil
            return
        }
        // 空绳时仅在拖入文件/文字或按住 ⌥ 时展开，避免空手无端弹出空晾衣绳
        let optionHeld = modifiers.contains(.option)
        if !isRealDrag && !optionHeld && (hasItemsProvider?() == false) {
            hoverShowTimer?.invalidate(); hoverShowTimer = nil
            return
        }

        // 拖文件 / 按住 ⌥：80ms 秒弹；空手贴顶：550ms 明确驻留防误触（对齐轻雪原稿）
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
