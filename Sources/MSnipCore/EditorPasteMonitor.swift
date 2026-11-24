import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

/// 编辑器专属按需监听引擎（仅在剪贴板仍归 MSnip 截图所有且前台为编辑器/IDE 时短暂挂载，离开或新复制即刻彻底销毁）：
/// 1. 被动 `AXObserver` 监听编辑器内部焦点切换（代码/AI 聊天框 ↔ 内置终端）；
/// 2. `.listenOnly` 级 `CGEventTap` 感应 `⌘V` 触发时机，供不透明 Electron / GPUI 编辑器执行无感路径回补；
/// 3. 绝不拦截或延迟任何正常按键，不记录任何输入内容。
@MainActor
public final class EditorPasteMonitor {
    /// 合成粘贴事件的唯一签名标记，避免触发自身回调死循环
    public static let syntheticPasteTag: Int64 = 0x4D53_4E50_5041_5354

    public var onFocusChanged: (() -> Void)?
    public var onCommandVPressed: (() -> Void)?
    public var onOtherKeyPressed: (() -> Void)?

    private var observedPID: pid_t = 0
    private var axObserver: AXObserver?
    private var axAppElement: AXUIElement?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var isTapActive = false

    public init() {}

    /// 启动对指定编辑器进程的按需焦点监听与 `⌘V` 被动感应（未授权辅助功能时静默跳过）
    public func start(forPID pid: pid_t) {
        guard AXIsProcessTrusted(), pid > 0 else {
            stop()
            return
        }
        if observedPID == pid && (axObserver != nil || isTapActive) {
            return
        }
        stop()
        observedPID = pid
        attachAXObserver(forPID: pid)
        attachListenOnlyKeyTap()
    }

    /// 立即彻底释放 `AXObserver`、`CFMachPort` 与 `CFRunLoopSource`（零残留、零开销）
    public func stop() {
        isTapActive = false
        observedPID = 0

        if let obs = axObserver {
            if let appEl = axAppElement {
                AXObserverRemoveNotification(obs, appEl, kAXFocusedUIElementChangedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
            axObserver = nil
        }
        axAppElement = nil

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        if let src = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            eventTapSource = nil
        }
    }

    /// 使用独立事件源发送一次带标记的 `⌘V`（不受物理修饰键瞬时抬起状态影响）
    public static func postSyntheticCommandV() {
        guard AXIsProcessTrusted() else { return }
        let src = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: syntheticPasteTag)
        up.setIntegerValueField(.eventSourceUserData, value: syntheticPasteTag)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    // MARK: - Private Setup

    private func attachAXObserver(forPID pid: pid_t) {
        var obs: AXObserver?
        guard AXObserverCreate(pid, Self.axObserverCallback, &obs) == .success, let observer = obs else {
            return
        }
        let appEl = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let err = AXObserverAddNotification(observer, appEl, kAXFocusedUIElementChangedNotification as CFString, refcon)
        guard err == .success || err == .notificationAlreadyRegistered else {
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axObserver = observer
        axAppElement = appEl
    }

    private func attachListenOnlyKeyTap() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.keyTapCallback,
            userInfo: refcon
        ) else {
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }
        eventTap = tap
        eventTapSource = source
        isTapActive = true
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private static let axObserverCallback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let monitor = Unmanaged<EditorPasteMonitor>.fromOpaque(refcon).takeUnretainedValue()
        DispatchQueue.main.async { [weak monitor] in
            monitor?.onFocusChanged?()
        }
    }

    private static let keyTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<EditorPasteMonitor>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if monitor.isTapActive, let tap = monitor.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard monitor.isTapActive, type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == EditorPasteMonitor.syntheticPasteTag {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let mods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if keyCode == kVK_ANSI_V && mods == .maskCommand {
            if !isRepeat {
                DispatchQueue.main.async { [weak monitor] in
                    monitor?.onCommandVPressed?()
                }
            }
        } else {
            DispatchQueue.main.async { [weak monitor] in
                monitor?.onOtherKeyPressed?()
            }
        }
        return Unmanaged.passUnretained(event)
    }
}
