import AppKit
import Foundation
import MSnipCore

/// 识字与翻译双栏面板默认行为控件盒（跨「通用」与「翻译」双标签页实时同步）
@MainActor
final class GeneralModeControls {
    var ocrModeSegment: GeekSegmentControl?
    var translateModeSegment: GeekSegmentControl?
    var ocrAutoCopySwitch: GeekToggleSwitch?
    var transTabDualSwitch: GeekToggleSwitch?
    var exportFmtPill: GeekDropdownPill?
    var export1xSwitch: GeekToggleSwitch?
    var terminalAdaptSwitch: GeekToggleSwitch?
    var appearanceSegment: GeekSegmentControl?
    var themeToggleBtn: GeekButton?
    var gifPresetSegment: GeekSegmentControl?
    var mp4ResSegment: GeekSegmentControl?
    var mp4FpsSegment: GeekSegmentControl?
    var recordCursorSwitch: GeekToggleSwitch?
    var recordAudioSwitch: GeekToggleSwitch?
    var extra = GeneralExtraControls()
}

/// 设置窗口「通用」标签页（基础设置、识字与翻译面板模式、导出格式与钥匙串密钥加密、系统权限状态）
extension TranslationSettingsWindow {
    func buildGeneralPage(in page: GeekFlippedView) {
        let cardX: CGFloat = 28, cardW = page.bounds.width - 56, insetX: CGFloat = 16, headerX = cardX + insetX
        let rowH: CGFloat = 44, segH: CGFloat = 28, segY: CGFloat = 8, switchH: CGFloat = 22, switchY: CGFloat = 11
        let switchX = cardW - insetX - 38, headerToCard: CGFloat = 24, sectionGap: CGFloat = 20

        let scroll = NSScrollView(frame: page.bounds)
        configureVerticalScroll(scroll)
        let content = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: 860))
        content.autoresizingMask = [.width]
        scroll.documentView = content; page.addSubview(scroll)
        var y: CGFloat = 18

        // 1) 基础（4 行：外观模式、开机自启、快捷键提示、保存位置）
        addSectionHeader("基础", x: headerX, y: y, in: content)
        let baseCard = GeekCardView(frame: NSRect(x: cardX, y: y + headerToCard, width: cardW, height: rowH * 4))
        content.addSubview(baseCard)

        addRowLabel("外观模式", y: 0, height: rowH, in: baseCard)
        let appSeg = GeekSegmentControl(
            items: AppAppearanceMode.allCases.map(\.title),
            symbols: ["circle.lefthalf.filled", "sun.max", "moon"],
            selectedIndex: 2
        )
        appSeg.toolTip = "切换全应用窗口、悬浮通知与暂存架的外观主题（也可点击右上角一键切换）"
        appSeg.frame = NSRect(x: cardW - insetX - 276, y: segY, width: 276, height: segH)
        appSeg.onSelect = { [weak self] idx in
            guard AppAppearanceMode.allCases.indices.contains(idx) else { return }
            self?.applyAppearanceMode(AppAppearanceMode.allCases[idx], persist: true)
        }
        modeControls.appearanceSegment = appSeg
        baseCard.addSubview(appSeg)

        baseCard.addHairline(atY: rowH)
        addRowLabel("开机自动启动", y: rowH, height: rowH, in: baseCard)
        loginSwitch = GeekToggleSwitch()
        loginSwitch.frame = NSRect(x: switchX, y: rowH + switchY, width: 38, height: switchH)
        loginSwitch.onToggle = { on in _ = LaunchAtLoginManager.setEnabled(on) }
        baseCard.addSubview(loginSwitch)

        baseCard.addHairline(atY: rowH * 2)
        addRowLabel("截图时显示快捷键提示", y: rowH * 2, height: rowH, in: baseCard)
        tipsSwitch = GeekToggleSwitch()
        tipsSwitch.frame = NSRect(x: switchX, y: rowH * 2 + switchY, width: 38, height: switchH)
        tipsSwitch.onToggle = { [weak self] on in self?.onAppConfigMutated? { $0.showShortcutTips = on } }
        baseCard.addSubview(tipsSwitch)

        baseCard.addHairline(atY: rowH * 3)
        addRowLabel("截图保存位置", y: rowH * 3, height: rowH, in: baseCard)
        let openX = cardW - insetX - 56
        let chooseX = openX - 8 - 56
        saveDirPathLabel = NSTextField(labelWithString: "~/Pictures/MSnip")
        saveDirPathLabel.font = .monospacedSystemFont(ofSize: 12.0, weight: .regular)
        saveDirPathLabel.textColor = GeekTheme.inkSecondary
        saveDirPathLabel.lineBreakMode = .byTruncatingMiddle
        saveDirPathLabel.alignment = .right
        GeekTheme.placeCentered(saveDirPathLabel, x: 156, width: chooseX - 156 - 12, centerY: rowH * 3 + rowH * 0.5)
        baseCard.addSubview(saveDirPathLabel)

        let chooseBtn = GeekButton(title: "更改", style: .subtle)
        chooseBtn.frame = NSRect(x: chooseX, y: rowH * 3 + segY, width: 56, height: segH)
        chooseBtn.onClick = { [weak self] in self?.chooseQuickSaveDirectory() }
        baseCard.addSubview(chooseBtn)

        let openDirBtn = GeekButton(title: "打开", style: .subtle)
        openDirBtn.frame = NSRect(x: openX, y: rowH * 3 + segY, width: 56, height: segH)
        openDirBtn.onClick = { [weak self] in
            NSWorkspace.shared.open(ClipboardAndSave.resolveQuickSaveDirectory(preferred: self?.appConfigProvider?().lastSaveDirectory))
        }
        baseCard.addSubview(openDirBtn)

        // 2) 格式与安全（6 行；识字、公式与翻译偏好已统一收口至「识字与翻译」标签页）
        y = baseCard.frame.maxY + sectionGap
        addSectionHeader("格式与安全", x: headerX, y: y, in: content)
        let fmtCard = GeekCardView(frame: NSRect(x: cardX, y: y + headerToCard, width: cardW, height: rowH * 6))
        content.addSubview(fmtCard)

        addRowLabel("截图保存格式", y: 0, height: rowH, in: fmtCard)
        let supportedFmts = CaptureExportFormat.supportedFormats
        let expPill = GeekDropdownPill(symbol: "photo", items: supportedFmts.map(\.menuTitle), selectedIndex: 0)
        expPill.toolTip = "快存与另存为的默认图片格式（按当前 macOS 原生硬件编码能力自动列出支持格式，低版本系统安全兼容）"
        expPill.frame = NSRect(x: cardW - insetX - 240, y: segY, width: 240, height: segH)
        expPill.onSelect = { [weak self] idx in
            let list = CaptureExportFormat.supportedFormats
            guard list.indices.contains(idx) else { return }
            self?.onAppConfigMutated? { $0.exportImageFormat = list[idx] }
        }
        modeControls.exportFmtPill = expPill
        fmtCard.addSubview(expPill)

        fmtCard.addHairline(atY: rowH)
        let scaleTip = "仅对保存的图片文件生效：在 Retina 高分屏（2×）上自动缩为 1× 标准尺寸，避免发文档或网页时大一倍并减小体积；普通 1080p 屏与剪贴板原图不受影响"
        addRowLabel("高分屏保存缩为标准尺寸", y: rowH, height: rowH, in: fmtCard, toolTip: scaleTip)
        let scale1xSw = GeekToggleSwitch(isOn: false)
        scale1xSw.toolTip = scaleTip
        scale1xSw.frame = NSRect(x: switchX, y: rowH + switchY, width: 38, height: switchH)
        scale1xSw.onToggle = { [weak self] on in self?.onAppConfigMutated? { $0.exportAt1xScale = on } }
        modeControls.export1xSwitch = scale1xSw
        fmtCard.addSubview(scale1xSw)

        fmtCard.addHairline(atY: rowH * 2)
        let termTip = "开启后，独立终端自动粘贴临时 PNG 路径，访达自动粘贴文件；主流编辑器内置终端按 ⌘V 自动适配路径，切回 AI 聊天框/Markdown/微信/浏览器自动保持纯净图像（编辑器自动感应需开启辅助功能；截图时也可按 ⇧⌘C 或 ⌥↩ 强制带路径复制）"
        addRowLabel("终端、编辑器与访达粘贴适配", y: rowH * 2, height: rowH, in: fmtCard, toolTip: termTip)
        let termSw = GeekToggleSwitch(isOn: true)
        termSw.toolTip = termTip
        termSw.frame = NSRect(x: switchX, y: rowH * 2 + switchY, width: 38, height: switchH)
        termSw.onToggle = { [weak self] on in self?.onAppConfigMutated? { $0.terminalPasteAdaptEnabled = on } }
        modeControls.terminalAdaptSwitch = termSw
        fmtCard.addSubview(termSw)

        fmtCard.addHairline(atY: rowH * 3)
        addRowLabel("取色复制格式", y: rowH * 3, height: rowH, in: fmtCard)
        colorFmtSegment = GeekSegmentControl(items: ColorCopyFormat.allCases.map(\.rawValue), selectedIndex: 0, mono: true)
        colorFmtSegment.frame = NSRect(x: cardW - insetX - 276, y: rowH * 3 + segY, width: 276, height: segH)
        colorFmtSegment.onSelect = { [weak self] idx in
            guard ColorCopyFormat.allCases.indices.contains(idx) else { return }
            self?.onAppConfigMutated? { $0.colorCopyFormat = ColorCopyFormat.allCases[idx] }
        }
        fmtCard.addSubview(colorFmtSegment)

        fmtCard.addHairline(atY: rowH * 4)
        addRowLabel("录屏导出格式", y: rowH * 4, height: rowH, in: fmtCard)
        recFmtSegment = GeekSegmentControl(items: ["GIF", "MP4"], selectedIndex: 0, mono: true)
        recFmtSegment.frame = NSRect(x: cardW - insetX - 136, y: rowH * 4 + segY, width: 136, height: segH)
        recFmtSegment.onSelect = { [weak self] idx in
            self?.onAppConfigMutated? { $0.preferredRecordingFormat = (idx == 1) ? .mp4 : .gif }
        }
        fmtCard.addSubview(recFmtSegment)

        fmtCard.addHairline(atY: rowH * 5)
        let kcTip = CredentialVault.hasStableCodeSignature()
            ? "将翻译与公式 API 密钥存入 macOS 登录钥匙串，本地 JSON 自动脱敏留空"
            : "将密钥转存至系统钥匙串（提示：建议先运行 scripts/setup-cert.sh 配置固定证书以免升级弹窗）"
        addRowLabel("钥匙串加密存储 API 密钥", y: rowH * 5, height: rowH, in: fmtCard, toolTip: kcTip)
        keychainSwitch = GeekToggleSwitch()
        keychainSwitch.toolTip = kcTip
        keychainSwitch.frame = NSRect(x: switchX, y: rowH * 5 + switchY, width: 38, height: switchH)
        keychainSwitch.onToggle = { [weak self] on in
            guard let self else { return }
            self.commitCurrentFormEdits(); self.commitOCRAndLatexEdits()
            self.draft.preferKeychainStorage = on; self.persistDraft(); self.saveOCRAndLatexConfigs()
        }
        fmtCard.addSubview(keychainSwitch)

        // 4) 系统权限（2 行）
        y = fmtCard.frame.maxY + sectionGap
        addSectionHeader("系统权限", x: headerX, y: y, in: content)
        let permCard = GeekCardView(frame: NSRect(x: cardX, y: y + headerToCard, width: cardW, height: rowH * 2))
        content.addSubview(permCard)

        screenPermRow = GeekDotLabel(frame: NSRect(x: insetX, y: 0, width: cardW - insetX * 2, height: rowH))
        permCard.addSubview(screenPermRow)
        screenPermBtn = GeekButton(title: "前往开启", style: .accent)
        screenPermBtn.frame = NSRect(x: cardW - insetX - 84, y: segY, width: 84, height: segH)
        screenPermBtn.onClick = { [weak self] in self?.onOpenPermissionGuide?(.screenRecording) }
        permCard.addSubview(screenPermBtn)

        permCard.addHairline(atY: rowH)
        axPermRow = GeekDotLabel(frame: NSRect(x: insetX, y: rowH, width: cardW - insetX * 2, height: rowH))
        permCard.addSubview(axPermRow)
        axPermBtn = GeekButton(title: "前往开启", style: .subtle)
        axPermBtn.frame = NSRect(x: cardW - insetX - 84, y: rowH + segY, width: 84, height: segH)
        axPermBtn.onClick = { [weak self] in self?.onOpenPermissionGuide?(.accessibility) }
        permCard.addSubview(axPermBtn)

        let bottomY = appendRecordingAndBackupCards(in: content, startY: permCard.frame.maxY + sectionGap, cardX: cardX, cardW: cardW)
        content.frame.size.height = bottomY + 24
    }

    func refreshGeneralAndPermissionsUI() {
        guard loginSwitch != nil else { return }
        let cfg = appConfigProvider?() ?? AppConfig()
        applyAppearanceMode(cfg.appearanceMode, persist: false)
        LaunchAtLoginManager.refreshCache()
        loginSwitch.isOn = LaunchAtLoginManager.isEnabled
        tipsSwitch.isOn = cfg.showShortcutTips
        keychainSwitch?.isOn = draft.preferKeychainStorage
        if let oIdx = OCRDefaultPresentation.allCases.firstIndex(of: cfg.ocrPresentation) { modeControls.ocrModeSegment?.selectedIndex = oIdx }
        modeControls.translateModeSegment?.selectedIndex = cfg.translateAutoOpenDualPane ? 1 : 0
        modeControls.ocrAutoCopySwitch?.isOn = cfg.ocrAutoCopy
        modeControls.transTabDualSwitch?.isOn = cfg.translateAutoOpenDualPane
        let supportedFmts = CaptureExportFormat.supportedFormats
        let resolvedFmt = cfg.exportImageFormat.resolvedForCurrentOS
        if let eIdx = supportedFmts.firstIndex(of: resolvedFmt) { modeControls.exportFmtPill?.selectedIndex = eIdx }
        modeControls.export1xSwitch?.isOn = cfg.exportAt1xScale
        modeControls.terminalAdaptSwitch?.isOn = cfg.terminalPasteAdaptEnabled
        if let cIdx = ColorCopyFormat.allCases.firstIndex(of: cfg.colorCopyFormat) { colorFmtSegment.selectedIndex = cIdx }
        recFmtSegment.selectedIndex = (cfg.preferredRecordingFormat == .mp4) ? 1 : 0
        let resolvedDir = ClipboardAndSave.resolveQuickSaveDirectory(preferred: cfg.lastSaveDirectory).path
        saveDirPathLabel.stringValue = resolvedDir.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        saveDirPathLabel.toolTip = resolvedDir

        let scrOK = ScreenCapturer.runtimeVerifiedAccess || CGPreflightScreenCaptureAccess()
        screenPermRow.dotColor = scrOK ? GeekTheme.emerald : GeekTheme.amber
        screenPermRow.text = "屏幕录制"; screenPermRow.detail = scrOK ? "已授权" : ""
        screenPermBtn.isHidden = scrOK

        let axOK = RegionDetector.checkAccessibilityPermission(prompt: false)
        axPermRow.dotColor = axOK ? GeekTheme.emerald : GeekTheme.inkMuted
        axPermRow.text = "辅助功能"; axPermRow.detail = axOK ? "已授权" : ""
        axPermBtn.isHidden = axOK

        refreshRecordingControlsUI(with: cfg)
        refreshShortcutsPageUI(with: cfg)
    }

    func chooseQuickSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false; panel.prompt = "设为保存目录"
        panel.directoryURL = ClipboardAndSave.resolveQuickSaveDirectory(preferred: appConfigProvider?().lastSaveDirectory)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onAppConfigMutated? { $0.lastSaveDirectory = url.path }
        refreshGeneralAndPermissionsUI()
    }

    func addSectionHeader(_ text: String, x: CGFloat, y: CGFloat, in parent: NSView) {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = .systemFont(ofSize: 12.0, weight: .semibold); lbl.textColor = GeekTheme.inkSecondary
        GeekTheme.placeCentered(lbl, x: x, width: 180, centerY: y + 8.0)
        parent.addSubview(lbl)
    }

    func addRowLabel(_ text: String, y: CGFloat, height: CGFloat, in card: GeekCardView, toolTip: String? = nil) {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = .systemFont(ofSize: 13.5, weight: .regular); lbl.textColor = GeekTheme.inkPrimary; lbl.sizeToFit()
        lbl.toolTip = toolTip
        GeekTheme.placeCentered(lbl, x: 16, width: lbl.frame.width + 6, centerY: y + height * 0.5)
        card.addSubview(lbl)
    }

    func revealConfigDirectory() {
        commitCurrentFormEdits(); persistDraft()
        if !FileManager.default.fileExists(atPath: AppConfig.configURL.path) { appConfigProvider?().save() }
        NSWorkspace.shared.open(AppConfig.configURL.deletingLastPathComponent())
    }
}

// MARK: - 截图模式与交互偏好设置卡

/// 设置「通用」页扩展：延时与全屏抓拍卡片（自定义延时秒数 + 截取全屏默认动作，与快捷键页双向联动）
extension TranslationSettingsWindow {
    func appendCaptureModesCard(in content: GeekFlippedView, startY: CGFloat, cardX: CGFloat, cardW: CGFloat) -> CGFloat {
        let insetX: CGFloat = 16, headerX = cardX + insetX
        let rowH: CGFloat = 44, segH: CGFloat = 28, segY: CGFloat = 8, headerToCard: CGFloat = 24
        let rightColW: CGFloat = 276
        let rightColX = cardW - insetX - rightColW

        addSectionHeader("延时与全屏截图", x: headerX, y: startY, in: content)
        let bindBtn = GeekButton(title: "绑定快捷键 ›", style: .ghost)
        bindBtn.toolTip = "前往「快捷键」标签页为「延时截图」与「截取当前全屏」绑定全局热键"
        bindBtn.frame = NSRect(x: cardX + cardW - insetX - 96, y: startY - 4, width: 96, height: 24)
        bindBtn.onClick = { [weak self] in self?.switchTab(.shortcuts) }
        content.addSubview(bindBtn)

        let card = GeekCardView(frame: NSRect(x: cardX, y: startY + headerToCard, width: cardW, height: rowH * 2))
        content.addSubview(card)

        // 1) 延时截图默认秒数（常用档位 3 / 5 / 10 秒 + 1–60 秒自定义圆角输入框）
        let delayTip = "全局快捷键或菜单「按默认延时截图」使用的倒计时秒数（支持 1–60 秒，快捷键可在「快捷键」页绑定）"
        addRowLabel("延时截图默认秒数", y: 0, height: rowH, in: card, toolTip: delayTip)

        let unitW: CGFloat = 14
        let inputW: CGFloat = 58
        let presetW = rightColW - inputW - unitW - 14 // 162pt
        let presetSeg = GeekSegmentControl(
            items: DelayedCaptureSettings.quickPresets.map { "\($0) 秒" },
            selectedIndex: 0,
            mono: true
        )
        presetSeg.toolTip = delayTip
        presetSeg.frame = NSRect(x: rightColX, y: segY, width: presetW, height: segH)
        presetSeg.onSelect = { [weak self] idx in
            let presets = DelayedCaptureSettings.quickPresets
            guard presets.indices.contains(idx) else { return }
            self?.applyDelayedCaptureSeconds(presets[idx])
        }
        modeControls.extra.delayPresetSeg = presetSeg
        card.addSubview(presetSeg)

        let delayField = NSTextField()
        let delayBoxX = presetSeg.frame.maxX + 8
        let delayBox = GeekInputBox(
            frame: NSRect(x: delayBoxX, y: segY, width: inputW, height: segH),
            field: delayField,
            placeholder: "1-60",
            mono: true
        )
        delayField.alignment = .center
        delayBox.hintToolTip = "输入任意 1–60 的整数秒数，回车或失焦自动保存"
        let delayDel = InlineGeekFieldDelegate(onCommit: { [weak self] raw in
            let fallback = self?.appConfigProvider?().delayedCaptureSeconds ?? DelayedCaptureSettings.defaultSeconds
            let secs = DelayedCaptureSettings.parseSeconds(raw, fallback: fallback)
            self?.applyDelayedCaptureSeconds(secs)
        })
        delayField.delegate = delayDel
        modeControls.extra.fieldDelegates.append(delayDel)
        modeControls.extra.delaySecondsField = delayField
        card.addSubview(delayBox)

        let unitLbl = NSTextField(labelWithString: "秒")
        unitLbl.font = .systemFont(ofSize: 12.5, weight: .regular)
        unitLbl.textColor = GeekTheme.inkSecondary
        unitLbl.alignment = .right
        GeekTheme.placeCentered(unitLbl, x: delayBox.frame.maxX + 6, width: unitW, centerY: rowH * 0.5)
        card.addSubview(unitLbl)

        // 2) 截取当前全屏默认动作（仅复制 | 仅保存 | 复制并保存，右列与上一行严格 248pt 齐平）
        card.addHairline(atY: rowH)
        let fsTip = "通过全局快捷键或菜单触发「截取当前全屏」时的默认动作（快捷键可在「快捷键」页自由绑定）"
        addRowLabel("截取全屏默认动作", y: rowH, height: rowH, in: card, toolTip: fsTip)

        let fsSeg = GeekSegmentControl(
            items: FullScreenCaptureAction.allCases.map(\.title),
            selectedIndex: 0
        )
        fsSeg.toolTip = fsTip
        fsSeg.frame = NSRect(x: rightColX, y: rowH + segY, width: rightColW, height: segH)
        fsSeg.onSelect = { [weak self] idx in
            let all = FullScreenCaptureAction.allCases
            guard all.indices.contains(idx) else { return }
            self?.onAppConfigMutated? { $0.fullScreenCaptureAction = all[idx] }
        }
        modeControls.extra.fullScreenActionSeg = fsSeg
        card.addSubview(fsSeg)

        return card.frame.maxY
    }

    private func applyDelayedCaptureSeconds(_ secs: Int) {
        let clamped = DelayedCaptureSettings.clampedSeconds(secs)
        modeControls.extra.delaySecondsField?.stringValue = "\(clamped)"
        modeControls.extra.delayPresetSeg?.selectedIndex = DelayedCaptureSettings.quickPresets.firstIndex(of: clamped) ?? -1
        onAppConfigMutated? { $0.delayedCaptureSeconds = clamped }
    }

    func refreshCaptureModesUI(with cfg: AppConfig) {
        let secs = DelayedCaptureSettings.clampedSeconds(cfg.delayedCaptureSeconds)
        modeControls.extra.delaySecondsField?.stringValue = "\(secs)"
        modeControls.extra.delayPresetSeg?.selectedIndex = DelayedCaptureSettings.quickPresets.firstIndex(of: secs) ?? -1
        if let idx = FullScreenCaptureAction.allCases.firstIndex(of: cfg.fullScreenCaptureAction) {
            modeControls.extra.fullScreenActionSeg?.selectedIndex = idx
        }
    }
}

// MARK: - 录屏参数、导出美化与配置迁移

/// 通用页新增导出美化与反馈控件盒
@MainActor
final class GeneralExtraControls {
    var quickAccessSwitch: GeekToggleSwitch?
    var soundSwitch: GeekToggleSwitch?
    var filenameField: NSTextField?
    var filenamePreviewLabel: NSTextField?
    var pinGlowSlider: GeekProgressSlider?
    var shelfTriggerSeg: GeekSegmentControl?
    var delayPresetSeg: GeekSegmentControl?
    var delaySecondsField: NSTextField?
    var fullScreenActionSeg: GeekSegmentControl?
    var fieldDelegates: [InlineGeekFieldDelegate] = []
}

/// 轻量输入框代理：实时更新预览并在失焦或回车时自动保存（无需手动记着按回车）
@MainActor
final class InlineGeekFieldDelegate: NSObject, NSTextFieldDelegate {
    let onChange: ((String) -> Void)?
    let onCommit: (String) -> Void

    init(onChange: ((String) -> Void)? = nil, onCommit: @escaping (String) -> Void) {
        self.onChange = onChange
        self.onCommit = onCommit
    }

    func controlTextDidChange(_ obj: Notification) {
        if let tf = obj.object as? NSTextField { onChange?(tf.stringValue) }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if let tf = obj.object as? NSTextField { onCommit(tf.stringValue) }
    }
}

/// 设置「通用」页扩展：录屏参数卡片 + 导出美化/命名/音效卡片 + 配置迁移与诊断卡片
extension TranslationSettingsWindow {
    func appendRecordingAndBackupCards(in content: GeekFlippedView, startY: CGFloat, cardX: CGFloat, cardW: CGFloat) -> CGFloat {
        let insetX: CGFloat = 16, headerX = cardX + insetX
        let rowH: CGFloat = 44, segH: CGFloat = 28, segY: CGFloat = 8, switchH: CGFloat = 22, switchY: CGFloat = 11
        let switchX = cardW - insetX - 38, headerToCard: CGFloat = 24, sectionGap: CGFloat = 20

        modeControls.extra.fieldDelegates.removeAll()
        let afterCaptureModesY = appendCaptureModesCard(in: content, startY: startY, cardX: cardX, cardW: cardW)
        let recStartY = afterCaptureModesY + sectionGap

        // 1) 录屏参数（5 行）
        addSectionHeader("录屏参数", x: headerX, y: recStartY, in: content)
        let recCard = GeekCardView(frame: NSRect(x: cardX, y: recStartY + headerToCard, width: cardW, height: rowH * 5))
        content.addSubview(recCard)

        let gifTip = "轻巧：10fps · 最长边 ≤720px｜标准：12fps · 最长边 ≤960px（默认）｜高清：15fps · 最长边 ≤1280px"
        addRowLabel("GIF 清晰度与帧率", y: 0, height: rowH, in: recCard, toolTip: gifTip)
        let gifSeg = GeekSegmentControl(items: ["轻巧·720px", "标准·960px", "高清·1280px"], selectedIndex: 1, mono: true)
        gifSeg.toolTip = gifTip
        gifSeg.frame = NSRect(x: cardW - insetX - 312, y: segY, width: 312, height: segH)
        gifSeg.onSelect = { [weak self] idx in
            let presets: [(Int, Int)] = [(10, 720), (12, 960), (15, 1280)]
            guard presets.indices.contains(idx) else { return }
            self?.onAppConfigMutated? { $0.recordingOptions.gifFPS = presets[idx].0; $0.recordingOptions.gifMaxLongSide = presets[idx].1 }
        }
        modeControls.gifPresetSegment = gifSeg
        recCard.addSubview(gifSeg)

        recCard.addHairline(atY: rowH)
        let resTip = "标准：最长边 ≤1280px（适合聊天秒发）｜高清：最长边 ≤1920px（默认推荐）｜原画：Retina 1:1 原生像素"
        addRowLabel("MP4 清晰度", y: rowH, height: rowH, in: recCard, toolTip: resTip)
        let resSeg = GeekSegmentControl(items: MP4ResolutionPreset.allCases.map(\.title), selectedIndex: 1)
        resSeg.toolTip = resTip
        resSeg.frame = NSRect(x: cardW - insetX - 228, y: rowH + segY, width: 228, height: segH)
        resSeg.onSelect = { [weak self] idx in
            let list = MP4ResolutionPreset.allCases
            guard list.indices.contains(idx) else { return }
            self?.onAppConfigMutated? { $0.recordingOptions.mp4Resolution = list[idx] }
        }
        modeControls.mp4ResSegment = resSeg
        recCard.addSubview(resSeg)

        recCard.addHairline(atY: rowH * 2)
        let maxScreenHz = NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60
        let nativeBadge = min(120, max(60, maxScreenHz))
        let fpsTip = "「原刷」自动读取当前显示器刷新率（当前屏最高 \(nativeBadge)fps；原画超 2560px 时自动稳帧 60fps 防硬件掉帧），码率随帧率自适应拉升"
        addRowLabel("MP4 录制帧率", y: rowH * 2, height: rowH, in: recCard, toolTip: fpsTip)
        let mp4Seg = GeekSegmentControl(items: ["30 fps", "60 fps", "原刷(\(nativeBadge))"], selectedIndex: 0, mono: true)
        mp4Seg.toolTip = fpsTip
        mp4Seg.frame = NSRect(x: cardW - insetX - 276, y: rowH * 2 + segY, width: 276, height: segH)
        mp4Seg.onSelect = { [weak self] idx in
            let modes = MP4FrameRateMode.allCases
            guard modes.indices.contains(idx) else { return }
            let picked = modes[idx]
            self?.onAppConfigMutated? {
                $0.recordingOptions.mp4FPSMode = picked
                $0.recordingOptions.mp4FPS = (picked == .fps30) ? 30 : (picked == .fps60 ? 60 : nativeBadge)
            }
        }
        modeControls.mp4FpsSegment = mp4Seg
        recCard.addSubview(mp4Seg)

        recCard.addHairline(atY: rowH * 3)
        addRowLabel("录屏显示鼠标光标", y: rowH * 3, height: rowH, in: recCard)
        let cursorSw = GeekToggleSwitch(isOn: true)
        cursorSw.frame = NSRect(x: switchX, y: rowH * 3 + switchY, width: 38, height: switchH)
        cursorSw.onToggle = { [weak self] on in self?.onAppConfigMutated? { $0.recordingOptions.showsCursor = on } }
        modeControls.recordCursorSwitch = cursorSw
        recCard.addSubview(cursorSw)

        recCard.addHairline(atY: rowH * 4)
        let audioTip = "仅对 MP4 生效（macOS 13+ ScreenCaptureKit 原生内录系统声音，自动排除 MSnip 自身提示音）"
        addRowLabel("MP4 录制系统音频", y: rowH * 4, height: rowH, in: recCard, toolTip: audioTip)
        let audioSw = GeekToggleSwitch(isOn: false)
        audioSw.toolTip = audioTip
        audioSw.frame = NSRect(x: switchX, y: rowH * 4 + switchY, width: 38, height: switchH)
        audioSw.onToggle = { [weak self] on in self?.onAppConfigMutated? { $0.recordingOptions.captureSystemAudio = on } }
        modeControls.recordAudioSwitch = audioSw
        recCard.addSubview(audioSw)

        // 2) 命名、贴图与反馈（5 行，右侧 224pt 统一圆角控件列对齐 + 文件名实时预览）
        let yMid = recCard.frame.maxY + sectionGap
        addSectionHeader("命名、贴图与反馈", x: headerX, y: yMid, in: content)
        let extCard = GeekCardView(frame: NSRect(x: cardX, y: yMid + headerToCard, width: cardW, height: rowH * 5))
        content.addSubview(extCard)

        let rightColW: CGFloat = 276
        let rightColX = cardW - insetX - rightColW

        let fnTip = "支持占位符：{date} {time} {yyyy} {MM} {dd} {HH} {mm} {ss} {w} {h}（留空自动恢复默认）"
        addRowLabel("保存文件名模板", y: 0, height: rowH, in: extCard, toolTip: fnTip)
        let fnPreview = NSTextField(labelWithString: "")
        fnPreview.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        fnPreview.textColor = GeekTheme.inkMuted
        fnPreview.alignment = .right
        fnPreview.lineBreakMode = .byTruncatingMiddle
        GeekTheme.placeCentered(fnPreview, x: 146, width: max(40, rightColX - 158), centerY: rowH * 0.5)
        extCard.addSubview(fnPreview)
        modeControls.extra.filenamePreviewLabel = fnPreview

        let fnField = NSTextField()
        let fnBox = GeekInputBox(frame: NSRect(x: rightColX, y: segY, width: rightColW, height: segH), field: fnField, placeholder: SaveFilenameTemplate.defaultTemplate, mono: true)
        fnBox.hintToolTip = fnTip
        let fnDel = InlineGeekFieldDelegate(
            onChange: { [weak self] raw in self?.updateFilenamePreview(template: raw) },
            onCommit: { [weak self] raw in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let val = trimmed.isEmpty ? SaveFilenameTemplate.defaultTemplate : trimmed
                self?.modeControls.extra.filenameField?.stringValue = val
                self?.updateFilenamePreview(template: val)
                self?.onAppConfigMutated? { $0.filenameTemplate = val }
            }
        )
        fnField.delegate = fnDel
        modeControls.extra.fieldDelegates.append(fnDel)
        modeControls.extra.filenameField = fnField
        extCard.addSubview(fnBox)

        extCard.addHairline(atY: rowH)
        let glowTip = "拖动进度条精细调节贴图默认发光边（0% 为关闭，双击滑条复位 45%），与截图选框右侧发光边滑条及贴图 ⌥+滚轮实时双向同步"
        addRowLabel("贴图默认发光边", y: rowH, height: rowH, in: extCard, toolTip: glowTip)
        let glowSlider = GeekProgressSlider(value: 0.45, defaultValue: 0.45, zeroLabel: "关闭")
        glowSlider.toolTip = glowTip
        glowSlider.frame = NSRect(x: rightColX, y: rowH + segY, width: rightColW, height: segH)
        glowSlider.onChange = { [weak self] v in self?.onPreviewPinGlow?(v) }
        glowSlider.onCommit = { [weak self] v in self?.onAppConfigMutated? { $0.pinGlowStrength = v } }
        modeControls.extra.pinGlowSlider = glowSlider
        extCard.addSubview(glowSlider)

        extCard.addHairline(atY: rowH * 2)
        let shelfTip = "悬停展开（推荐）：贴顶停留 0.55 秒或拖文件到顶边下拉，截图静默收录不自动弹窗打扰；快捷键切换：仅热键或右键菜单呼出；常驻显示：紧凑悬浮条常驻顶部"
        addRowLabel("顶部暂存架显示方式", y: rowH * 2, height: rowH, in: extCard, toolTip: shelfTip)
        let shelfSeg = GeekSegmentControl(items: TopShelfTriggerMode.allCases.map(\.title), selectedIndex: 0)
        shelfSeg.toolTip = shelfTip
        shelfSeg.frame = NSRect(x: rightColX, y: rowH * 2 + segY, width: rightColW, height: segH)
        shelfSeg.onSelect = { [weak self] idx in
            let all = TopShelfTriggerMode.allCases
            guard all.indices.contains(idx) else { return }
            self?.onAppConfigMutated? { $0.topShelfTriggerMode = all[idx]; $0.topShelfHoverEnabled = (all[idx] != .manualOnly) }
        }
        modeControls.extra.shelfTriggerSeg = shelfSeg
        extCard.addSubview(shelfSeg)

        extCard.addHairline(atY: rowH * 3)
        let qaTip = "保存截图文件或录屏完成后，在屏幕左下角半透明显示 3.5 秒悬浮速览卡（悬停清晰并暂停倒计时，支持直接拖拽文件发送或访达定位）；普通截图复制默认静默无打扰"
        addRowLabel("保存 / 录屏后悬浮速览卡", y: rowH * 3, height: rowH, in: extCard, toolTip: qaTip)
        let qaSw = GeekToggleSwitch(isOn: true)
        qaSw.toolTip = qaTip
        qaSw.frame = NSRect(x: switchX, y: rowH * 3 + switchY, width: 38, height: switchH)
        qaSw.onToggle = { [weak self] on in self?.onAppConfigMutated? { $0.showQuickAccessOverlay = on } }
        modeControls.extra.quickAccessSwitch = qaSw
        extCard.addSubview(qaSw)

        extCard.addHairline(atY: rowH * 4)
        addRowLabel("复制与保存轻提示音", y: rowH * 4, height: rowH, in: extCard)
        let sndSw = GeekToggleSwitch(isOn: false)
        sndSw.frame = NSRect(x: switchX, y: rowH * 4 + switchY, width: 38, height: switchH)
        sndSw.onToggle = { [weak self] on in
            self?.onAppConfigMutated? { $0.soundFeedbackEnabled = on }
            if on { ClipboardAndSave.playFeedbackSound(enabled: true) }
        }
        modeControls.extra.soundSwitch = sndSw
        extCard.addSubview(sndSw)

        // 3) 配置与诊断（2 行）
        let y2 = extCard.frame.maxY + sectionGap
        addSectionHeader("配置与诊断", x: headerX, y: y2, in: content)
        let bakCard = GeekCardView(frame: NSRect(x: cardX, y: y2 + headerToCard, width: cardW, height: rowH * 2))
        content.addSubview(bakCard)

        let bakTip = "导入/导出常规偏好、保存格式与快捷键配置（自动排除全部 API Key 保证密钥安全）"
        addRowLabel("备份与迁移配置", y: 0, height: rowH, in: bakCard, toolTip: bakTip)
        let importBtn = GeekButton(title: "导入配置", style: .subtle)
        importBtn.frame = NSRect(x: cardW - insetX - 78, y: segY, width: 78, height: segH)
        importBtn.onClick = { [weak self] in
            guard let self, let imported = AppConfigPortability.importConfigInteractive() else { return }
            self.onAppConfigMutated? { $0 = imported }
            self.refreshGeneralAndPermissionsUI()
        }
        bakCard.addSubview(importBtn)

        let exportBtn = GeekButton(title: "导出配置", style: .subtle)
        exportBtn.frame = NSRect(x: importBtn.frame.minX - 8 - 78, y: segY, width: 78, height: segH)
        exportBtn.onClick = { [weak self] in
            AppConfigPortability.exportConfigInteractive(self?.appConfigProvider?() ?? AppConfig())
        }
        bakCard.addSubview(exportBtn)

        bakCard.addHairline(atY: rowH)
        let diagTip = "复制系统版本、芯片架构、屏幕拓扑、权限状态、近期崩溃报告与最近运行日志到剪贴板，便于反馈问题（不含密钥、截图或识别内容；日志只存于本机 ~/Library/Logs/MSnip）"
        addRowLabel("诊断信息与日志", y: rowH, height: rowH, in: bakCard, toolTip: diagTip)
        let diagBtn = GeekButton(title: "复制诊断信息", style: .subtle)
        diagBtn.frame = NSRect(x: cardW - insetX - 102, y: rowH + segY, width: 102, height: segH)
        diagBtn.onClick = { [weak self] in
            ClipboardAndSave.copyText(AppConfigPortability.buildDiagnosticReport(config: self?.appConfigProvider?() ?? AppConfig()))
            ToastHUD.show(message: "✓ 已复制诊断信息（含最近日志）到剪贴板")
        }
        bakCard.addSubview(diagBtn)

        let logBtn = GeekButton(title: "打开日志", style: .subtle)
        logBtn.frame = NSRect(x: diagBtn.frame.minX - 8 - 78, y: rowH + segY, width: 78, height: segH)
        logBtn.toolTip = "在访达中显示本地运行日志 msnip.log"
        logBtn.onClick = { DiagnosticLogging.revealLogFile() }
        bakCard.addSubview(logBtn)

        return bakCard.frame.maxY
    }

    private func updateFilenamePreview(template: String) {
        let ext = (appConfigProvider?().exportImageFormat.resolvedForCurrentOS ?? .png).fileExtension
        let sample = SaveFilenameTemplate.render(template: template, pixelWidth: 1920, pixelHeight: 1080, fileExtension: ext)
        modeControls.extra.filenamePreviewLabel?.stringValue = "例：\(sample)"
        modeControls.extra.filenamePreviewLabel?.toolTip = "示例导出文件名：\(sample)"
    }

    func refreshRecordingControlsUI(with cfg: AppConfig) {
        let ro = cfg.recordingOptions
        modeControls.gifPresetSegment?.selectedIndex = ro.gifMaxLongSide <= 760 ? 0 : (ro.gifMaxLongSide >= 1080 ? 2 : 1)
        if let rIdx = MP4ResolutionPreset.allCases.firstIndex(of: ro.mp4Resolution) { modeControls.mp4ResSegment?.selectedIndex = rIdx }
        if let fIdx = MP4FrameRateMode.allCases.firstIndex(of: ro.mp4FPSMode) { modeControls.mp4FpsSegment?.selectedIndex = fIdx }
        modeControls.recordCursorSwitch?.isOn = ro.showsCursor
        modeControls.recordAudioSwitch?.isOn = ro.captureSystemAudio
        modeControls.extra.filenameField?.stringValue = cfg.filenameTemplate
        updateFilenamePreview(template: cfg.filenameTemplate)
        modeControls.extra.pinGlowSlider?.value = cfg.pinGlowStrength
        if let sIdx = TopShelfTriggerMode.allCases.firstIndex(of: cfg.topShelfTriggerMode) { modeControls.extra.shelfTriggerSeg?.selectedIndex = sIdx }
        modeControls.extra.quickAccessSwitch?.isOn = cfg.showQuickAccessOverlay
        modeControls.extra.soundSwitch?.isOn = cfg.soundFeedbackEnabled
        refreshCaptureModesUI(with: cfg)
    }
}
