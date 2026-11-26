import AppKit
import Foundation
import MSnipCore

/// 贴图悬浮状态事件驱动协调器：
/// - 弥补后台 `.accessory` 应用下 `NSTrackingArea` 在弹窗出生、右键菜单关闭、跨应用切焦点、
///   VisionKit 异步挂载与透明圆角边缘时的 `mouseEntered` 漏报问题；
/// - 零贴图或全部暂藏/穿透时自动注销全部事件监听（闲时 0% CPU）；有贴图时先做 O(N) 纯矩形预筛，
///   仅在光标真正靠近贴图或已有悬浮条可见时才调用 1 次 WindowServer 遮挡判定。
@MainActor
final class PinHoverCoordinator {
    var windowsProvider: (() -> [PinWindow])?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var menuCloseObserver: NSObjectProtocol?
    private var reconcileWorkItem: DispatchWorkItem?
    private var lastThrottledUptime: TimeInterval = 0

    func syncMonitors() {
        let hasEligible = (windowsProvider?() ?? []).contains { $0.isVisible && !$0.isClickThrough }
        if !hasEligible {
            stop()
            return
        }
        guard globalMonitor == nil, localMonitor == nil else { return }

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseUp, .rightMouseUp]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] ev in
            let immediate = (ev.type != .mouseMoved)
            MainActor.assumeIsolated { self?.handlePointerEvent(immediate: immediate) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] ev in
            self?.handlePointerEvent(immediate: ev.type != .mouseMoved)
            return ev
        }
        menuCloseObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcileSoon(delay: 0.03) }
        }
    }

    func stop() {
        reconcileWorkItem?.cancel()
        reconcileWorkItem = nil
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let o = menuCloseObserver { NotificationCenter.default.removeObserver(o); menuCloseObserver = nil }
    }

    func reconcileSoon(delay: TimeInterval = 0.05) {
        reconcileWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.reconcileWorkItem = nil
                self?.reconcileNow()
            }
        }
        reconcileWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func reconcileNow() {
        let pins = windowsProvider?() ?? []
        guard !pins.isEmpty else { return }
        let mouse = NSEvent.mouseLocation

        // 快速预筛：若鼠标不在任何贴图/悬浮条热区且当前没有任何贴图处于悬停态，零 WindowServer 调用直接返回
        var needsWindowServerQuery = false
        for pin in pins {
            if pin.isMouseInPin || pin.isMouseInHoverBar || pin.hoverBarPanel.isVisible {
                needsWindowServerQuery = true
                break
            }
            guard pin.isHoverBarAllowed,
                  PinHoverGeometry.isPointInHoverZone(
                      point: mouse,
                      pinFrame: pin.interactiveHoverFrame,
                      barFrame: nil,
                      isBarVisible: false
                  ) else { continue }
            needsWindowServerQuery = true
            break
        }
        guard needsWindowServerQuery else { return }

        let topWin = NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0)
        var pinWindowNumbers = Set<Int>()
        pinWindowNumbers.reserveCapacity(pins.count * 2)
        for pin in pins where pin.isVisible {
            pinWindowNumbers.insert(pin.windowNumber)
            if pin.hoverBarPanel.isVisible { pinWindowNumbers.insert(pin.hoverBarPanel.windowNumber) }
        }

        for pin in pins {
            pin.reconcileHover(mouse: mouse, topWindowNumber: topWin, allPinWindowNumbers: pinWindowNumbers)
        }
    }

    private func handlePointerEvent(immediate: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if !immediate && (now - lastThrottledUptime) < 0.024 { return }
        lastThrottledUptime = now
        reconcileNow()
    }
}

/// 贴图窗口悬浮态自愈与真实光标复核扩展
extension PinWindow {
    var interactiveHoverFrame: NSRect {
        let r = PinGlowContainerView.outerResizeReach
        return imageScreenFrame.insetBy(dx: -r, dy: -r)
    }

    var isHoverBarAllowed: Bool {
        isVisible && isOnActiveSpace && !isClickThrough
            && editorCanvas == nil && cropOverlay == nil && !pinContentView.isAnnotating
    }

    func updatePinHover(_ inside: Bool) {
        if inside {
            guard isHoverBarAllowed else { return }
            let changed = !isMouseInPin
            isMouseInPin = true
            pinContentView.syncMouseInsideFlag(true)
            if changed { syncGlowState(); syncResizeChromeVisibility() }
            if changed || !hoverBarPanel.isVisible || !hoverBarPanel.isOnActiveSpace { syncHoverBarVisibility() }
            return
        }

        // 防止 VisionKit / 边角跟踪区重建导致鼠标仍在图内或外沿缩放带时发出伪 mouseExited
        let mouse = NSEvent.mouseLocation
        if isHoverBarAllowed,
           PinHoverGeometry.containsPointInclusive(interactiveHoverFrame, mouse),
           isPinUncovered(at: mouse, topWindowNumber: NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0)) {
            pinContentView.syncMouseInsideFlag(true)
            return
        }
        guard isMouseInPin else { return }
        isMouseInPin = false
        pinContentView.syncMouseInsideFlag(false)
        clearResizeHoverCursorIfNeeded()
        syncGlowState()
        syncHoverBarVisibility()
    }

    func updateHoverBarHover(_ inside: Bool) {
        guard isMouseInHoverBar != inside || (inside && (!hoverBarPanel.isVisible || !hoverBarPanel.isOnActiveSpace)) else { return }
        isMouseInHoverBar = inside
        syncGlowState()
        syncHoverBarVisibility()
    }

    func reconcileHoverFromCurrentMouse() {
        let mouse = NSEvent.mouseLocation
        let topWin = NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0)
        reconcileHover(mouse: mouse, topWindowNumber: topWin, allPinWindowNumbers: [])
    }

    func reconcileHover(mouse: NSPoint, topWindowNumber topWin: Int, allPinWindowNumbers: Set<Int>) {
        if isActivelyDraggingOrResizing { return }
        guard isHoverBarAllowed else {
            if isMouseInPin || isMouseInHoverBar || hoverBarPanel.isVisible {
                isMouseInPin = false
                isMouseInHoverBar = false
                pinContentView.syncMouseInsideFlag(false)
                clearResizeHoverCursorIfNeeded()
                syncGlowState()
                hoverBarPanel.hideCleanly()
            }
            return
        }

        let barVisible = hoverBarPanel.isVisible && hoverBarPanel.isOnActiveSpace
        let inBar = barVisible
            && PinHoverGeometry.containsPointInclusive(hoverBarPanel.frame, mouse)
            && isHoverBarUncovered(at: mouse, topWindowNumber: topWin)

        let inPinRect = PinHoverGeometry.containsPointInclusive(interactiveHoverFrame, mouse)
        let blockedByOtherPin = allPinWindowNumbers.contains(topWin)
            && topWin != windowNumber && topWin != hoverBarPanel.windowNumber
        let inPin = !inBar && inPinRect && !blockedByOtherPin && isPinUncovered(at: mouse, topWindowNumber: topWin)

        let inBridge = !inPin && !inBar && barVisible && !blockedByOtherPin
            && PinHoverGeometry.containsPointInclusive(
                PinHoverGeometry.bridgeCorridor(pinFrame: imageScreenFrame, barFrame: hoverBarPanel.frame),
                mouse
            )
            && isHoverBarUncovered(at: mouse, topWindowNumber: topWin)

        if inBar { hoverBarPanel.barView.reconcileHover(screenPoint: mouse) }

        let prevPin = isMouseInPin, prevBar = isMouseInHoverBar
        if inPin || inBar {
            isMouseInPin = inPin
            isMouseInHoverBar = inBar
            pinContentView.syncMouseInsideFlag(inPin)
            if inPin {
                _ = handleResizeHover(contentPoint: pinContentView.convert(convertPoint(fromScreen: mouse), from: nil))
            } else {
                clearResizeHoverCursorIfNeeded()
            }
            if prevPin != inPin || prevBar != inBar { syncGlowState(); syncResizeChromeVisibility() }
            if prevPin != inPin || prevBar != inBar || !barVisible { syncHoverBarVisibility() }
        } else if inBridge {
            // 正在跨过贴图与悬浮条之间的 5pt 间隙：保持悬浮条不闪退
            if prevPin || prevBar {
                isMouseInPin = false
                isMouseInHoverBar = false
                pinContentView.syncMouseInsideFlag(false)
                clearResizeHoverCursorIfNeeded()
                syncGlowState()
                syncHoverBarVisibility()
            }
        } else if prevPin || prevBar {
            isMouseInPin = false
            isMouseInHoverBar = false
            pinContentView.syncMouseInsideFlag(false)
            clearResizeHoverCursorIfNeeded()
            syncGlowState()
            syncHoverBarVisibility()
        } else if hoverBarPanel.isVisible && hideHoverWorkItem == nil {
            syncHoverBarVisibility()
        }
    }

    /// `hideHoverWorkItem` 真正隐藏前再次核验实时光标位置，杜绝在桥接区或贴图内被误隐藏
    func shouldKeepHoverBarAliveNow() -> Bool {
        guard isHoverBarAllowed else { return false }
        let mouse = NSEvent.mouseLocation
        let topWin = NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0)
        if PinHoverGeometry.containsPointInclusive(interactiveHoverFrame, mouse),
           isPinUncovered(at: mouse, topWindowNumber: topWin) {
            isMouseInPin = true
            pinContentView.syncMouseInsideFlag(true)
            syncGlowState()
            return true
        }
        if hoverBarPanel.isVisible,
           PinHoverGeometry.containsPointInclusive(hoverBarPanel.frame, mouse),
           isHoverBarUncovered(at: mouse, topWindowNumber: topWin) {
            isMouseInHoverBar = true
            syncGlowState()
            return true
        }
        if hoverBarPanel.isVisible,
           PinHoverGeometry.containsPointInclusive(
               PinHoverGeometry.bridgeCorridor(pinFrame: imageScreenFrame, barFrame: hoverBarPanel.frame),
               mouse
           ),
           isHoverBarUncovered(at: mouse, topWindowNumber: topWin) {
            syncHoverBarVisibility()
            return true
        }
        return false
    }

    func hideForToggle() {
        hideHoverWorkItem?.cancel()
        hideHoverWorkItem = nil
        isMouseInPin = false
        isMouseInHoverBar = false
        pinContentView.syncMouseInsideFlag(false)
        clearResizeHoverCursorIfNeeded()
        hoverBarPanel.hideCleanly()
        orderOut(nil)
    }

    private func isPinUncovered(at mouse: NSPoint, topWindowNumber topWin: Int) -> Bool {
        if topWin == windowNumber { return true }
        let belowPin = NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: windowNumber)
        return PinHoverGeometry.isWindowUncovered(
            pinWindowNumber: windowNumber,
            topWindowNumber: topWin,
            belowPinWindowNumber: belowPin
        )
    }

    private func isHoverBarUncovered(at mouse: NSPoint, topWindowNumber topWin: Int) -> Bool {
        let barNum = hoverBarPanel.windowNumber
        if topWin == barNum { return true }
        let belowBar = NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: barNum)
        return PinHoverGeometry.isWindowUncovered(
            pinWindowNumber: barNum,
            topWindowNumber: topWin,
            belowPinWindowNumber: belowBar
        )
    }
}
