import AppKit
import Foundation
import MSnipCore

/// 极客简约单页设置窗口（Carbon Dark HUD 风格，合并常规/热键/权限与翻译 API 于 640×488 紧凑双页）
@MainActor
final class TranslationSettingsWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum SettingsTab: Int, CaseIterable {
        case general = 0
        case translation = 1

        var title: String {
            switch self {
            case .general:     return "常规"
            case .translation: return "翻译 API"
            }
        }
    }

    enum HotKeySlot: Int, CaseIterable {
        case capture = 0
        case pin = 1
        case ocr = 2

        var title: String {
            switch self {
            case .capture: return "区域截图"
            case .pin:     return "桌面贴图"
            case .ocr:     return "快捷识字"
            }
        }

        var subtitle: String {
            switch self {
            case .capture: return "截图、标注、长截图与录屏"
            case .pin:     return "将剪贴板图像钉在屏幕最前"
            case .ocr:     return "框选区域直接识别并提取文字"
            }
        }
    }

    var onAppConfigMutated: (((inout AppConfig) -> Void) -> Void)?
    var appConfigProvider: (() -> AppConfig)?
    var onBeginHotKeyRecording: (() -> Void)?
    var onEndHotKeyRecording: (() -> Void)?
    var onOpenHotKeyRecorder: (() -> Void)?
    var onOpenPermissionGuide: (() -> Void)?

    var window: GeekSettingsWindowPanel?
    var activeTab: SettingsTab = .general
    var tabSegment: GeekSegmentControl!
    var generalPage: GeekFlippedView!
    var translationPage: GeekFlippedView!

    // 常规页控件引用（含行内快捷键录制、偏好与权限状态）
    var activeRecordingSlot: HotKeySlot?
    var hotKeyEnableSwitch: GeekToggleSwitch!
    var presetDropdown: GeekDropdownPill!
    var hotKeyHintLabel: NSTextField!
    var hotKeyPills: [HotKeySlot: GeekHotKeyPill] = [:]
    var loginSwitch: GeekToggleSwitch!
    var tipsSwitch: GeekToggleSwitch!
    var colorFmtSegment: GeekSegmentControl!
    var recFmtSegment: GeekSegmentControl!
    var saveDirPathLabel: NSTextField!
    var screenPermRow: GeekDotLabel!
    var axPermRow: GeekDotLabel!
    var screenPermBtn: GeekButton!
    var axPermBtn: GeekButton!

    // 翻译页状态与控件引用
    var draft: TranslationSettingsConfig = TranslationSettingsConfig.load()
    var selectedIndex: Int = 0
    var isAPIKeyRevealed = false
    var targetLangPill: GeekDropdownPill!
    var primaryEnginePill: GeekDropdownPill!
    var fallbackEnginePill: GeekDropdownPill!
    var autoCopySwitch: GeekToggleSwitch!

    var tableView: NSTableView!
    var addBtn: GeekButton!
    var removeBtn: GeekButton!

    var detailContainer: GeekCardView!
    var nameField: NSTextField!
    var enabledSwitch: GeekToggleSwitch!
    var setDefaultBtn: GeekButton!
    var kindPill: GeekDropdownPill!
    var presetRowView: GeekFlippedView!
    var llmPresetPill: GeekDropdownPill!
    var nativeCardBox: GeekFlippedView!
    var nativeInfoLabel: NSTextField!

    var appIdRow: GeekFlippedView!
    var appIdLabel: NSTextField!
    var appIdField: NSTextField!
    var endpointRow: GeekFlippedView!
    var endpointLabel: NSTextField!
    var endpointField: NSTextField!
    var apiKeyRow: GeekFlippedView!
    var apiKeyLabel: NSTextField!
    var apiKeySecureBox: GeekInputBox!
    var apiKeyPlainBox: GeekInputBox!
    var apiKeySecureField: NSSecureTextField!
    var apiKeyPlainField: NSTextField!
    var eyeToggleBtn: GeekButton!
    var modelRow: GeekFlippedView!
    var modelLabel: NSTextField!
    var modelField: NSTextField!
    var extra1Row: GeekFlippedView!
    var extraLabel1: NSTextField!
    var extraField1: NSTextField!
    var extra2Row: GeekFlippedView!
    var extraLabel2: NSTextField!
    var extraField2: NSTextField!
    var testBtn: GeekButton!
    var testStatusLabel: NSTextField!

    func show(tab: SettingsTab = .general) {
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
        cancelInlineHotKeyRecording(restoreHotKeys: false)
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
        let W: CGFloat = 640, H: CGFloat = 488
        let win = GeekSettingsWindowPanel(
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
        win.animationBehavior = .none
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
        win.appearance = NSAppearance(named: .darkAqua)
        win.backgroundColor = GeekTheme.windowBg
        win.level = .floating
        win.delegate = self
        win.onKeyDownIntercept = { [weak self] ev in
            self?.handleInlineHotKeyEvent(ev) ?? false
        }

        let root = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        root.wantsLayer = true
        root.layer?.backgroundColor = GeekTheme.windowBg.cgColor
        win.contentView = root

        buildTopBar(in: root, width: W)
        let bodyFrame = NSRect(x: 0, y: 52, width: W, height: H - 90)
        generalPage = GeekFlippedView(frame: bodyFrame)
        translationPage = GeekFlippedView(frame: bodyFrame)
        root.addSubview(generalPage)
        root.addSubview(translationPage)

        buildGeneralPage(in: generalPage)
        buildTranslationPage(in: translationPage)
        buildFooterBar(in: root, width: W, y: H - 38)
        self.window = win
    }

    private func buildTopBar(in root: GeekFlippedView, width W: CGFloat) {
        let bar = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: W, height: 52))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = GeekTheme.barBg.cgColor
        root.addSubview(bar)

        let brand = NSTextField(labelWithString: "MSnip")
        brand.font = .systemFont(ofSize: 13.5, weight: .bold)
        brand.textColor = GeekTheme.inkPrimary
        brand.frame = NSRect(x: 42, y: 17, width: 52, height: 18)
        bar.addSubview(brand)

        let ver = NSTextField(labelWithString: "v1.4.3")
        ver.font = .monospacedSystemFont(ofSize: 10.5, weight: .medium)
        ver.textColor = GeekTheme.inkMuted
        ver.frame = NSRect(x: 94, y: 19, width: 48, height: 15)
        bar.addSubview(ver)

        tabSegment = GeekSegmentControl(items: SettingsTab.allCases.map(\.title), selectedIndex: 0)
        tabSegment.frame = NSRect(x: round((W - 208) * 0.5), y: 11, width: 208, height: 30)
        tabSegment.onSelect = { [weak self] idx in
            guard let tab = SettingsTab(rawValue: idx) else { return }
            self?.switchTab(tab)
        }
        bar.addSubview(tabSegment)

        let sep = NSView(frame: NSRect(x: 0, y: 51, width: W, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = GeekTheme.border.cgColor
        bar.addSubview(sep)
    }

    private func buildFooterBar(in root: GeekFlippedView, width W: CGFloat, y: CGFloat) {
        let foot = GeekFlippedView(frame: NSRect(x: 0, y: y, width: W, height: 38))
        foot.wantsLayer = true
        foot.layer?.backgroundColor = GeekTheme.barBg.cgColor
        root.addSubview(foot)

        let sep = NSView(frame: NSRect(x: 0, y: 0, width: W, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = GeekTheme.border.cgColor
        foot.addSubview(sep)

        let cfgBtn = GeekButton(title: "config.json", symbol: "doc.text", style: .ghost, mono: true)
        cfgBtn.toolTip = "在 Finder 中显示通用配置文件"
        cfgBtn.frame = NSRect(x: 16, y: 7, width: 98, height: 24)
        cfgBtn.onClick = { [weak self] in self?.revealAppConfigJSON() }
        foot.addSubview(cfgBtn)

        let provBtn = GeekButton(title: "providers.json", symbol: "key", style: .ghost, mono: true)
        provBtn.toolTip = "在 Finder 中显示翻译 API 配置文件（0600 权限）"
        provBtn.frame = NSRect(x: 118, y: 7, width: 116, height: 24)
        provBtn.onClick = { [weak self] in self?.revealJSONConfig() }
        foot.addSubview(provBtn)

        let tip = NSTextField(labelWithString: "自动保存 · ⌘W 关闭")
        tip.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        tip.textColor = GeekTheme.inkMuted
        tip.alignment = .right
        tip.frame = NSRect(x: W - 234, y: 12, width: 146, height: 15)
        foot.addSubview(tip)

        let doneBtn = GeekButton(title: "完成", style: .primaryLight)
        doneBtn.frame = NSRect(x: W - 78, y: 7, width: 62, height: 24)
        doneBtn.onClick = { [weak self] in self?.onSaveAndClose() }
        foot.addSubview(doneBtn)
    }

    func switchTab(_ tab: SettingsTab) {
        cancelInlineHotKeyRecording(restoreHotKeys: true)
        commitCurrentFormEdits()
        persistDraft()
        activeTab = tab
        tabSegment.selectedIndex = tab.rawValue
        generalPage.isHidden = (tab != .general)
        translationPage.isHidden = (tab != .translation)
        if tab == .general { refreshGeneralAndPermissionsUI() }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { draft.profiles.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard draft.profiles.indices.contains(row) else { return nil }
        let p = draft.profiles[row]
        let isPrimary = (p.id == draft.activeProfileID)
        let dotColor: NSColor = !p.isEnabled
            ? GeekTheme.inkMuted
            : (isPrimary ? GeekTheme.emerald : (p.isConfiguredReady ? GeekTheme.accent : GeekTheme.amber))
        return ProviderRowCellView(title: p.name, isPrimary: isPrimary, isSelected: row == selectedIndex, dotColor: dotColor)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row != selectedIndex, draft.profiles.indices.contains(row) else { return }
        commitCurrentFormEdits()
        selectedIndex = row
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        loadSelectedProfileIntoForm()
    }

    func windowWillClose(_ notification: Notification) {
        cancelInlineHotKeyRecording(restoreHotKeys: true)
        commitCurrentFormEdits()
        persistDraft()
    }

    func persistDraft() {
        TranslationService.shared.updateSettings { $0 = self.draft }
    }
}
