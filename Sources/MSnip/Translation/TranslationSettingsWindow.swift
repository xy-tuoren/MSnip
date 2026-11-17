import AppKit
import Foundation
import MSnipCore

/// 统一「MSnip 偏好与翻译 API 设置中心」（Daylight Porcelain 现代无边框侧边栏卡片式窗口）
@MainActor
final class TranslationSettingsWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum SettingsTab: Int, CaseIterable {
        case translation = 0
        case general = 1
        case permissions = 2

        var title: String {
            switch self {
            case .translation: return "翻译与大模型"
            case .general:     return "热键与偏好"
            case .permissions: return "权限与签名"
            }
        }

        var symbol: String {
            switch self {
            case .translation: return "character.bubble"
            case .general:     return "keyboard"
            case .permissions: return "checkmark.shield"
            }
        }
    }

    var onAppConfigMutated: (((inout AppConfig) -> Void) -> Void)?
    var appConfigProvider: (() -> AppConfig)?
    var onOpenHotKeyRecorder: (() -> Void)?
    var onOpenPermissionGuide: (() -> Void)?

    var window: NSWindow?
    var activeTab: SettingsTab = .translation
    var navButtons: [SettingsNavItemView] = []
    var translationPage: NSView!
    var generalPage: NSView!
    var permissionsPage: NSView!

    var draft: TranslationSettingsConfig = TranslationSettingsConfig.load()
    var selectedIndex: Int = 0
    var isAPIKeyRevealed = false

    // 翻译页顶栏胶囊选择器
    var targetLangPill: LightDropdownPill!
    var primaryEnginePill: LightDropdownPill!
    var fallbackEnginePill: LightDropdownPill!

    // 左栏服务卡片列表
    var tableView: NSTableView!
    var addBtn: OCRPillButton!
    var removeBtn: OCRPillButton!

    // 右栏动态协议表单引用
    var detailContainer: NSView!
    var nameField: NSTextField!
    var enabledCheck: NSButton!
    var kindPill: LightDropdownPill!
    var presetRowView: NSView!
    var llmPresetPill: LightDropdownPill!
    var nativeCardBox: NSView!
    var nativeInfoLabel: NSTextField!
    var appIdLabel: NSTextField!
    var appIdField: NSTextField!
    var endpointLabel: NSTextField!
    var endpointField: NSTextField!
    var apiKeyLabel: NSTextField!
    var apiKeySecureField: NSSecureTextField!
    var apiKeyPlainField: NSTextField!
    var eyeToggleBtn: OCRPillButton!
    var modelLabel: NSTextField!
    var modelField: NSTextField!
    var extraLabel1: NSTextField!
    var extraField1: NSTextField!
    var extraLabel2: NSTextField!
    var extraField2: NSTextField!
    var testStatusLabel: NSTextField!
    var testBtn: OCRPillButton!

    // 通用偏好与权限页动态引用
    var presetDropdown: LightDropdownPill!
    var colorFmtDropdown: LightDropdownPill!
    var tipsToggle: NSButton!
    var autoCopyToggle: NSButton!
    var loginToggle: NSButton!
    var hotKeySummaryLabel: NSTextField!
    var permStatusLabel: NSTextField!

    func show(tab: SettingsTab = .translation) {
        draft = TranslationService.shared.settings
        if draft.profiles.isEmpty {
            draft.profiles = TranslationSettingsConfig.defaultStarterProfiles()
        }
        if let activeID = draft.activeProfileID,
           let idx = draft.profiles.firstIndex(where: { $0.id == activeID }) {
            selectedIndex = idx
        } else {
            selectedIndex = 0
        }

        ensureWindowBuilt()
        refreshTopBarPopups()
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        loadSelectedProfileIntoForm()
        refreshGeneralAndPermissionsUI()
        switchTab(tab)

        NSApp.activate(ignoringOtherApps: true)
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }

    private func ensureWindowBuilt() {
        if window != nil { return }
        let W: CGFloat = 860, H: CGFloat = 556
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: W, height: H),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = ""
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.appearance = NSAppearance(named: .aqua)
        win.backgroundColor = MSnipUITheme.canvasBg
        win.level = .floating
        win.delegate = self

        let root = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        root.wantsLayer = true
        root.layer?.backgroundColor = MSnipUITheme.canvasBg.cgColor
        win.contentView = root

        buildSidebarRail(in: root, height: H)
        let contentFrame = NSRect(x: 186, y: 0, width: W - 186, height: H)
        translationPage = NSView(frame: contentFrame)
        generalPage = NSView(frame: contentFrame)
        permissionsPage = NSView(frame: contentFrame)
        root.addSubview(translationPage)
        root.addSubview(generalPage)
        root.addSubview(permissionsPage)

        buildTranslationPage(in: translationPage)
        buildGeneralAndPermissionsPages()
        self.window = win
    }

    private func buildSidebarRail(in root: NSView, height H: CGFloat) {
        let rail = NSView(frame: NSRect(x: 0, y: 0, width: 186, height: H))
        rail.wantsLayer = true
        rail.layer?.backgroundColor = MSnipUITheme.sidebarBg.cgColor
        root.addSubview(rail)

        let sep = NSView(frame: NSRect(x: 185, y: 0, width: 1, height: H))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = MSnipUITheme.borderHairline.cgColor
        root.addSubview(sep)

        let brand = NSTextField(labelWithString: "MSnip 设置中心")
        brand.font = .systemFont(ofSize: 13.5, weight: .bold)
        brand.textColor = MSnipUITheme.inkPrimary
        brand.frame = NSRect(x: 18, y: H - 68, width: 150, height: 20)
        rail.addSubview(brand)

        var y = H - 114
        for tab in SettingsTab.allCases {
            let btn = SettingsNavItemView(title: tab.title, symbol: tab.symbol)
            btn.frame = NSRect(x: 12, y: y, width: 162, height: 36)
            btn.onClick = { [weak self] in self?.switchTab(tab) }
            rail.addSubview(btn)
            navButtons.append(btn)
            y -= 42
        }
    }

    func switchTab(_ tab: SettingsTab) {
        commitCurrentFormEdits()
        persistDraft()
        activeTab = tab
        for (i, b) in navButtons.enumerated() { b.isActive = (i == tab.rawValue) }
        translationPage.isHidden = (tab != .translation)
        generalPage.isHidden = (tab != .general)
        permissionsPage.isHidden = (tab != .permissions)
        if tab != .translation { refreshGeneralAndPermissionsUI() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { draft.profiles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard draft.profiles.indices.contains(row) else { return nil }
        let p = draft.profiles[row]
        let isPrimary = (p.id == draft.activeProfileID)
        let dotColor: NSColor = !p.isEnabled
            ? MSnipUITheme.inkMuted
            : (isPrimary ? MSnipUITheme.success : (p.isConfiguredReady ? MSnipUITheme.accent : MSnipUITheme.warning))
        return ProviderRowCellView(title: p.name, isPrimary: isPrimary, dotColor: dotColor)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row != selectedIndex, draft.profiles.indices.contains(row) else { return }
        commitCurrentFormEdits()
        selectedIndex = row
        loadSelectedProfileIntoForm()
    }

    func windowWillClose(_ notification: Notification) {
        commitCurrentFormEdits()
        persistDraft()
    }

    func persistDraft() {
        TranslationService.shared.updateSettings { $0 = self.draft }
    }
}

/// 侧边栏矢量图标导航项（零 Emoji，支持悬停与白色选中卡片高亮）
final class SettingsNavItemView: NSView {
    let title: String
    let symbol: String
    var isActive = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    init(title: String, symbol: String) {
        self.title = title; self.symbol = symbol
        super.init(frame: .zero)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if isActive || hovered {
            let p = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 8, cornerHeight: 8, transform: nil)
            ctx.setFillColor((isActive ? MSnipUITheme.cardSolid : MSnipUITheme.hoverFill).cgColor)
            ctx.addPath(p); ctx.fillPath()
            if isActive {
                ctx.setStrokeColor(MSnipUITheme.borderHairline.cgColor)
                ctx.setLineWidth(1.0); ctx.addPath(p); ctx.strokePath()
            }
        }
        let fg = isActive ? MSnipUITheme.accent : MSnipUITheme.inkPrimary
        ToolbarView.drawSymbol(symbol, in: CGRect(x: 10, y: 0, width: 18, height: bounds.height), alpha: 0.95, tint: fg)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: isActive ? .semibold : .medium),
            .foregroundColor: isActive ? MSnipUITheme.inkPrimary : MSnipUITheme.inkSecondary
        ]
        let sz = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: CGPoint(x: 34, y: round((bounds.height - sz.height) * 0.5)), withAttributes: attrs)
    }
}
