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

/// 极简毛玻璃置顶权限引导面板（280 × 240）：
/// 全程采用 Auto Layout 中心轴对齐 + 等宽零外边距胶囊签，彻底消除文字上下/左右错位。
@MainActor
final class PermissionGuideController: NSObject, NSWindowDelegate {
    var onPermissionChanged: (() -> Void)?

    private var panel: NSPanel?
    private var pollTimer: Timer?
    private let settingsDock = SettingsDockOverlay()
    private var lastScreenGranted = false
    private var lastAXGranted = false

    private let screenDot = StatusDotView()
    private let axDot = StatusDotView()
    private var screenPill: PillControl!
    private var axPill: PillControl!
    private var relaunchPill: PillControl!

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
        if !CGPreflightScreenCaptureAccess() || !AXIsProcessTrusted() {
            settingsDock.startTracking()
        }
    }

    func applyMockStateForPreview(screenOK: Bool, axOK: Bool) -> NSView {
        let win = ensureWindow()
        updateUI(screenOK: screenOK, axOK: axOK)
        return win.contentView!
    }

    private func ensureWindow() -> NSPanel {
        if let existing = panel { return existing }

        let w: CGFloat = 280
        let h: CGFloat = 246
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

        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        p.contentView = root

        let dragCard = DraggableAppCardView(frame: .zero)
        dragCard.translatesAutoresizingMaskIntoConstraints = false
        dragCard.onRevealInFinder = {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
        root.addSubview(dragCard)

        let groupBox = CardContainerView()
        groupBox.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(groupBox)

        let row1 = NSView(); row1.translatesAutoresizingMaskIntoConstraints = false
        let row2 = NSView(); row2.translatesAutoresizingMaskIntoConstraints = false
        let sep = NSView(); sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        sep.translatesAutoresizingMaskIntoConstraints = false
        groupBox.addSubview(row1)
        groupBox.addSubview(sep)
        groupBox.addSubview(row2)

        screenPill = populateRow(row1, title: "屏幕录制", dot: screenDot) { [weak self] in
            self?.openPane(.screenRecording)
        }
        axPill = populateRow(row2, title: "辅助功能", dot: axDot) { [weak self] in
            self?.openPane(.accessibility)
        }

        relaunchPill = PillControl(title: "重启生效", style: .subtleButton) { [weak self] in
            self?.relaunchApp()
        }
        let donePill = PillControl(title: "完成", style: .primaryButton) { [weak self] in
            self?.panel?.close()
        }
        root.addSubview(relaunchPill)
        root.addSubview(donePill)

        NSLayoutConstraint.activate([
            dragCard.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            dragCard.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            dragCard.widthAnchor.constraint(equalToConstant: 200),
            dragCard.heightAnchor.constraint(equalToConstant: 94),

            groupBox.topAnchor.constraint(equalTo: dragCard.bottomAnchor, constant: 10),
            groupBox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            groupBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            groupBox.heightAnchor.constraint(equalToConstant: 77),

            row1.topAnchor.constraint(equalTo: groupBox.topAnchor),
            row1.leadingAnchor.constraint(equalTo: groupBox.leadingAnchor),
            row1.trailingAnchor.constraint(equalTo: groupBox.trailingAnchor),
            row1.heightAnchor.constraint(equalToConstant: 38.25),

            sep.topAnchor.constraint(equalTo: row1.bottomAnchor),
            sep.leadingAnchor.constraint(equalTo: groupBox.leadingAnchor, constant: 31),
            sep.trailingAnchor.constraint(equalTo: groupBox.trailingAnchor, constant: -12),
            sep.heightAnchor.constraint(equalToConstant: 0.5),

            row2.topAnchor.constraint(equalTo: sep.bottomAnchor),
            row2.leadingAnchor.constraint(equalTo: groupBox.leadingAnchor),
            row2.trailingAnchor.constraint(equalTo: groupBox.trailingAnchor),
            row2.bottomAnchor.constraint(equalTo: groupBox.bottomAnchor),

            relaunchPill.leadingAnchor.constraint(equalTo: groupBox.leadingAnchor),
            relaunchPill.topAnchor.constraint(equalTo: groupBox.bottomAnchor, constant: 11),
            relaunchPill.widthAnchor.constraint(equalToConstant: 68),
            relaunchPill.heightAnchor.constraint(equalToConstant: 24),

            donePill.trailingAnchor.constraint(equalTo: groupBox.trailingAnchor),
            donePill.centerYAnchor.constraint(equalTo: relaunchPill.centerYAnchor),
            donePill.widthAnchor.constraint(equalToConstant: 60),
            donePill.heightAnchor.constraint(equalToConstant: 24)
        ])

        self.panel = p
        return p
    }

    private func populateRow(
        _ row: NSView, title: String, dot: StatusDotView, onOpen: @escaping () -> Void
    ) -> PillControl {
        dot.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let pill = PillControl(title: "去开启", style: .subtleButton, onClick: onOpen)
        row.addSubview(dot)
        row.addSubview(label)
        row.addSubview(pill)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 13),
            dot.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7.5),
            dot.heightAnchor.constraint(equalToConstant: 7.5),

            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            pill.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            pill.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            pill.widthAnchor.constraint(equalToConstant: 60),
            pill.heightAnchor.constraint(equalToConstant: 23)
        ])
        return pill
    }

    private func positionBesideSystemSettings(_ win: NSWindow) {
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = round(max(vf.minX + 60, vf.midX - win.frame.width - 140))
        let y = round(vf.midY - win.frame.height * 0.5 + 24)
        win.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshStatus(notifyIfChanged: true) }
        }
    }

    private func refreshStatus(notifyIfChanged: Bool) {
        let screenOK = CGPreflightScreenCaptureAccess()
        let axOK = AXIsProcessTrusted()
        updateUI(screenOK: screenOK, axOK: axOK)

        if screenOK && axOK {
            settingsDock.stopAndHide()
        }
        if notifyIfChanged && (screenOK != lastScreenGranted || axOK != lastAXGranted) {
            onPermissionChanged?()
        }
        lastScreenGranted = screenOK
        lastAXGranted = axOK
    }

    private func updateUI(screenOK: Bool, axOK: Bool) {
        screenDot.color = screenOK ? .systemGreen : .systemOrange
        screenPill.title = screenOK ? "已开启" : "去开启"
        screenPill.style = screenOK ? .grantedBadge : .subtleButton
        relaunchPill.isHidden = screenOK

        axDot.color = axOK ? .systemGreen : NSColor.secondaryLabelColor.withAlphaComponent(0.45)
        axPill.title = axOK ? "已开启" : "去开启"
        axPill.style = axOK ? .grantedBadge : .subtleButton
    }

    private func openPane(_ pane: PermissionPane) {
        if let url = pane.settingsURL { NSWorkspace.shared.open(url) }
        settingsDock.startTracking()
    }

    private func relaunchApp() {
        settingsDock.stopAndHide()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "sleep 0.35 && open \"$1\"", "--", Bundle.main.bundlePath]
        try? proc.run()
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        settingsDock.stopAndHide()
    }
}
