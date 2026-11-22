import AppKit
import Carbon
import CoreGraphics
import Foundation
import MSnipCore
import QuartzCore
import UniformTypeIdentifiers

/// 选区录制会话的倒计时驱动、窗口布局、全局点击/快捷键回显监听、保存面板与跨线程状态原子盒扩展
extension RegionRecordingSession {
    func startCountdownThenRecord() {
        guard !controlBar.isRecording, countdownTimer == nil, let screen = targetScreen else { return }
        countdownRemaining = 3
        countdownStartedAt = CACurrentMediaTime()
        borderView.countdownFormatBadge = controlBar.format.badgeTitle
        borderView.countdownProgress = 1.0
        applyCountdownDisplay(3, on: screen)
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceCountdown() }
        }
    }

    func skipCountdownAndRecord() {
        countdownTimer?.invalidate(); countdownTimer = nil
        countdownRemaining = 0
        borderView.countdownNumber = nil
        borderView.countdownProgress = 1.0
        controlBar.countdownNumber = nil
        beginStreamRecording()
    }

    private func advanceCountdown() {
        guard !closed, let screen = targetScreen else { return }
        let totalDur: TimeInterval = 2.55
        let elapsed = max(0, CACurrentMediaTime() - countdownStartedAt)
        let remain = totalDur - elapsed
        if remain <= 0 { skipCountdownAndRecord(); return }
        borderView.countdownProgress = CGFloat(remain / totalDur)
        let sec = min(3, max(1, Int(ceil(remain / 0.85))))
        if sec != countdownRemaining {
            countdownRemaining = sec
            applyCountdownDisplay(sec, on: screen)
        }
    }

    private func applyCountdownDisplay(_ n: Int, on screen: NSScreen) {
        borderView.countdownNumber = n
        borderView.statusStyle = .warning
        borderView.statusText = "即将录制 \(controlBar.format.badgeTitle) · \(n) 秒后开始（↩ 立即开始 · Esc 取消）"
        controlBar.countdownNumber = n
        repositionControlWindow(around: Self.toAppKitScreenRect(localTopLeft: localCaptureRect, on: screen), on: screen)
    }

    func finishSession(_ outcome: Outcome) {
        guard !closed else { return }
        closed = true
        countdownTimer?.invalidate(); countdownTimer = nil
        tickTimer?.invalidate(); tickTimer = nil
        streamSampler.stop()
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        if let g = globalKeyMonitor { NSEvent.removeMonitor(g); globalKeyMonitor = nil }
        if let gm = globalMouseMonitor { NSEvent.removeMonitor(gm); globalMouseMonitor = nil }
        borderWindow?.orderOut(nil); borderWindow = nil
        controlWindow?.orderOut(nil); controlWindow = nil
        initialFrame = nil
        onComplete?(outcome)
    }

    func promptSaveMedia(tempURL: URL, format: RecordingFormat) -> (url: URL, dir: String)? {
        let panel = NSSavePanel()
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "MSnip-\(df.string(from: Date())).\(format.rawValue)"
        panel.allowedContentTypes = [format == .gif ? .gif : .mpeg4Movie]
        panel.canCreateDirectories = true
        panel.level = .modalPanel
        if let dir = saveDirHint, FileManager.default.fileExists(atPath: dir) {
            panel.directoryURL = URL(fileURLWithPath: dir, isDirectory: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dst = panel.url else { return nil }
        try? FileManager.default.removeItem(at: dst)
        guard (try? FileManager.default.copyItem(at: tempURL, to: dst)) != nil else { return nil }
        return (dst, dst.deletingLastPathComponent().path)
    }

    func installKeyMonitors() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self else { return ev }
            if ev.keyCode == 53 { self.cancel(); return nil }
            if ev.keyCode == 49, self.controlBar.isRecording { self.togglePause(); return nil }
            if ev.keyCode == 36 || ev.keyCode == 76 {
                if self.controlBar.isRecording { self.finalizeRecording(saveInteractive: false) }
                else if self.countdownTimer != nil { self.skipCountdownAndRecord() }
                else { self.startCountdownThenRecord() }
                return nil
            }
            return ev
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            if ev.keyCode == 53 {
                Task { @MainActor in self?.cancel() }
                return
            }
            let badge = Self.formatSafeShortcutBadge(event: ev)
            guard let badge else { return }
            Task { @MainActor [weak self] in
                guard let self, self.controlBar.isRecording, !self.paused else { return }
                self.overlayCompositor.recordKeyBadge(badge, at: self.currentActiveDuration())
            }
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] ev in
            let isRight = (ev.type == .rightMouseDown)
            let pt = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                guard let self, self.controlBar.isRecording, !self.paused, let scr = self.targetScreen else { return }
                if let cWin = self.controlWindow, cWin.frame.contains(pt) { return }
                let capScreen = Self.toAppKitScreenRect(localTopLeft: self.localCaptureRect, on: scr)
                guard capScreen.width > 1, capScreen.height > 1, capScreen.contains(pt) else { return }
                let nx = (pt.x - capScreen.minX) / capScreen.width
                let ny = (capScreen.maxY - pt.y) / capScreen.height
                self.overlayCompositor.recordClick(
                    normalizedX: nx,
                    normalizedY: ny,
                    isRightClick: isRight,
                    at: self.currentActiveDuration()
                )
            }
        }
    }

    /// 仅格式化带修饰符（⌘/⌃/⌥）的组合快捷键或特殊功能键，绝不回显普通打字字符以保护密码隐私
    private static func formatSafeShortcutBadge(event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods = ""
        if flags.contains(.control) { mods += "⌃" }
        if flags.contains(.option)  { mods += "⌥" }
        if flags.contains(.shift)   { mods += "⇧" }
        if flags.contains(.command) { mods += "⌘" }

        let specialKey: String? = {
            switch Int(event.keyCode) {
            case kVK_Return, kVK_ANSI_KeypadEnter: return "↩"
            case kVK_Tab:           return "⇥"
            case kVK_Delete:        return "⌫"
            case kVK_ForwardDelete: return "⌦"
            case kVK_LeftArrow:     return "←"
            case kVK_RightArrow:    return "→"
            case kVK_UpArrow:       return "↑"
            case kVK_DownArrow:     return "↓"
            default:                return nil
            }
        }()

        if let sp = specialKey {
            return mods + sp
        }
        return KeyCombo.from(event: event)?.displayString
    }

    func repositionControlWindow(around screenRect: NSRect, on screen: NSScreen) {
        guard let cWin = controlWindow else { return }
        let sz = controlBar.frame.size
        let pad = RecordingControlBarView.shadowPad
        let barW = sz.width - pad * 2
        let barH = sz.height - pad * 2
        let vis = screen.visibleFrame
        let barX = min(max(vis.minX + 8, screenRect.maxX - barW), vis.maxX - barW - 8)
        let belowY = screenRect.minY - barH - 10
        let barY = belowY >= vis.minY + 6 ? belowY : min(screenRect.maxY + 36, vis.maxY - barH - 6)
        cWin.setFrame(NSRect(origin: NSPoint(x: round(barX - pad), y: round(barY - pad)), size: sz), display: true)
    }

    static func toAppKitScreenRect(localTopLeft r: CGRect, on screen: NSScreen) -> NSRect {
        NSRect(x: screen.frame.minX + r.minX, y: screen.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    static func makePanel(frame: NSRect, ignoresMouse: Bool, contentView: NSView) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .screenSaver
        p.animationBehavior = .none
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = ignoresMouse
        p.acceptsMouseMovedEvents = !ignoresMouse
        p.contentView = contentView
        return p
    }
}

final class RecordingFlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _v = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _v }
        set { lock.lock(); _v = newValue; lock.unlock() }
    }
}

final class RecordingTimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _v: TimeInterval
    init(_ v: TimeInterval) { _v = v }
    var value: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _v }
        set { lock.lock(); _v = newValue; lock.unlock() }
    }
}
