import AppKit
import Foundation
import MSnipCore

/// 极客简约 3 标签设置窗口（780×600 Carbon Dark HUD，高可读字阶、宽敞留白、实时自动保存）
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

    var onAppConfigMutated: (((inout AppConfig) -> Void) -> Void)?
    var appConfigProvider: (() -> AppConfig)?
    var isPriorityTapActiveProvider: (() -> Bool)?
    var onReapplyHotKeys: (() -> Void)?
    var onBeginHotKeyRecording: (() -> Void)?
    var onEndHotKeyRecording: (() -> Void)?
    var onOpenPermissionGuide: (() -> Void)?

    var window: GeekSettingsWindowPanel?
    var activeTab: SettingsTab = .general
    var tabSegment: GeekSegmentControl!
    var generalPage: GeekFlippedView!
    var shortcutsPage: GeekFlippedView!
    var translationPage: GeekFlippedView!

    // 通用页控件
    var loginSwitch: GeekToggleSwitch!; var tipsSwitch: GeekToggleSwitch!; var keychainSwitch: GeekToggleSwitch!
    var colorFmtSegment: GeekSegmentControl!; var recFmtSegment: GeekSegmentControl!
    var saveDirPathLabel: NSTextField!
    var screenPermRow: GeekDotLabel!; var axPermRow: GeekDotLabel!
    var screenPermBtn: GeekButton!; var axPermBtn: GeekButton!
    let modeControls = GeneralModeControls()

    // 快捷键页控件（双子模式：全局热键 + 截图内按键）
    var shortcutSubMode: Int = 0
    var shortcutModeSegment: GeekSegmentControl!
    var globalShortcutsBox: GeekFlippedView!
    var canvasShortcutsBox: GeekFlippedView!
    var activeRecordingSlot: GlobalHotKeyAction?
    var activeCanvasRecording: CanvasAction?
    var hotKeyEnableLabel: NSTextField!
    var hotKeyEnableSwitch: GeekToggleSwitch!
    var resetShortcutsBtn: GeekButton!
    var presetSegment: GeekSegmentControl!
    var hotKeyHintLabel: NSTextField!
    var canvasKeyHintLabel: NSTextField!
    var hotKeyPills: [GlobalHotKeyAction: GeekHotKeyPill] = [:]
    var canvasKeyPills: [CanvasAction: GeekHotKeyPill] = [:]
    var shortcutAudit = ShortcutConflictUIState()

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
    var detailHeaderSubtitle: NSTextField!
    var setDefaultBtn: GeekButton!
    var formScrollView: NSScrollView!
    var formContentView: GeekFlippedView!
    var guideCard: GeekFlippedView!
    var guideLabel: NSTextField!
    var getKeyBtn: GeekButton!
    var nameRow: GeekFlippedView!
    var nameField: NSTextField!
    var kindRow: GeekFlippedView!
    var kindPill: GeekDropdownPill!
    var llmProtocolRow: GeekFlippedView!
    var llmProtocolSegment: GeekSegmentControl!
    var presetRowView: GeekFlippedView!
    var llmPresetPill: GeekDropdownPill!
    var presetGetKeyBtn: GeekButton!
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
    var pasteKeyBtn: GeekButton!
    var eyeToggleBtn: GeekButton!
    var modelRow: GeekFlippedView!
    var modelLabel: NSTextField!
    var modelInputBox: GeekInputBox!
    var modelField: NSTextField!
    var fetchModelsBtn: GeekButton!
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
        if let win = window, !win.isVisible {
            MSnipUITheme.centerOnActiveScreen(win)
        }
        window?.makeKeyAndOrderFront(nil)
    }

    private func ensureWindowBuilt() {
        if window != nil { return }
        let W: CGFloat = 780, H: CGFloat = 600
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
        win.standardWindowButton(.closeButton)?.isHidden = true
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.standardWindowButton(.zoomButton)?.isHidden = true
        win.appearance = GeekTheme.windowAppearance
        win.backgroundColor = GeekTheme.windowBg
        win.level = .normal
        win.collectionBehavior = [.moveToActiveSpace]
        win.delegate = self
        win.onKeyDownIntercept = { [weak self] ev in
            self?.handleInlineHotKeyEvent(ev) ?? false
        }

        let root = GeekSurfaceView(frame: NSRect(x: 0, y: 0, width: W, height: H), fill: GeekTheme.windowBg)
        win.contentView = root

        buildTopBar(in: root, width: W)
        let bodyFrame = NSRect(x: 0, y: 58, width: W, height: H - 100)
        generalPage = GeekFlippedView(frame: bodyFrame)
        shortcutsPage = GeekFlippedView(frame: bodyFrame)
        translationPage = GeekFlippedView(frame: bodyFrame)
        root.addSubview(generalPage)
        root.addSubview(shortcutsPage)
        root.addSubview(translationPage)

        buildGeneralPage(in: generalPage)
        buildShortcutsPage(in: shortcutsPage)
        buildTranslationPage(in: translationPage)
        buildFooterBar(in: root, width: W, y: H - 42)
        self.window = win
    }

    private func buildTopBar(in root: GeekFlippedView, width W: CGFloat) {
        let bar = GeekSurfaceView(frame: NSRect(x: 0, y: 0, width: W, height: 58), fill: GeekTheme.barBg)
        root.addSubview(bar)

        bar.addSubview(GeekWindowCloseButton(frame: NSRect(x: 20, y: 15, width: 28, height: 28)))
        let appVer = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.9.0"
        bar.addSubview(GeekBrandTitleView(frame: NSRect(x: 48, y: 0, width: 164, height: 58), version: "v\(appVer)"))

        tabSegment = GeekSegmentControl(
            items: SettingsTab.allCases.map(\.title),
            symbols: ["slider.horizontal.3", "command", "character.bubble"],
            selectedIndex: 0
        )
        tabSegment.frame = NSRect(x: round((W - 348) * 0.5), y: 12, width: 348, height: 34)
        tabSegment.onSelect = { [weak self] idx in
            guard let tab = SettingsTab(rawValue: idx) else { return }
            self?.switchTab(tab)
        }
        bar.addSubview(tabSegment)

        let themeBtn = GeekButton(title: "明亮", symbol: "sun.max", style: .subtle)
        themeBtn.frame = NSRect(x: W - 28 - 76, y: 14, width: 76, height: 30)
        themeBtn.onClick = { [weak self] in self?.toggleDarkLightQuick() }
        modeControls.themeToggleBtn = themeBtn
        bar.addSubview(themeBtn)

        bar.addSubview(GeekSurfaceView(frame: NSRect(x: 0, y: 57, width: W, height: 1), fill: GeekTheme.border))
    }

    private func buildFooterBar(in root: GeekFlippedView, width W: CGFloat, y: CGFloat) {
        let foot = GeekSurfaceView(frame: NSRect(x: 0, y: y, width: W, height: 42), fill: GeekTheme.barBg)
        root.addSubview(foot)
        foot.addSubview(GeekSurfaceView(frame: NSRect(x: 0, y: 0, width: W, height: 1), fill: GeekTheme.border))

        let dirBtn = GeekButton(title: "打开配置目录", symbol: "folder", style: .ghost)
        dirBtn.contentAlignment = .left
        dirBtn.toolTip = "在 Finder 中打开 MSnip 配置文件夹（含 config.json 与 translation_providers.json）"
        dirBtn.frame = NSRect(x: 20, y: 7, width: 126, height: 28)
        dirBtn.onClick = { [weak self] in self?.revealConfigDirectory() }
        foot.addSubview(dirBtn)

        let tip = NSTextField(labelWithString: "自动保存 · ⌘W 关闭")
        tip.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        tip.textColor = GeekTheme.inkMuted
        tip.alignment = .right
        GeekTheme.placeCentered(tip, x: W - 28 - 176, width: 176, centerY: 21.0)
        foot.addSubview(tip)
    }

    func switchTab(_ tab: SettingsTab) {
        HotKeyConflictPopover.shared.closeIfShown(); ProviderAddAndPresetPopover.shared.closeIfShown()
        stopLiveHotKeyProbe(restoreHotKeys: true)
        cancelInlineHotKeyRecording(restoreHotKeys: true)
        commitCurrentFormEdits(); persistDraft()
        activeTab = tab; tabSegment.selectedIndex = tab.rawValue
        generalPage.isHidden = (tab != .general)
        shortcutsPage.isHidden = (tab != .shortcuts)
        translationPage.isHidden = (tab != .translation)
        if tab == .shortcuts { _ = rescanHotKeyConflicts() }
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
        let stateDesc = isPrimary ? "当前使用中" : (p.isConfiguredReady ? "已就绪" : "待填写密钥")
        let tip = p.endpoint.isEmpty ? "\(p.name)（\(stateDesc)）" : "\(p.name)（\(stateDesc)）\n\(p.endpoint)"
        return ProviderRowCellView(title: p.name, isPrimary: isPrimary, isReady: p.isConfiguredReady, isSelected: row == selectedIndex, dotColor: dotColor, fullTooltip: tip)
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
        HotKeyConflictPopover.shared.closeIfShown(); ProviderAddAndPresetPopover.shared.closeIfShown()
        stopLiveHotKeyProbe(restoreHotKeys: true)
        cancelInlineHotKeyRecording(restoreHotKeys: true); commitCurrentFormEdits(); persistDraft()
    }

    func persistDraft() {
        TranslationService.shared.updateSettings { $0 = self.draft }
    }
}
