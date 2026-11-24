import AppKit
import CoreGraphics
import Foundation

/// 主线程三层无感剪贴板动态投影控制器：
/// - 第 1 层（App 级，零权限）：独立终端自动附带临时 PNG 路径，访达自动附带文件 URL，普通应用保持纯净图像；
/// - 第 2a 层（编辑器 AX 焦点级）：仅当剪贴板归 MSnip 截图所有且前台是编辑器/IDE 时，被动探测焦点切换，
///   命中内置终端立即投影路径，切回 AI 聊天框/Markdown/代码区立即还原纯净图像；
/// - 第 2b 层（不透明 Electron/GPUI 编辑器消费探针）：以纯净图像优先粘贴，AI 聊天框/Markdown 消费 PNG 后零干扰结束；
///   内置终端忽略 PNG（120ms 未消费）时自动升格路径并补发一次带标记 `⌘V`，随后 220ms 自动回落纯净图像；
/// - 一旦用户在任意应用复制新内容（`changeCount` 变化），立即释放图像引用并销毁所有监听句柄，严格保持零驻留。
@MainActor
public final class SmartClipboardProjectionManager {
    public static let shared = SmartClipboardProjectionManager()

    public var isAdaptiveEnabled: Bool = true {
        didSet {
            if !isAdaptiveEnabled {
                cancelPendingTasks(); editorMonitor.stop()
                activeEditorPID = 0; activeEditorFocus = .indeterminate
                reprojectIfStillOwned(forApp: nil)
            } else if trackedImage != nil {
                reprojectIfStillOwned(forApp: NSWorkspace.shared.frontmostApplication)
            }
        }
    }

    private let editorMonitor = EditorPasteMonitor()
    private var trackedImage: CGImage?
    private var trackedScale: CGFloat = 2.0
    private var trackedFileBox: ClipboardFileBox?
    private var trackedChangeCount: Int = -1
    private var lastMode: ClipboardProjectionMode = .imageOnly
    private var isForcedPathMode = false
    private var activeEditorPID: pid_t = 0
    private var activeEditorFocus: EditorFocusClassification = .indeterminate
    private var currentProbe: ClipboardConsumptionProbe?
    private var pendingPasteFallback: DispatchWorkItem?
    private var pendingRevertWork: DispatchWorkItem?
    private var pendingProbeRefresh: DispatchWorkItem?
    private var observerRegistered = false

    private init() {}

    public func writeImage(_ cgImage: CGImage, scaleFactor: CGFloat, forceIncludePath: Bool = false) {
        registerObserversIfNeeded()
        cancelPendingTasks()

        trackedImage = cgImage
        trackedScale = max(1.0, scaleFactor)
        trackedFileBox = ClipboardFileBox()
        isForcedPathMode = forceIncludePath

        if forceIncludePath {
            editorMonitor.stop(); activeEditorPID = 0; activeEditorFocus = .indeterminate
            writeProjection(mode: .terminalImageAndPath, transient: false, attachProbe: false)
            return
        }

        let state = resolveTargetState(for: effectiveFrontmostApp())
        activeEditorPID = state.editorPID
        activeEditorFocus = state.focus
        syncEditorMonitor(forPID: state.editorPID)
        writeProjection(mode: state.mode, transient: false, attachProbe: state.editorPID > 0 && state.mode == .imageOnly)
    }

    public func clearTrackedState() {
        cancelPendingTasks()
        editorMonitor.stop()
        trackedImage = nil; trackedFileBox = nil; currentProbe = nil
        trackedChangeCount = -1; lastMode = .imageOnly; isForcedPathMode = false
        activeEditorPID = 0; activeEditorFocus = .indeterminate
    }

    // MARK: - Observers & State Transitions

    private func registerObserversIfNeeded() {
        guard !observerRegistered else { return }
        observerRegistered = true

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in self?.reprojectIfStillOwned(forApp: app) }
        }

        editorMonitor.onFocusChanged = { [weak self] in self?.handleEditorFocusChanged() }
        editorMonitor.onCommandVPressed = { [weak self] in self?.handleEditorCommandVPressed() }
        editorMonitor.onOtherKeyPressed = { [weak self] in self?.handleEditorOtherKeyPressed() }
    }

    private func reprojectIfStillOwned(forApp app: NSRunningApplication?) {
        guard checkOwnershipOrClear(), !isForcedPathMode else { return }
        if let bid = app?.bundleIdentifier, bid == Bundle.main.bundleIdentifier { return }

        cancelPendingTasks()
        let state = resolveTargetState(for: app)
        activeEditorPID = state.editorPID
        activeEditorFocus = state.focus
        syncEditorMonitor(forPID: state.editorPID)

        let needsProbe = state.editorPID > 0 && state.mode == .imageOnly
        if state.mode != lastMode || (needsProbe && currentProbe == nil) {
            writeProjection(mode: state.mode, transient: true, attachProbe: needsProbe)
        }
    }

    private func handleEditorFocusChanged() {
        guard isActiveEditorContext(pid: activeEditorPID) else { return }
        pendingPasteFallback?.cancel(); pendingPasteFallback = nil
        pendingRevertWork?.cancel(); pendingRevertWork = nil

        let focus = EditorTerminalFocusDetector.detectFocusedTarget(pid: activeEditorPID)
        activeEditorFocus = focus
        let nextMode: ClipboardProjectionMode = (focus == .terminal) ? .terminalImageAndPath : .imageOnly
        if nextMode != lastMode {
            writeProjection(mode: nextMode, transient: true, attachProbe: nextMode == .imageOnly)
        }
    }

    private func handleEditorCommandVPressed() {
        guard isActiveEditorContext(pid: activeEditorPID) else { return }
        if lastMode == .terminalImageAndPath {
            if pendingRevertWork != nil { scheduleOpaqueEditorRevert(expectedPID: activeEditorPID) }
            return
        }

        // 在 ⌘V 瞬间再做一次 <1ms 被动 AX 复核：明确命中编辑区/AI 聊天框则绝不补路径
        let liveFocus = EditorTerminalFocusDetector.detectFocusedTarget(pid: activeEditorPID)
        activeEditorFocus = liveFocus
        guard liveFocus != .nonTerminalInput, let probe = currentProbe, !probe.wasImageRequested else { return }

        let targetPID = activeEditorPID
        let expectedCount = trackedChangeCount
        let waitSeconds: TimeInterval = (liveFocus == .terminal) ? 0.045 : 0.12

        pendingPasteFallback = scheduleDelayed(replacing: pendingPasteFallback, after: waitSeconds) { [weak self] in
            guard let self else { return }
            self.pendingPasteFallback = nil
            guard self.isActiveEditorContext(pid: targetPID),
                  self.trackedChangeCount == expectedCount,
                  self.lastMode == .imageOnly,
                  !probe.wasImageRequested else { return }

            self.writeProjection(mode: .terminalImageAndPath, transient: true, attachProbe: false)
            EditorPasteMonitor.postSyntheticCommandV()
            if liveFocus == .indeterminate { self.scheduleOpaqueEditorRevert(expectedPID: targetPID) }
        }
    }

    private func handleEditorOtherKeyPressed() {
        pendingPasteFallback?.cancel(); pendingPasteFallback = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            Task { @MainActor [weak self] in _ = self?.checkOwnershipOrClear() }
        }
    }

    private func handleImageConsumedInEditor() {
        pendingPasteFallback?.cancel(); pendingPasteFallback = nil
        guard isActiveEditorContext(pid: activeEditorPID), lastMode == .imageOnly else { return }
        let targetPID = activeEditorPID
        pendingProbeRefresh = scheduleDelayed(replacing: pendingProbeRefresh, after: 0.30) { [weak self] in
            guard let self else { return }
            self.pendingProbeRefresh = nil
            guard self.isActiveEditorContext(pid: targetPID), self.lastMode == .imageOnly else { return }
            self.writeProjection(mode: .imageOnly, transient: true, attachProbe: true)
        }
    }

    private func scheduleOpaqueEditorRevert(expectedPID: pid_t) {
        pendingRevertWork = scheduleDelayed(replacing: pendingRevertWork, after: 0.22) { [weak self] in
            guard let self else { return }
            self.pendingRevertWork = nil
            guard self.isActiveEditorContext(pid: expectedPID), self.lastMode == .terminalImageAndPath else { return }
            guard EditorTerminalFocusDetector.detectFocusedTarget(pid: expectedPID) != .terminal else { return }
            self.writeProjection(mode: .imageOnly, transient: true, attachProbe: true)
        }
    }

    // MARK: - Helpers

    private func isActiveEditorContext(pid: pid_t) -> Bool {
        guard pid > 0, checkOwnershipOrClear(), !isForcedPathMode, isAdaptiveEnabled else { return false }
        return activeEditorPID == pid && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private func resolveTargetState(
        for app: NSRunningApplication?
    ) -> (mode: ClipboardProjectionMode, editorPID: pid_t, focus: EditorFocusClassification) {
        let bundleID = app?.bundleIdentifier
        guard isAdaptiveEnabled else { return (.imageOnly, 0, .indeterminate) }
        if ClipboardTerminalAdapter.isEditorBundleID(bundleID), let pid = app?.processIdentifier, pid > 0 {
            let focus = EditorTerminalFocusDetector.detectFocusedTarget(pid: pid)
            let mode = ClipboardTerminalAdapter.projectionMode(forBundleID: bundleID, adaptiveEnabled: true, editorFocus: focus)
            return (mode, pid, focus)
        }
        return (ClipboardTerminalAdapter.projectionMode(forBundleID: bundleID, adaptiveEnabled: true), 0, .indeterminate)
    }

    private func writeProjection(mode: ClipboardProjectionMode, transient: Bool, attachProbe: Bool) {
        guard let img = trackedImage, let box = trackedFileBox else { return }
        let probe: ClipboardConsumptionProbe? = attachProbe
            ? ClipboardConsumptionProbe { [weak self] in
                Task { @MainActor [weak self] in self?.handleImageConsumedInEditor() }
            }
            : nil
        trackedChangeCount = ClipboardImagePromise.write(
            cgImage: img, scaleFactor: trackedScale, mode: mode, transient: transient, fileBox: box, probe: probe
        )
        lastMode = mode
        currentProbe = probe
    }

    private func syncEditorMonitor(forPID pid: pid_t) {
        if isAdaptiveEnabled && !isForcedPathMode && pid > 0 { editorMonitor.start(forPID: pid) }
        else { editorMonitor.stop() }
    }

    @discardableResult
    private func checkOwnershipOrClear() -> Bool {
        guard trackedImage != nil, trackedFileBox != nil else { return false }
        if NSPasteboard.general.changeCount != trackedChangeCount { clearTrackedState(); return false }
        return true
    }

    private func effectiveFrontmostApp() -> NSRunningApplication? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return front
    }

    private func scheduleDelayed(
        replacing existing: DispatchWorkItem?,
        after delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> DispatchWorkItem {
        existing?.cancel()
        let work = DispatchWorkItem { Task { @MainActor in action() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return work
    }

    private func cancelPendingTasks() {
        pendingPasteFallback?.cancel(); pendingPasteFallback = nil
        pendingRevertWork?.cancel(); pendingRevertWork = nil
        pendingProbeRefresh?.cancel(); pendingProbeRefresh = nil
    }
}
