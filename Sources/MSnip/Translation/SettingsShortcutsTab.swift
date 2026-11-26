import AppKit
import Foundation
import MSnipCore

/// 设置窗口独立「快捷键」标签页（全局系统热键 + 强制接管一键开关 + 截图内 24 项单键自定义）
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
        auditBtn.frame = NSRect(x: 286, y: 8, width: 174, height: 32)
        auditBtn.onClick = { [weak self] in self?.presentHotKeyConflictPopover() }
        shortcutAudit.auditButton = auditBtn
        topStrip.addSubview(auditBtn)

        hotKeyEnableLabel = NSTextField(labelWithString: "启用全局热键")
        hotKeyEnableLabel.font = .systemFont(ofSize: 13.0, weight: .medium)
        hotKeyEnableLabel.textColor = GeekTheme.inkSecondary
        hotKeyEnableLabel.alignment = .right
        GeekTheme.placeCentered(hotKeyEnableLabel, x: cardW - 258, width: 96, centerY: 24.0)
        topStrip.addSubview(hotKeyEnableLabel)

        hotKeyEnableSwitch = GeekToggleSwitch(isOn: true)
        hotKeyEnableSwitch.frame = NSRect(x: cardW - 152, y: 13, width: 38, height: 22)
        hotKeyEnableSwitch.onToggle = { [weak self] on in
            self?.onAppConfigMutated? { $0.hotKeysEnabled = on }
            _ = self?.rescanHotKeyConflicts()
            self?.refreshGeneralAndPermissionsUI()
        }
        topStrip.addSubview(hotKeyEnableSwitch)

        resetShortcutsBtn = GeekButton(title: "恢复默认", symbol: "arrow.counterclockwise", style: .subtle)
        resetShortcutsBtn.frame = NSRect(x: cardW - 102, y: 8, width: 94, height: 32)
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

        let listCard = GeekCardView(frame: NSRect(x: 28, y: 136, width: cardW, height: max(276, container.bounds.height - 150)))
        container.addSubview(listCard)

        let scroll = NSScrollView(frame: listCard.bounds.insetBy(dx: 0, dy: 1))
        configureVerticalScroll(scroll)

        let rowH: CGFloat = 54
        let actions = GlobalHotKeyAction.allCases
        let docW = scroll.contentSize.width
        let docView = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: docW, height: CGFloat(actions.count) * rowH))
        docView.autoresizingMask = [.width]
        for (i, slot) in actions.enumerated() {
            let ry = CGFloat(i) * rowH
            let row = GeekHoverRowView(frame: NSRect(x: 0, y: ry, width: docW, height: rowH))
            if i > 0 {
                row.addSubview(GeekSurfaceView(frame: NSRect(x: 16, y: 0, width: docW - 32, height: 1), fill: GeekTheme.divider))
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
            GeekTheme.placeTwoLineStack(titleLbl, subLbl, x: 60, width: docW - 216, centerY: rowH * 0.5, gap: 2.0)

            let badge = HotKeyConflictBadgeView(frame: NSRect(x: docW - 266, y: 16, width: 114, height: 22))
            badge.isHidden = true
            badge.onClick = { [weak self] in self?.presentHotKeyConflictPopover() }
            shortcutAudit.rowBadges[slot] = badge
            row.addSubview(badge)

            let pill = GeekHotKeyPill(frame: NSRect(x: docW - 144, y: 12, width: 128, height: 30))
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

// MARK: - 画布内快捷键自定义设置卡

/// 设置窗口「截图内按键」子页面构建与全局/画布双模式按键录入路由扩展
extension TranslationSettingsWindow {
    func buildCanvasShortcutsSubPage(in container: GeekFlippedView, cardW: CGFloat) {
        addSectionHeader("截图画布单键映射", x: 44, y: 8, in: container)
        canvasKeyHintLabel = NSTextField(labelWithString: "点击键帽直接按单键修改（中英文通用 · 冲突自动互换 · ⌫ 恢复默认）")
        canvasKeyHintLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        canvasKeyHintLabel.textColor = GeekTheme.inkMuted
        canvasKeyHintLabel.alignment = .right
        canvasKeyHintLabel.lineBreakMode = .byTruncatingTail
        canvasKeyHintLabel.toolTip = canvasKeyHintLabel.stringValue
        GeekTheme.placeCentered(canvasKeyHintLabel, x: 172, width: (28 + cardW - 16) - 172, centerY: 16.0)
        container.addSubview(canvasKeyHintLabel)

        let listCard = GeekCardView(frame: NSRect(x: 28, y: 32, width: cardW, height: max(380, container.bounds.height - 46)))
        container.addSubview(listCard)

        let scroll = NSScrollView(frame: listCard.bounds.insetBy(dx: 0, dy: 2))
        configureVerticalScroll(scroll)

        let headerH: CGFloat = 32, rowH: CGFloat = 44
        let groups = CanvasActionGroup.allCases
        let totalH = CGFloat(groups.count) * headerH + CGFloat(CanvasAction.allCases.count) * rowH + 8
        let docW = scroll.contentSize.width
        let docView = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: docW, height: totalH))
        docView.autoresizingMask = [.width]

        var y: CGFloat = 4
        for (gIdx, group) in groups.enumerated() {
            let hdrBar = GeekFlippedView(frame: NSRect(x: 0, y: y, width: docW, height: headerH))
            if gIdx > 0 {
                hdrBar.addSubview(GeekSurfaceView(frame: NSRect(x: 16, y: 0, width: docW - 32, height: 1), fill: GeekTheme.border))
            }
            let hdr = NSTextField(labelWithString: group.title)
            hdr.font = .systemFont(ofSize: 11.5, weight: .semibold)
            hdr.textColor = GeekTheme.accent
            GeekTheme.placeCentered(hdr, x: 16, width: 280, centerY: headerH * 0.5 + 1)
            hdrBar.addSubview(hdr)
            docView.addSubview(hdrBar)
            y += headerH

            let items = CanvasAction.allCases.filter { $0.group == group }
            for (i, act) in items.enumerated() {
                let row = GeekHoverRowView(frame: NSRect(x: 0, y: y, width: docW, height: rowH))
                if i > 0 {
                    row.addSubview(GeekSurfaceView(frame: NSRect(x: 16, y: 0, width: docW - 32, height: 1), fill: GeekTheme.divider))
                }
                row.addSubview(GeekShortcutIconBadge(symbol: act.symbol, pointSize: 12.5, frame: NSRect(x: 16, y: 8, width: 28, height: 28)))

                let titleLbl = NSTextField(labelWithString: act.title)
                titleLbl.font = .systemFont(ofSize: 13.5, weight: .regular)
                titleLbl.textColor = GeekTheme.inkPrimary
                titleLbl.lineBreakMode = .byTruncatingTail
                titleLbl.toolTip = act.title
                row.toolTip = act.title
                GeekTheme.placeCentered(titleLbl, x: 54, width: docW - 180, centerY: rowH * 0.5)
                row.addSubview(titleLbl)

                let pill = GeekHotKeyPill(frame: NSRect(x: docW - 108, y: 8, width: 92, height: 28))
                pill.toolTip = "点击后按下任意单字母键修改（默认 \(act.defaultKey.uppercased())）"
                pill.onClick = { [weak self] in self?.toggleInlineCanvasKey(act) }
                canvasKeyPills[act] = pill
                row.addSubview(pill)
                docView.addSubview(row)
                y += rowH
            }
        }
        scroll.documentView = docView
        listCard.addSubview(scroll)
    }

    private func toggleInlineCanvasKey(_ action: CanvasAction) {
        if activeCanvasRecording == action { cancelInlineHotKeyRecording(restoreHotKeys: false); return }
        if activeRecordingSlot != nil {
            activeRecordingSlot = nil
            onEndHotKeyRecording?()
        }
        activeCanvasRecording = action
        canvasKeyHintLabel.textColor = GeekTheme.accent
        canvasKeyHintLabel.stringValue = "请直接按下「\(action.title)」的单键（无需按 ⌘/⌥ · Esc 取消 · ⌫ 恢复默认 \(action.defaultKey.uppercased())）"
        refreshGeneralAndPermissionsUI()
    }

    func handleInlineHotKeyEvent(_ event: NSEvent) -> Bool {
        if shortcutAudit.liveDetective.isListening {
            if event.keyCode == 53 { stopLiveHotKeyProbe(restoreHotKeys: true); return true }
            if let combo = KeyCombo.from(event: event) {
                let cfg = appConfigProvider?() ?? AppConfig(); let snap = shortcutAudit.snapshot
                shortcutAudit.liveDetective.noteLocalKeyPressed(combo) {
                    HotKeyConflictScanner.evaluate(combo: combo, for: nil, config: cfg, snapshot: snap, probeLiveExclusive: true)
                }
                return true
            }
            return false
        }
        if let canvasAct = activeCanvasRecording { return handleCanvasKeyRecordingEvent(event, for: canvasAct) }
        guard let slot = activeRecordingSlot else { return false }
        if event.keyCode == 53 { cancelInlineHotKeyRecording(restoreHotKeys: true); return true }
        if event.keyCode == 51 || event.keyCode == 117 {
            applyGlobalCombo(nil, for: slot)
            hotKeyHintLabel.textColor = GeekTheme.inkSecondary
            hotKeyHintLabel.stringValue = "已停用「\(slot.title)」全局热键（可随时点击重新绑定或点右上角恢复默认）"
            return true
        }
        guard let combo = KeyCombo.from(event: event) else {
            NSSound.beep()
            hotKeyHintLabel.textColor = GeekTheme.amber
            hotKeyHintLabel.stringValue = "请按双键组合（如 ⌥A、⌥1、⌘E）或直接按 F1–F19"
            return true
        }
        let cfg = appConfigProvider?() ?? AppConfig()
        let conflicts = HotKeyConflictScanner.evaluate(
            combo: combo,
            for: slot,
            config: cfg,
            snapshot: shortcutAudit.snapshot,
            probeLiveExclusive: true
        )
        if let internalHit = conflicts.first(where: { $0.owner == "MSnip" }) {
            NSSound.beep()
            shortcutAudit.pendingForceCombo = nil
            hotKeyHintLabel.setTextWithTooltip("\(internalHit.detailMessage)，请换一个按键", color: GeekTheme.danger)
            return true
        }
        if let top = conflicts.first, top.requiresDoublePressConfirm {
            if shortcutAudit.pendingForceCombo != combo {
                NSSound.beep()
                shortcutAudit.pendingForceCombo = combo
                hotKeyHintLabel.setTextWithTooltip("⚠ \(top.detailMessage) · 建议换键（再按一次 \(combo.displayString) 强制绑定）", color: (top.severity == .blocking) ? GeekTheme.danger : GeekTheme.amber)
                return true
            }
            shortcutAudit.pendingForceCombo = nil
            applyGlobalCombo(combo, for: slot)
            hotKeyHintLabel.setTextWithTooltip("⚠ 已强制设为 \(combo.displayString)（\(top.detailMessage)）", color: GeekTheme.amber)
            return true
        }
        shortcutAudit.pendingForceCombo = nil
        applyGlobalCombo(combo, for: slot)
        if let warn = conflicts.first {
            hotKeyHintLabel.setTextWithTooltip("⚠ 已设为 \(combo.displayString) · \(warn.detailMessage)", color: GeekTheme.amber)
        } else {
            hotKeyHintLabel.setTextWithTooltip("✓ 「\(slot.title)」已设为 \(combo.displayString) · 系统与运行中应用均无冲突", color: GeekTheme.emerald)
        }
        return true
    }

    private func handleCanvasKeyRecordingEvent(_ event: NSEvent, for action: CanvasAction) -> Bool {
        let pureModifiers: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        if pureModifiers.contains(event.keyCode) { return true }
        if event.keyCode == 53 { cancelInlineHotKeyRecording(restoreHotKeys: false); return true }
        if event.keyCode == 51 || event.keyCode == 117 {
            onAppConfigMutated? { $0.resetCanvasKey(for: action) }
            activeCanvasRecording = nil
            canvasKeyHintLabel.textColor = GeekTheme.emerald
            canvasKeyHintLabel.stringValue = "✓ 「\(action.title)」已恢复为默认键 \(action.defaultKey.uppercased())"
            refreshGeneralAndPermissionsUI()
            return true
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.option) || flags.contains(.control) {
            NSSound.beep()
            canvasKeyHintLabel.textColor = GeekTheme.amber
            canvasKeyHintLabel.stringValue = "截图内快捷键只需按单个字母键（无需按住 ⌘ / ⌥ / ⌃）"
            return true
        }
        guard let token = CanvasAction.singleKeyToken(for: event.keyCode) else {
            NSSound.beep()
            canvasKeyHintLabel.textColor = GeekTheme.amber
            canvasKeyHintLabel.stringValue = "请使用 A–Z 字母或 ; ' , . \\ 单键（数字 1–9 与方向键已保留）"
            return true
        }
        var swapped: CanvasAction?
        let oldKey = (appConfigProvider?().canvasKey(for: action) ?? action.defaultKey).uppercased()
        onAppConfigMutated? { swapped = $0.setCanvasKey(token, for: action) }
        activeCanvasRecording = nil
        canvasKeyHintLabel.textColor = GeekTheme.emerald
        if let other = swapped {
            canvasKeyHintLabel.stringValue = "✓ 已设为 \(token.uppercased())（原占用项「\(other.title)」已自动互换为 \(oldKey)）"
        } else {
            canvasKeyHintLabel.stringValue = "✓ 「\(action.title)」已更新为单键 \(token.uppercased())"
        }
        refreshGeneralAndPermissionsUI()
        return true
    }

    private func applyGlobalCombo(_ combo: KeyCombo?, for slot: GlobalHotKeyAction) {
        onAppConfigMutated? { c in
            if combo != nil { c.hotKeysEnabled = true }
            c.setGlobalCombo(combo, for: slot)
        }
        activeRecordingSlot = nil
        _ = rescanHotKeyConflicts()
        refreshGeneralAndPermissionsUI()
    }

    func rescanHotKeyConflicts(with cfg: AppConfig? = nil) -> HotKeyConflictSnapshot {
        let cur = cfg ?? appConfigProvider?() ?? AppConfig()
        let activeCombos = cur.hotKeysEnabled
            ? GlobalHotKeyAction.allCases.compactMap { cur.activeCombo(for: $0) }
            : []
        // 关键：瞬时暂卸 MSnip 自身热键后再做 Carbon 独占探测，彻底杜绝同进程探测撞上自己（-9878 误报）
        let needsSuspend = (activeRecordingSlot == nil && !shortcutAudit.liveDetective.isListening)
        if needsSuspend { onBeginHotKeyRecording?() }
        let snap = HotKeyConflictScanner.scan(probing: activeCombos)
        if needsSuspend { onEndHotKeyRecording?() }
        shortcutAudit.snapshot = snap
        return snap
    }

    func presentHotKeyConflictPopover() {
        guard let anchor = shortcutAudit.auditButton else { return }
        _ = rescanHotKeyConflicts()
        refreshShortcutsPageUI(with: appConfigProvider?() ?? AppConfig())
        HotKeyConflictPopover.shared.show(
            anchoredTo: anchor,
            configProvider: { [weak self] in self?.appConfigProvider?() ?? AppConfig() },
            snapshotProvider: { [weak self] in self?.shortcutAudit.snapshot ?? .empty },
            isPriorityActiveProvider: { [weak self] in self?.isPriorityTapActiveProvider?() ?? false },
            onRescan: { [weak self] in
                guard let self else { return .empty }
                let snap = self.rescanHotKeyConflicts()
                self.refreshShortcutsPageUI(with: self.appConfigProvider?() ?? AppConfig())
                return snap
            },
            onApplyRecommended: { [weak self] slot, combo in
                guard let self else { return }
                self.onAppConfigMutated? { c in c.hotKeysEnabled = true; c.setGlobalCombo(combo, for: slot) }
                _ = self.rescanHotKeyConflicts()
                self.hotKeyHintLabel.setTextWithTooltip("✓ 「\(slot.title)」已更换为零冲突推荐键 \(combo.displayString)", color: GeekTheme.emerald)
                self.refreshGeneralAndPermissionsUI()
            },
            onApplyBatchRecommended: { [weak self] pairs in
                guard let self else { return }
                self.onAppConfigMutated? { c in
                    c.hotKeysEnabled = true
                    for (slot, combo) in pairs { c.setGlobalCombo(combo, for: slot) }
                }
                _ = self.rescanHotKeyConflicts()
                self.hotKeyHintLabel.setTextWithTooltip("✓ 已一键为 \(pairs.count) 项动作切换为零冲突组合键", color: GeekTheme.emerald)
                self.refreshGeneralAndPermissionsUI()
            },
            onToggleLiveProbe: { [weak self] in self?.toggleLiveHotKeyProbe() },
            onPopoverClosed: { [weak self] in self?.stopLiveHotKeyProbe(restoreHotKeys: true) }
        )
    }

    func toggleLiveHotKeyProbe() {
        if shortcutAudit.liveDetective.isListening {
            stopLiveHotKeyProbe(restoreHotKeys: true)
            return
        }
        cancelInlineHotKeyRecording(restoreHotKeys: false)
        _ = rescanHotKeyConflicts()
        onBeginHotKeyRecording?()
        HotKeyConflictPopover.shared.setProbingStarted(duration: 10)
        shortcutAudit.liveDetective.start(duration: 10.0) { [weak self] outcome in
            guard let self else { return }
            self.onEndHotKeyRecording?()
            let now = HotKeyConflictPopover.formatTime(Date())
            switch outcome {
            case .appTriggered(let appName, let viaWindow):
                let detail = viaWindow
                    ? "按下后捕获到「\(appName)」弹出了界面/浮层。可在「\(appName)」设置中改键，或在 MSnip 换用其他组合键。"
                    : "按下后激活了前台应用「\(appName)」。可在「\(appName)」中关闭该键，或在 MSnip 改用其他组合键。"
                let entry = LiveProbeLogEntry(timeText: now, title: "🎯 实测命中：由「\(appName)」占用", detail: detail, color: GeekTheme.danger, symbol: "exclamationmark.triangle.fill")
                HotKeyConflictPopover.shared.finishProbing(entry: entry)
                ToastHUD.show(message: "🎯 实测命中：该快捷键由「\(appName)」占用", subtitle: viaWindow ? "触发了「\(appName)」浮层窗口" : "激活了「\(appName)」")
            case .localKeyConflict(let combo, let hit):
                let entry = LiveProbeLogEntry(timeText: now, title: "⚠ \(combo.displayString) 存在系统或通用冲突", detail: hit.detailMessage, color: GeekTheme.amber, symbol: "exclamationmark.triangle")
                HotKeyConflictPopover.shared.finishProbing(entry: entry)
                ToastHUD.show(message: "⚠ \(combo.displayString) 存在冲突", subtitle: hit.detailMessage)
            case .localKeyClean(let combo):
                let entry = LiveProbeLogEntry(timeText: now, title: "✓ 实测通过：\(combo.displayString) 可放心使用", detail: "未触发任何后台应用，且与 macOS 系统热键及通用快捷键均无冲突。", color: GeekTheme.emerald, symbol: "checkmark.shield.fill")
                HotKeyConflictPopover.shared.finishProbing(entry: entry)
                ToastHUD.show(message: "✓ 实测通过：\(combo.displayString) 未被其他应用占用")
            case .timedOut:
                let entry = LiveProbeLogEntry(timeText: now, title: "监听已超时（10 秒内未捕获响应）", detail: "若刚按了某快捷键却毫无反应，可能是被无窗口的静默系统热键拦截；可点上方「开始按键实测」重试。", color: GeekTheme.inkSecondary, symbol: "clock")
                HotKeyConflictPopover.shared.finishProbing(entry: entry)
            case .cancelled:
                HotKeyConflictPopover.shared.finishProbing(entry: nil)
            }
        }
    }

    func stopLiveHotKeyProbe(restoreHotKeys: Bool) {
        guard shortcutAudit.liveDetective.isListening else { return }
        shortcutAudit.liveDetective.stop(notify: false)
        if restoreHotKeys { onEndHotKeyRecording?() }
        HotKeyConflictPopover.shared.finishProbing(entry: nil)
    }
}
