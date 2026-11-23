import AppKit
import CoreGraphics
import Foundation
import MSnipCore

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
