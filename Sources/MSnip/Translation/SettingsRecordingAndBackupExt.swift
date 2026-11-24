import AppKit
import Foundation
import MSnipCore

/// 设置「通用」页扩展：录屏画质/原刷高帧率/光标/系统音频参数卡片 + 非敏感配置导出导入与系统诊断卡片
extension TranslationSettingsWindow {
    func appendRecordingAndBackupCards(in content: GeekFlippedView, startY: CGFloat, cardX: CGFloat, cardW: CGFloat) -> CGFloat {
        let insetX: CGFloat = 16, headerX = cardX + insetX
        let rowH: CGFloat = 44, segH: CGFloat = 28, segY: CGFloat = 8, switchH: CGFloat = 22, switchY: CGFloat = 11
        let switchX = cardW - insetX - 38, headerToCard: CGFloat = 24, sectionGap: CGFloat = 20

        // 1) 录屏参数（5 行：GIF 档位、MP4 清晰度、MP4 帧率、鼠标光标、系统音频）
        addSectionHeader("录屏参数", x: headerX, y: startY, in: content)
        let recCard = GeekCardView(frame: NSRect(x: cardX, y: startY + headerToCard, width: cardW, height: rowH * 5))
        content.addSubview(recCard)

        let gifTip = "轻巧：10fps · 最长边 ≤720px｜标准：12fps · 最长边 ≤960px（默认）｜高清：15fps · 最长边 ≤1280px"
        addRowLabel("GIF 清晰度与帧率", y: 0, height: rowH, in: recCard, toolTip: gifTip)
        let gifSeg = GeekSegmentControl(items: ["轻巧·720px", "标准·960px", "高清·1280px"], selectedIndex: 1, mono: true)
        gifSeg.toolTip = gifTip
        gifSeg.frame = NSRect(x: cardW - insetX - 282, y: segY, width: 282, height: segH)
        gifSeg.onSelect = { [weak self] idx in
            let presets: [(Int, Int)] = [(10, 720), (12, 960), (15, 1280)]
            guard presets.indices.contains(idx) else { return }
            let (fps, maxSide) = presets[idx]
            self?.onAppConfigMutated? {
                $0.recordingOptions.gifFPS = fps
                $0.recordingOptions.gifMaxLongSide = maxSide
            }
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
        let fpsTip = "「原刷」自动读取当前显示器刷新率（当前屏最高 \(nativeBadge)fps；原画超 2560px 时自动稳帧 60fps 防硬件编解码掉帧），码率随帧率自适应拉升"
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

        // 2) 配置与诊断（2 行）
        let y2 = recCard.frame.maxY + sectionGap
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
            let cfg = self?.appConfigProvider?() ?? AppConfig()
            AppConfigPortability.exportConfigInteractive(cfg)
        }
        bakCard.addSubview(exportBtn)

        bakCard.addHairline(atY: rowH)
        let diagTip = "复制系统版本、芯片架构、屏幕拓扑与权限状态摘要到剪贴板，便于排查系统授权问题（不含任何密钥）"
        addRowLabel("系统环境诊断", y: rowH, height: rowH, in: bakCard, toolTip: diagTip)
        let diagBtn = GeekButton(title: "复制诊断信息", style: .subtle)
        diagBtn.frame = NSRect(x: cardW - insetX - 102, y: rowH + segY, width: 102, height: segH)
        diagBtn.onClick = { [weak self] in
            let cfg = self?.appConfigProvider?() ?? AppConfig()
            ClipboardAndSave.copyText(AppConfigPortability.buildDiagnosticReport(config: cfg))
            ToastHUD.show(message: "✓ 已复制系统环境诊断信息到剪贴板")
        }
        bakCard.addSubview(diagBtn)

        return bakCard.frame.maxY
    }

    func refreshRecordingControlsUI(with cfg: AppConfig) {
        let ro = cfg.recordingOptions
        let gifIdx = ro.gifMaxLongSide <= 760 ? 0 : (ro.gifMaxLongSide >= 1080 ? 2 : 1)
        modeControls.gifPresetSegment?.selectedIndex = gifIdx
        if let rIdx = MP4ResolutionPreset.allCases.firstIndex(of: ro.mp4Resolution) {
            modeControls.mp4ResSegment?.selectedIndex = rIdx
        }
        if let fIdx = MP4FrameRateMode.allCases.firstIndex(of: ro.mp4FPSMode) {
            modeControls.mp4FpsSegment?.selectedIndex = fIdx
        }
        modeControls.recordCursorSwitch?.isOn = ro.showsCursor
        modeControls.recordAudioSwitch?.isOn = ro.captureSystemAudio
    }
}
