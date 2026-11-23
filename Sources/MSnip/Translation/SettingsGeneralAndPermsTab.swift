import AppKit
import Foundation
import MSnipCore

/// 识字与翻译双栏面板默认行为控件盒（跨「通用」与「翻译」双标签页实时同步）
@MainActor
final class GeneralModeControls {
    var ocrModeSegment: GeekSegmentControl?
    var translateModeSegment: GeekSegmentControl?
    var transTabDualSwitch: GeekToggleSwitch?
}

/// 设置窗口「通用」标签页（基础设置、识字与翻译面板模式、导出格式与钥匙串密钥加密、系统权限状态）
extension TranslationSettingsWindow {
    func buildGeneralPage(in page: GeekFlippedView) {
        let cardW = page.bounds.width - 56 // 724
        let rowH: CGFloat = 44

        let scroll = NSScrollView(frame: page.bounds)
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let content = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: page.bounds.width, height: 632))
        scroll.documentView = content
        page.addSubview(scroll)

        // 1) 基础（3 行 × 44px）
        addSectionHeader("基础", x: 30, y: 18, in: content)
        let baseCard = GeekCardView(frame: NSRect(x: 28, y: 42, width: cardW, height: rowH * 3))
        content.addSubview(baseCard)

        addRowLabel("开机自动启动", y: 0, height: rowH, in: baseCard)
        loginSwitch = GeekToggleSwitch()
        loginSwitch.frame = NSRect(x: cardW - 54, y: 11, width: 38, height: 22)
        loginSwitch.onToggle = { on in _ = LaunchAtLoginManager.setEnabled(on) }
        baseCard.addSubview(loginSwitch)

        baseCard.addHairline(atY: rowH)
        addRowLabel("截图时显示快捷键提示", y: rowH, height: rowH, in: baseCard)
        tipsSwitch = GeekToggleSwitch()
        tipsSwitch.frame = NSRect(x: cardW - 54, y: rowH + 11, width: 38, height: 22)
        tipsSwitch.onToggle = { [weak self] on in self?.onAppConfigMutated? { $0.showShortcutTips = on } }
        baseCard.addSubview(tipsSwitch)

        baseCard.addHairline(atY: rowH * 2)
        addRowLabel("截图保存位置", y: rowH * 2, height: rowH, in: baseCard)
        saveDirPathLabel = NSTextField(labelWithString: "~/Pictures/MSnip")
        saveDirPathLabel.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        saveDirPathLabel.textColor = GeekTheme.inkSecondary
        saveDirPathLabel.lineBreakMode = .byTruncatingMiddle
        saveDirPathLabel.alignment = .right
        GeekTheme.placeCentered(saveDirPathLabel, x: 164, width: cardW - 314, centerY: rowH * 2 + rowH * 0.5)
        baseCard.addSubview(saveDirPathLabel)

        let chooseBtn = GeekButton(title: "更改", style: .subtle)
        chooseBtn.frame = NSRect(x: cardW - 138, y: rowH * 2 + 7, width: 58, height: 30)
        chooseBtn.onClick = { [weak self] in self?.chooseQuickSaveDirectory() }
        baseCard.addSubview(chooseBtn)

        let openDirBtn = GeekButton(title: "打开", style: .subtle)
        openDirBtn.frame = NSRect(x: cardW - 74, y: rowH * 2 + 7, width: 58, height: 30)
        openDirBtn.onClick = { [weak self] in
            NSWorkspace.shared.open(ClipboardAndSave.resolveQuickSaveDirectory(preferred: self?.appConfigProvider?().lastSaveDirectory))
        }
        baseCard.addSubview(openDirBtn)

        // 2) 识字与翻译展示模式（2 行 × 44px，支持各自独立设置原位或自动打开双栏面板）
        addSectionHeader("识字与翻译面板", x: 30, y: 194, in: content)
        let panelCard = GeekCardView(frame: NSRect(x: 28, y: 218, width: cardW, height: rowH * 2))
        content.addSubview(panelCard)

        addRowLabel("提取文字 (OCR) 自动打开双栏面板", y: 0, height: rowH, in: panelCard)
        let ocrSeg = GeekSegmentControl(items: ["原位划词", "双栏面板"], selectedIndex: 0)
        ocrSeg.toolTip = "选择提取文字的默认交互方式（按住 ⌥ 触发可临时切换为另一种方式）"
        ocrSeg.frame = NSRect(x: cardW - 196, y: 7, width: 180, height: 30)
        ocrSeg.onSelect = { [weak self] idx in
            self?.onAppConfigMutated? { $0.ocrAutoOpenDualPane = (idx == 1) }
        }
        modeControls.ocrModeSegment = ocrSeg
        panelCard.addSubview(ocrSeg)

        panelCard.addHairline(atY: rowH)
        addRowLabel("截图翻译自动打开双栏面板", y: rowH, height: rowH, in: panelCard)
        let trSeg = GeekSegmentControl(items: ["原位译文", "双栏面板"], selectedIndex: 0)
        trSeg.toolTip = "选择截图翻译的默认交互方式（按住 ⌥ 触发可临时切换为另一种方式）"
        trSeg.frame = NSRect(x: cardW - 196, y: rowH + 7, width: 180, height: 30)
        trSeg.onSelect = { [weak self] idx in
            let dual = (idx == 1)
            self?.onAppConfigMutated? { $0.translateAutoOpenDualPane = dual }
            self?.modeControls.transTabDualSwitch?.isOn = dual
        }
        modeControls.translateModeSegment = trSeg
        panelCard.addSubview(trSeg)

        // 3) 格式与密钥安全（3 行 × 44px）
        addSectionHeader("格式与安全", x: 30, y: 326, in: content)
        let fmtCard = GeekCardView(frame: NSRect(x: 28, y: 350, width: cardW, height: rowH * 3))
        content.addSubview(fmtCard)

        addRowLabel("取色复制格式", y: 0, height: rowH, in: fmtCard)
        colorFmtSegment = GeekSegmentControl(items: ColorCopyFormat.allCases.map(\.rawValue), selectedIndex: 0, mono: true)
        colorFmtSegment.frame = NSRect(x: cardW - 264, y: 7, width: 248, height: 30)
        colorFmtSegment.onSelect = { [weak self] idx in
            guard ColorCopyFormat.allCases.indices.contains(idx) else { return }
            self?.onAppConfigMutated? { $0.colorCopyFormat = ColorCopyFormat.allCases[idx] }
        }
        fmtCard.addSubview(colorFmtSegment)

        fmtCard.addHairline(atY: rowH)
        addRowLabel("录屏导出格式", y: rowH, height: rowH, in: fmtCard)
        recFmtSegment = GeekSegmentControl(items: ["GIF", "MP4"], selectedIndex: 0, mono: true)
        recFmtSegment.frame = NSRect(x: cardW - 144, y: rowH + 7, width: 128, height: 30)
        recFmtSegment.onSelect = { [weak self] idx in
            self?.onAppConfigMutated? { $0.preferredRecordingFormat = (idx == 1) ? .mp4 : .gif }
        }
        fmtCard.addSubview(recFmtSegment)

        fmtCard.addHairline(atY: rowH * 2)
        addRowLabel("钥匙串加密存储 API 密钥", y: rowH * 2, height: rowH, in: fmtCard)
        keychainSwitch = GeekToggleSwitch()
        keychainSwitch.toolTip = CredentialVault.hasStableCodeSignature()
            ? "将翻译与公式 API 密钥存入 macOS 登录钥匙串，本地 JSON 自动脱敏留空"
            : "将密钥转存至系统钥匙串（提示：建议先运行 scripts/setup-cert.sh 配置固定证书以免升级弹窗）"
        keychainSwitch.frame = NSRect(x: cardW - 54, y: rowH * 2 + 11, width: 38, height: 22)
        keychainSwitch.onToggle = { [weak self] on in
            guard let self else { return }
            self.commitCurrentFormEdits()
            self.draft.preferKeychainStorage = on
            self.persistDraft()
        }
        fmtCard.addSubview(keychainSwitch)

        // 4) 系统权限（2 行 × 44px）
        addSectionHeader("系统权限", x: 30, y: 502, in: content)
        let permCard = GeekCardView(frame: NSRect(x: 28, y: 526, width: cardW, height: rowH * 2))
        content.addSubview(permCard)

        screenPermRow = GeekDotLabel(frame: NSRect(x: 16, y: 0, width: cardW - 32, height: rowH))
        permCard.addSubview(screenPermRow)
        screenPermBtn = GeekButton(title: "前往开启", style: .accent)
        screenPermBtn.frame = NSRect(x: cardW - 104, y: 7, width: 88, height: 30)
        screenPermBtn.onClick = { [weak self] in self?.onOpenPermissionGuide?() }
        permCard.addSubview(screenPermBtn)

        permCard.addHairline(atY: rowH)
        axPermRow = GeekDotLabel(frame: NSRect(x: 16, y: rowH, width: cardW - 32, height: rowH))
        permCard.addSubview(axPermRow)
        axPermBtn = GeekButton(title: "前往开启", style: .subtle)
        axPermBtn.frame = NSRect(x: cardW - 104, y: rowH + 7, width: 88, height: 30)
        axPermBtn.onClick = { [weak self] in self?.onOpenPermissionGuide?() }
        permCard.addSubview(axPermBtn)
    }

    func refreshGeneralAndPermissionsUI() {
        guard loginSwitch != nil else { return }
        let cfg = appConfigProvider?() ?? AppConfig()
        loginSwitch.isOn = LaunchAtLoginManager.isEnabled
        tipsSwitch.isOn = cfg.showShortcutTips
        keychainSwitch?.isOn = draft.preferKeychainStorage
        modeControls.ocrModeSegment?.selectedIndex = cfg.ocrAutoOpenDualPane ? 1 : 0
        modeControls.translateModeSegment?.selectedIndex = cfg.translateAutoOpenDualPane ? 1 : 0
        modeControls.transTabDualSwitch?.isOn = cfg.translateAutoOpenDualPane
        if let cIdx = ColorCopyFormat.allCases.firstIndex(of: cfg.colorCopyFormat) { colorFmtSegment.selectedIndex = cIdx }
        recFmtSegment.selectedIndex = (cfg.preferredRecordingFormat == .mp4) ? 1 : 0
        let resolvedDir = ClipboardAndSave.resolveQuickSaveDirectory(preferred: cfg.lastSaveDirectory).path
        saveDirPathLabel.stringValue = resolvedDir.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        saveDirPathLabel.toolTip = resolvedDir

        let scrOK = ScreenCapturer.runtimeVerifiedAccess || CGPreflightScreenCaptureAccess()
        screenPermRow.dotColor = scrOK ? GeekTheme.emerald : GeekTheme.amber
        screenPermRow.text = "屏幕录制"
        screenPermRow.detail = scrOK ? "已授权" : ""
        screenPermBtn.isHidden = scrOK

        let axOK = RegionDetector.checkAccessibilityPermission(prompt: false)
        axPermRow.dotColor = axOK ? GeekTheme.emerald : GeekTheme.inkMuted
        axPermRow.text = "辅助功能"
        axPermRow.detail = axOK ? "已授权" : ""
        axPermBtn.isHidden = axOK

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
        lbl.font = .systemFont(ofSize: 13.0, weight: .semibold); lbl.textColor = GeekTheme.inkSecondary
        GeekTheme.placeCentered(lbl, x: x, width: 160, centerY: y + 9.0)
        parent.addSubview(lbl)
    }

    func addRowLabel(_ text: String, y: CGFloat, height: CGFloat, in card: GeekCardView) {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = .systemFont(ofSize: 14.0, weight: .medium); lbl.textColor = GeekTheme.inkPrimary; lbl.sizeToFit()
        GeekTheme.placeCentered(lbl, x: 16, width: lbl.frame.width + 6, centerY: y + height * 0.5)
        card.addSubview(lbl)
    }

    func revealConfigDirectory() {
        commitCurrentFormEdits(); persistDraft()
        if !FileManager.default.fileExists(atPath: AppConfig.configURL.path) { appConfigProvider?().save() }
        NSWorkspace.shared.open(AppConfig.configURL.deletingLastPathComponent())
    }
}
