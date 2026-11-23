import AppKit
import Foundation
import MSnipCore

/// Google 翻译级可搜索全语种 + 自由自定义目标语言选择器弹窗（适配深色极客设置窗与浅色双栏对照窗）
@MainActor
final class LanguagePickerPopover: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    static let shared = LanguagePickerPopover()

    private enum RowItem {
        case header(String)
        case target(TranslationTargetLang, title: String, subtitle: String?, isCustomAction: Bool)
    }

    private let popover = NSPopover()
    private var searchField: NSTextField!
    private var tableView: NSTableView!
    private var rows: [RowItem] = []
    private var currentLang: TranslationTargetLang = .autoZhEn
    private var isDark = true
    private var onPick: ((TranslationTargetLang) -> Void)?

    private override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = true
    }

    func show(
        anchoredTo anchorView: NSView,
        current: TranslationTargetLang,
        dark: Bool,
        onPick: @escaping (TranslationTargetLang) -> Void
    ) {
        if popover.isShown { popover.performClose(nil) }
        self.currentLang = current
        self.isDark = dark
        self.onPick = onPick

        let W: CGFloat = 348, H: CGFloat = 400
        let vc = NSViewController()
        let root = PickerRootView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        root.wantsLayer = true
        root.layer?.backgroundColor = (dark ? GeekTheme.cardBg : MSnipUITheme.cardSolid).cgColor
        vc.view = root
        popover.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        popover.contentSize = NSSize(width: W, height: H)
        popover.contentViewController = vc

        let searchBox = PickerRootView(frame: NSRect(x: 12, y: 12, width: W - 24, height: 34))
        searchBox.wantsLayer = true
        searchBox.layer?.backgroundColor = (dark ? GeekTheme.inputBg : MSnipUITheme.subtleFill).cgColor
        searchBox.layer?.cornerRadius = 8.0
        searchBox.layer?.borderWidth = 1.0
        searchBox.layer?.borderColor = (dark ? GeekTheme.borderStrong : MSnipUITheme.borderStrong).cgColor
        root.addSubview(searchBox)

        let iconView = PickerSymbolIcon(symbol: "magnifyingglass", tint: dark ? GeekTheme.inkSecondary : MSnipUITheme.inkSecondary)
        iconView.frame = NSRect(x: 10, y: 0, width: 16, height: 34)
        searchBox.addSubview(iconView)

        let sf = NSTextField()
        sf.isBordered = false
        sf.drawsBackground = false
        sf.focusRingType = .none
        let sfFont = NSFont.systemFont(ofSize: 13.0, weight: .regular)
        sf.font = sfFont
        sf.textColor = dark ? GeekTheme.inkPrimary : MSnipUITheme.inkPrimary
        sf.placeholderAttributedString = NSAttributedString(
            string: "搜索全语种，或输入自定义语言回车…",
            attributes: [.font: sfFont, .foregroundColor: dark ? GeekTheme.inkMuted : MSnipUITheme.inkMuted]
        )
        sf.cell?.isScrollable = true
        sf.cell?.wraps = false
        GeekTheme.placeCentered(sf, x: 30, width: searchBox.bounds.width - 40, centerY: 17.0)
        sf.delegate = self
        searchBox.addSubview(sf)
        self.searchField = sf

        let tipLbl = NSTextField(labelWithString: "支持中英文与代码搜索 · 可直接输入粤语口语、文言文等")
        tipLbl.font = .systemFont(ofSize: 11.0, weight: .regular)
        tipLbl.textColor = dark ? GeekTheme.inkMuted : MSnipUITheme.inkMuted
        tipLbl.lineBreakMode = .byTruncatingTail
        GeekTheme.placeCentered(tipLbl, x: 14, width: W - 28, centerY: 58.0)
        root.addSubview(tipLbl)

        let scroll = NSScrollView(frame: NSRect(x: 6, y: 72, width: W - 12, height: H - 80))
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let tv = ClickableLangTableView(frame: scroll.bounds)
        if #available(macOS 11.0, *) { tv.style = .plain }
        tv.headerView = nil
        tv.backgroundColor = .clear
        tv.intercellSpacing = NSSize(width: 0, height: 1)
        tv.selectionHighlightStyle = .none
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("LangCol"))
        col.width = scroll.bounds.width
        tv.addTableColumn(col)
        tv.dataSource = self
        tv.delegate = self
        tv.onRowClicked = { [weak self] row in self?.commitRow(at: row) }
        scroll.documentView = tv
        root.addSubview(scroll)
        self.tableView = tv

        rebuildRows(query: "")
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
        sf.window?.makeFirstResponder(sf)
    }

    private func rebuildRows(query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var built: [RowItem] = []

        if q.isEmpty {
            built.append(.target(.autoZhEn, title: "自动互译（外→中 / 中→英）", subtitle: "智能识别原文语种", isCustomAction: false))
            if let custom = currentLang.customText {
                built.append(.target(currentLang, title: "自定义：\(custom)", subtitle: "当前自定义目标", isCustomAction: false))
            }
            built.append(.header("常用语种"))
            for e in TranslationLanguageCatalog.allEntries where e.isCommon {
                built.append(.target(.language(e.code), title: e.zhName, subtitle: e.nativeName == e.zhName ? e.code : e.nativeName, isCustomAction: false))
            }
            built.append(.header("全部世界语种 (\(TranslationLanguageCatalog.allEntries.count))"))
            for e in TranslationLanguageCatalog.allEntries where !e.isCommon {
                built.append(.target(.language(e.code), title: e.zhName, subtitle: e.nativeName.isEmpty ? e.enName : e.nativeName, isCustomAction: false))
            }
        } else {
            let matched = TranslationLanguageCatalog.allEntries.filter { $0.matches(q) }
            for e in matched {
                built.append(.target(.language(e.code), title: e.zhName, subtitle: "\(e.enName) · \(e.code)", isCustomAction: false))
            }
            let customTarget = TranslationTargetLang(rawValue: "custom:\(q)")
            built.append(.target(customTarget, title: "使用自定义目标：「\(q)」", subtitle: "按 ↩ 回车或点击直接生效", isCustomAction: true))
        }
        rows = built
        tableView?.reloadData()
    }

    func controlTextDidChange(_ obj: Notification) {
        rebuildRows(query: searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let q = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return false }
            if let firstHit = rows.compactMap({ item -> TranslationTargetLang? in
                if case .target(let lang, _, _, let isCustom) = item, !isCustom { return lang }
                return nil
            }).first, rows.count == 2 {
                finish(with: firstHit)
            } else {
                finish(with: TranslationTargetLang(rawValue: "custom:\(q)"))
            }
            return true
        }
        return false
    }

    private func commitRow(at row: Int) {
        guard rows.indices.contains(row) else { return }
        if case .target(let lang, _, _, _) = rows[row] {
            finish(with: lang)
        }
    }

    private func finish(with lang: TranslationTargetLang) {
        let cb = onPick
        popover.performClose(nil)
        cb?(lang)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 26 }
        return 32
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .header(let title):
            return LangHeaderView(title: title, dark: isDark)

        case .target(let lang, let title, let sub, let isCustomAct):
            let selected = (!isCustomAct && lang == currentLang)
            return LangRowView(title: title, subtitle: sub, selected: selected, highlightAccent: isCustomAct, dark: isDark)
        }
    }
}

private final class PickerRootView: NSView { override var isFlipped: Bool { true } }

private final class PickerSymbolIcon: NSView {
    let symbol: String; let tint: NSColor
    override var isFlipped: Bool { true }
    init(symbol: String, tint: NSColor) { self.symbol = symbol; self.tint = tint; super.init(frame: .zero) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        GeekTheme.drawSymbol(symbol, pointSize: 12.5, weight: .semibold, in: bounds, alpha: 0.9, tint: tint)
    }
}

private final class LangHeaderView: NSView {
    let title: String; let dark: Bool
    override var isFlipped: Bool { true }
    init(title: String, dark: Bool) { self.title = title; self.dark = dark; super.init(frame: .zero) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let fg = dark ? GeekTheme.inkMuted : MSnipUITheme.inkMuted
        GeekTheme.drawText(title, in: CGRect(x: 16, y: 2, width: max(40, bounds.width - 32), height: bounds.height - 2), font: .systemFont(ofSize: 11.0, weight: .semibold), color: fg)
    }
}

private final class ClickableLangTableView: NSTableView {
    var onRowClicked: ((Int) -> Void)?
    override func mouseDown(with event: NSEvent) {
        let r = row(at: convert(event.locationInWindow, from: nil))
        if r >= 0 { onRowClicked?(r) }
    }
}

private final class LangRowView: NSView {
    let title: String; let subtitle: String?; let selected: Bool; let highlightAccent: Bool; let dark: Bool
    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    override var isFlipped: Bool { true }

    init(title: String, subtitle: String?, selected: Bool, highlightAccent: Bool, dark: Bool) {
        self.title = title; self.subtitle = subtitle; self.selected = selected; self.highlightAccent = highlightAccent; self.dark = dark
        super.init(frame: .zero)
        self.toolTip = subtitle.map { "\($0.isEmpty ? title : "\(title) · \($0)")" } ?? title
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 6, dy: 1.5)
        if selected || hovered || highlightAccent {
            let p = CGPath(roundedRect: r, cornerWidth: 7.0, cornerHeight: 7.0, transform: nil)
            let fill: NSColor = selected
                ? (dark ? GeekTheme.accentSoft : MSnipUITheme.activeSoftFill)
                : (hovered ? (dark ? GeekTheme.controlHover : MSnipUITheme.hoverFill) : (dark ? NSColor(white: 1, alpha: 0.03) : MSnipUITheme.subtleFill))
            ctx.setFillColor(fill.cgColor); ctx.addPath(p); ctx.fillPath()
        }
        let accent = dark ? GeekTheme.accent : MSnipUITheme.accent
        let fg = (selected || highlightAccent) ? accent : (dark ? GeekTheme.inkPrimary : MSnipUITheme.inkPrimary)
        if selected {
            GeekTheme.drawSymbol("checkmark", pointSize: 11.5, weight: .bold, in: CGRect(x: 14, y: 0, width: 14, height: bounds.height), alpha: 1.0, tint: accent)
        } else if highlightAccent {
            GeekTheme.drawSymbol("sparkles", pointSize: 11.5, weight: .semibold, in: CGRect(x: 14, y: 0, width: 14, height: bounds.height), alpha: 1.0, tint: accent)
        }
        let leftX: CGFloat = (selected || highlightAccent) ? 32 : 16
        let titleFont = NSFont.systemFont(ofSize: 12.5, weight: (selected || highlightAccent) ? .semibold : .medium)
        var maxTitleRight = bounds.width - 16
        if let sub = subtitle, !sub.isEmpty {
            let subFont = NSFont.systemFont(ofSize: 11.0, weight: .regular)
            let subW = GeekTheme.measureTextWidth(sub, font: subFont)
            let titleW = GeekTheme.measureTextWidth(title, font: titleFont)
            if leftX + min(titleW, 180) + 12 + subW <= bounds.width - 14 {
                GeekTheme.drawText(sub, in: CGRect(x: bounds.width - subW - 16, y: 0, width: subW + 2, height: bounds.height), font: subFont, color: dark ? GeekTheme.inkMuted : MSnipUITheme.inkMuted, align: .right)
                maxTitleRight = bounds.width - subW - 24
            }
        }
        GeekTheme.drawText(title, in: CGRect(x: leftX, y: 0, width: max(40, maxTitleRight - leftX), height: bounds.height), font: titleFont, color: fg)
    }
}
