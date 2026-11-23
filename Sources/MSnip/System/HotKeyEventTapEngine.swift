import AppKit
import Carbon
import CoreGraphics
import Foundation
import MSnipCore

/// 基于 macOS 公开 `CGEventTap`（`.cgSessionEventTap` + `.headInsertEventTap`）的头部优先热键拦截器：
/// - 优先级高于常规 Carbon 全局热键（其他截图/聊天/翻译软件）与系统符号热键；
/// - 仅对 MSnip 已绑定的少数键码做 O(1) 内存查表并消费事件，绝不记录或存储任何其他按键；
/// - `stop()` 会彻底停用、作废 `CFMachPort` 并从主 RunLoop 移除，关闭即零钩子、零副作用。
final class HotKeyEventTapEngine {
    var onTrigger: ((GlobalHotKeyAction) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var bindings: [KeyCombo: GlobalHotKeyAction] = [:]
    private(set) var isActive: Bool = false

    deinit {
        stop()
    }

    /// 尝试启动头部优先事件拦截；若未授予「辅助功能」权限则返回 `false`（不留任何残留句柄）
    @discardableResult
    func start(bindings: [KeyCombo: GlobalHotKeyAction]) -> Bool {
        stop()
        guard !bindings.isEmpty else { return false }

        // 安全红线：永不接管系统强制退出 (⌥⌘Esc)
        let forceQuitCombo = KeyCombo(keyCode: UInt32(kVK_Escape), carbonModifiers: UInt32(optionKey | cmdKey))
        var filtered = bindings
        filtered.removeValue(forKey: forceQuitCombo)
        guard !filtered.isEmpty else { return false }

        self.bindings = filtered
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.tapCallback,
            userInfo: userInfo
        ) else {
            self.bindings.removeAll()
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            self.bindings.removeAll()
            return false
        }

        self.eventTap = tap
        self.runLoopSource = source
        self.isActive = true
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// 一键完全停用并彻底清理 MachPort 与 RunLoopSource（零残留、零副作用）
    func stop() {
        isActive = false
        bindings.removeAll()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let engine = Unmanaged<HotKeyEventTapEngine>.fromOpaque(userInfo).takeUnretainedValue()

        // 长时间待机或偶发超时导致系统自动暂停 Tap 时立即自愈重启用
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if engine.isActive, let tap = engine.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard engine.isActive, type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        var carbonMods: UInt32 = 0
        if flags.contains(.maskControl)   { carbonMods |= UInt32(controlKey) }
        if flags.contains(.maskAlternate) { carbonMods |= UInt32(optionKey) }
        if flags.contains(.maskShift)     { carbonMods |= UInt32(shiftKey) }
        if flags.contains(.maskCommand)   { carbonMods |= UInt32(cmdKey) }

        let combo = KeyCombo(keyCode: keyCode, carbonModifiers: carbonMods)
        guard let action = engine.bindings[combo] else {
            return Unmanaged.passUnretained(event)
        }

        // 长按连发也一并消费防止泄漏给底层冲突应用，但仅在首次按下时触发 MSnip 动作
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if !isRepeat {
            DispatchQueue.main.async { [weak engine] in
                engine?.onTrigger?(action)
            }
        }
        return nil
    }
}
