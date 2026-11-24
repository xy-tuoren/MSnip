import Carbon
import Foundation
import MSnipCore

/// 双模全局快捷键管理器：
/// - 常规模式：零权限、零开销的 Carbon `RegisterEventHotKey`；
/// - 强制优先接管模式（按需开启、一键无副作用关闭）：`CGEventTap` 头部优先拦截，压过冲突应用与系统热键；未授辅助功能时自动回退 Carbon。
final class HotKeyManager {
    private static let signature: OSType = 0x4D53_4E50 // 'MSNP'

    var onTrigger: ((GlobalHotKeyAction) -> Void)?
    private(set) var isPriorityTapActive: Bool = false
    private(set) var failedActions: Set<GlobalHotKeyAction> = []

    private var eventHandlerRef: EventHandlerRef?
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private let priorityTap = HotKeyEventTapEngine()

    init() {
        installCarbonHandler()
        priorityTap.onTrigger = { [weak self] action in
            self?.onTrigger?(action)
        }
    }

    deinit {
        unregisterAll()
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
        }
    }

    /// 根据当前配置注册或卸载全部已启用的全局热键
    func apply(config: AppConfig) {
        unregisterAll()
        guard config.hotKeysEnabled else { return }

        if config.forcePriorityHotKeys {
            var map: [KeyCombo: GlobalHotKeyAction] = [:]
            for action in GlobalHotKeyAction.allCases {
                if let combo = config.activeCombo(for: action) { map[combo] = action }
            }
            if priorityTap.start(bindings: map) {
                isPriorityTapActive = true
                return
            }
        }

        for (index, action) in GlobalHotKeyAction.allCases.enumerated() {
            guard let combo = config.activeCombo(for: action) else { continue }
            let hotKeyID = UInt32(index + 1)
            let eventID = EventHotKeyID(signature: Self.signature, id: hotKeyID)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                combo.keyCode,
                combo.carbonModifiers,
                eventID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                hotKeyRefs[hotKeyID] = ref
            } else {
                failedActions.insert(action)
            }
        }
    }

    func unregisterAll() {
        priorityTap.stop()
        isPriorityTapActive = false
        failedActions.removeAll()
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
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
                let idx = Int(hotKeyID.id) - 1
                let actions = GlobalHotKeyAction.allCases
                guard actions.indices.contains(idx) else {
                    return OSStatus(eventNotHandledErr)
                }
                let action = actions[idx]
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { manager.onTrigger?(action) }
                return noErr
            },
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )
    }
}
