import AppKit
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

/// ChatGPT 风格的「系统设置」底部拖拽卡片主体视图（467 × 108）
final class SettingsAccessoryCardView: NSView {
    var onBackClicked: (() -> Void)? { didSet { backButton.onClick = onBackClicked } }
    var onCloseClicked: (() -> Void)? { didSet { closeButton.onClick = onCloseClicked } }
    var onDragStateChanged: ((Bool) -> Void)? { didSet { appRow.onDragStateChanged = onDragStateChanged } }

    private let effectView = NSVisualEffectView()
    private let borderOverlay = CardHairlineView()
    private let backButton = CircleIconButton(symbolName: "chevron.left", showRestingFill: true, toolTip: "返回权限列表")
    private let closeButton = CircleIconButton(symbolName: "xmark", showRestingFill: false, toolTip: "关闭提示")
    private let promptLabel = NSTextField(labelWithAttributedString: NSAttributedString())
    private let appRow = DraggableAppRowView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        effectView.frame = bounds
        effectView.autoresizingMask = [.width, .height]
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 13
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true
        addSubview(effectView)

        borderOverlay.frame = bounds
        borderOverlay.autoresizingMask = [.width, .height]
        addSubview(borderOverlay)

        promptLabel.translatesAutoresizingMaskIntoConstraints = false
        promptLabel.lineBreakMode = .byTruncatingTail

        effectView.addSubview(backButton)
        effectView.addSubview(promptLabel)
        effectView.addSubview(closeButton)
        effectView.addSubview(appRow)

        NSLayoutConstraint.activate([
            backButton.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 16),
            backButton.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 13),
            backButton.widthAnchor.constraint(equalToConstant: 24),
            backButton.heightAnchor.constraint(equalToConstant: 24),

            promptLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 10),
            promptLabel.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            promptLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),

            closeButton.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -13),
            closeButton.centerYAnchor.constraint(equalTo: backButton.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22),

            appRow.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 16),
            appRow.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -16),
            appRow.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -14),
            appRow.heightAnchor.constraint(equalToConstant: 44)
        ])

        setPane(.screenRecording)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setPane(_ pane: PermissionPane) {
        let permName = (pane == .screenRecording) ? "屏幕录制" : "辅助功能"
        let reg: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let bold: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        let str = NSMutableAttributedString(string: "将 ", attributes: reg)
        str.append(NSAttributedString(string: "MSnip", attributes: bold))
        str.append(NSAttributedString(string: " 拖到上方列表中以允许", attributes: reg))
        str.append(NSAttributedString(string: permName, attributes: bold))
        promptLabel.attributedStringValue = str
    }
}

private final class CardHairlineView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: 13, yRadius: 13)
        let stroke = isDark
            ? NSColor.white.withAlphaComponent(0.16)
            : NSColor(srgbRed: 0.84, green: 0.84, blue: 0.87, alpha: 0.95)
        stroke.setStroke()
        path.lineWidth = 1.0
        path.stroke()
    }
}

/// 复刻 ChatGPT `SystemSettingsAccessoryWindow` + `ArrowWindow`：
/// 自动吸附在「系统设置」右侧详情面板底部（录屏页精准停靠在「录屏与系统录音」列表正下方），配蓝白弹跳上指箭头。
@MainActor
final class SettingsDockOverlay {
    var onBackRequested: (() -> Void)?
    var onVisibilityChanged: ((Bool) -> Void)?

    private var panel: NSPanel?
    private var arrowPanel: NSPanel?
    private var cardView: SettingsAccessoryCardView?
    private var arrowView: HintArrowView?
    private var trackTimer: Timer?
    private var manuallyDismissed = false
    private(set) var activePane: PermissionPane = .screenRecording

    var isDockVisible: Bool { panel?.isVisible == true }

    func startTracking(for pane: PermissionPane) {
        activePane = pane
        manuallyDismissed = false
        ensurePanels()
        cardView?.setPane(pane)
        syncPosition()
        guard trackTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPosition() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackTimer = timer
    }

    func stopAndHide() {
        trackTimer?.invalidate()
        trackTimer = nil
        hidePanels()
    }

    private func ensurePanels() {
        guard panel == nil else { return }
        let size = NSSize(width: 467, height: 108)
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true

        let card = SettingsAccessoryCardView(frame: NSRect(origin: .zero, size: size))
        card.onBackClicked = { [weak self] in
            self?.manuallyDismissed = true
            self?.hidePanels()
            self?.onBackRequested?()
        }
        card.onCloseClicked = { [weak self] in
            self?.manuallyDismissed = true
            self?.hidePanels()
            self?.onBackRequested?()
        }
        card.onDragStateChanged = { [weak self] dragging in
            self?.arrowPanel?.animator().alphaValue = dragging ? 0.0 : 1.0
        }
        p.contentView = card

        let arrowSize = NSSize(width: 64, height: 56)
        let ap = NSPanel(
            contentRect: NSRect(origin: .zero, size: arrowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        ap.level = .floating
        ap.isFloatingPanel = true
        ap.hidesOnDeactivate = false
        ap.isReleasedWhenClosed = false
        ap.isOpaque = false
        ap.backgroundColor = .clear
        ap.hasShadow = false
        ap.ignoresMouseEvents = true

        let av = HintArrowView(frame: NSRect(origin: .zero, size: arrowSize))
        ap.contentView = av

        self.panel = p
        self.arrowPanel = ap
        self.cardView = card
        self.arrowView = av
    }

    private func hidePanels() {
        let wasVisible = panel?.isVisible == true
        if let p = panel, let ap = arrowPanel, p.childWindows?.contains(ap) == true {
            p.removeChildWindow(ap)
        }
        arrowPanel?.orderOut(nil)
        panel?.orderOut(nil)
        if wasVisible { onVisibilityChanged?(false) }
    }

    private func syncPosition() {
        guard !manuallyDismissed, let panel, let arrowPanel else { return }
        guard let origin = locateSystemSettingsDockOrigin(barSize: panel.frame.size) else {
            hidePanels()
            return
        }
        let arrowOrigin = NSPoint(x: origin.x + 42 - 32, y: origin.y + panel.frame.height - 14)
        if panel.frame.origin != origin {
            panel.setFrameOrigin(origin)
            arrowPanel.setFrameOrigin(arrowOrigin)
        }
        if !panel.isVisible {
            arrowPanel.setFrameOrigin(arrowOrigin)
            panel.orderFrontRegardless()
            if panel.childWindows?.contains(arrowPanel) != true {
                panel.addChildWindow(arrowPanel, ordered: .above)
            }
            arrowView?.startBounceAnimation()
            onVisibilityChanged?(true)
        }
    }

    private func locateSystemSettingsDockOrigin(barSize: NSSize) -> NSPoint? {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        guard primaryH > 0 else { return nil }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let rawList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

        var occludersAbove: [CGRect] = []
        for entry in rawList {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != selfPID,
                  (entry[kCGWindowLayer as String] as? Int ?? -1) == 0,
                  let dict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let cgBounds = CGRect(dictionaryRepresentation: dict),
                  cgBounds.width >= 200, cgBounds.height >= 150 else { continue }

            let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
            if (owner == "系统设置" || owner == "System Settings" || owner == "System Preferences"),
               cgBounds.width >= 480, cgBounds.height >= 360 {
                let barX = cgBounds.width >= 660 ? (cgBounds.maxX - barSize.width - 20) : (cgBounds.midX - barSize.width * 0.5)
                let topQuartzY: CGFloat
                switch activePane {
                case .screenRecording:
                    // 停靠在上方「录屏与系统录音」列表正下方，完整遮住易混淆的「仅系统录音」区域
                    topQuartzY = min(cgBounds.maxY - barSize.height - 14, max(cgBounds.minY + 340, cgBounds.minY + 471))
                case .accessibility:
                    topQuartzY = cgBounds.maxY - barSize.height - 14
                }
                let barQuartzRect = CGRect(x: barX, y: topQuartzY, width: barSize.width, height: barSize.height)
                if occludersAbove.contains(where: { !$0.intersection(barQuartzRect).isNull }) { return nil }
                return NSPoint(x: round(barX), y: round(primaryH - barQuartzRect.maxY))
            }
            occludersAbove.append(cgBounds)
        }
        return nil
    }
}
