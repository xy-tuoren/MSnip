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

/// 顶部原点布局容器，确保权限引导面板内各行像素级对齐
private final class FlippedGuideContentView: NSView {
    override var isFlipped: Bool { true }
}

/// 置顶并排「拖拽图标授权引导窗」控制器：
/// - 采用 `.floating` 置顶层级并停靠屏幕偏左，避免被「系统设置」窗口遮挡；
/// - 内置 `DraggableAppCardView`，直接把 `MSnip.app` 拖进右侧系统设置列表即可开启权限；
/// - 窗口打开期间每 0.8s 无感刷新权限状态，窗口关闭即停止定时器（待机 0% CPU）。
@MainActor
final class PermissionGuideController: NSObject, NSWindowDelegate {
    var onPermissionChanged: (() -> Void)?

    private var panel: NSPanel?
    private var pollTimer: Timer?
    private var lastScreenGranted = false
    private var lastAXGranted = false

    private let screenBadge = NSTextField(labelWithString: "")
    private let axBadge = NSTextField(labelWithString: "")

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

    // MARK: - Window & UI Construction

    private func ensureWindow() -> NSPanel {
        if let existing = panel { return existing }

        let w: CGFloat = 456
        let h: CGFloat = 368
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        p.title = "MSnip 权限引导（拖拽图标即可开启）"
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.delegate = self

        let root = FlippedGuideContentView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        p.contentView = root

        let pad: CGFloat = 20
        let innerW = w - pad * 2

        let titleLabel = NSTextField(labelWithString: "一拖即用：把下方图标拖进「系统设置」")
        titleLabel.font = .systemFont(ofSize: 16, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: pad, y: 18, width: innerW, height: 22)
        root.addSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: "点击下方按钮打开对应设置页，再将 MSnip 图标拖进右侧列表松手即可")
        subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.frame = NSRect(x: pad, y: 42, width: innerW, height: 18)
        root.addSubview(subtitleLabel)

        let dragCard = DraggableAppCardView(frame: NSRect(x: pad, y: 70, width: innerW, height: 98))
        dragCard.onRevealInFinder = {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
        root.addSubview(dragCard)

        // 第 1 行：录屏与系统录音
        addPermissionRow(
            to: root,
            y: 184,
            width: innerW,
            pad: pad,
            title: "1. 录屏与系统录音（截图必选）",
            badgeField: screenBadge,
            buttonTitle: "打开录屏设置",
            action: #selector(openScreenRecordingSettings)
        )

        // 第 2 行：辅助功能
        addPermissionRow(
            to: root,
            y: 246,
            width: innerW,
            pad: pad,
            title: "2. 辅助功能（自动识别窗口内按钮 / 卡片）",
            badgeField: axBadge,
            buttonTitle: "打开辅助功能",
            action: #selector(openAccessibilitySettings)
        )

        let sep = NSBox(frame: NSRect(x: pad, y: 308, width: innerW, height: 1))
        sep.boxType = .separator
        root.addSubview(sep)

        let footHint = NSTextField(labelWithString: "提示：新开启「录屏」权限后，点右侧「重启生效」即可立即截屏")
        footHint.font = .systemFont(ofSize: 11, weight: .regular)
        footHint.textColor = .secondaryLabelColor
        footHint.frame = NSRect(x: pad, y: 327, width: 268, height: 16)
        root.addSubview(footHint)

        let relaunchBtn = NSButton(title: "重启生效", target: self, action: #selector(relaunchApp))
        relaunchBtn.bezelStyle = .rounded
        relaunchBtn.frame = NSRect(x: w - pad - 156, y: 320, width: 84, height: 28)
        root.addSubview(relaunchBtn)

        let doneBtn = NSButton(title: "完成", target: self, action: #selector(closeGuide))
        doneBtn.bezelStyle = .rounded
        doneBtn.keyEquivalent = "\r"
        doneBtn.frame = NSRect(x: w - pad - 66, y: 320, width: 66, height: 28)
        root.addSubview(doneBtn)

        self.panel = p
        return p
    }

    private func addPermissionRow(
        to container: NSView,
        y: CGFloat,
        width: CGFloat,
        pad: CGFloat,
        title: String,
        badgeField: NSTextField,
        buttonTitle: String,
        action: Selector
    ) {
        let rowBg = NSBox(frame: NSRect(x: pad, y: y, width: width, height: 52))
        rowBg.boxType = .custom
        rowBg.cornerRadius = 8
        rowBg.borderWidth = 1
        rowBg.borderColor = NSColor.separatorColor.withAlphaComponent(0.5)
        rowBg.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5)
        container.addSubview(rowBg)

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.textColor = .labelColor
        titleField.frame = NSRect(x: pad + 12, y: y + 8, width: width - 132, height: 18)
        container.addSubview(titleField)

        badgeField.font = .systemFont(ofSize: 11.5, weight: .semibold)
        badgeField.frame = NSRect(x: pad + 12, y: y + 28, width: width - 132, height: 16)
        container.addSubview(badgeField)

        let btn = NSButton(title: buttonTitle, target: self, action: action)
        btn.bezelStyle = .rounded
        btn.controlSize = .small
        btn.frame = NSRect(x: pad + width - 114, y: y + 13, width: 102, height: 26)
        container.addSubview(btn)
    }

    private func positionBesideSystemSettings(_ win: NSWindow) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // 停靠在屏幕偏左侧，给右侧弹出的「系统设置」留出充足并排拖拽空间
        let x = max(vf.minX + 44, vf.midX - win.frame.width - 110)
        let y = vf.midY - win.frame.height * 0.5 + 20
        win.setFrameOrigin(NSPoint(x: round(x), y: round(y)))
    }

    // MARK: - Live Polling & Actions

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

        screenBadge.stringValue = screenOK ? "✓ 已开启" : "● 待开启（点击右侧按钮并拖入上方图标）"
        screenBadge.textColor = screenOK ? .systemGreen : .systemOrange

        axBadge.stringValue = axOK ? "✓ 已开启（子控件识别实时生效）" : "○ 未开启（仅窗口+视觉识别，拖入可解锁深层控件）"
        axBadge.textColor = axOK ? .systemGreen : .secondaryLabelColor

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
