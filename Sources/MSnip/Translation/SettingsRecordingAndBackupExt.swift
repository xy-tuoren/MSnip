import AppKit
import Foundation
import MSnipCore

/// 通用页新增导出美化与反馈控件盒（保持主标签页文件 ≤ 300 行）
@MainActor
final class GeneralExtraControls {
    var soundSwitch: GeekToggleSwitch?
    var filenameField: NSTextField?
    var filenamePreviewLabel: NSTextField?
    var pinGlowSeg: GeekSegmentControl?
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
        gifSeg.frame = NSRect(x: cardW - insetX - 282, y: segY, width: 282, height: segH)
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
        resSeg.frame = NSRect(x: cardW - insetX - 204, y: rowH + segY, width: 204, height: segH)
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
        mp4Seg.frame = NSRect(x: cardW - insetX - 234, y: rowH * 2 + segY, width: 234, height: segH)
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

        // 2) 命名、贴图与反馈（4 行，右侧 224pt 统一圆角控件列对齐 + 文件名实时预览）
        let yMid = recCard.frame.maxY + sectionGap
        addSectionHeader("命名、贴图与反馈", x: headerX, y: yMid, in: content)
        let extCard = GeekCardView(frame: NSRect(x: cardX, y: yMid + headerToCard, width: cardW, height: rowH * 4))
        content.addSubview(extCard)

        let rightColW: CGFloat = 224
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
        let glowTip = "贴图默认呈现淡淡白光外缘、悬浮时亮起柔和蓝边（截图右侧第 2 颗圆钮或贴图上按住 ⌥+滚轮可精细调节 0%–100%）"
        addRowLabel("贴图默认发光边", y: rowH, height: rowH, in: extCard, toolTip: glowTip)
        let glowSeg = GeekSegmentControl(items: ["关闭", "柔和 45%", "明亮 80%"], selectedIndex: 1)
        glowSeg.toolTip = glowTip
        glowSeg.frame = NSRect(x: rightColX, y: rowH + segY, width: rightColW, height: segH)
        glowSeg.onSelect = { [weak self] idx in
            let levels: [CGFloat] = [0.0, 0.45, 0.80]
            guard levels.indices.contains(idx) else { return }
            self?.onAppConfigMutated? { $0.pinGlowStrength = levels[idx] }
        }
        modeControls.extra.pinGlowSeg = glowSeg
        extCard.addSubview(glowSeg)

        extCard.addHairline(atY: rowH * 2)
        let shelfTip = "悬停展开（推荐）：贴顶停留 0.55 秒或拖文件到顶边下拉，新截图自动探头 3 秒，点顶栏秒收；快捷键切换：仅热键或右键菜单呼出；常驻显示：紧凑悬浮条常驻顶部"
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
        addRowLabel("复制与保存轻提示音", y: rowH * 3, height: rowH, in: extCard)
        let sndSw = GeekToggleSwitch(isOn: false)
        sndSw.frame = NSRect(x: switchX, y: rowH * 3 + switchY, width: 38, height: switchH)
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
        let diagTip = "复制系统版本、芯片架构、屏幕拓扑与权限状态摘要到剪贴板，便于排查系统授权问题（不含任何密钥）"
        addRowLabel("系统环境诊断", y: rowH, height: rowH, in: bakCard, toolTip: diagTip)
        let diagBtn = GeekButton(title: "复制诊断信息", style: .subtle)
        diagBtn.frame = NSRect(x: cardW - insetX - 102, y: rowH + segY, width: 102, height: segH)
        diagBtn.onClick = { [weak self] in
            ClipboardAndSave.copyText(AppConfigPortability.buildDiagnosticReport(config: self?.appConfigProvider?() ?? AppConfig()))
            ToastHUD.show(message: "✓ 已复制系统环境诊断信息到剪贴板")
        }
        bakCard.addSubview(diagBtn)

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
        let g = cfg.pinGlowStrength
        modeControls.extra.pinGlowSeg?.selectedIndex = g <= 0.01 ? 0 : (abs(g - 0.45) < 0.06 ? 1 : (abs(g - 0.80) < 0.06 ? 2 : -1))
        if let sIdx = TopShelfTriggerMode.allCases.firstIndex(of: cfg.topShelfTriggerMode) { modeControls.extra.shelfTriggerSeg?.selectedIndex = sIdx }
        modeControls.extra.soundSwitch?.isOn = cfg.soundFeedbackEnabled
        refreshCaptureModesUI(with: cfg)
    }
}
