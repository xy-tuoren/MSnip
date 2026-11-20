import AppKit
import Foundation
import MSnipCore

/// 极客简约 3 标签设置窗口（720×560 Carbon Dark HUD，高可读字阶、宽敞留白、实时自动保存）
@MainActor
final class TranslationSettingsWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum SettingsTab: Int, CaseIterable {
        case general = 0, shortcuts = 1, translation = 2
        var title: String {
            switch self {
            case .general: return "通用"
            case .shortcuts: return "快捷键"
            case .translation: return "翻译"
            }
        }
    }

    enum HotKeySlot: Int, CaseIterable {
        case capture = 0, pin = 1, ocr = 2
        var title: String { self == .capture ? "区域截图" : (self == .pin ? "桌面贴图" : "快捷识字") }
        var subtitle: String {
            switch self {
            case .capture: return "截屏、标注、滚动长截图与录屏"
            case .pin:     return "将剪贴板图片钉在屏幕最前方"
            case .ocr:     return "框选任意区域直接提取文字"
            }
        }
        var symbol: String { self == .capture ? "viewfinder" : (self == .pin ? "pin" : "text.viewfinder") }
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
    var shortcutsPage: GeekFlippedView!
    var translationPage: GeekFlippedView!

    // 通用页控件
    var loginSwitch: GeekToggleSwitch!
    var tipsSwitch: GeekToggleSwitch!
    var colorFmtSegment: GeekSegmentControl!
    var recFmtSegment: GeekSegmentControl!
    var saveDirPathLabel: NSTextField!
    var screenPermRow: GeekDotLabel!
    var axPermRow: GeekDotLabel!
    var screenPermBtn: GeekButton!
    var axPermBtn: GeekButton!

    // 快捷键页控件
    var activeRecordingSlot: HotKeySlot?
    var hotKeyEnableSwitch: GeekToggleSwitch!
    var presetSegment: GeekSegmentControl!
    var hotKeyHintLabel: NSTextField!
    var hotKeyPills: [HotKeySlot: GeekHotKeyPill] = [:]

    // 翻译页状态与控件
    var draft: TranslationSettingsConfig = TranslationSettingsConfig.load()
    var selectedIndex: Int = 0
    var isAPIKeyRevealed = false
    var isAdvancedExpanded = false
    var targetLangPill: GeekDropdownPill!
    var autoCopySwitch: GeekToggleSwitch!

    var tableView: NSTableView!
    var addBtn: GeekButton!
    var removeBtn: GeekButton!

    var detailContainer: GeekCardView!
    var detailHeaderTitle: NSTextField!
    var setDefaultBtn: GeekButton!
    var formScrollView: NSScrollView!
    var formContentView: GeekFlippedView!
    var nameField: NSTextField!
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
    var advancedToggleBtn: GeekButton!
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
        let W: CGFloat = 720, H: CGFloat = 560
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
        let bodyFrame = NSRect(x: 0, y: 56, width: W, height: H - 96)
        generalPage = GeekFlippedView(frame: bodyFrame)
        shortcutsPage = GeekFlippedView(frame: bodyFrame)
        translationPage = GeekFlippedView(frame: bodyFrame)
        root.addSubview(generalPage)
        root.addSubview(shortcutsPage)
        root.addSubview(translationPage)

        buildGeneralPage(in: generalPage)
        buildShortcutsPage(in: shortcutsPage)
        buildTranslationPage(in: translationPage)
        buildFooterBar(in: root, width: W, y: H - 40)
        self.window = win
    }

    private func buildTopBar(in root: GeekFlippedView, width W: CGFloat) {
        let bar = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: W, height: 56))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = GeekTheme.barBg.cgColor
        root.addSubview(bar)

        let brand = NSTextField(labelWithString: "MSnip")
        brand.font = .systemFont(ofSize: 15.0, weight: .bold)
        brand.textColor = GeekTheme.inkPrimary
        brand.frame = NSRect(x: 42, y: 18, width: 58, height: 20)
        bar.addSubview(brand)

        let appVer = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.2.1"
        let ver = NSTextField(labelWithString: "v\(appVer)")
        ver.font = .monospacedSystemFont(ofSize: 12.0, weight: .medium)
        ver.textColor = GeekTheme.inkMuted
        ver.frame = NSRect(x: 100, y: 20, width: 54, height: 16)
        bar.addSubview(ver)

        tabSegment = GeekSegmentControl(items: SettingsTab.allCases.map(\.title), selectedIndex: 0)
        tabSegment.frame = NSRect(x: round((W - 312) * 0.5), y: 11, width: 312, height: 34)
        tabSegment.onSelect = { [weak self] idx in
            guard let tab = SettingsTab(rawValue: idx) else { return }
            self?.switchTab(tab)
        }
        bar.addSubview(tabSegment)

        let sep = NSView(frame: NSRect(x: 0, y: 55, width: W, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = GeekTheme.border.cgColor
        bar.addSubview(sep)
    }

    private func buildFooterBar(in root: GeekFlippedView, width W: CGFloat, y: CGFloat) {
        let foot = GeekFlippedView(frame: NSRect(x: 0, y: y, width: W, height: 40))
        foot.wantsLayer = true
        foot.layer?.backgroundColor = GeekTheme.barBg.cgColor
        root.addSubview(foot)

        let sep = NSView(frame: NSRect(x: 0, y: 0, width: W, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = GeekTheme.border.cgColor
        foot.addSubview(sep)

        let dirBtn = GeekButton(title: "打开配置目录", symbol: "folder", style: .ghost)
        dirBtn.toolTip = "在 Finder 中打开 MSnip 配置文件夹（含 config.json 与 translation_providers.json）"
        dirBtn.frame = NSRect(x: 20, y: 7, width: 122, height: 26)
        dirBtn.onClick = { [weak self] in self?.revealConfigDirectory() }
        foot.addSubview(dirBtn)

        let tip = NSTextField(labelWithString: "自动保存 · ⌘W 关闭")
        tip.font = .monospacedSystemFont(ofSize: 12.0, weight: .regular)
        tip.textColor = GeekTheme.inkMuted
        tip.alignment = .right
        tip.frame = NSRect(x: W - 196, y: 12, width: 170, height: 16)
        foot.addSubview(tip)
    }

    func switchTab(_ tab: SettingsTab) {
        cancelInlineHotKeyRecording(restoreHotKeys: true)
        commitCurrentFormEdits()
        persistDraft()
        activeTab = tab
        tabSegment.selectedIndex = tab.rawValue
        generalPage.isHidden = (tab != .general)
        shortcutsPage.isHidden = (tab != .shortcuts)
        translationPage.isHidden = (tab != .translation)
        if tab != .translation { refreshGeneralAndPermissionsUI() }
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
        isAdvancedExpanded = false
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
