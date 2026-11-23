import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 实时热键冲突体检、本机已占热键搜索一览与独立「实测归属」互动诊断浮窗
@MainActor
final class HotKeyConflictPopover: NSObject, NSPopoverDelegate, NSTextFieldDelegate {
    static let shared = HotKeyConflictPopover()

    private let popover = NSPopover()
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
        let root = GeekFlippedView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        root.wantsLayer = true
        root.layer?.backgroundColor = GeekTheme.cardBg.cgColor
        vc.view = root
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentSize = NSSize(width: W, height: H)
        popover.contentViewController = vc

        let title = NSTextField(labelWithString: "热键冲突体检与占用一览")
        title.font = .systemFont(ofSize: 14.5, weight: .semibold); title.textColor = GeekTheme.inkPrimary
        summaryLabel = NSTextField(labelWithString: "")
        summaryLabel.font = .systemFont(ofSize: 11.5, weight: .regular); summaryLabel.textColor = GeekTheme.inkMuted
        summaryLabel.lineBreakMode = .byTruncatingTail
        GeekTheme.placeTwoLineStack(title, summaryLabel, x: 16, width: W - 116, centerY: 29, gap: 2)
        root.addSubview(title); root.addSubview(summaryLabel)

        rescanBtn = GeekButton(title: "重扫", symbol: "arrow.clockwise", style: .subtle)
        rescanBtn.toolTip = "重新扫描 macOS 系统热键与当前后台运行中应用"
        rescanBtn.frame = NSRect(x: W - 92, y: 15, width: 76, height: 28)
        rescanBtn.onClick = { [weak self] in self?.handleRescanClicked() }
        root.addSubview(rescanBtn)

        tabSegment = GeekSegmentControl(items: ["当前体检", "实测归属", "系统已占", "运行中应用"], selectedIndex: 0)
        tabSegment.frame = NSRect(x: 14, y: 58, width: W - 28, height: 32)
        tabSegment.onSelect = { [weak self] idx in
            guard let self else { return }
            self.activeTab = idx
            self.searchQuery = ""
            self.searchField.stringValue = ""
            self.rebuildList()
        }
        root.addSubview(tabSegment)

        searchContainer = GeekFlippedView(frame: NSRect(x: 14, y: 98, width: W - 28, height: 32))
        searchContainer.wantsLayer = true
        searchContainer.layer?.backgroundColor = GeekTheme.inputBg.cgColor
        searchContainer.layer?.cornerRadius = 7.5
        searchContainer.layer?.borderWidth = 1.0
        searchContainer.layer?.borderColor = GeekTheme.border.cgColor
        searchContainer.addSubview(ProviderSearchIconView(frame: NSRect(x: 10, y: 0, width: 14, height: 32)))
        searchField = NSTextField()
        searchField.isBordered = false; searchField.drawsBackground = false; searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 12.5); searchField.textColor = GeekTheme.inkPrimary
        searchField.setGeekPlaceholder("筛选快捷键、功能或应用名（如 截图 / ⌥1 / ⌘␣ / 聚焦搜索）…")
        searchField.cell?.isScrollable = true; searchField.cell?.wraps = false
        GeekTheme.placeCentered(searchField, x: 28, width: searchContainer.bounds.width - 38, centerY: 16)
        searchField.delegate = self
        searchContainer.addSubview(searchField)
        root.addSubview(searchContainer)

        let sep = NSView(frame: NSRect(x: 0, y: 97, width: W, height: 1))
        sep.wantsLayer = true; sep.layer?.backgroundColor = GeekTheme.divider.cgColor
        root.addSubview(sep)

        let sv = NSScrollView(frame: NSRect(x: 0, y: 98, width: W, height: H - 98))
        sv.drawsBackground = false; sv.borderType = .noBorder
        sv.hasVerticalScroller = true; sv.autohidesScrollers = true
        root.addSubview(sv)
        self.scrollView = sv

        rebuildList()
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
        rescanBtn.title = "已更新"
        rescanBtn.symbolName = "checkmark"
        rescanBtn.style = .emeraldSoft
        let work = DispatchWorkItem { [weak self] in
            self?.rescanBtn?.title = "重扫"
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
            "当前体检",
            isProbing ? "监听中…" : "实测归属",
            "系统 (\(snap.systemEntries.count))",
            "应用 (\(snap.runningAppEntries.count))"
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
            summaryLabel.setTextWithTooltip("全局热键总开关已关闭 · 扫描于 \(timeStr)", color: GeekTheme.inkSecondary)
        } else if priorityActive && conflictCount > 0 {
            summaryLabel.setTextWithTooltip("⚡ 已强制优先接管 \(conflictCount) 项外部冲突 · 扫描于 \(timeStr)", color: GeekTheme.accent)
        } else if conflictCount > 0 {
            summaryLabel.setTextWithTooltip("发现 \(conflictCount) 项冲突/预警 · 扫描于 \(timeStr)（共 \(snap.systemEntries.count) 系统 / \(snap.runningAppEntries.count) 应用）", color: GeekTheme.amber)
        } else {
            summaryLabel.setTextWithTooltip("✓ 全部已设热键零冲突 · 扫描于 \(timeStr)（已核验 \(snap.systemEntries.count + snap.runningAppEntries.count) 项）", color: GeekTheme.emerald)
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
            y = populateOccupiedRows(snap.systemEntries, own: own, in: doc, width: W, emptyText: "未匹配到符合条件的 macOS 系统热键", showProbeHint: false)
        } else {
            y = populateOccupiedRows(snap.runningAppEntries, own: own, in: doc, width: W, emptyText: "当前后台未匹配到已知冲突应用，可切至「实测归属」直接按键抓取真实占用方。", showProbeHint: true)
        }
        doc.frame.size.height = max(scrollView.bounds.height, y + 12)
        scrollView.documentView = doc
    }

    static func formatTime(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
