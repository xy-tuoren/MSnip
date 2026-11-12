import Carbon
import Foundation

/// 基于 Carbon `RegisterEventHotKey` 的零开销全局快捷键管理器（无需申请辅助功能权限）
final class HotKeyManager {
    private static let signature: OSType = 0x4D53_4E50 // 'MSNP'
    private static let captureHotKeyID: UInt32 = 1
    private static let pinHotKeyID: UInt32 = 2

    var onCapture: (() -> Void)?
    var onPin: (() -> Void)?

    private var eventHandlerRef: EventHandlerRef?
    private var captureRef: EventHotKeyRef?
    private var pinRef: EventHotKeyRef?

    init() {
        installCarbonHandler()
    }

    deinit {
        unregisterAll()
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
        }
    }

    /// 根据当前配置注册或卸载全局热键
    func apply(preset: HotKeyPreset, enabled: Bool) {
        unregisterAll()
        guard enabled else { return }

        let cap = preset.captureShortcut
        let capID = EventHotKeyID(signature: Self.signature, id: Self.captureHotKeyID)
        RegisterEventHotKey(
            cap.keyCode,
            cap.modifiers,
            capID,
            GetApplicationEventTarget(),
            0,
            &captureRef
        )

        let pin = preset.pinShortcut
        let pinID = EventHotKeyID(signature: Self.signature, id: Self.pinHotKeyID)
        RegisterEventHotKey(
            pin.keyCode,
            pin.modifiers,
            pinID,
            GetApplicationEventTarget(),
            0,
            &pinRef
        )
    }

    func unregisterAll() {
        if let ref = captureRef {
            UnregisterEventHotKey(ref)
            captureRef = nil
        }
        if let ref = pinRef {
            UnregisterEventHotKey(ref)
            pinRef = nil
        }
    }

    private func installCarbonHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr, hotKeyID.signature == HotKeyManager.signature else {
                    return OSStatus(eventNotHandledErr)
                }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                switch hotKeyID.id {
                case HotKeyManager.captureHotKeyID:
                    DispatchQueue.main.async { manager.onCapture?() }
                    return noErr
                case HotKeyManager.pinHotKeyID:
                    DispatchQueue.main.async { manager.onPin?() }
                    return noErr
                default:
                    return OSStatus(eventNotHandledErr)
                }
            },
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )
    }
}
