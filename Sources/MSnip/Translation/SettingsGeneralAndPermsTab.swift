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
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let content = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: page.bounds.width, height: 860))
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
        appSeg.toolTip = "切换设置与识字/翻译窗口的外观主题（也可点击右上角按钮一键切暗黑/明亮）"
        appSeg.frame = NSRect(x: cardW - insetX - 264, y: segY, width: 264, height: segH)
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
        expPill.frame = NSRect(x: cardW - insetX - 212, y: segY, width: 212, height: segH)
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
        colorFmtSegment.frame = NSRect(x: cardW - insetX - 248, y: rowH * 3 + segY, width: 248, height: segH)
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
        screenPermBtn.onClick = { [weak self] in self?.onOpenPermissionGuide?() }
        permCard.addSubview(screenPermBtn)

        permCard.addHairline(atY: rowH)
        axPermRow = GeekDotLabel(frame: NSRect(x: insetX, y: rowH, width: cardW - insetX * 2, height: rowH))
        permCard.addSubview(axPermRow)
        axPermBtn = GeekButton(title: "前往开启", style: .subtle)
        axPermBtn.frame = NSRect(x: cardW - insetX - 84, y: rowH + segY, width: 84, height: segH)
        axPermBtn.onClick = { [weak self] in self?.onOpenPermissionGuide?() }
        permCard.addSubview(axPermBtn)

        let bottomY = appendRecordingAndBackupCards(in: content, startY: permCard.frame.maxY + sectionGap, cardX: cardX, cardW: cardW)
        content.frame.size.height = bottomY + 24
    }

    func refreshGeneralAndPermissionsUI() {
        guard loginSwitch != nil else { return }
        let cfg = appConfigProvider?() ?? AppConfig()
        applyAppearanceMode(cfg.appearanceMode, persist: false)
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
