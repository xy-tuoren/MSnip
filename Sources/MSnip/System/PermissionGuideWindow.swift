import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum PermissionPane {
    case screenRecording
    case accessibility

    var settingsURL: URL? {
        switch self {
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }
}

private final class FlippedRootView: NSView {
    override var isFlipped: Bool { true }
}

private final class StatusDotView: NSView {
    var color: NSColor = .tertiaryLabelColor {
        didSet { needsDisplay = true }
    }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
}

/// 极简毛玻璃置顶权限引导面板（284 × 244）：
/// 顶部居中可拖拽图标托盘 + 双行分组状态卡，停靠屏幕偏左，绝不遮挡「系统设置」。
@MainActor
final class PermissionGuideController: NSObject, NSWindowDelegate {
    var onPermissionChanged: (() -> Void)?

    private var panel: NSPanel?
    private var pollTimer: Timer?
    private var lastScreenGranted = false
    private var lastAXGranted = false

    private let screenDot = StatusDotView()
    private let axDot = StatusDotView()
    private var screenBtn: NSButton!
    private var axBtn: NSButton!
    private let screenDoneLabel = NSTextField(labelWithString: "已开启")
    private let axDoneLabel = NSTextField(labelWithString: "已开启")
    private var relaunchBtn: NSButton!

    func show(opening pane: PermissionPane? = nil) {
        let win = ensureWindow()
        refreshStatus(notifyIfChanged: false)

        if !win.isVisible {
            positionBesideSystemSettings(win)
        }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        startPolling()

        if let targetPane = pane, let url = targetPane.settingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Compact Vibrancy UI

    private func ensureWindow() -> NSPanel {
        if let existing = panel { return existing }

        let w: CGFloat = 284
        let h: CGFloat = 244
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.title = "权限引导"
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.backgroundColor = .clear
        p.delegate = self

        let visualEffect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        visualEffect.material = .popover
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active

        let root = FlippedRootView(frame: visualEffect.bounds)
        root.autoresizingMask = [.width, .height]
        visualEffect.addSubview(root)
        p.contentView = visualEffect

        // 顶部居中拖拽图标托盘
        let dragCard = DraggableAppCardView(frame: NSRect(x: (w - 200) * 0.5, y: 18, width: 200, height: 96))
        dragCard.onRevealInFinder = {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
        root.addSubview(dragCard)

        // 中部精简双行分组卡
        let pad: CGFloat = 16
        let groupW = w - pad * 2
        let groupY: CGFloat = 124
        let groupBox = NSBox(frame: NSRect(x: pad, y: groupY, width: groupW, height: 76))
        groupBox.boxType = .custom
        groupBox.cornerRadius = 10
        groupBox.borderWidth = 0.5
        groupBox.borderColor = NSColor.separatorColor
        groupBox.fillColor = NSColor.labelColor.withAlphaComponent(0.04)
        root.addSubview(groupBox)

        screenBtn = buildRow(
            in: root, x: pad, y: groupY, width: groupW,
            title: "屏幕录制", dot: screenDot, doneLabel: screenDoneLabel,
            action: #selector(openScreenRecordingSettings)
        )

        let divider = NSBox(frame: NSRect(x: pad + 28, y: groupY + 38, width: groupW - 38, height: 1))
        divider.boxType = .separator
        root.addSubview(divider)

        axBtn = buildRow(
            in: root, x: pad, y: groupY + 38, width: groupW,
            title: "辅助功能", dot: axDot, doneLabel: axDoneLabel,
            action: #selector(openAccessibilitySettings)
        )

        // 底部操作栏（无冗余说明字）
        let restart = NSButton(title: "重启生效", target: self, action: #selector(relaunchApp))
        restart.bezelStyle = .rounded
        restart.controlSize = .small
        restart.frame = NSRect(x: pad, y: 209, width: 72, height: 24)
        root.addSubview(restart)
        self.relaunchBtn = restart

        let done = NSButton(title: "完成", target: self, action: #selector(closeGuide))
        done.bezelStyle = .rounded
        done.controlSize = .small
        done.keyEquivalent = "\r"
        done.frame = NSRect(x: w - pad - 58, y: 209, width: 58, height: 24)
        root.addSubview(done)

        self.panel = p
        return p
    }

    private func buildRow(
        in container: NSView,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        title: String,
        dot: StatusDotView,
        doneLabel: NSTextField,
        action: Selector
    ) -> NSButton {
        dot.frame = NSRect(x: x + 12, y: y + 15, width: 8, height: 8)
        container.addSubview(dot)

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.frame = NSRect(x: x + 28, y: y + 10, width: 120, height: 18)
        container.addSubview(label)

        doneLabel.font = .systemFont(ofSize: 12, weight: .medium)
        doneLabel.textColor = .systemGreen
        doneLabel.alignment = .right
        doneLabel.frame = NSRect(x: x + width - 70, y: y + 11, width: 58, height: 16)
        container.addSubview(doneLabel)

        let btn = NSButton(title: "去开启", target: self, action: action)
        btn.bezelStyle = .rounded
        btn.controlSize = .small
        btn.frame = NSRect(x: x + width - 72, y: y + 7, width: 62, height: 24)
        container.addSubview(btn)
        return btn
    }

    private func positionBesideSystemSettings(_ win: NSWindow) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = max(vf.minX + 60, vf.midX - win.frame.width - 140)
        let y = vf.midY - win.frame.height * 0.5 + 24
        win.setFrameOrigin(NSPoint(x: round(x), y: round(y)))
    }

    // MARK: - Live Status & Actions

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshStatus(notifyIfChanged: true)
            }
        }
    }

    private func refreshStatus(notifyIfChanged: Bool) {
        let screenOK = CGPreflightScreenCaptureAccess()
        let axOK = AXIsProcessTrusted()

        screenDot.color = screenOK ? .systemGreen : .systemOrange
        screenBtn.isHidden = screenOK
        screenDoneLabel.isHidden = !screenOK
        relaunchBtn.isHidden = screenOK

        axDot.color = axOK ? .systemGreen : .tertiaryLabelColor
        axBtn.isHidden = axOK
        axDoneLabel.isHidden = !axOK

        if notifyIfChanged && (screenOK != lastScreenGranted || axOK != lastAXGranted) {
            onPermissionChanged?()
        }
        lastScreenGranted = screenOK
        lastAXGranted = axOK
    }

    @objc private func openScreenRecordingSettings() {
        if let url = PermissionPane.screenRecording.settingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openAccessibilitySettings() {
        if let url = PermissionPane.accessibility.settingsURL {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func relaunchApp() {
        let bundlePath = Bundle.main.bundlePath
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "sleep 0.35 && open \"$1\"", "--", bundlePath]
        try? proc.run()
        NSApp.terminate(nil)
    }

    @objc private func closeGuide() {
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
