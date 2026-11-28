import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 实时热键冲突体检、本机已占热键搜索一览与独立「实测归属」互动诊断浮窗
@MainActor
final class HotKeyConflictPopover: NSObject, NSPopoverDelegate, NSTextFieldDelegate {
    static let shared = HotKeyConflictPopover()

    private let popover = NSPopover()

    #if DEBUG
    /// 仅 Debug 离屏渲染：已构建好的弹窗内容视图
    var debugContentView: NSView? { popover.contentViewController?.view }
    func debugSelectTab(_ idx: Int) { activeTab = idx; tabSegment.selectedIndex = idx; rebuildList() }
    #endif
    private var tabSegment: GeekSegmentControl!
    private var summaryLabel: NSTextField!
    private var rescanBtn: GeekButton!
    private var searchContainer: GeekFlippedView!
    private var searchField: NSTextField!
    private var scrollView: NSScrollView!

    private var activeTab = 0
    var searchQuery = ""
    private var isProbing = false
    private var probeRemaining = 0
    private var probeHistory: [LiveProbeLogEntry] = []
    private var rescanFlashWork: DispatchWorkItem?
    private var countdownTimer: Timer?

    private var configProvider: (() -> AppConfig)?
    private var snapshotProvider: (() -> HotKeyConflictSnapshot)?
    var isPriorityActiveProvider: (() -> Bool)?
    private var onRescan: (() -> HotKeyConflictSnapshot)?
    var onApplyRecommended: ((GlobalHotKeyAction, KeyCombo) -> Void)?
    var onApplyBatchRecommended: (([(GlobalHotKeyAction, KeyCombo)]) -> Void)?
    private var onToggleLiveProbe: (() -> Void)?
    private var onPopoverClosed: (() -> Void)?

    private override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    func show(
        anchoredTo anchor: NSView,
        configProvider: @escaping () -> AppConfig,
        snapshotProvider: @escaping () -> HotKeyConflictSnapshot,
        isPriorityActiveProvider: @escaping () -> Bool,
        onRescan: @escaping () -> HotKeyConflictSnapshot,
        onApplyRecommended: @escaping (GlobalHotKeyAction, KeyCombo) -> Void,
        onApplyBatchRecommended: @escaping ([(GlobalHotKeyAction, KeyCombo)]) -> Void,
        onToggleLiveProbe: @escaping () -> Void,
        onPopoverClosed: @escaping () -> Void
    ) {
        if popover.isShown { popover.performClose(nil); return }
        self.configProvider = configProvider
        self.snapshotProvider = snapshotProvider
        self.isPriorityActiveProvider = isPriorityActiveProvider
        self.onRescan = onRescan
        self.onApplyRecommended = onApplyRecommended
        self.onApplyBatchRecommended = onApplyBatchRecommended
        self.onToggleLiveProbe = onToggleLiveProbe
        self.onPopoverClosed = onPopoverClosed
        self.activeTab = 0
        self.searchQuery = ""
        self.isProbing = false

        let W: CGFloat = 516, H: CGFloat = 524
        let vc = NSViewController()
        let root = GeekSurfaceView(frame: NSRect(x: 0, y: 0, width: W, height: H), fill: GeekTheme.cardBg)
        vc.view = root
        popover.appearance = GeekTheme.popoverAppearance
        popover.contentSize = NSSize(width: W, height: H)
        popover.contentViewController = vc

        let title = NSTextField(labelWithString: L("热键冲突体检与占用一览"))
        title.font = .systemFont(ofSize: 14.5, weight: .semibold); title.textColor = GeekTheme.inkPrimary
        summaryLabel = NSTextField(labelWithString: "")
        summaryLabel.font = .systemFont(ofSize: 11.5, weight: .regular); summaryLabel.textColor = GeekTheme.inkMuted
        summaryLabel.lineBreakMode = .byTruncatingTail
        GeekTheme.placeTwoLineStack(title, summaryLabel, x: 16, width: W - 116, centerY: 29, gap: 2)
        root.addSubview(title); root.addSubview(summaryLabel)

        rescanBtn = GeekButton(title: L("重扫"), symbol: "arrow.clockwise", style: .subtle)
        rescanBtn.toolTip = L("重新扫描 macOS 系统热键与当前后台运行中应用")
        rescanBtn.frame = NSRect(x: W - 92, y: 15, width: 76, height: 28)
        rescanBtn.onClick = { [weak self] in self?.handleRescanClicked() }
        root.addSubview(rescanBtn)

        tabSegment = GeekSegmentControl(items: [L("当前体检"), L("实测归属"), L("系统已占"), L("运行中应用")], selectedIndex: 0)
        tabSegment.frame = NSRect(x: 14, y: 58, width: W - 28, height: 32)
        tabSegment.onSelect = { [weak self] idx in
            guard let self else { return }
            self.activeTab = idx
            self.searchQuery = ""
            self.searchField.stringValue = ""
            self.rebuildList()
        }
        root.addSubview(tabSegment)

        searchContainer = GeekSurfaceView(frame: NSRect(x: 14, y: 98, width: W - 28, height: 32), fill: GeekTheme.inputBg, border: GeekTheme.border, cornerRadius: 7.5, borderWidth: 1.0)
        searchContainer.addSubview(ProviderSearchIconView(frame: NSRect(x: 10, y: 0, width: 14, height: 32)))
        searchField = NSTextField()
        searchField.isBordered = false; searchField.drawsBackground = false; searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 12.5); searchField.textColor = GeekTheme.inkPrimary
        searchField.setGeekPlaceholder(L("筛选快捷键、功能或应用名（如 截图 / ⌥1 / ⌘␣ / 聚焦搜索）…"))
        searchField.cell?.isScrollable = true; searchField.cell?.wraps = false
        GeekTheme.placeCentered(searchField, x: 28, width: searchContainer.bounds.width - 38, centerY: 16)
        searchField.delegate = self
        searchContainer.addSubview(searchField)
        root.addSubview(searchContainer)

        root.addSubview(GeekSurfaceView(frame: NSRect(x: 0, y: 97, width: W, height: 1), fill: GeekTheme.divider))

        let sv = NSScrollView(frame: NSRect(x: 0, y: 98, width: W, height: H - 98))
        sv.drawsBackground = false; sv.borderType = .noBorder
        sv.hasVerticalScroller = true; sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true; sv.scrollerStyle = .overlay; sv.horizontalScrollElasticity = .none
        root.addSubview(sv)
        self.scrollView = sv

        rebuildList()
        #if DEBUG
        if DebugSettingsSnapshot.suppressPopoverPresentation { return }
        #endif
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    func closeIfShown() {
        countdownTimer?.invalidate(); countdownTimer = nil
        popover.behavior = .transient
        if popover.isShown { popover.performClose(nil) }
    }

    func popoverWillClose(_ notification: Notification) {
        countdownTimer?.invalidate(); countdownTimer = nil
        popover.behavior = .transient
        onPopoverClosed?()
    }

    func setProbingStarted(duration: Int) {
        isProbing = true
        probeRemaining = duration
        popover.behavior = .applicationDefined
        activeTab = 1
        tabSegment?.selectedIndex = 1
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isProbing else { return }
                self.probeRemaining = max(1, self.probeRemaining - 1)
                if self.activeTab == 1 { self.rebuildList() }
            }
        }
        rebuildList()
    }

    func finishProbing(entry: LiveProbeLogEntry?) {
        isProbing = false
        countdownTimer?.invalidate(); countdownTimer = nil
        popover.behavior = .transient
        if let entry {
            probeHistory.insert(entry, at: 0)
            if probeHistory.count > 6 { probeHistory = Array(probeHistory.prefix(6)) }
        }
        if popover.isShown { rebuildList() }
    }

    private func handleRescanClicked() {
        _ = onRescan?()
        rebuildList()
        rescanFlashWork?.cancel()
        rescanBtn.title = L("已更新")
        rescanBtn.symbolName = "checkmark"
        rescanBtn.style = .emeraldSoft
        let work = DispatchWorkItem { [weak self] in
            self?.rescanBtn?.title = L("重扫")
            self?.rescanBtn?.symbolName = "arrow.clockwise"
            self?.rescanBtn?.style = .subtle
        }
        rescanFlashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25, execute: work)
    }

    func controlTextDidChange(_ obj: Notification) {
        searchQuery = searchField.stringValue
        rebuildList()
    }

    func switchToProbeTab() {
        activeTab = 1
        rebuildList()
    }

    func rebuildList() {
        guard let cfg = configProvider?(), let snap = snapshotProvider?() else { return }
        tabSegment.items = [
            L("当前体检"),
            isProbing ? L("监听中…") : L("实测归属"),
            L("系统 (%@)", snap.systemEntries.count),
            L("应用 (%@)", snap.runningAppEntries.count)
        ]
        tabSegment.selectedIndex = activeTab

        var own: [GlobalHotKeyAction: KeyCombo] = [:]
        for act in GlobalHotKeyAction.allCases { if let c = cfg.activeCombo(for: act) { own[act] = c } }

        var conflictCount = 0
        if cfg.hotKeysEnabled {
            for (act, combo) in own {
                if !HotKeyConflictScanner.evaluate(combo: combo, for: act, config: cfg, snapshot: snap).isEmpty { conflictCount += 1 }
            }
        }
        let timeStr = Self.formatTime(snap.scannedAt)
        let priorityActive = cfg.hotKeysEnabled && cfg.forcePriorityHotKeys && (isPriorityActiveProvider?() ?? false)
        if !cfg.hotKeysEnabled {
            summaryLabel.setTextWithTooltip(L("全局热键总开关已关闭 · 扫描于 %@", timeStr), color: GeekTheme.inkSecondary)
        } else if priorityActive && conflictCount > 0 {
            summaryLabel.setTextWithTooltip(L("⚡ 已强制优先接管 %@ 项外部冲突 · 扫描于 %@", conflictCount, timeStr), color: GeekTheme.accent)
        } else if conflictCount > 0 {
            summaryLabel.setTextWithTooltip(L("发现 %@ 项冲突/预警 · 扫描于 %@（共 %@ 系统 / %@ 应用）", conflictCount, timeStr, snap.systemEntries.count, snap.runningAppEntries.count), color: GeekTheme.amber)
        } else {
            summaryLabel.setTextWithTooltip(L("✓ 全部已设热键零冲突 · 扫描于 %@（已核验 %@ 项）", timeStr, snap.systemEntries.count + snap.runningAppEntries.count), color: GeekTheme.emerald)
        }

        let showSearch = (activeTab == 2 || activeTab == 3)
        searchContainer.isHidden = !showSearch
        let svTop: CGFloat = showSearch ? 138 : 98
        scrollView.frame = NSRect(x: 0, y: svTop, width: 516, height: 524 - svTop)

        let W = scrollView.bounds.width
        if activeTab == 1 {
            scrollView.documentView = HotKeyConflictProbeStage.build(
                width: W,
                isListening: isProbing,
                remainingSeconds: probeRemaining,
                latest: probeHistory.first,
                history: probeHistory,
                onToggleProbe: { [weak self] in self?.onToggleLiveProbe?() },
                onClearHistory: { [weak self] in self?.probeHistory.removeAll(); self?.rebuildList() }
            )
            return
        }

        let doc = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: W, height: 100))
        let y: CGFloat
        if activeTab == 0 {
            y = populateAuditRows(in: doc, width: W, cfg: cfg, own: own, snap: snap)
        } else if activeTab == 2 {
            y = populateOccupiedRows(snap.systemEntries, own: own, in: doc, width: W, emptyText: L("未匹配到符合条件的 macOS 系统热键"), showProbeHint: false)
        } else {
            y = populateOccupiedRows(snap.runningAppEntries, own: own, in: doc, width: W, emptyText: L("当前后台未匹配到已知冲突应用，可切至「实测归属」直接按键抓取真实占用方。"), showProbeHint: true)
        }
        doc.frame.size.height = max(scrollView.bounds.height, y + 12)
        scrollView.documentView = doc
    }

    static func formatTime(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}

// MARK: - 冲突列表行视图

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
            let tip = NSTextField(labelWithString: L("已为 %@ 项冲突热键计算互不重复的零冲突替代键", pendingFixes.count))
            tip.font = .systemFont(ofSize: 12.0, weight: .medium); tip.textColor = GeekTheme.amber
            GeekTheme.placeCentered(tip, x: 12, width: bar.bounds.width - 140, centerY: 19)
            bar.addSubview(tip)
            let allBtn = GeekButton(title: L("一键全部解决"), symbol: "wand.and.stars", style: .accent)
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
                ? (combo == nil ? L("未启用全局绑定") : L("全局热键总开关已关闭"))
                : (isOverridden ? L("⚡ 已由 MSnip 优先接管（压过：%@）", top!.detailMessage) : (top?.detailMessage ?? L("无冲突 · 可放心使用")))

            row.addSubview(PopoverStatusDot(color: dotCol, frame: NSRect(x: 14, y: 0, width: 14, height: rowH)))
            let rightReserve: CGFloat = (top != nil) ? 164 : 80
            let tLbl = NSTextField(labelWithString: act.title)
            tLbl.font = .systemFont(ofSize: 13.0, weight: .semibold); tLbl.textColor = GeekTheme.inkPrimary
            let sLbl = NSTextField(labelWithString: subText)
            sLbl.font = .systemFont(ofSize: 11.5, weight: .regular)
            sLbl.textColor = (top == nil) ? GeekTheme.inkMuted : dotCol
            sLbl.lineBreakMode = .byTruncatingTail; sLbl.toolTip = subText
            row.toolTip = L("%@（%@）\n%@", act.title, combo?.displayString ?? L("未设置"), subText)
            GeekTheme.placeTwoLineStack(tLbl, sLbl, x: 34, width: W - 34 - rightReserve, centerY: rowH * 0.5, gap: 2)
            row.addSubview(tLbl); row.addSubview(sLbl)

            let capX = (top != nil) ? (W - 156) : (W - 74)
            row.addSubview(PopoverKeyCapView(text: combo?.displayString ?? "—", highlight: top != nil ? dotCol : nil, frame: NSRect(x: capX, y: 13, width: 60, height: 24)))
            if let suggested = perActionFix[act] {
                let fixBtn = GeekButton(title: L("换 %@", suggested.displayString), style: .accent, mono: true)
                fixBtn.toolTip = L("一键将「%@」更换为零冲突组合键 %@", act.title, suggested.displayString)
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
                row.toolTip = L("%@  %@（%@）", entry.combo.displayString, mainText, entry.sourceKind.badgeTitle)
                GeekTheme.placeCentered(lbl, x: 96, width: W - 186, centerY: rowH * 0.5)
                row.addSubview(lbl)

                let tag = NSTextField(labelWithString: hitOwn ? L("冲突中") : entry.sourceKind.badgeTitle)
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
            let btn = GeekButton(title: L("找不到自定义热键？去「实测归属」按下现场抓取"), symbol: "scope", style: .ghost)
            btn.frame = NSRect(x: 14, y: y + 8, width: W - 28, height: 30)
            btn.onClick = { [weak self] in self?.switchToProbeTab() }
            doc.addSubview(btn)
            y += 44
        }
        return y
    }

    private func addRowDivider(in row: NSView, width W: CGFloat) {
        row.addSubview(GeekSurfaceView(frame: NSRect(x: 14, y: 0, width: W - 28, height: 1), fill: GeekTheme.divider))
    }
}

// MARK: - 热键冲突实时探测状态视图

/// 实测归属单次测试记录（持久化在单例弹窗内，切 Tab 或切 App 回来仍清晰可见）
struct LiveProbeLogEntry {
    let timeText: String
    let title: String
    let detail: String
    let color: NSColor
    let symbol: String
}

/// 独立「按键实测归属」互动诊断画布（大卡片多行完整展示，绝不截断，带倒计时与最近实测历史）
@MainActor
enum HotKeyConflictProbeStage {
    static func build(
        width W: CGFloat,
        isListening: Bool,
        remainingSeconds: Int,
        latest: LiveProbeLogEntry?,
        history: [LiveProbeLogEntry],
        onToggleProbe: @escaping () -> Void,
        onClearHistory: @escaping () -> Void
    ) -> GeekFlippedView {
        let container = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: W, height: 390))
        var y: CGFloat = 14

        // 1) 互动监听主控卡片
        let heroH: CGFloat = 154
        let hero = GeekSurfaceView(
            frame: NSRect(x: 14, y: y, width: W - 28, height: heroH),
            fill: isListening ? GeekTheme.accentSoft : GeekTheme.inputBg,
            border: isListening ? GeekTheme.accent.withAlphaComponent(0.75) : GeekTheme.border,
            cornerRadius: 11.0,
            borderWidth: isListening ? 1.25 : 1.0
        )
        container.addSubview(hero)

        let badgeColor: NSColor = isListening ? GeekTheme.accent : GeekTheme.inkSecondary
        let iconBox = ProbeStageIconView(
            symbol: isListening ? "waveform" : "scope",
            tint: badgeColor,
            frame: NSRect(x: round((hero.bounds.width - 34) * 0.5), y: 15, width: 34, height: 34)
        )
        hero.addSubview(iconBox)

        let titleStr = isListening
            ? L("正在实时监听… 剩余 %@ 秒（按 Esc 停止）", max(1, remainingSeconds))
            : L("按下任意快捷键，现场检测占用它的具体应用")
        let titleLbl = NSTextField(labelWithString: titleStr)
        titleLbl.font = .systemFont(ofSize: 13.5, weight: .semibold)
        titleLbl.textColor = isListening ? GeekTheme.accent : GeekTheme.inkPrimary
        titleLbl.alignment = .center
        GeekTheme.placeCentered(titleLbl, x: 14, width: hero.bounds.width - 28, centerY: 63)
        hero.addSubview(titleLbl)

        let descStr = isListening
            ? L("请直接按下你想检测的组合键（如 ⌥1、⌃⌘A、⌘␣）。若触发了其他软件的窗口或悬浮面板，MSnip 将立即捕获其名称。")
            : L("无论对方是常规前台应用窗口，还是无焦点悬浮面板与全屏覆盖层，按下即可实时定位占用该快捷键的具体应用。")
        let descLbl = NSTextField(wrappingLabelWithString: descStr)
        descLbl.font = .systemFont(ofSize: 11.5, weight: .regular)
        descLbl.textColor = GeekTheme.inkSecondary
        descLbl.alignment = .center
        descLbl.frame = NSRect(x: 20, y: 76, width: hero.bounds.width - 40, height: 32)
        hero.addSubview(descLbl)

        let btnW: CGFloat = isListening ? 136 : 126
        let actBtn = GeekButton(
            title: isListening ? L("停止监听") : L("开始按键实测"),
            symbol: isListening ? "stop.circle" : "play.fill",
            style: isListening ? .amberSoft : .accent
        )
        actBtn.frame = NSRect(x: round((hero.bounds.width - btnW) * 0.5), y: 114, width: btnW, height: 28)
        actBtn.onClick = onToggleProbe
        hero.addSubview(actBtn)
        y += heroH + 12

        // 2) 最新实测结论多行卡片（永不截断）
        if let res = latest {
            let card = GeekFlippedView(frame: NSRect(x: 14, y: y, width: W - 28, height: 82))
            card.wantsLayer = true
            card.layer?.cornerRadius = 10.0
            card.layer?.backgroundColor = res.color.withAlphaComponent(0.10).cgColor
            card.layer?.borderWidth = 1.0
            card.layer?.borderColor = res.color.withAlphaComponent(0.40).cgColor

            let accentBar = NSView(frame: NSRect(x: 0, y: 10, width: 3, height: 62))
            accentBar.wantsLayer = true
            accentBar.layer?.backgroundColor = res.color.cgColor
            accentBar.layer?.cornerRadius = 1.5
            card.addSubview(accentBar)

            let rTitle = NSTextField(labelWithString: res.title)
            rTitle.font = .systemFont(ofSize: 13.0, weight: .semibold)
            rTitle.textColor = res.color
            GeekTheme.placeCentered(rTitle, x: 14, width: card.bounds.width - 84, centerY: 21)
            card.addSubview(rTitle)

            let tLbl = NSTextField(labelWithString: res.timeText)
            tLbl.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
            tLbl.textColor = GeekTheme.inkMuted
            tLbl.alignment = .right
            GeekTheme.placeCentered(tLbl, x: card.bounds.width - 70, width: 58, centerY: 21)
            card.addSubview(tLbl)

            let rDesc = NSTextField(wrappingLabelWithString: res.detail)
            rDesc.font = .systemFont(ofSize: 12.0, weight: .regular)
            rDesc.textColor = GeekTheme.inkPrimary
            rDesc.frame = NSRect(x: 14, y: 34, width: card.bounds.width - 26, height: 40)
            card.addSubview(rDesc)
            container.addSubview(card)
            y += 94
        }

        // 3) 最近实测记录
        if history.count > 1 {
            let hdr = NSTextField(labelWithString: L("最近实测记录"))
            hdr.font = .systemFont(ofSize: 11.5, weight: .semibold)
            hdr.textColor = GeekTheme.inkMuted
            GeekTheme.placeCentered(hdr, x: 16, width: 120, centerY: y + 10)
            container.addSubview(hdr)

            let clr = GeekButton(title: L("清空"), style: .ghost)
            clr.frame = NSRect(x: W - 64, y: y - 1, width: 50, height: 22)
            clr.onClick = onClearHistory
            container.addSubview(clr)
            y += 24

            for item in history.dropFirst().prefix(4) {
                let row = GeekHoverRowView(frame: NSRect(x: 14, y: y, width: W - 28, height: 32))
                row.wantsLayer = true; row.layer?.cornerRadius = 6.5
                row.toolTip = "\(item.title)\n\(item.detail)"
                row.addSubview(PopoverStatusDot(color: item.color, frame: NSRect(x: 6, y: 0, width: 12, height: 32)))
                let lbl = NSTextField(labelWithString: item.title)
                lbl.font = .systemFont(ofSize: 12.0, weight: .medium)
                lbl.textColor = GeekTheme.inkSecondary
                lbl.lineBreakMode = .byTruncatingTail
                GeekTheme.placeCentered(lbl, x: 24, width: row.bounds.width - 84, centerY: 16)
                row.addSubview(lbl)

                let tm = NSTextField(labelWithString: item.timeText)
                tm.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
                tm.textColor = GeekTheme.inkMuted; tm.alignment = .right
                GeekTheme.placeCentered(tm, x: row.bounds.width - 58, width: 52, centerY: 16)
                row.addSubview(tm)
                container.addSubview(row)
                y += 33
            }
        }

        container.frame.size.height = max(388, y + 12)
        return container
    }
}

private final class ProbeStageIconView: NSView {
    let symbol: String
    let tint: NSColor
    override var isFlipped: Bool { true }
    init(symbol: String, tint: NSColor, frame: NSRect) {
        self.symbol = symbol; self.tint = tint
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9.0
        layer?.backgroundColor = tint.withAlphaComponent(0.14).cgColor
        layer?.borderWidth = 1.0
        layer?.borderColor = tint.withAlphaComponent(0.35).cgColor
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        GeekTheme.drawSymbol(symbol, pointSize: 15.0, weight: .semibold, in: bounds, alpha: 0.96, tint: tint)
    }
}
