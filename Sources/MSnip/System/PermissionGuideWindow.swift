import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MSnipCore

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
                self.prefersAccessoryMode = false
                self.settingsDock.stopAndHide()
                self.presentChecklistWindow()
            }
        }
    }

    func show(opening pane: PermissionPane? = nil) {
        isSessionActive = true
        _ = ensureWindow()
        lastScreenGranted = ScreenCapturer.runtimeVerifiedAccess || CGPreflightScreenCaptureAccess()
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
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        p.title = L("开启 MSnip 权限"); p.titleVisibility = .hidden; p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.level = .floating; p.isFloatingPanel = true; p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false; p.backgroundColor = .clear; p.delegate = self

        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        root.material = .popover; root.blendingMode = .behindWindow; root.state = .active
        p.contentView = root

        let header = buildHeaderView()
        screenRow = PermissionRowView(kind: .screenRecording, title: L("屏幕录制"), subtitle: L("捕获屏幕画面与像素级放大取色")) { [weak self] in self?.openPane(.screenRecording) }
        axRow = PermissionRowView(kind: .accessibility, title: L("辅助功能"), subtitle: L("智能识别窗口与多层控件矩阵边界")) { [weak self] in self?.openPane(.accessibility) }
        relaunchPill = PillControl(title: L("重启生效"), style: .subtleButton) { [weak self] in self?.relaunchApp() }
        donePill = PillControl(title: L("完成"), style: .subtleButton) { [weak self] in self?.closeAll() }
        [header, screenRow, axRow, relaunchPill, donePill].forEach { root.addSubview($0) }

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
        let container = NSView(); container.translatesAutoresizingMaskIntoConstraints = false
        let iconView = NSImageView(); iconView.translatesAutoresizingMaskIntoConstraints = false
        let icon = (NSApp.applicationIconImage?.copy() as? NSImage) ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        icon.size = NSSize(width: 34, height: 34); iconView.image = icon

        let title = NSTextField(labelWithString: L("开启 MSnip 权限"))
        title.font = .systemFont(ofSize: 14.5, weight: .semibold); title.textColor = .labelColor
        let sub = NSTextField(labelWithString: L("点击允许后，从系统设置底部将图标拖入列表"))
        sub.font = .systemFont(ofSize: 11.5, weight: .regular); sub.textColor = .secondaryLabelColor
        // 较长译文截断而不是撑宽固定 342pt 的面板（完整文案见提示）
        sub.lineBreakMode = .byTruncatingTail; sub.toolTip = sub.stringValue
        sub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [title, sub])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 1.5
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(iconView); container.addSubview(stack)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 34), iconView.heightAnchor.constraint(equalToConstant: 34),
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
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshStatus() }
        }
    }

    private func refreshStatus() async {
        let screenOK = await ScreenCapturer.hasScreenCapturePermission()
        let axOK = AXIsProcessTrusted()
        let changed = (screenOK != lastScreenGranted || axOK != lastAXGranted)
        lastScreenGranted = screenOK
        lastAXGranted = axOK
        updateUI(screenOK: screenOK, axOK: axOK)

        if changed {
            // 引导窗每秒轮询一次，只在状态变化时记录，避免刷屏
            MSnipLog.info(.permission, "Permission state: screenRecording=\(screenOK ? "granted" : "missing") accessibility=\(axOK ? "granted" : "missing")")
            onPermissionChanged?()
            if screenOK && axOK {
                closeAll()
                ToastHUD.show(message: L("✓ 屏幕录制与辅助功能权限均已生效"))
                return
            }
            let completedActivePane = settingsDock.isDockVisible && (
                (settingsDock.activePane == .screenRecording && screenOK) ||
                (settingsDock.activePane == .accessibility && axOK)
            )
            if completedActivePane {
                prefersAccessoryMode = false
                settingsDock.stopAndHide()
                presentChecklistWindow()
            }
        }
    }

    private func updateUI(screenOK: Bool, axOK: Bool) {
        screenRow.actionPill.title = screenOK ? L("✓ 已开启") : L("允许")
        screenRow.actionPill.style = screenOK ? .grantedBadge : .primaryButton

        axRow.actionPill.title = axOK ? L("✓ 已开启") : L("允许")
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
            self.prefersAccessoryMode = false
            self.settingsDock.stopAndHide()
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
        MSnipRelauncher.relaunch()
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
        if !(prefersAccessoryMode && settingsDock.isDockVisible) {
            isSessionActive = false
            prefersAccessoryMode = false
            pollTimer?.invalidate()
            pollTimer = nil
            settingsDock.stopAndHide()
        }
    }
}

// MARK: - 权限引导行与状态徽章控件

/// 零外边距的圆角胶囊按钮与状态签（消除原生 NSButton 隐形边距导致的错位）
private final class PillControl: NSView {
    enum Style {
        case subtleButton
        case primaryButton
        case grantedBadge
    }

    var title: String { didSet { labelField.stringValue = title; refreshAppearance() } }
    var style: Style { didSet { updateTrackingAreas(); refreshAppearance() } }
    var onClick: (() -> Void)?

    private let labelField = NSTextField(labelWithString: "")
    private var isHovered = false { didSet { if oldValue != isHovered { refreshAppearance() } } }
    private var isPressed = false { didSet { if oldValue != isPressed { refreshAppearance() } } }

    init(title: String, style: Style, onClick: (() -> Void)? = nil) {
        self.title = title
        self.style = style
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        labelField.stringValue = title
        labelField.alignment = .center
        labelField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelField)

        NSLayoutConstraint.activate([
            labelField.centerXAnchor.constraint(equalTo: centerXAnchor),
            labelField.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5)
        ])
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        guard style != .grantedBadge else { isHovered = false; isPressed = false; return }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; isPressed = false }
    override func mouseDown(with event: NSEvent) {
        guard style != .grantedBadge else { return }
        isPressed = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    private func refreshAppearance() {
        labelField.font = .systemFont(ofSize: 12, weight: style == .primaryButton ? .semibold : .medium)
        switch style {
        case .subtleButton:
            labelField.textColor = .labelColor
        case .primaryButton:
            labelField.textColor = .white
        case .grantedBadge:
            labelField.textColor = .systemGreen
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7)
        let bgColor: NSColor
        switch style {
        case .subtleButton:
            let alpha: CGFloat = isPressed ? 0.20 : (isHovered ? 0.14 : 0.09)
            bgColor = NSColor.labelColor.withAlphaComponent(alpha)
        case .primaryButton:
            let base = NSColor.controlAccentColor
            bgColor = isPressed ? (base.blended(withFraction: 0.18, of: .black) ?? base)
                : (isHovered ? (base.blended(withFraction: 0.10, of: .white) ?? base) : base)
        case .grantedBadge:
            bgColor = NSColor.systemGreen.withAlphaComponent(0.15)
        }
        bgColor.setFill()
        path.fill()
    }
}

/// 圆形返回 / 关闭图标小按钮（纯 Auto Layout + NSImageView 矢量着色，零上下文污染）
final class CircleIconButton: NSView {
    private let showRestingFill: Bool
    private let iconView = NSImageView()
    var onClick: (() -> Void)?

    private var isHovered = false { didSet { if oldValue != isHovered { syncTint(); needsDisplay = true } } }
    private var isPressed = false { didSet { if oldValue != isPressed { needsDisplay = true } } }

    init(symbolName: String, showRestingFill: Bool = true, toolTip: String? = nil, onClick: (() -> Void)? = nil) {
        self.showRestingFill = showRestingFill
        self.onClick = onClick
        super.init(frame: .zero)
        self.toolTip = toolTip
        translatesAutoresizingMaskIntoConstraints = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        addSubview(iconView)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        syncTint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; isPressed = false }
    override func mouseDown(with event: NSEvent) { isPressed = true }
    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    private func syncTint() {
        iconView.contentTintColor = isHovered ? .labelColor : .secondaryLabelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isPressed ? 0.18 : (isHovered ? 0.13 : (showRestingFill ? 0.08 : 0.0))
        if alpha > 0 {
            NSColor.labelColor.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
    }
}

/// 权限类型图标徽章（复刻 ChatGPT SkyPermissions 的屏幕录制取景框与辅助功能蓝圆徽章）
private final class PermissionBadgeView: NSView {
    enum Kind {
        case screenRecording
        case accessibility
    }

    private let kind: Kind
    private let symbolView = NSImageView()

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        symbolView.translatesAutoresizingMaskIntoConstraints = false
        switch kind {
        case .screenRecording:
            symbolView.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
            symbolView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15.5, weight: .medium)
            symbolView.contentTintColor = .labelColor
        case .accessibility:
            symbolView.image = MSnipUITheme.systemSymbol("figure.arms.open")
            symbolView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
            symbolView.contentTintColor = .white
        }
        addSubview(symbolView)

        NSLayoutConstraint.activate([
            symbolView.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        switch kind {
        case .screenRecording:
            let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7.5, yRadius: 7.5)
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            bg.fill()
        case .accessibility:
            let circleRect = bounds.insetBy(dx: 1.5, dy: 1.5)
            let grad = NSGradient(
                starting: NSColor(srgbRed: 0.14, green: 0.62, blue: 1.0, alpha: 1.0),
                ending: NSColor(srgbRed: 0.0, green: 0.45, blue: 0.96, alpha: 1.0)
            )
            grad?.draw(in: NSBezierPath(ovalIn: circleRect), angle: -90)
            NSColor.white.withAlphaComponent(0.88).setStroke()
            let ring = NSBezierPath(ovalIn: circleRect.insetBy(dx: 2.0, dy: 2.0))
            ring.lineWidth = 1.1
            ring.stroke()
        }
    }
}

/// ChatGPT 风格的独立圆角权限条目卡片（左图标 + 双行说明 + 右侧胶囊按钮）
private final class PermissionRowView: NSView {
    let actionPill: PillControl

    init(kind: PermissionBadgeView.Kind, title: String, subtitle: String, onAction: @escaping () -> Void) {
        self.actionPill = PillControl(title: L("允许"), style: .primaryButton, onClick: onAction)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let badge = PermissionBadgeView(kind: kind)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor

        let subLabel = NSTextField(labelWithString: subtitle)
        subLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subLabel.textColor = .secondaryLabelColor
        subLabel.lineBreakMode = .byTruncatingTail; subLabel.toolTip = subtitle
        subLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [titleLabel, subLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1.5
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(badge)
        addSubview(textStack)
        addSubview(actionPill)

        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 30),
            badge.heightAnchor.constraint(equalToConstant: 30),

            textStack.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: actionPill.leadingAnchor, constant: -8),

            actionPill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            actionPill.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionPill.widthAnchor.constraint(equalToConstant: 66),
            actionPill.heightAnchor.constraint(equalToConstant: 25)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
        (isDark ? NSColor.white.withAlphaComponent(0.05) : NSColor.black.withAlphaComponent(0.025)).setFill()
        path.fill()
        (isDark ? NSColor.white.withAlphaComponent(0.11) : NSColor.black.withAlphaComponent(0.09)).setStroke()
        path.lineWidth = 1.0
        path.stroke()
    }
}

#if DEBUG
extension PermissionGuideController {
    /// 仅 Debug：离屏渲染权限引导面板（未授权 / 已授权两种状态），不显示窗口、不轮询权限
    func debugRender(to dir: URL, suffix: String) {
        let p = ensureWindow()
        p.delegate = nil
        guard let root = p.contentView else { return }
        updateUI(screenOK: false, axOK: false)
        DebugSettingsSnapshot.writePNG(root, named: "\(suffix)-perm-missing", to: dir, background: .windowBackgroundColor)
        updateUI(screenOK: true, axOK: false)
        DebugSettingsSnapshot.writePNG(root, named: "\(suffix)-perm-partial", to: dir, background: .windowBackgroundColor)
    }
}
#endif

/// 退出当前进程并在 0.35 秒后由 `open` 重新拉起本应用（授权生效、切换界面语言等需要重启的场景共用）
@MainActor
enum MSnipRelauncher {
    static func relaunch() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "sleep 0.35 && open \"$1\"", "--", Bundle.main.bundlePath]
        try? proc.run()
        NSApp.terminate(nil)
    }
}
