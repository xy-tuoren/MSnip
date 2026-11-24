import AppKit
import Foundation
import MSnipCore

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

        let listCard = GeekCardView(frame: NSRect(x: 28, y: 32, width: cardW, height: 380))
        container.addSubview(listCard)

        let scroll = NSScrollView(frame: listCard.bounds.insetBy(dx: 0, dy: 2))
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true

        let headerH: CGFloat = 32, rowH: CGFloat = 44
        let groups = CanvasActionGroup.allCases
        let totalH = CGFloat(groups.count) * headerH + CGFloat(CanvasAction.allCases.count) * rowH + 8
        let docView = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: cardW, height: totalH))

        var y: CGFloat = 4
        for (gIdx, group) in groups.enumerated() {
            let hdrBar = GeekFlippedView(frame: NSRect(x: 0, y: y, width: cardW, height: headerH))
            if gIdx > 0 {
                hdrBar.addSubview(GeekSurfaceView(frame: NSRect(x: 16, y: 0, width: cardW - 32, height: 1), fill: GeekTheme.border))
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
                let row = GeekHoverRowView(frame: NSRect(x: 0, y: y, width: cardW, height: rowH))
                if i > 0 {
                    row.addSubview(GeekSurfaceView(frame: NSRect(x: 16, y: 0, width: cardW - 32, height: 1), fill: GeekTheme.divider))
                }
                row.addSubview(GeekShortcutIconBadge(symbol: act.symbol, pointSize: 12.5, frame: NSRect(x: 16, y: 8, width: 28, height: 28)))

                let titleLbl = NSTextField(labelWithString: act.title)
                titleLbl.font = .systemFont(ofSize: 13.5, weight: .regular)
                titleLbl.textColor = GeekTheme.inkPrimary
                titleLbl.lineBreakMode = .byTruncatingTail
                titleLbl.toolTip = act.title
                row.toolTip = act.title
                GeekTheme.placeCentered(titleLbl, x: 54, width: cardW - 180, centerY: rowH * 0.5)
                row.addSubview(titleLbl)

                let pill = GeekHotKeyPill(frame: NSRect(x: cardW - 108, y: 8, width: 92, height: 28))
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
