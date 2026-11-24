import AppKit
import Foundation
import MSnipCore

/// 设置「通用」页扩展：延时与全屏抓拍卡片（自定义延时秒数 + 截取全屏默认动作，与快捷键页双向联动）
extension TranslationSettingsWindow {
    func appendCaptureModesCard(in content: GeekFlippedView, startY: CGFloat, cardX: CGFloat, cardW: CGFloat) -> CGFloat {
        let insetX: CGFloat = 16, headerX = cardX + insetX
        let rowH: CGFloat = 44, segH: CGFloat = 28, segY: CGFloat = 8, headerToCard: CGFloat = 24
        let rightColW: CGFloat = 248
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
