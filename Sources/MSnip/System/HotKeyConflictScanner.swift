import AppKit
import Carbon
import CoreGraphics
import Foundation
import MSnipCore

/// 本机热键占用与冲突实时快照
struct HotKeyConflictSnapshot: Sendable {
    let systemEntries: [OccupiedHotKeyEntry]
    let runningAppEntries: [OccupiedHotKeyEntry]
    let exclusiveOccupied: Set<KeyCombo>
    let scannedAt: Date

    static let empty = HotKeyConflictSnapshot(
        systemEntries: [],
        runningAppEntries: [],
        exclusiveOccupied: [],
        scannedAt: .distantPast
    )

    var allOccupiedCombos: Set<KeyCombo> {
        var set = exclusiveOccupied
        for e in systemEntries { set.insert(e.combo) }
        for e in runningAppEntries { set.insert(e.combo) }
        return set
    }
}

/// 基于 macOS 公开 API（`CopySymbolicHotKeys` + `AppleSymbolicHotKeys` + `kEventHotKeyExclusive` + `NSWorkspace`）的实时热键冲突扫描器
enum HotKeyConflictScanner {
    private static let probeSignature: OSType = 0x4D53_5052 // 'MSPR'
    private static let fnModifierBit: Int = 0x20000
    private static let carbonModMask: Int = Int(cmdKey | optionKey | controlKey | shiftKey)

    /// 扫描当前系统的活跃符号热键、运行中第三方应用的公开配置/默认热键，并实时探测指定组合键是否被系统/应用独占
    static func scan(probing combos: [KeyCombo] = []) -> HotKeyConflictSnapshot {
        let systemEntries = fetchActiveSystemHotKeys()
        let runningApps = NSWorkspace.shared.runningApplications
        let runningBundleIDs = Set(runningApps.compactMap(\.bundleIdentifier))
        var appEntries = fetchRunningAppLiveConfigs(apps: runningApps)
        let seenPairs = Set(appEntries.map { "\($0.owner)|\($0.combo.keyCode)|\($0.combo.carbonModifiers)" })
        for fallback in HotKeyConflictCatalog.runningAppEntries(for: runningBundleIDs) {
            let key = "\(fallback.owner)|\(fallback.combo.keyCode)|\(fallback.combo.carbonModifiers)"
            if !seenPairs.contains(key) { appEntries.append(fallback) }
        }

        var exclusiveSet: Set<KeyCombo> = []
        for combo in Set(combos) where probeExclusive(combo: combo) {
            exclusiveSet.insert(combo)
        }
        return HotKeyConflictSnapshot(
            systemEntries: systemEntries,
            runningAppEntries: appEntries,
            exclusiveOccupied: exclusiveSet,
            scannedAt: Date()
        )
    }

    /// 扫描当前运行中非系统应用的公开偏好域，直接解析标准 `KeyboardShortcuts_*` 与 `Raycast` 真实自定义热键
    private static func fetchRunningAppLiveConfigs(apps: [NSRunningApplication]) -> [OccupiedHotKeyEntry] {
        let ownBid = Bundle.main.bundleIdentifier
        var seenBids: Set<String> = []
        var out: [OccupiedHotKeyEntry] = []
        for app in apps {
            guard app.activationPolicy == .regular || app.activationPolicy == .accessory,
                  let bid = app.bundleIdentifier,
                  bid != ownBid, !bid.hasPrefix("com.apple."),
                  !seenBids.contains(bid) else { continue }
            seenBids.insert(bid)
            guard let domain = UserDefaults.standard.persistentDomain(forName: bid) else { continue }
            let appName = app.localizedName ?? bid
            for (k, v) in domain {
                if k.hasPrefix("KeyboardShortcuts_"), let s = v as? String,
                   let combo = HotKeyConflictProfiles.parseKeyboardShortcutsJSON(s) {
                    out.append(OccupiedHotKeyEntry(
                        combo: combo,
                        owner: appName,
                        feature: HotKeyConflictProfiles.humanizeShortcutKeyName(k),
                        category: .runningApp,
                        sourceKind: .appConfigLive
                    ))
                } else if k == "raycastGlobalHotkey", let s = v as? String,
                          let combo = HotKeyConflictProfiles.parseRaycastHotkeyString(s) {
                    out.append(OccupiedHotKeyEntry(
                        combo: combo,
                        owner: appName,
                        feature: "主呼出热键",
                        category: .runningApp,
                        sourceKind: .appConfigLive
                    ))
                }
            }
        }
        return out
    }

    /// 评估某组按键在当前配置与实时快照下的全部冲突（录制按键时可开启 `probeLiveExclusive` 做实时独占探测）
    static func evaluate(
        combo: KeyCombo,
        for slot: GlobalHotKeyAction?,
        config: AppConfig,
        snapshot: HotKeyConflictSnapshot,
        probeLiveExclusive: Bool = false
    ) -> [HotKeyConflict] {
        var own: [GlobalHotKeyAction: KeyCombo] = [:]
        for act in GlobalHotKeyAction.allCases {
            if let c = config.activeCombo(for: act) { own[act] = c }
        }
        let isExcl = snapshot.exclusiveOccupied.contains(combo) || (probeLiveExclusive && probeExclusive(combo: combo))
        return HotKeyConflictCatalog.evaluate(
            combo: combo,
            excluding: slot,
            ownBindings: own,
            systemEntries: snapshot.systemEntries,
            runningAppEntries: snapshot.runningAppEntries,
            carbonExclusiveOccupied: isExcl
        )
    }

    /// 通过 Carbon `kEventHotKeyExclusive` 瞬时探测某热键是否已被系统或其他常驻应用独占注册
    static func probeExclusive(combo: KeyCombo) -> Bool {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: probeSignature, id: 9001)
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            id,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &ref
        )
        if let ref { UnregisterEventHotKey(ref) }
        return status == OSStatus(eventHotKeyExistsErr)
    }

    /// 实时读取 macOS WindowServer 活跃系统符号热键，并融合用户偏好中自定义项的准确名称
    private static func fetchActiveSystemHotKeys() -> [OccupiedHotKeyEntry] {
        var customNamesByCombo: [KeyCombo: String] = [:]
        if let rawDict = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") {
            for (k, v) in rawDict {
                guard let id = Int(k),
                      let dict = v as? [String: Any],
                      (dict["enabled"] as? Bool) == true,
                      let val = dict["value"] as? [String: Any],
                      let params = val["parameters"] as? [Int],
                      params.count >= 3,
                      let name = HotKeyConflictCatalog.symbolicHotKeyIDName(id) else { continue }
                let code = params[1]
                let cocoaFlags = NSEvent.ModifierFlags(rawValue: UInt(params[2]))
                var carbon: UInt32 = 0
                if cocoaFlags.contains(.control) { carbon |= UInt32(controlKey) }
                if cocoaFlags.contains(.option)  { carbon |= UInt32(optionKey) }
                if cocoaFlags.contains(.shift)   { carbon |= UInt32(shiftKey) }
                if cocoaFlags.contains(.command) { carbon |= UInt32(cmdKey) }
                guard KeyCombo.isDisplayableKeyCode(code), carbon != 0 || KeyCombo.isFunctionOrNavKey(code) else { continue }
                customNamesByCombo[KeyCombo(keyCode: UInt32(code), carbonModifiers: carbon)] = name
            }
        }

        var rawCF: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&rawCF) == noErr,
              let list = rawCF?.takeRetainedValue() as? [[String: Any]] else {
            return customNamesByCombo.map {
                OccupiedHotKeyEntry(combo: $0.key, owner: "macOS", feature: $0.value, category: .system)
            }
        }

        var seen: Set<KeyCombo> = []
        var entries: [OccupiedHotKeyEntry] = []
        for item in list {
            guard (item[kHISymbolicHotKeyEnabled] as? Bool) == true,
                  let code = item[kHISymbolicHotKeyCode] as? Int,
                  let rawMods = item[kHISymbolicHotKeyModifiers] as? Int,
                  KeyCombo.isDisplayableKeyCode(code) else { continue }

            // 排除需要按住 Globe/Fn 键的字母/符号系统热键（如 Sequoia 窗口平铺 🌐⌃F），避免与普通 ⌃F 误报
            let hasFn = (rawMods & fnModifierBit) != 0
            if hasFn && !KeyCombo.isFunctionOrNavKey(code) { continue }

            let cleanMods = UInt32(rawMods & carbonModMask)
            guard cleanMods != 0 || KeyCombo.isFunctionOrNavKey(code) else { continue }
            let combo = KeyCombo(keyCode: UInt32(code), carbonModifiers: cleanMods)
            guard !seen.contains(combo) else { continue }
            seen.insert(combo)

            let name = customNamesByCombo[combo]
                ?? HotKeyConflictCatalog.systemSignatureName(for: combo)
                ?? "macOS 系统保留热键"
            entries.append(OccupiedHotKeyEntry(combo: combo, owner: "macOS", feature: name, category: .system))
        }

        // 将知名核心热键排在最前面，方便一眼扫视
        return entries.sorted { a, b in
            let aNamed = (a.feature != "macOS 系统保留热键")
            let bNamed = (b.feature != "macOS 系统保留热键")
            if aNamed != bNamed { return aNamed }
            return a.combo.displayString < b.combo.displayString
        }
    }
}

// MARK: - 快捷键冲突实时探针

/// 实时按键归属实测结果（通过系统激活通知与窗口列表差分精准定位抢占热键的应用）
enum HotKeyLiveProbeOutcome: Sendable {
    case appTriggered(appName: String, viaWindow: Bool)
    case localKeyClean(KeyCombo)
    case localKeyConflict(KeyCombo, HotKeyConflict)
    case timedOut
    case cancelled
}

/// 零私有 API 的实时「按键归属侦探」：
/// 监听应用前台激活与屏幕新增浮层窗口（如 PixPin / 微信 / Bob / Spotlight / 系统截屏等无焦点覆盖层），
/// 毫秒级定位究竟是哪一个具体应用响应并抢走了你刚按下的快捷键。
@MainActor
final class HotKeyLiveDetective {
    private(set) var isListening = false

    private var baselineWindowIDs: Set<Int> = []
    private var ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
    private var activateObserver: NSObjectProtocol?
    private var pollTimer: Timer?
    private var timeoutWork: DispatchWorkItem?
    private var pendingLocalKeyWork: DispatchWorkItem?
    private var onFinish: ((HotKeyLiveProbeOutcome) -> Void)?

    private static let ignoredOwnerNames: Set<String> = [
        "Window Server", "Dock", "程序坞", "Control Center", "控制中心",
        "Notification Center", "通知中心", "SystemUIServer", "Wallpaper", "壁纸"
    ]

    func start(duration: TimeInterval = 10.0, onFinish: @escaping (HotKeyLiveProbeOutcome) -> Void) {
        stop(notify: false)
        self.onFinish = onFinish
        self.ownPID = ProcessInfo.processInfo.processIdentifier
        self.baselineWindowIDs = Set(Self.currentVisibleWindows().map(\.id))
        self.isListening = true

        activateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            let name = app.localizedName ?? app.bundleIdentifier ?? "未知应用"
            Task { @MainActor [weak self] in
                guard let self, self.isListening, pid != self.ownPID else { return }
                self.complete(with: .appTriggered(appName: Self.friendlyOwnerName(name), viaWindow: false))
            }
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkNewOverlayWindows() }
        }

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                self.complete(with: .timedOut)
            }
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    /// 当按键穿透到达 MSnip 窗口本身时调用：延迟 260ms 确认没有后台软件异步弹窗，再结合静态/独占扫描下结论
    func noteLocalKeyPressed(_ combo: KeyCombo, evaluator: @escaping () -> [HotKeyConflict]) {
        guard isListening else { return }
        pendingLocalKeyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isListening else { return }
                if let hit = self.findFirstNewWindowOwner() {
                    self.complete(with: .appTriggered(appName: hit, viaWindow: true))
                    return
                }
                if let top = evaluator().first {
                    self.complete(with: .localKeyConflict(combo, top))
                } else {
                    self.complete(with: .localKeyClean(combo))
                }
            }
        }
        pendingLocalKeyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26, execute: work)
    }

    func cancel() {
        guard isListening else { return }
        complete(with: .cancelled)
    }

    func stop(notify: Bool = false) {
        let cb = notify ? onFinish : nil
        isListening = false
        onFinish = nil
        if let obs = activateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            activateObserver = nil
        }
        pollTimer?.invalidate(); pollTimer = nil
        timeoutWork?.cancel(); timeoutWork = nil
        pendingLocalKeyWork?.cancel(); pendingLocalKeyWork = nil
        cb?(.cancelled)
    }

    private func complete(with outcome: HotKeyLiveProbeOutcome) {
        let cb = onFinish
        stop(notify: false)
        cb?(outcome)
    }

    private func checkNewOverlayWindows() {
        guard isListening, let owner = findFirstNewWindowOwner() else { return }
        complete(with: .appTriggered(appName: owner, viaWindow: true))
    }

    private func findFirstNewWindowOwner() -> String? {
        for win in Self.currentVisibleWindows() {
            guard !baselineWindowIDs.contains(win.id),
                  win.pid != ownPID,
                  win.width >= 24, win.height >= 24,
                  !Self.ignoredOwnerNames.contains(win.owner) else { continue }
            return Self.friendlyOwnerName(win.owner)
        }
        return nil
    }

    private struct VisibleWindowInfo {
        let id: Int
        let pid: pid_t
        let owner: String
        let width: CGFloat
        let height: CGFloat
    }

    private static func currentVisibleWindows() -> [VisibleWindowInfo] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let id = item[kCGWindowNumber as String] as? Int,
                  let pid = item[kCGWindowOwnerPID as String] as? Int32,
                  let owner = item[kCGWindowOwnerName as String] as? String,
                  let bounds = item[kCGWindowBounds as String] as? [String: Any] else { return nil }
            let w = (bounds["Width"] as? CGFloat) ?? CGFloat((bounds["Width"] as? Double) ?? 0)
            let h = (bounds["Height"] as? CGFloat) ?? CGFloat((bounds["Height"] as? Double) ?? 0)
            return VisibleWindowInfo(id: id, pid: pid, owner: owner, width: w, height: h)
        }
    }

    private static func friendlyOwnerName(_ raw: String) -> String {
        switch raw {
        case "screencaptureui": return "macOS 系统截屏"
        case "Spotlight":       return "macOS 聚焦搜索 (Spotlight)"
        default:                return raw
        }
    }
}
