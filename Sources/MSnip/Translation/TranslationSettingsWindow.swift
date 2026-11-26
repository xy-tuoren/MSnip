import AppKit
import Foundation
import MSnipCore

/// 极客简约 3 标签设置窗口（780×600 Carbon Dark HUD，高可读字阶、宽敞留白、实时自动保存）
@MainActor
final class TranslationSettingsWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    enum SettingsTab: Int, CaseIterable {
        case general = 0, shortcuts = 1, ocrAndLatex = 2, translation = 3
        var title: String {
            switch self {
            case .general:     return "通用"
            case .shortcuts:   return "快捷键"
            case .ocrAndLatex: return "识字与翻译"
            case .translation: return "模型与服务"
            }
        }
    }

    var onAppConfigMutated: (((inout AppConfig) -> Void) -> Void)?
    var onPreviewPinGlow: ((CGFloat) -> Void)?
    var appConfigProvider: (() -> AppConfig)?
    var isPriorityTapActiveProvider: (() -> Bool)?
    var onReapplyHotKeys: (() -> Void)?
    var onBeginHotKeyRecording: (() -> Void)?
    var onEndHotKeyRecording: (() -> Void)?
    var onOpenPermissionGuide: ((PermissionPane?) -> Void)?

    var window: GeekSettingsWindowPanel?
    nonisolated(unsafe) private var appearanceObserver: NSObjectProtocol?
    deinit { if let obs = appearanceObserver { NotificationCenter.default.removeObserver(obs) } }
    var activeTab: SettingsTab = .general
    var tabSegment: GeekSegmentControl!
    var generalPage: GeekFlippedView!
    var shortcutsPage: GeekFlippedView!
    var ocrAndLatexPage: GeekFlippedView!
    var translationPage: GeekFlippedView!

    // 通用页控件
    var loginSwitch: GeekToggleSwitch!; var tipsSwitch: GeekToggleSwitch!; var keychainSwitch: GeekToggleSwitch!
    var colorFmtSegment: GeekSegmentControl!; var recFmtSegment: GeekSegmentControl!
    var saveDirPathLabel: NSTextField!
    var screenPermRow: GeekDotLabel!; var axPermRow: GeekDotLabel!
    var screenPermBtn: GeekButton!; var axPermBtn: GeekButton!
    let modeControls = GeneralModeControls()
    let ocrLatex = OCRLatexSettingsControls()

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

    var detailContainer: GeekCardView!; var detailHeaderTitle: NSTextField!; var detailHeaderSubtitle: NSTextField!
    var setDefaultBtn: GeekButton!; var formScrollView: NSScrollView!; var formContentView: GeekFlippedView!
    var guideCard: GeekFlippedView!
    var guideLabel: NSTextField!
    var getKeyBtn: GeekButton!
    var nameRow: GeekFlippedView!
    var nameField: NSTextField!
    var kindRow: GeekFlippedView!
    var kindPill: GeekDropdownPill!
    var llmProtocolRow: GeekFlippedView!
    var llmProtocolPill: GeekDropdownPill!
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
    var testBtn: GeekButton!; var testStatusLabel: NSTextField!
    var activeTestTask: Task<Void, Never>?; var activeFetchModelsTask: Task<Void, Never>?

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
        testBtn?.isEnabled = true; fetchModelsBtn?.isEnabled = true
        ocrLatex.ocrTestBtn?.isEnabled = true; ocrLatex.latexTestBtn?.isEnabled = true
        cancelInlineHotKeyRecording(restoreHotKeys: false)
        refreshTopBarPopups()
        tableView.reloadData(); tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        loadSelectedProfileIntoForm(); refreshGeneralAndPermissionsUI(); refreshOCRAndLatexUI(); switchTab(tab)
        NSApp.activate(ignoringOtherApps: true)
        if let win = window, !win.isVisible { MSnipUITheme.centerOnActiveScreen(win) }
        window?.makeKeyAndOrderFront(nil)
    }

    private func ensureWindowBuilt() {
        if window != nil { return }
        let W: CGFloat = 840, H: CGFloat = 620
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
        generalPage = GeekFlippedView(frame: bodyFrame); shortcutsPage = GeekFlippedView(frame: bodyFrame)
        ocrAndLatexPage = GeekFlippedView(frame: bodyFrame); translationPage = GeekFlippedView(frame: bodyFrame)
        for p in [generalPage!, shortcutsPage!, ocrAndLatexPage!, translationPage!] { root.addSubview(p) }

        buildGeneralPage(in: generalPage); buildShortcutsPage(in: shortcutsPage)
        buildOCRAndLatexPage(in: ocrAndLatexPage); buildTranslationPage(in: translationPage)
        buildFooterBar(in: root, width: W, y: H - 42)
        self.window = win
        if appearanceObserver == nil {
            appearanceObserver = NotificationCenter.default.addObserver(forName: .msnipAppearanceDidChange, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshSettingsWindowAppearance() }
            }
        }
    }

    private func buildTopBar(in root: GeekFlippedView, width W: CGFloat) {
        let bar = GeekSurfaceView(frame: NSRect(x: 0, y: 0, width: W, height: 58), fill: GeekTheme.barBg)
        root.addSubview(bar)

        bar.addSubview(GeekWindowCloseButton(frame: NSRect(x: 20, y: 15, width: 28, height: 28)))
        let appVer = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.9.3"
        bar.addSubview(GeekBrandTitleView(frame: NSRect(x: 52, y: 0, width: 148, height: 58), version: "v\(appVer)"))

        tabSegment = GeekSegmentControl(
            items: SettingsTab.allCases.map(\.title),
            symbols: ["slider.horizontal.3", "command", "text.viewfinder", "cpu"],
            selectedIndex: 0
        )
        tabSegment.frame = NSRect(x: round((W - 432) * 0.5), y: 12, width: 432, height: 34)
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
        commitCurrentFormEdits(); commitOCRAndLatexEdits(); persistDraft(); saveOCRAndLatexConfigs()
        activeTab = tab; tabSegment.selectedIndex = tab.rawValue
        generalPage.isHidden = (tab != .general)
        shortcutsPage.isHidden = (tab != .shortcuts)
        ocrAndLatexPage.isHidden = (tab != .ocrAndLatex)
        translationPage.isHidden = (tab != .translation)
        if tab == .shortcuts { _ = rescanHotKeyConflicts() }
        if tab == .ocrAndLatex { refreshOCRAndLatexUI() }
        if tab == .translation {
            tableView.reloadData(); tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false); loadSelectedProfileIntoForm()
        } else { refreshGeneralAndPermissionsUI() }
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
        activeTestTask?.cancel(); activeFetchModelsTask?.cancel(); testBtn.isEnabled = true; fetchModelsBtn.isEnabled = true
        commitCurrentFormEdits()
        selectedIndex = row; isAdvancedExpanded = false
        tableView.reloadData(); tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        loadSelectedProfileIntoForm()
    }

    func windowWillClose(_ notification: Notification) {
        activeTestTask?.cancel(); activeFetchModelsTask?.cancel(); ocrLatex.ocrTestTask?.cancel(); ocrLatex.latexTestTask?.cancel()
        testBtn?.isEnabled = true; fetchModelsBtn?.isEnabled = true; ocrLatex.ocrTestBtn?.isEnabled = true; ocrLatex.latexTestBtn?.isEnabled = true
        HotKeyConflictPopover.shared.closeIfShown(); ProviderAddAndPresetPopover.shared.closeIfShown()
        stopLiveHotKeyProbe(restoreHotKeys: true)
        cancelInlineHotKeyRecording(restoreHotKeys: true); commitCurrentFormEdits(); commitOCRAndLatexEdits(); persistDraft(); saveOCRAndLatexConfigs()
    }

    func persistDraft() {
        TranslationService.shared.updateSettings { $0 = self.draft }
        NotificationCenter.default.post(name: .msnipOCRLatexConfigChanged, object: nil)
    }
}

// MARK: - 翻译渠道表单视图与联动更新

/// 统一「模型与服务」管理页：集中管理大模型 API（OpenAI Chat/Responses、Anthropic、Gemini、Ollama）与各云翻译服务凭据，
/// 同时供给截图翻译、AI 视觉识字 (OCR) 与 LaTeX 公式识别复用；翻译偏好已拆出至「识字与翻译」标签页。
extension TranslationSettingsWindow {
    func buildTranslationPage(in page: GeekFlippedView) {
        let cardW = page.bounds.width - 56 // 784
        let pageH = page.bounds.height // 520

        // 1) 左侧服务列表（256px 宽敞栏宽，完整显示服务全称 + 底部添加/删除操作栏）
        let listW: CGFloat = 256
        let listH = pageH - 74 // 446
        let listCard = GeekCardView(frame: NSRect(x: 28, y: 16, width: listW, height: listH))
        page.addSubview(listCard)

        let scroll = NSScrollView(frame: listCard.bounds.insetBy(dx: 4, dy: 6))
        configureVerticalScroll(scroll)
        let tv = NSTableView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        if #available(macOS 11.0, *) { tv.style = .plain }
        tv.intercellSpacing = NSSize(width: 0, height: 2)
        tv.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("PCol"))
        col.width = scroll.contentSize.width
        tv.addTableColumn(col); tv.headerView = nil; tv.rowHeight = 38
        tv.backgroundColor = .clear; tv.selectionHighlightStyle = .none
        tv.dataSource = self; tv.delegate = self
        scroll.documentView = tv; self.tableView = tv
        listCard.addSubview(scroll)

        addBtn = GeekButton(title: "添加服务", symbol: "plus", style: .subtle)
        addBtn.frame = NSRect(x: 28, y: listCard.frame.maxY + 10, width: listW - 78, height: 32)
        addBtn.onClick = { [weak self] in self?.popAddProviderMenu() }
        page.addSubview(addBtn)

        removeBtn = GeekButton(title: "删除", style: .subtle)
        removeBtn.frame = NSRect(x: 28 + listW - 70, y: listCard.frame.maxY + 10, width: 70, height: 32)
        removeBtn.onClick = { [weak self] in self?.removeSelectedProvider() }
        page.addSubview(removeBtn)

        // 2) 右侧详情配置卡片（514 × 488，宽敞零拥挤）
        let detailW = cardW - listW - 14 // 514
        let formCard = GeekCardView(frame: NSRect(x: 28 + listW + 14, y: 16, width: detailW, height: pageH - 32))
        page.addSubview(formCard)
        self.detailContainer = formCard
        buildDetailCard(in: formCard)
    }

    private func buildDetailCard(in cv: GeekCardView) {
        let fw = cv.bounds.width, fh = cv.bounds.height
        let ctrlX: CGFloat = 96
        let ctrlW = fw - ctrlX - 18

        // 卡片顶栏（60px）：服务名称 + 简明副标题 + 设为当前
        detailHeaderTitle = NSTextField(labelWithString: "")
        detailHeaderTitle.font = .systemFont(ofSize: 15.0, weight: .semibold); detailHeaderTitle.textColor = GeekTheme.inkPrimary
        detailHeaderTitle.lineBreakMode = .byTruncatingTail; cv.addSubview(detailHeaderTitle)

        detailHeaderSubtitle = NSTextField(labelWithString: "")
        detailHeaderSubtitle.font = .systemFont(ofSize: 11.5, weight: .regular); detailHeaderSubtitle.textColor = GeekTheme.inkMuted
        detailHeaderSubtitle.lineBreakMode = .byTruncatingTail; cv.addSubview(detailHeaderSubtitle)
        GeekTheme.placeTwoLineStack(detailHeaderTitle, detailHeaderSubtitle, x: 18, width: fw - 138, centerY: 30.0, gap: 2.0)

        setDefaultBtn = GeekButton(title: "设为当前", style: .accent)
        setDefaultBtn.frame = NSRect(x: fw - 110, y: 15, width: 92, height: 30)
        setDefaultBtn.onClick = { [weak self] in self?.onSetAsPrimaryClicked() }
        cv.addSubview(setDefaultBtn); cv.addHairline(atY: 60, insetX: 0)

        let footerY = fh - 58
        let bodyRect = NSRect(x: 0, y: 61, width: fw, height: footerY - 61)
        let fScroll = NSScrollView(frame: bodyRect)
        configureVerticalScroll(fScroll)
        let content = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: fScroll.contentSize.width, height: bodyRect.height))
        content.autoresizingMask = [.width]
        fScroll.documentView = content; cv.addSubview(fScroll)
        self.formScrollView = fScroll; self.formContentView = content

        // 传统云翻译指引条 + 官方「获取 Key ↗」直达按钮
        guideCard = makeSubCard(frame: NSRect(x: 18, y: 14, width: fw - 36, height: 42))
        guideLabel = NSTextField(labelWithString: "")
        guideLabel.font = .systemFont(ofSize: 12.0, weight: .medium)
        guideLabel.textColor = GeekTheme.inkSecondary
        guideLabel.lineBreakMode = .byTruncatingTail
        GeekTheme.placeCentered(guideLabel, x: 14, width: fw - 152, centerY: 21.0)
        guideCard.addSubview(guideLabel)

        getKeyBtn = GeekButton(title: "获取 Key", symbol: "arrow.up.right", style: .accent)
        getKeyBtn.frame = NSRect(x: fw - 36 - 96, y: 7, width: 88, height: 28)
        getKeyBtn.onClick = { [weak self] in self?.onOpenConsoleURLClicked() }
        guideCard.addSubview(getKeyBtn)
        content.addSubview(guideCard)

        // Apple 离线开箱即用状态卡
        nativeCardBox = makeSubCard(frame: NSRect(x: 18, y: 16, width: fw - 36, height: 176))
        nativeInfoLabel = NSTextField(wrappingLabelWithString: "")
        nativeInfoLabel.font = .systemFont(ofSize: 13.0)
        nativeInfoLabel.textColor = GeekTheme.inkSecondary
        nativeInfoLabel.frame = NSRect(x: 16, y: 16, width: fw - 68, height: 104)
        nativeCardBox.addSubview(nativeInfoLabel)

        let sysLangBtn = GeekButton(title: "打开系统翻译语言设置…", symbol: "globe", style: .subtle)
        sysLangBtn.frame = NSRect(x: 16, y: 130, width: 208, height: 30)
        sysLangBtn.onClick = {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") { NSWorkspace.shared.open(url) }
        }
        nativeCardBox.addSubview(sysLangBtn)
        content.addSubview(nativeCardBox)

        // 统一 38px 行高与 30px 控件高度，所有控件严格对齐 x = 96 .. fw - 18
        (appIdRow, appIdLabel, appIdField) = makeDynamicRow(label: "AppID", placeholder: "输入平台应用 ID", mono: true, width: fw)

        apiKeyRow = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: fw, height: 38))
        apiKeyLabel = addRowCaption("API 密钥", rowHeight: 38, in: apiKeyRow)
        let keyW = ctrlW - 94 // 50(粘贴) + 32(眼) + 12(双6pt间距)
        apiKeySecureField = NSSecureTextField()
        apiKeySecureBox = GeekInputBox(frame: NSRect(x: ctrlX, y: 4, width: keyW, height: 30), field: apiKeySecureField, placeholder: "粘贴 API Key 即可使用", mono: true)
        apiKeyRow.addSubview(apiKeySecureBox)
        apiKeyPlainField = NSTextField()
        apiKeyPlainBox = GeekInputBox(frame: NSRect(x: ctrlX, y: 4, width: keyW, height: 30), field: apiKeyPlainField, placeholder: "粘贴 API Key 即可使用", mono: true)
        apiKeyPlainBox.isHidden = true
        apiKeyRow.addSubview(apiKeyPlainBox)

        pasteKeyBtn = GeekButton(title: "粘贴", style: .subtle)
        pasteKeyBtn.toolTip = "一键从剪贴板粘贴 API 密钥"
        pasteKeyBtn.frame = NSRect(x: ctrlX + keyW + 6, y: 4, width: 50, height: 30)
        pasteKeyBtn.onClick = { [weak self] in self?.onPasteAPIKeyClicked() }
        apiKeyRow.addSubview(pasteKeyBtn)

        eyeToggleBtn = GeekButton(title: "", symbol: "eye", style: .subtle)
        eyeToggleBtn.toolTip = "显示 / 隐藏明文密钥"
        eyeToggleBtn.frame = NSRect(x: ctrlX + keyW + 62, y: 4, width: 32, height: 30)
        eyeToggleBtn.onClick = { [weak self] in self?.toggleAPIKeyVisibility() }
        apiKeyRow.addSubview(eyeToggleBtn)

        llmProtocolRow = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: fw, height: 38))
        addRowCaption("接口格式", rowHeight: 38, in: llmProtocolRow)
        llmProtocolPill = GeekDropdownPill(symbol: "network", items: TranslationProviderKind.llmProtocolCases.map(\.llmFormatTitle))
        llmProtocolPill.frame = NSRect(x: ctrlX, y: 4, width: ctrlW, height: 30)
        llmProtocolPill.onSelect = { [weak self] idx in self?.onSelectLLMProtocolIndex(idx) }
        llmProtocolRow.addSubview(llmProtocolPill)

        presetRowView = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: fw, height: 38))
        addRowCaption("服务预设", rowHeight: 38, in: presetRowView)
        llmPresetPill = GeekDropdownPill(symbol: "sparkles")
        llmPresetPill.customDisplayTitle = "自定义 / 中转站"
        llmPresetPill.frame = NSRect(x: ctrlX, y: 4, width: ctrlW, height: 30)
        llmPresetPill.onCustomClick = { [weak self] anchor in self?.popLLMPresetMenu(from: anchor) }
        presetRowView.addSubview(llmPresetPill)
        presetGetKeyBtn = GeekButton(title: "获取 Key", symbol: "arrow.up.right", style: .accent)
        presetGetKeyBtn.frame = NSRect(x: fw - 18 - 88, y: 4, width: 88, height: 30)
        presetGetKeyBtn.onClick = { [weak self] in self?.onOpenConsoleURLClicked() }
        presetRowView.addSubview(presetGetKeyBtn)

        (nameRow, _, nameField) = makeDynamicRow(label: "显示名称", placeholder: "自定义显示名称", mono: false, width: fw)
        kindRow = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: fw, height: 38))
        addRowCaption("服务类型", rowHeight: 38, in: kindRow)
        kindPill = GeekDropdownPill(symbol: "network", items: TranslationProviderKind.allCases.map(\.displayName))
        kindPill.frame = NSRect(x: ctrlX, y: 4, width: ctrlW, height: 30)
        kindPill.onSelect = { [weak self] idx in self?.onSelectKindIndex(idx) }
        kindRow.addSubview(kindPill)

        (endpointRow, endpointLabel, endpointField) = makeDynamicRow(label: "接口地址", placeholder: "https://your-api.com（自动补全协议路径）", mono: true, width: fw)
        endpointField.delegate = self

        modelRow = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: fw, height: 38))
        modelLabel = addRowCaption("模型名称", rowHeight: 38, in: modelRow)
        modelField = NSTextField()
        let modelW = ctrlW - 74 // 68(拉取) + 6(间距)
        modelInputBox = GeekInputBox(frame: NSRect(x: ctrlX, y: 4, width: modelW, height: 30), field: modelField, placeholder: "如 deepseek-chat，或点右侧拉取", mono: true)
        modelRow.addSubview(modelInputBox)
        fetchModelsBtn = GeekButton(title: "拉取", symbol: "arrow.clockwise", style: .subtle)
        fetchModelsBtn.toolTip = "从当前接口地址自动拉取 /v1/models 可用模型列表"
        fetchModelsBtn.frame = NSRect(x: ctrlX + modelW + 6, y: 4, width: 68, height: 30)
        fetchModelsBtn.onClick = { [weak self] in self?.onFetchModelsClicked() }
        modelRow.addSubview(fetchModelsBtn)

        (extra1Row, extraLabel1, extraField1) = makeDynamicRow(label: "提示词", placeholder: "", mono: false, width: fw)
        (extra2Row, extraLabel2, extraField2) = makeDynamicRow(label: "请求头", placeholder: "", mono: true, width: fw)

        advancedToggleBtn = GeekButton(title: "高级设置（显示名称 / 提示词 / 请求头）", symbol: "chevron.right", style: .ghost)
        advancedToggleBtn.contentAlignment = .left
        advancedToggleBtn.frame = NSRect(x: 88, y: 0, width: fw - 106, height: 28)
        advancedToggleBtn.onClick = { [weak self] in
            guard let self, self.draft.profiles.indices.contains(self.selectedIndex) else { return }
            self.commitCurrentFormEdits(); self.isAdvancedExpanded.toggle()
            self.updateFieldVisibility(for: self.draft.profiles[self.selectedIndex])
        }
        content.addSubview(advancedToggleBtn)
        for r in [llmProtocolRow!, presetRowView!, appIdRow!, apiKeyRow!, endpointRow!, modelRow!, nameRow!, kindRow!, extra1Row!, extra2Row!] { content.addSubview(r) }

        cv.addHairline(atY: footerY, insetX: 0)
        testBtn = GeekButton(title: "测试并启用", symbol: "bolt.horizontal", style: .accent)
        testBtn.frame = NSRect(x: 18, y: footerY + 14, width: 124, height: 30)
        testBtn.onClick = { [weak self] in self?.onTestClicked() }
        cv.addSubview(testBtn)

        testStatusLabel = NSTextField(labelWithString: "")
        testStatusLabel.font = .monospacedSystemFont(ofSize: 12.0, weight: .medium); testStatusLabel.textColor = GeekTheme.inkSecondary
        testStatusLabel.lineBreakMode = .byTruncatingTail
        GeekTheme.placeCentered(testStatusLabel, x: 152, width: fw - 170, centerY: footerY + 29.0)
        cv.addSubview(testStatusLabel)
    }

    private func makeSubCard(frame: NSRect) -> GeekFlippedView {
        GeekSurfaceView(frame: frame, fill: GeekTheme.inputBg, border: GeekTheme.border, cornerRadius: 9.0, borderWidth: 1.0)
    }

    private func makeDynamicRow(label: String, placeholder: String, mono: Bool, width fw: CGFloat) -> (GeekFlippedView, NSTextField, NSTextField) {
        let row = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: fw, height: 38))
        let lbl = addRowCaption(label, rowHeight: 38, in: row)
        let tf = NSTextField()
        row.addSubview(GeekInputBox(frame: NSRect(x: 96, y: 4, width: fw - 114, height: 30), field: tf, placeholder: placeholder, mono: mono))
        return (row, lbl, tf)
    }

    @discardableResult
    private func addRowCaption(_ text: String, rowHeight: CGFloat, in parent: NSView) -> NSTextField {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = .systemFont(ofSize: 13.0, weight: .medium); lbl.textColor = GeekTheme.inkSecondary; lbl.alignment = .right
        GeekTheme.placeCentered(lbl, x: 12, width: 72, centerY: rowHeight * 0.5)
        parent.addSubview(lbl)
        return lbl
    }
}
