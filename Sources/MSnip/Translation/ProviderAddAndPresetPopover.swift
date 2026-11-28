import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 现代可搜索翻译服务添加与 LLM 预设选择器浮窗（替代易被屏幕底边裁切、需二级悬停的原生 NSMenu）
@MainActor
final class ProviderAddAndPresetPopover: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    static let shared = ProviderAddAndPresetPopover()

    private enum Mode { case addService, pickLLMPreset(currentEndpoint: String) }

    private struct PickOption {
        let title: String
        let subtitle: String
        let symbol: String
        let badge: String
        let badgeColor: NSColor
        let searchBlob: String
        let category: Int // 1 = LLM, 2 = Cloud/Native
        let isCurrent: Bool
        let onChoose: () -> Void
    }

    private enum Row {
        case header(String)
        case option(PickOption)
    }

    private let popover = NSPopover()
    private var mode: Mode = .addService
    private var filterIndex = 0
    private var searchField: NSTextField!
    private var filterSegment: GeekSegmentControl?
    private var tableView: NSTableView!
    private var rows: [Row] = []
    private var onCreateProfile: ((TranslationProviderProfile) -> Void)?
    private var onPickPreset: ((LLMQuickPreset) -> Void)?

    private override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = true
    }

    func closeIfShown() {
        if popover.isShown { popover.performClose(nil) }
    }

    func showAddService(anchoredTo anchor: NSView, onCreate: @escaping (TranslationProviderProfile) -> Void) {
        self.mode = .addService
        self.onCreateProfile = onCreate
        self.onPickPreset = nil
        present(anchoredTo: anchor, preferredEdge: .minY)
    }

    func showLLMPresetPicker(anchoredTo anchor: NSView, currentEndpoint: String, onPick: @escaping (LLMQuickPreset) -> Void) {
        self.mode = .pickLLMPreset(currentEndpoint: currentEndpoint)
        self.onCreateProfile = nil
        self.onPickPreset = onPick
        present(anchoredTo: anchor, preferredEdge: .maxY)
    }

    private func present(anchoredTo anchor: NSView, preferredEdge: NSRectEdge) {
        if popover.isShown { popover.performClose(nil); return }
        filterIndex = 0
        let isAdd: Bool
        if case .addService = mode { isAdd = true } else { isAdd = false }

        let W: CGFloat = 416, H: CGFloat = 446
        let vc = NSViewController()
        let root = GeekSurfaceView(frame: NSRect(x: 0, y: 0, width: W, height: H), fill: GeekTheme.cardBg)
        vc.view = root
        popover.appearance = GeekTheme.popoverAppearance
        popover.contentSize = NSSize(width: W, height: H)
        popover.contentViewController = vc

        let searchBox = GeekSurfaceView(frame: NSRect(x: 12, y: 12, width: W - 24, height: 34), fill: GeekTheme.inputBg, border: GeekTheme.borderStrong, cornerRadius: 8.0, borderWidth: 1.0)
        root.addSubview(searchBox)

        let icon = ProviderSearchIconView(frame: NSRect(x: 10, y: 0, width: 16, height: 34))
        searchBox.addSubview(icon)

        let sf = NSTextField()
        sf.isBordered = false; sf.drawsBackground = false; sf.focusRingType = .none
        let sfFont = NSFont.systemFont(ofSize: 13.0)
        sf.font = sfFont; sf.textColor = GeekTheme.inkPrimary
        sf.setGeekPlaceholder(isAdd ? L("搜索厂商或服务（如 DeepSeek、豆包、腾讯、Ollama）…") : L("搜索主流大模型官网预设（支持中英文 / 域名）…"))
        sf.cell?.isScrollable = true; sf.cell?.wraps = false
        GeekTheme.placeCentered(sf, x: 30, width: searchBox.bounds.width - 40, centerY: 17.0)
        sf.delegate = self
        searchBox.addSubview(sf)
        self.searchField = sf

        var listTopY: CGFloat = 56
        if isAdd {
            let seg = GeekSegmentControl(items: [L("全部服务"), L("LLM 大模型 (21)"), L("云翻译 & 离线")], selectedIndex: 0)
            seg.frame = NSRect(x: 12, y: 54, width: W - 24, height: 30)
            seg.onSelect = { [weak self] idx in
                self?.filterIndex = idx
                self?.rebuildRows(query: self?.searchField.stringValue ?? "")
            }
            root.addSubview(seg)
            self.filterSegment = seg
            listTopY = 92
        } else {
            self.filterSegment = nil
        }

        root.addSubview(GeekSurfaceView(frame: NSRect(x: 0, y: listTopY - 1, width: W, height: 1), fill: GeekTheme.divider))

        let scroll = NSScrollView(frame: NSRect(x: 4, y: listTopY + 2, width: W - 8, height: H - listTopY - 6))
        scroll.drawsBackground = false; scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true; scroll.scrollerStyle = .overlay; scroll.horizontalScrollElasticity = .none

        let tv = ClickableProviderTableView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        if #available(macOS 11.0, *) { tv.style = .plain }
        tv.headerView = nil; tv.backgroundColor = .clear
        tv.intercellSpacing = NSSize(width: 0, height: 2)
        tv.selectionHighlightStyle = .none
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ProvPickCol"))
        col.width = scroll.contentSize.width
        tv.addTableColumn(col)
        tv.dataSource = self; tv.delegate = self
        tv.onRowClicked = { [weak self] row in self?.commitRow(at: row) }
        scroll.documentView = tv
        root.addSubview(scroll)
        self.tableView = tv

        rebuildRows(query: "")
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: preferredEdge)
        sf.window?.makeFirstResponder(sf)
    }

    private func rebuildRows(query rawQuery: String) {
        let q = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var built: [Row] = []

        func matches(_ opt: PickOption) -> Bool {
            if case .addService = mode {
                if filterIndex == 1 && opt.category != 1 { return false }
                if filterIndex == 2 && opt.category != 2 { return false }
            }
            if q.isEmpty { return true }
            return opt.searchBlob.contains(q)
        }

        func appendGroup(_ header: String, _ options: [PickOption]) {
            let hits = options.filter(matches)
            guard !hits.isEmpty else { return }
            built.append(.header(header))
            built.append(contentsOf: hits.map { .option($0) })
        }

        let currentMatch: LLMQuickPreset?
        if case .pickLLMPreset(let ep) = mode { currentMatch = LLMQuickPreset.match(endpoint: ep) ?? .customOpenAI }
        else { currentMatch = nil }

        for group in LLMQuickPresetGroup.allCases {
            let opts = LLMQuickPreset.allCases.filter { $0.group == group }.map { preset -> PickOption in
                let proto = Self.protocolBadge(for: preset)
                let sym = preset == .customOpenAI ? "slider.horizontal.3"
                    : (group == .local ? "desktopcomputer" : (group == .international ? "globe" : "sparkles"))
                let parsed = URL(string: preset.baseURL)
                let host = parsed.map { u in
                    let h = u.host ?? preset.baseURL
                    return u.port.map { "\(h):\($0)" } ?? h
                } ?? preset.baseURL
                let sub = preset == .customOpenAI
                    ? L("支持 OpenAI Chat / Responses / Anthropic / Gemini 四种格式")
                    : host
                return PickOption(
                    title: preset.title,
                    subtitle: sub,
                    symbol: sym,
                    badge: proto.text,
                    badgeColor: proto.color,
                    searchBlob: "\(preset.title) \(preset.shortName) \(preset.baseURL) \(preset.defaultModel) \(proto.text) llm".lowercased(),
                    category: 1,
                    isCurrent: (preset == currentMatch),
                    onChoose: { [weak self] in
                        guard let self else { return }
                        if case .pickLLMPreset = self.mode {
                            self.onPickPreset?(preset)
                        } else {
                            let prof = TranslationProviderProfile(
                                name: preset.shortName,
                                kind: preset.providerKind,
                                isEnabled: true,
                                endpoint: preset.baseURL,
                                model: preset.defaultModel
                            )
                            self.onCreateProfile?(prof)
                        }
                    }
                )
            }
            appendGroup(group.title, opts)
        }

        if case .addService = mode {
            let nativeAndCloud: [(String, String, TranslationProviderKind, String, String, NSColor)] = [
                (L("Apple 离线翻译（免费）"), L("macOS 系统内置神经网络 · 无需 Key · 断网可用"), .appleNative, "apple.logo", L("免费离线"), GeekTheme.emerald),
                (L("腾讯云翻译"), L("每月 500 万字符免费额度 · 填入 SecretId / SecretKey"), .tencent, "cloud", L("云翻译"), GeekTheme.inkSecondary),
                (L("百度翻译开放平台"), L("每月百万字符免费额度 · 填入 AppID / 密钥"), .baidu, "cloud", L("云翻译"), GeekTheme.inkSecondary),
                (L("有道智云翻译"), L("有道神经网络翻译 · 填入应用 ID / 应用密钥"), .youdao, "cloud", L("云翻译"), GeekTheme.inkSecondary),
                (L("DeepL / 自建 DeepLX"), L("支持官方 Auth Key 与本机免密钥 DeepLX 服务"), .deepl, "globe", L("云 / 自建"), GeekTheme.inkSecondary),
                (L("自定义 HTTP JSON 接口"), L("开发者自由定制 URL、请求体模版与 JSON 提取路径"), .customWebhook, "wrench.and.screwdriver", "Webhook", GeekTheme.amber)
            ]
            appendGroup(L("系统离线 & 传统云翻译"), nativeAndCloud.map { item in
                PickOption(
                    title: item.0, subtitle: item.1, symbol: item.3, badge: item.4, badgeColor: item.5,
                    searchBlob: "\(item.0) \(item.1) \(item.2.displayName) \(item.4)".lowercased(),
                    category: 2, isCurrent: false,
                    onChoose: { [weak self] in self?.onCreateProfile?(.makePreset(item.2)) }
                )
            })
        }

        rows = built
        tableView?.reloadData()
        tableView?.scrollRowToVisible(0)
    }

    private static func protocolBadge(for preset: LLMQuickPreset) -> (text: String, color: NSColor) {
        if preset == .customOpenAI { return (L("自定义"), GeekTheme.inkSecondary) }
        if preset.group == .local { return (L("本机免 Key"), GeekTheme.emerald) }
        switch preset.providerKind {
        case .openAIResponses:     return ("Responses", GeekTheme.accent)
        case .anthropicCompatible: return ("Anthropic", GeekTheme.amber)
        case .geminiNative:        return ("Gemini", GeekTheme.accent)
        default:                   return ("OpenAI", GeekTheme.accent)
        }
    }

    func controlTextDidChange(_ obj: Notification) { rebuildRows(query: searchField.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if let idx = rows.firstIndex(where: { if case .option = $0 { return true }; return false }) {
                commitRow(at: idx)
                return true
            }
        }
        return false
    }

    private func commitRow(at row: Int) {
        guard rows.indices.contains(row), case .option(let opt) = rows[row] else { return }
        popover.performClose(nil)
        opt.onChoose()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 26 }
        return 46
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .header(let title):
            return ProviderPickerHeaderView(title: title)
        case .option(let opt):
            return ProviderPickerRowView(
                title: opt.title, subtitle: opt.subtitle, symbol: opt.symbol,
                badge: opt.isCurrent ? L("✓ 当前") : opt.badge,
                badgeColor: opt.isCurrent ? GeekTheme.emerald : opt.badgeColor,
                selected: opt.isCurrent
            )
        }
    }
}

// MARK: - 预设渠道选择器行视图

/// 服务添加 / 预设选择浮窗内的辅助视图（搜索图标、分组头、带悬停完整提示的双行富选项卡片）
final class ProviderSearchIconView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        GeekTheme.drawSymbol("magnifyingglass", pointSize: 12.5, weight: .semibold, in: bounds, alpha: 0.9, tint: GeekTheme.inkSecondary)
    }
}

private final class ClickableProviderTableView: NSTableView {
    var onRowClicked: ((Int) -> Void)?
    override func mouseDown(with event: NSEvent) {
        let r = row(at: convert(event.locationInWindow, from: nil))
        if r >= 0 { onRowClicked?(r) }
    }
}

private final class ProviderPickerHeaderView: NSView {
    let title: String
    override var isFlipped: Bool { true }
    init(title: String) { self.title = title; super.init(frame: .zero) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        GeekTheme.drawText(title, in: CGRect(x: 12, y: 4, width: max(40, bounds.width - 24), height: bounds.height - 4), font: .systemFont(ofSize: 11.0, weight: .semibold), color: GeekTheme.inkMuted)
    }
}

private final class ProviderPickerRowView: NSView {
    let title: String
    let subtitle: String
    let symbol: String
    let badge: String
    let badgeColor: NSColor
    let selected: Bool
    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    override var isFlipped: Bool { true }

    init(title: String, subtitle: String, symbol: String, badge: String, badgeColor: NSColor, selected: Bool) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol
        self.badge = badge; self.badgeColor = badgeColor; self.selected = selected
        super.init(frame: .zero)
        self.toolTip = "\(title)\n\(subtitle)"
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 6, dy: 1.5)
        if selected || hovered {
            let p = CGPath(roundedRect: r, cornerWidth: 8.0, cornerHeight: 8.0, transform: nil)
            ctx.setFillColor((selected ? GeekTheme.accentSoft : GeekTheme.controlHover).cgColor)
            ctx.addPath(p); ctx.fillPath()
        }
        let iconBox = CGRect(x: 14, y: GeekTheme.snap((bounds.height - 28) * 0.5), width: 28, height: 28)
        let ip = CGPath(roundedRect: iconBox, cornerWidth: 7.0, cornerHeight: 7.0, transform: nil)
        ctx.setFillColor(GeekTheme.controlBg.cgColor); ctx.addPath(ip); ctx.fillPath()
        ctx.setStrokeColor(GeekTheme.border.cgColor); ctx.setLineWidth(1.0); ctx.addPath(ip); ctx.strokePath()
        GeekTheme.drawSymbol(symbol, pointSize: 12.0, weight: .medium, in: iconBox, alpha: 0.94, tint: selected ? GeekTheme.accent : GeekTheme.inkPrimary)

        let badgeFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        let bw = max(46, ceil(GeekTheme.measureTextWidth(badge, font: badgeFont) + 12))
        let br = CGRect(x: bounds.width - bw - 14, y: GeekTheme.snap((bounds.height - 20) * 0.5), width: bw, height: 20)
        ctx.setFillColor(badgeColor.withAlphaComponent(0.14).cgColor)
        ctx.addPath(CGPath(roundedRect: br, cornerWidth: 5.0, cornerHeight: 5.0, transform: nil)); ctx.fillPath()
        GeekTheme.drawText(badge, in: br, font: badgeFont, color: badgeColor, align: .center)

        let textW = max(60, br.minX - 58)
        GeekTheme.drawText(title, in: CGRect(x: 50, y: 6, width: textW, height: 18), font: .systemFont(ofSize: 13.0, weight: .semibold), color: GeekTheme.inkPrimary)
        GeekTheme.drawText(subtitle, in: CGRect(x: 50, y: 24, width: textW, height: 15), font: .systemFont(ofSize: 11.0, weight: .regular), color: GeekTheme.inkSecondary)
    }
}
