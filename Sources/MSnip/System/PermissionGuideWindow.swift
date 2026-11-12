import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// ChatGPT 风格权限引导主控制器：
/// 1. 独立权限总览面板：双圆角卡片（屏幕录制 / 辅助功能），主次按钮随授权进度自动切换；
/// 2. 点击「允许」跳转「系统设置」后，无缝切换为吸附在列表下方的 ChatGPT 拖拽条与蓝白弹跳箭头。
@MainActor
final class PermissionGuideController: NSObject, NSWindowDelegate {
    var onPermissionChanged: (() -> Void)?

    private var panel: NSPanel?
    private var pollTimer: Timer?
    private let settingsDock = SettingsDockOverlay()
    private var isSessionActive = false
    private var prefersAccessoryMode = false
    private var lastScreenGranted = false
    private var lastAXGranted = false

    private var screenRow: PermissionRowView!
    private var axRow: PermissionRowView!
    private var relaunchPill: PillControl!
    private var donePill: PillControl!

    override init() {
        super.init()
        settingsDock.onBackRequested = { [weak self] in
            guard let self else { return }
            self.prefersAccessoryMode = false
            self.presentChecklistWindow()
        }
        settingsDock.onVisibilityChanged = { [weak self] dockVisible in
            guard let self, self.isSessionActive else { return }
            if dockVisible && self.prefersAccessoryMode {
                self.panel?.orderOut(nil)
            } else if !dockVisible && self.prefersAccessoryMode {
                self.presentChecklistWindow()
            }
        }
    }

    func show(opening pane: PermissionPane? = nil) {
        isSessionActive = true
        _ = ensureWindow()
        lastScreenGranted = CGPreflightScreenCaptureAccess()
        lastAXGranted = AXIsProcessTrusted()
        updateUI(screenOK: lastScreenGranted, axOK: lastAXGranted)
        startPolling()

        if let targetPane = pane {
            openPane(targetPane)
        } else {
            prefersAccessoryMode = false
            settingsDock.stopAndHide()
            presentChecklistWindow()
        }
    }

    func applyMockStateForPreview(screenOK: Bool, axOK: Bool) -> NSView {
        let win = ensureWindow()
        updateUI(screenOK: screenOK, axOK: axOK)
        return win.contentView!
    }

    private func presentChecklistWindow() {
        let win = ensureWindow()
        if !win.isVisible {
            positionChecklistWindow(win)
        }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private func ensureWindow() -> NSPanel {
        if let existing = panel { return existing }

        let w: CGFloat = 342
        let h: CGFloat = 244
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.title = "开启 MSnip 权限"
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

        let header = buildHeaderView()
        screenRow = PermissionRowView(
            kind: .screenRecording,
            title: "屏幕录制",
            subtitle: "捕获屏幕画面与像素级放大取色"
        ) { [weak self] in self?.openPane(.screenRecording) }

        axRow = PermissionRowView(
            kind: .accessibility,
            title: "辅助功能",
            subtitle: "智能识别窗口与多层控件矩阵边界"
        ) { [weak self] in self?.openPane(.accessibility) }

        relaunchPill = PillControl(title: "重启生效", style: .subtleButton) { [weak self] in
            self?.relaunchApp()
        }
        donePill = PillControl(title: "完成", style: .subtleButton) { [weak self] in
            self?.closeAll()
        }

        root.addSubview(header)
        root.addSubview(screenRow)
        root.addSubview(axRow)
        root.addSubview(relaunchPill)
        root.addSubview(donePill)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            header.heightAnchor.constraint(equalToConstant: 36),

            screenRow.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            screenRow.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            screenRow.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            screenRow.heightAnchor.constraint(equalToConstant: 54),

            axRow.topAnchor.constraint(equalTo: screenRow.bottomAnchor, constant: 8),
            axRow.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            axRow.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            axRow.heightAnchor.constraint(equalToConstant: 54),

            relaunchPill.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            relaunchPill.topAnchor.constraint(equalTo: axRow.bottomAnchor, constant: 12),
            relaunchPill.widthAnchor.constraint(equalToConstant: 68),
            relaunchPill.heightAnchor.constraint(equalToConstant: 24),

            donePill.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            donePill.centerYAnchor.constraint(equalTo: relaunchPill.centerYAnchor),
            donePill.widthAnchor.constraint(equalToConstant: 62),
            donePill.heightAnchor.constraint(equalToConstant: 24)
        ])

        self.panel = p
        return p
    }

    private func buildHeaderView() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        let icon = (NSApp.applicationIconImage?.copy() as? NSImage) ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        icon.size = NSSize(width: 34, height: 34)
        iconView.image = icon

        let title = NSTextField(labelWithString: "开启 MSnip 权限")
        title.font = .systemFont(ofSize: 14.5, weight: .semibold)
        title.textColor = .labelColor

        let sub = NSTextField(labelWithString: "点击允许后，从系统设置底部将图标拖入列表")
        sub.font = .systemFont(ofSize: 11.5, weight: .regular)
        sub.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, sub])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1.5
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(iconView)
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 34),
            iconView.heightAnchor.constraint(equalToConstant: 34),

            stack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor)
        ])
        return container
    }

    private func positionChecklistWindow(_ win: NSWindow) {
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = round(max(vf.minX + 60, vf.midX - win.frame.width - 120))
        let y = round(vf.midY - win.frame.height * 0.5 + 20)
        win.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshStatus() }
        }
    }

    private func refreshStatus() {
        let screenOK = CGPreflightScreenCaptureAccess()
        let axOK = AXIsProcessTrusted()
        let changed = (screenOK != lastScreenGranted || axOK != lastAXGranted)
        lastScreenGranted = screenOK
        lastAXGranted = axOK
        updateUI(screenOK: screenOK, axOK: axOK)

        if changed {
            onPermissionChanged?()
            let completedActivePane = settingsDock.isDockVisible && (
                (settingsDock.activePane == .screenRecording && screenOK && !axOK) ||
                (settingsDock.activePane == .accessibility && axOK && !screenOK)
            )
            if (screenOK && axOK) || completedActivePane {
                prefersAccessoryMode = false
                settingsDock.stopAndHide()
                presentChecklistWindow()
            }
        }
    }

    private func updateUI(screenOK: Bool, axOK: Bool) {
        screenRow.actionPill.title = screenOK ? "✓ 已开启" : "允许"
        screenRow.actionPill.style = screenOK ? .grantedBadge : .primaryButton

        axRow.actionPill.title = axOK ? "✓ 已开启" : "允许"
        axRow.actionPill.style = axOK ? .grantedBadge : (screenOK ? .primaryButton : .subtleButton)

        relaunchPill.isHidden = screenOK
        donePill.style = (screenOK && axOK) ? .primaryButton : .subtleButton
    }

    private func openPane(_ pane: PermissionPane) {
        prefersAccessoryMode = true
        panel?.orderOut(nil)
        if let url = pane.settingsURL { NSWorkspace.shared.open(url) }
        activateSystemSettings()
        settingsDock.startTracking(for: pane)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.activateSystemSettings() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.isSessionActive, self.prefersAccessoryMode, !self.settingsDock.isDockVisible else { return }
            self.presentChecklistWindow()
        }
    }

    private func activateSystemSettings() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences") {
            app.activate(options: [.activateAllWindows])
        }
    }

    private func relaunchApp() {
        closeAll()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "sleep 0.35 && open \"$1\"", "--", Bundle.main.bundlePath]
        try? proc.run()
        NSApp.terminate(nil)
    }

    private func closeAll() {
        isSessionActive = false
        prefersAccessoryMode = false
        pollTimer?.invalidate()
        pollTimer = nil
        settingsDock.stopAndHide()
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if !prefersAccessoryMode {
            isSessionActive = false
            pollTimer?.invalidate()
            pollTimer = nil
            settingsDock.stopAndHide()
        }
    }
}
