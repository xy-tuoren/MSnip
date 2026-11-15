import Carbon
import Foundation
import MSnipCore

/// 基于 Carbon `RegisterEventHotKey` 的零开销全局快捷键管理器（支持预设与用户自由录制组合键）
final class HotKeyManager {
    private static let signature: OSType = 0x4D53_4E50 // 'MSNP'
    private static let captureHotKeyID: UInt32 = 1
    private static let pinHotKeyID: UInt32 = 2
    private static let ocrHotKeyID: UInt32 = 3

    var onCapture: (() -> Void)?
    var onPin: (() -> Void)?
    var onOCR: (() -> Void)?

    private var eventHandlerRef: EventHandlerRef?
    private var captureRef: EventHotKeyRef?
    private var pinRef: EventHotKeyRef?
    private var ocrRef: EventHotKeyRef?

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
    func apply(config: AppConfig) {
        unregisterAll()
        guard config.hotKeysEnabled else { return }

        let cap = config.activeCaptureCombo
        let capID = EventHotKeyID(signature: Self.signature, id: Self.captureHotKeyID)
        RegisterEventHotKey(cap.keyCode, cap.carbonModifiers, capID, GetApplicationEventTarget(), 0, &captureRef)

        let pin = config.activePinCombo
        let pinID = EventHotKeyID(signature: Self.signature, id: Self.pinHotKeyID)
        RegisterEventHotKey(pin.keyCode, pin.carbonModifiers, pinID, GetApplicationEventTarget(), 0, &pinRef)

        let ocr = config.activeOCRCombo
        let ocrID = EventHotKeyID(signature: Self.signature, id: Self.ocrHotKeyID)
        RegisterEventHotKey(ocr.keyCode, ocr.carbonModifiers, ocrID, GetApplicationEventTarget(), 0, &ocrRef)
    }

    func unregisterAll() {
        if let ref = captureRef { UnregisterEventHotKey(ref); captureRef = nil }
        if let ref = pinRef { UnregisterEventHotKey(ref); pinRef = nil }
        if let ref = ocrRef { UnregisterEventHotKey(ref); ocrRef = nil }
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
                case HotKeyManager.ocrHotKeyID:
                    DispatchQueue.main.async { manager.onOCR?() }
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
