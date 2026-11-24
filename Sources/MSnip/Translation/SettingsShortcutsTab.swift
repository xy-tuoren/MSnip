import AppKit
import Foundation
import MSnipCore

/// 设置窗口独立「快捷键」标签页（全局 9 项双键优先热键 + 强制接管一键开关 + 截图内 24 项单键自定义）
extension TranslationSettingsWindow {
    func buildShortcutsPage(in page: GeekFlippedView) {
        let cardW = page.bounds.width - 56 // 724

        // 1) 顶部模式与操作栏（全局热键 | 截图内按键 + 开关 + 恢复默认，严格 8pt 外圈边距）
        let topStrip = GeekCardView(frame: NSRect(x: 28, y: 16, width: cardW, height: 48))
        page.addSubview(topStrip)

        shortcutModeSegment = GeekSegmentControl(
            items: ["全局热键 (\(GlobalHotKeyAction.allCases.count))", "截图内按键 (\(CanvasAction.allCases.count))"],
            selectedIndex: 0
        )
        shortcutModeSegment.frame = NSRect(x: 8, y: 8, width: 268, height: 32)
        shortcutModeSegment.onSelect = { [weak self] idx in self?.switchShortcutSubMode(idx) }
        topStrip.addSubview(shortcutModeSegment)

        let auditBtn = GeekButton(title: "无冲突 · 已占热键", symbol: "checkmark.shield", style: .emeraldSoft)
        auditBtn.toolTip = "点击实时查看 macOS 系统热键占用、后台运行中应用冲突，并支持一键更换推荐键"
        auditBtn.frame = NSRect(x: 286, y: 8, width: 158, height: 32)
        auditBtn.onClick = { [weak self] in self?.presentHotKeyConflictPopover() }
        shortcutAudit.auditButton = auditBtn
        topStrip.addSubview(auditBtn)

        hotKeyEnableLabel = NSTextField(labelWithString: "启用全局热键")
        hotKeyEnableLabel.font = .systemFont(ofSize: 13.0, weight: .medium)
        hotKeyEnableLabel.textColor = GeekTheme.inkSecondary
        hotKeyEnableLabel.alignment = .right
        GeekTheme.placeCentered(hotKeyEnableLabel, x: cardW - 252, width: 92, centerY: 24.0)
        topStrip.addSubview(hotKeyEnableLabel)

        hotKeyEnableSwitch = GeekToggleSwitch(isOn: true)
        hotKeyEnableSwitch.frame = NSRect(x: cardW - 150, y: 13, width: 38, height: 22)
        hotKeyEnableSwitch.onToggle = { [weak self] on in
            self?.onAppConfigMutated? { $0.hotKeysEnabled = on }
            _ = self?.rescanHotKeyConflicts()
            self?.refreshGeneralAndPermissionsUI()
        }
        topStrip.addSubview(hotKeyEnableSwitch)

        resetShortcutsBtn = GeekButton(title: "恢复默认", symbol: "arrow.counterclockwise", style: .subtle)
        resetShortcutsBtn.frame = NSRect(x: cardW - 98, y: 8, width: 90, height: 32)
        resetShortcutsBtn.onClick = { [weak self] in self?.resetCurrentShortcutSubMode() }
        topStrip.addSubview(resetShortcutsBtn)

        // 2) 子页面容器
        let subFrame = NSRect(x: 0, y: 74, width: page.bounds.width, height: page.bounds.height - 74)
        globalShortcutsBox = GeekFlippedView(frame: subFrame)
        canvasShortcutsBox = GeekFlippedView(frame: subFrame)
        canvasShortcutsBox.isHidden = true
        page.addSubview(globalShortcutsBox)
        page.addSubview(canvasShortcutsBox)

        buildGlobalShortcutsSubPage(in: globalShortcutsBox, cardW: cardW)
        buildCanvasShortcutsSubPage(in: canvasShortcutsBox, cardW: cardW)
    }

    private func buildGlobalShortcutsSubPage(in container: GeekFlippedView, cardW: CGFloat) {
        let presetCard = GeekCardView(frame: NSRect(x: 28, y: 4, width: cardW, height: 46))
        container.addSubview(presetCard)

        let pLbl = NSTextField(labelWithString: "快捷预设")
        pLbl.font = .systemFont(ofSize: 13.5, weight: .regular); pLbl.textColor = GeekTheme.inkPrimary
        GeekTheme.placeCentered(pLbl, x: 16, width: 68, centerY: 23.0)
        presetCard.addSubview(pLbl)

        presetSegment = GeekSegmentControl(items: HotKeyPreset.allCases.map(\.segmentTitle), selectedIndex: 0, mono: true)
        presetSegment.frame = NSRect(x: 88, y: 7, width: cardW - 104, height: 32)
        presetSegment.onSelect = { [weak self] idx in
            guard let self, HotKeyPreset.allCases.indices.contains(idx) else { return }
            self.cancelInlineHotKeyRecording(restoreHotKeys: false)
            let preset = HotKeyPreset.allCases[idx]
            self.onAppConfigMutated? { $0.hotKeyPreset = preset; $0.clearCustomHotKeys(); $0.hotKeysEnabled = true }
            _ = self.rescanHotKeyConflicts()
            self.refreshGeneralAndPermissionsUI()
        }
        presetCard.addSubview(presetSegment)
        buildPriorityTakeoverCard(in: container, cardW: cardW)

        addSectionHeader("全局触发动作", x: 44, y: 112, in: container)
        hotKeyHintLabel = NSTextField(labelWithString: "点击键帽录入双键（如 ⌥A、⌃1、F1） · Esc 取消 · ⌫ 停用单项")
        hotKeyHintLabel.font = .systemFont(ofSize: 11.5, weight: .regular); hotKeyHintLabel.textColor = GeekTheme.inkMuted
        hotKeyHintLabel.alignment = .right; hotKeyHintLabel.lineBreakMode = .byTruncatingTail
        hotKeyHintLabel.toolTip = hotKeyHintLabel.stringValue
        GeekTheme.placeCentered(hotKeyHintLabel, x: 164, width: (28 + cardW - 16) - 164, centerY: 120.0)
        container.addSubview(hotKeyHintLabel)

        let listCard = GeekCardView(frame: NSRect(x: 28, y: 136, width: cardW, height: 276))
        container.addSubview(listCard)

        let scroll = NSScrollView(frame: listCard.bounds.insetBy(dx: 0, dy: 1))
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true

        let rowH: CGFloat = 54
        let actions = GlobalHotKeyAction.allCases
        let docView = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: cardW, height: CGFloat(actions.count) * rowH))
        for (i, slot) in actions.enumerated() {
            let ry = CGFloat(i) * rowH
            let row = GeekHoverRowView(frame: NSRect(x: 0, y: ry, width: cardW, height: rowH))
            if i > 0 {
                row.addSubview(GeekSurfaceView(frame: NSRect(x: 16, y: 0, width: cardW - 32, height: 1), fill: GeekTheme.divider))
            }
            row.addSubview(GeekShortcutIconBadge(symbol: slot.symbol, frame: NSRect(x: 16, y: 11, width: 32, height: 32)))

            let titleLbl = NSTextField(labelWithString: slot.title)
            titleLbl.font = .systemFont(ofSize: 13.5, weight: .medium)
            titleLbl.textColor = GeekTheme.inkPrimary
            row.addSubview(titleLbl)

            let subLbl = NSTextField(labelWithString: slot.subtitle)
            subLbl.font = .systemFont(ofSize: 11.5, weight: .regular)
            subLbl.textColor = GeekTheme.inkSecondary
            subLbl.lineBreakMode = .byTruncatingTail
            subLbl.toolTip = slot.subtitle
            row.toolTip = "\(slot.title)\n\(slot.subtitle)"
            row.addSubview(subLbl)
            shortcutAudit.rowSubLabels[slot] = subLbl
            GeekTheme.placeTwoLineStack(titleLbl, subLbl, x: 60, width: cardW - 216, centerY: rowH * 0.5, gap: 2.0)

            let badge = HotKeyConflictBadgeView(frame: NSRect(x: cardW - 266, y: 16, width: 114, height: 22))
            badge.isHidden = true
            badge.onClick = { [weak self] in self?.presentHotKeyConflictPopover() }
            shortcutAudit.rowBadges[slot] = badge
            row.addSubview(badge)

            let pill = GeekHotKeyPill(frame: NSRect(x: cardW - 144, y: 12, width: 128, height: 30))
            pill.toolTip = "点击录入新组合键 · 录入时按 ⌫ 停用该项"
            pill.onClick = { [weak self] in self?.toggleInlineGlobalHotKey(slot) }
            hotKeyPills[slot] = pill
            row.addSubview(pill)
            docView.addSubview(row)
        }
        scroll.documentView = docView
        listCard.addSubview(scroll)
    }

    func switchShortcutSubMode(_ idx: Int) {
        HotKeyConflictPopover.shared.closeIfShown()
        cancelInlineHotKeyRecording(restoreHotKeys: true)
        shortcutSubMode = idx
        shortcutModeSegment.selectedIndex = idx
        globalShortcutsBox.isHidden = (idx != 0)
        canvasShortcutsBox.isHidden = (idx != 1)
        hotKeyEnableLabel.isHidden = (idx != 0)
        hotKeyEnableSwitch.isHidden = (idx != 0)
        shortcutAudit.auditButton?.isHidden = (idx != 0)
        if idx == 0 { _ = rescanHotKeyConflicts() }
        refreshGeneralAndPermissionsUI()
    }

    private func resetCurrentShortcutSubMode() {
        cancelInlineHotKeyRecording(restoreHotKeys: true)
        if shortcutSubMode == 0 {
            onAppConfigMutated? { $0.clearCustomHotKeys(); $0.hotKeysEnabled = true }
            _ = rescanHotKeyConflicts()
            hotKeyHintLabel.textColor = GeekTheme.emerald
            hotKeyHintLabel.stringValue = "✓ 已恢复为当前预设方案默认热键"
        } else {
            onAppConfigMutated? { $0.resetAllCanvasKeys() }
            canvasKeyHintLabel.textColor = GeekTheme.emerald
            canvasKeyHintLabel.stringValue = "✓ 已恢复全部截图内按键为默认单键"
        }
        refreshGeneralAndPermissionsUI()
    }

    func refreshShortcutsPageUI(with cfg: AppConfig) {
        guard hotKeyEnableSwitch != nil else { return }
        if Date().timeIntervalSince(shortcutAudit.snapshot.scannedAt) > 2.5 {
            _ = rescanHotKeyConflicts(with: cfg)
        }
        let priorityActive = syncPriorityTakeoverStatus(with: cfg)
        hotKeyEnableSwitch.isOn = cfg.hotKeysEnabled
        presetSegment.selectedIndex = cfg.hasCustomHotKeys
            ? -1
            : (HotKeyPreset.allCases.firstIndex(of: cfg.hotKeyPreset) ?? 0)
        let failedRegs = (cfg.hotKeysEnabled && !priorityActive) ? (shortcutAudit.failedHotKeyActionsProvider?() ?? []) : []
        var blockingCount = 0
        var warningCount = 0
        for slot in GlobalHotKeyAction.allCases {
            let active = cfg.activeCombo(for: slot)
            let isMod = cfg.globalHotKeyOverrides[slot.rawValue] != nil
            var conflicts = (cfg.hotKeysEnabled && active != nil)
                ? HotKeyConflictScanner.evaluate(combo: active!, for: slot, config: cfg, snapshot: shortcutAudit.snapshot)
                : []
            if active != nil && failedRegs.contains(slot) && !conflicts.contains(where: { $0.severity == .blocking }) {
                conflicts.insert(HotKeyConflict(
                    severity: .blocking,
                    owner: "系统热键注册",
                    shortBadge: "注册失败",
                    detailMessage: "常规 Carbon 热键注册被系统拒绝（已被独占），请更换键位或开启上方「冲突时强制优先接管」",
                    requiresDoublePressConfirm: true
                ), at: 0)
            }
            let top = conflicts.first
            if let sev = top?.severity {
                if sev == .blocking { blockingCount += 1 } else { warningCount += 1 }
            }
            shortcutAudit.rowBadges[slot]?.configure(conflict: top, overridden: priorityActive)
            if let subLbl = shortcutAudit.rowSubLabels[slot], let rowW = subLbl.superview?.bounds.width {
                subLbl.frame.size.width = (top != nil) ? (rowW - 332) : (rowW - 216)
            }
            hotKeyPills[slot]?.configure(
                label: active?.displayString,
                recording: activeRecordingSlot == slot,
                modified: isMod,
                conflict: priorityActive ? nil : top?.severity,
                prompt: "按下双键…"
            )
        }
        if let btn = shortcutAudit.auditButton {
            let total = blockingCount + warningCount
            if priorityActive && total > 0 {
                btn.title = "已优先接管 · 查看"
                btn.symbolName = "bolt.shield"
                btn.style = .accent
            } else if blockingCount > 0 {
                btn.title = "\(total) 项冲突 · 查看"
                btn.symbolName = "exclamationmark.triangle"
                btn.style = .dangerSoft
            } else if warningCount > 0 {
                btn.title = "\(total) 项预警 · 查看"
                btn.symbolName = "exclamationmark.triangle"
                btn.style = .amberSoft
            } else {
                btn.title = "无冲突 · 已占热键"
                btn.symbolName = "checkmark.shield"
                btn.style = .emeraldSoft
            }
        }
        for act in CanvasAction.allCases {
            let k = cfg.canvasKey(for: act)
            canvasKeyPills[act]?.configure(
                label: k.uppercased(),
                recording: activeCanvasRecording == act,
                modified: k != act.defaultKey,
                prompt: "按单键…"
            )
        }
    }

    private func toggleInlineGlobalHotKey(_ slot: GlobalHotKeyAction) {
        if activeRecordingSlot == slot { cancelInlineHotKeyRecording(restoreHotKeys: true); return }
        activeCanvasRecording = nil
        shortcutAudit.pendingForceCombo = nil
        activeRecordingSlot = slot
        onBeginHotKeyRecording?()
        _ = rescanHotKeyConflicts()
        hotKeyHintLabel.setTextWithTooltip("请按下「\(slot.title)」快捷键（实时检测系统与应用冲突 · Esc 取消 · ⌫ 停用）", color: GeekTheme.accent)
        refreshGeneralAndPermissionsUI()
    }

    func cancelInlineHotKeyRecording(restoreHotKeys: Bool) {
        let hadGlobal = (activeRecordingSlot != nil)
        let hadCanvas = (activeCanvasRecording != nil)
        guard hadGlobal || hadCanvas else { return }
        activeRecordingSlot = nil
        activeCanvasRecording = nil
        shortcutAudit.pendingForceCombo = nil
        if hadGlobal && restoreHotKeys { onEndHotKeyRecording?() }
        hotKeyHintLabel?.setTextWithTooltip("点击键帽录入双键（如 ⌥A、⌃1、F1） · Esc 取消 · ⌫ 停用单项", color: GeekTheme.inkMuted)
        canvasKeyHintLabel?.setTextWithTooltip("点击键帽直接按单键修改（中英文通用 · 冲突自动互换 · ⌫ 恢复默认）", color: GeekTheme.inkMuted)
        refreshGeneralAndPermissionsUI()
    }
}
