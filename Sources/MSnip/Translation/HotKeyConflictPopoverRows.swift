import AppKit
import Foundation
import MSnipCore

/// 热键冲突体检弹窗列表行渲染扩展（当前体检 + 一键全部解决 + 系统/应用筛选清单）
extension HotKeyConflictPopover {
    func populateAuditRows(
        in doc: GeekFlippedView, width W: CGFloat,
        cfg: AppConfig, own: [GlobalHotKeyAction: KeyCombo], snap: HotKeyConflictSnapshot
    ) -> CGFloat {
        var y: CGFloat = 8
        var occupied = snap.allOccupiedCombos
        var pendingFixes: [(GlobalHotKeyAction, KeyCombo)] = []
        var perActionFix: [GlobalHotKeyAction: KeyCombo] = [:]
        var perActionTop: [GlobalHotKeyAction: HotKeyConflict] = [:]

        for act in GlobalHotKeyAction.allCases {
            guard cfg.hotKeysEnabled, let combo = own[act] else { continue }
            if let top = HotKeyConflictScanner.evaluate(combo: combo, for: act, config: cfg, snapshot: snap).first {
                perActionTop[act] = top
                if let sug = HotKeyConflictCatalog.suggestConflictFreeCombo(for: act, ownBindings: own, occupied: occupied) {
                    occupied.insert(sug)
                    perActionFix[act] = sug
                    pendingFixes.append((act, sug))
                }
            }
        }

        let priorityActive = cfg.hotKeysEnabled && cfg.forcePriorityHotKeys && (isPriorityActiveProvider?() ?? false)
        if pendingFixes.count >= 2 && !priorityActive {
            let bar = GeekFlippedView(frame: NSRect(x: 14, y: y, width: W - 28, height: 38))
            bar.wantsLayer = true; bar.layer?.cornerRadius = 8.5
            bar.layer?.backgroundColor = GeekTheme.amber.withAlphaComponent(0.11).cgColor
            bar.layer?.borderWidth = 1.0; bar.layer?.borderColor = GeekTheme.amber.withAlphaComponent(0.32).cgColor
            let tip = NSTextField(labelWithString: "已为 \(pendingFixes.count) 项冲突热键计算互不重复的零冲突替代键")
            tip.font = .systemFont(ofSize: 12.0, weight: .medium); tip.textColor = GeekTheme.amber
            GeekTheme.placeCentered(tip, x: 12, width: bar.bounds.width - 140, centerY: 19)
            bar.addSubview(tip)
            let allBtn = GeekButton(title: "一键全部解决", symbol: "wand.and.stars", style: .accent)
            allBtn.frame = NSRect(x: bar.bounds.width - 122, y: 6, width: 114, height: 26)
            allBtn.onClick = { [weak self] in self?.onApplyBatchRecommended?(pendingFixes); self?.rebuildList() }
            bar.addSubview(allBtn)
            doc.addSubview(bar)
            y += 46
        }

        for (i, act) in GlobalHotKeyAction.allCases.enumerated() {
            let rowH: CGFloat = 50
            let row = GeekHoverRowView(frame: NSRect(x: 0, y: y, width: W, height: rowH))
            if i > 0 { addRowDivider(in: row, width: W) }
            let combo = own[act]
            let top = perActionTop[act]
            let isOverridden = priorityActive && top != nil && top?.owner != "MSnip"
            let dotCol: NSColor = (!cfg.hotKeysEnabled || combo == nil)
                ? GeekTheme.inkMuted
                : (isOverridden ? GeekTheme.accent : (top == nil ? GeekTheme.emerald : (top!.severity == .blocking ? GeekTheme.danger : GeekTheme.amber)))
            let subText: String = (!cfg.hotKeysEnabled || combo == nil)
                ? (combo == nil ? "未启用全局绑定" : "全局热键总开关已关闭")
                : (isOverridden ? "⚡ 已由 MSnip 优先接管（压过：\(top!.detailMessage)）" : (top?.detailMessage ?? "无冲突 · 可放心使用"))

            row.addSubview(PopoverStatusDot(color: dotCol, frame: NSRect(x: 14, y: 0, width: 14, height: rowH)))
            let rightReserve: CGFloat = (top != nil) ? 164 : 80
            let tLbl = NSTextField(labelWithString: act.title)
            tLbl.font = .systemFont(ofSize: 13.0, weight: .semibold); tLbl.textColor = GeekTheme.inkPrimary
            let sLbl = NSTextField(labelWithString: subText)
            sLbl.font = .systemFont(ofSize: 11.5, weight: .regular)
            sLbl.textColor = (top == nil) ? GeekTheme.inkMuted : dotCol
            sLbl.lineBreakMode = .byTruncatingTail; sLbl.toolTip = subText
            row.toolTip = "\(act.title)（\(combo?.displayString ?? "未设置")）\n\(subText)"
            GeekTheme.placeTwoLineStack(tLbl, sLbl, x: 34, width: W - 34 - rightReserve, centerY: rowH * 0.5, gap: 2)
            row.addSubview(tLbl); row.addSubview(sLbl)

            let capX = (top != nil) ? (W - 156) : (W - 74)
            row.addSubview(PopoverKeyCapView(text: combo?.displayString ?? "—", highlight: top != nil ? dotCol : nil, frame: NSRect(x: capX, y: 13, width: 60, height: 24)))
            if let suggested = perActionFix[act] {
                let fixBtn = GeekButton(title: "换 \(suggested.displayString)", style: .accent, mono: true)
                fixBtn.toolTip = "一键将「\(act.title)」更换为零冲突组合键 \(suggested.displayString)"
                fixBtn.frame = NSRect(x: W - 88, y: 13, width: 74, height: 24)
                fixBtn.onClick = { [weak self] in self?.onApplyRecommended?(act, suggested); self?.rebuildList() }
                row.addSubview(fixBtn)
            }
            doc.addSubview(row)
            y += rowH
        }
        return y
    }

    func populateOccupiedRows(
        _ entries: [OccupiedHotKeyEntry], own: [GlobalHotKeyAction: KeyCombo],
        in doc: GeekFlippedView, width W: CGFloat, emptyText: String, showProbeHint: Bool
    ) -> CGFloat {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = q.isEmpty ? entries : entries.filter {
            "\($0.combo.displayString) \($0.owner) \($0.feature) \($0.sourceKind.badgeTitle)".lowercased().contains(q)
        }
        var y: CGFloat = 6
        if filtered.isEmpty {
            let lbl = NSTextField(wrappingLabelWithString: emptyText)
            lbl.font = .systemFont(ofSize: 12.5); lbl.textColor = GeekTheme.inkSecondary
            lbl.frame = NSRect(x: 18, y: 18, width: W - 36, height: 64)
            doc.addSubview(lbl)
            y = 92
        } else {
            let ownSet = Set(own.values)
            for (i, entry) in filtered.enumerated() {
                let rowH: CGFloat = 36
                let row = GeekHoverRowView(frame: NSRect(x: 0, y: y, width: W, height: rowH))
                if i > 0 { addRowDivider(in: row, width: W) }
                let hitOwn = ownSet.contains(entry.combo)
                let hiCol: NSColor? = hitOwn ? ((entry.sourceKind == .runningAppDefault) ? GeekTheme.amber : GeekTheme.danger) : nil
                row.addSubview(PopoverKeyCapView(text: entry.combo.displayString, highlight: hiCol, frame: NSRect(x: 14, y: 6, width: 72, height: 24)))

                let mainText = (entry.category == .runningApp) ? "\(entry.owner) · \(entry.feature)" : entry.feature
                let lbl = NSTextField(labelWithString: mainText)
                lbl.font = .systemFont(ofSize: 12.5, weight: hitOwn ? .semibold : .medium)
                lbl.textColor = hitOwn ? (hiCol ?? GeekTheme.inkPrimary) : GeekTheme.inkPrimary
                lbl.lineBreakMode = .byTruncatingTail; lbl.toolTip = mainText
                row.toolTip = "\(entry.combo.displayString)  \(mainText)（\(entry.sourceKind.badgeTitle)）"
                GeekTheme.placeCentered(lbl, x: 96, width: W - 186, centerY: rowH * 0.5)
                row.addSubview(lbl)

                let tag = NSTextField(labelWithString: hitOwn ? "冲突中" : entry.sourceKind.badgeTitle)
                tag.font = .systemFont(ofSize: 11.0, weight: (hitOwn || entry.sourceKind == .appConfigLive) ? .semibold : .regular)
                tag.textColor = hitOwn ? (hiCol ?? GeekTheme.amber) : (entry.sourceKind == .appConfigLive ? GeekTheme.accent : GeekTheme.inkMuted)
                tag.alignment = .right
                GeekTheme.placeCentered(tag, x: W - 84, width: 70, centerY: rowH * 0.5)
                row.addSubview(tag)
                doc.addSubview(row)
                y += rowH
            }
        }
        if showProbeHint {
            let btn = GeekButton(title: "找不到自定义热键？去「实测归属」按下现场抓取", symbol: "scope", style: .ghost)
            btn.frame = NSRect(x: 14, y: y + 8, width: W - 28, height: 30)
            btn.onClick = { [weak self] in self?.switchToProbeTab() }
            doc.addSubview(btn)
            y += 44
        }
        return y
    }

    private func addRowDivider(in row: NSView, width W: CGFloat) {
        let sep = NSView(frame: NSRect(x: 14, y: 0, width: W - 28, height: 1))
        sep.wantsLayer = true; sep.layer?.backgroundColor = GeekTheme.divider.cgColor
        row.addSubview(sep)
    }
}
