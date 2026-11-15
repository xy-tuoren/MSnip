import AppKit
import CoreGraphics
import Foundation
import MSnipCore
import UniformTypeIdentifiers

/// 选区录制会话的窗口布局、全局按键监听、保存面板与跨线程状态原子盒扩展
extension RegionRecordingSession {
    func finishSession(_ outcome: Outcome) {
        guard !closed else { return }
        closed = true
        tickTimer?.invalidate(); tickTimer = nil
        streamSampler.stop()
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        if let g = globalKeyMonitor { NSEvent.removeMonitor(g); globalKeyMonitor = nil }
        borderWindow?.orderOut(nil); borderWindow = nil
        controlWindow?.orderOut(nil); controlWindow = nil
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
                else { self.beginStreamRecording() }
                return nil
            }
            return ev
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            if ev.keyCode == 53 { Task { @MainActor in self?.cancel() } }
        }
    }

    func repositionControlWindow(around screenRect: NSRect, on screen: NSScreen) {
        guard let cWin = controlWindow else { return }
        let sz = controlBar.frame.size
        let vis = screen.visibleFrame
        let x = min(max(vis.minX + 8, screenRect.maxX - sz.width), vis.maxX - sz.width - 8)
        let belowY = screenRect.minY - sz.height - 10
        let y = belowY >= vis.minY + 6 ? belowY : min(screenRect.maxY + 36, vis.maxY - sz.height - 6)
        cWin.setFrame(NSRect(origin: NSPoint(x: round(x), y: round(y)), size: sz), display: true)
    }

    static func toAppKitScreenRect(localTopLeft r: CGRect, on screen: NSScreen) -> NSRect {
        NSRect(x: screen.frame.minX + r.minX, y: screen.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    static func makePanel(frame: NSRect, ignoresMouse: Bool, contentView: NSView) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .screenSaver
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
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
