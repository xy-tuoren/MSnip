import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 翻译服务列表行视图（38px 行高 + 悬停柔和底色 + 清晰「使用中 / 已就绪 / 填 Key」状态胶囊）
final class ProviderRowCellView: NSTableCellView {
    private let titleText: String
    private let isPrimary: Bool
    private let isReady: Bool
    private let isRowSelected: Bool
    private let dotColor: NSColor
    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    override var isFlipped: Bool { true }

    init(title: String, isPrimary: Bool, isReady: Bool, isSelected: Bool, dotColor: NSColor, fullTooltip: String? = nil) {
        self.titleText = title
        self.isPrimary = isPrimary
        self.isReady = isReady
        self.isRowSelected = isSelected
        self.dotColor = dotColor
        super.init(frame: .zero)
        self.toolTip = fullTooltip ?? title
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if isRowSelected || hovered {
            let bg = CGPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), cornerWidth: 7.5, cornerHeight: 7.5, transform: nil)
            ctx.setFillColor((isRowSelected ? GeekTheme.controlHover : GeekTheme.hoverSoft).cgColor)
            ctx.addPath(bg); ctx.fillPath()
            if isRowSelected {
                ctx.setStrokeColor(GeekTheme.borderStrong.cgColor)
                ctx.setLineWidth(1.0); ctx.addPath(bg); ctx.strokePath()
            }
        }
        MSnipUITheme.drawStatusDot(ctx: ctx, center: CGPoint(x: 14, y: bounds.midY), color: dotColor, halo: isPrimary)

        let badgeText: String = isPrimary ? "使用中" : (isReady ? "已就绪" : "填 Key")
        let badgeBg: NSColor = isPrimary ? GeekTheme.emeraldSoft : (isReady ? GeekTheme.accentSoft : GeekTheme.pillSubtle)
        let badgeFg: NSColor = isPrimary ? GeekTheme.emerald : (isReady ? GeekTheme.accent : GeekTheme.inkMuted)
        let bw: CGFloat = 44, bh: CGFloat = 20
        let br = CGRect(x: bounds.width - bw - 8, y: GeekTheme.snap((bounds.height - bh) * 0.5), width: bw, height: bh)
        ctx.setFillColor(badgeBg.cgColor)
        ctx.addPath(CGPath(roundedRect: br, cornerWidth: 5.0, cornerHeight: 5.0, transform: nil)); ctx.fillPath()
        GeekTheme.drawText(badgeText, in: br, font: .systemFont(ofSize: 10.5, weight: .semibold), color: badgeFg, align: .center)

        let titleFont = NSFont.systemFont(ofSize: 13.0, weight: (isRowSelected || isPrimary) ? .semibold : .medium)
        let titleFg = (isRowSelected || hovered) ? GeekTheme.inkPrimary : GeekTheme.inkSecondary
        GeekTheme.drawText(titleText, in: CGRect(x: 24, y: 0, width: max(30, br.minX - 28), height: bounds.height), font: titleFont, color: titleFg)
    }
}

/// 极客暗色文本输入壳（即时响应 firstResponder 蓝框焦点反馈 + 悬停显示完整内容提示）
final class GeekInputBox: NSView, NSViewToolTipOwner {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    let field: NSTextField
    var hintToolTip: String?
    private var hovered = false { didSet { if oldValue != hovered { refreshBorder() } } }
    private var focused = false { didSet { if oldValue != focused { refreshBorder() } } }
    private var responderObservation: NSKeyValueObservation?
    private var tooltipTag: NSView.ToolTipTag?

    init(frame: NSRect, field: NSTextField, placeholder: String, mono: Bool) {
        self.field = field
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = GeekTheme.inputBg.cgColor
        layer?.cornerRadius = 7.5
        layer?.borderWidth = 1.0
        layer?.borderColor = GeekTheme.border.cgColor

        field.isBordered = false; field.isBezeled = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = mono ? .monospacedSystemFont(ofSize: 12.5, weight: .regular) : .systemFont(ofSize: 13.0, weight: .regular)
        field.textColor = GeekTheme.inkPrimary
        field.setGeekPlaceholder(placeholder)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true; field.cell?.wraps = false
        let fh = ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 400, height: 40)).height ?? 18)
        field.frame = NSRect(x: 10, y: GeekTheme.snap((frame.height - fh) * 0.5 - 0.25), width: frame.width - 20, height: fh)
        addSubview(field)
        refreshTooltipRect()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshTooltipRect()
    }

    private func refreshTooltipRect() {
        if let tag = tooltipTag { removeToolTip(tag) }
        tooltipTag = addToolTip(bounds, owner: self, userData: nil)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard !(field is NSSecureTextField) else { return "" }
        if let hint = hintToolTip, !hint.isEmpty { return hint }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.backgroundColor = GeekTheme.resolvedCGColor(GeekTheme.inputBg, for: self)
        refreshBorder()
        responderObservation?.invalidate()
        responderObservation = nil
        guard let win = window else { focused = false; return }
        responderObservation = win.observe(\.firstResponder, options: [.initial, .new]) { [weak self] window, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let editor = window.firstResponder as? NSTextView, (editor.delegate as AnyObject?) === self.field {
                    self.focused = true
                } else {
                    self.focused = (window.firstResponder === self.field)
                }
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(field) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = GeekTheme.resolvedCGColor(GeekTheme.inputBg, for: self)
        refreshBorder()
        if let ph = field.placeholderAttributedString?.string, !ph.isEmpty { field.setGeekPlaceholder(ph) }
    }

    private func refreshBorder() {
        layer?.borderWidth = focused ? 1.25 : 1.0
        let col = focused ? GeekTheme.accent.withAlphaComponent(0.80) : (hovered ? GeekTheme.borderStrong : GeekTheme.border)
        layer?.borderColor = GeekTheme.resolvedCGColor(col, for: self)
    }
}

extension NSTextField {
    func setGeekPlaceholder(_ text: String) {
        placeholderAttributedString = NSAttributedString(
            string: text,
            attributes: [.font: font ?? NSFont.systemFont(ofSize: 13.0), .foregroundColor: GeekTheme.inkMuted]
        )
    }

    func setTextWithTooltip(_ text: String, color: NSColor? = nil) {
        if let color { textColor = color }
        stringValue = text
        toolTip = text.isEmpty ? nil : text
    }
}

/// 权限状态行视图（14pt 主标题 + 右侧或紧邻清晰语义状态）
final class GeekDotLabel: NSView {
    var dotColor: NSColor = GeekTheme.emerald { didSet { needsDisplay = true } }
    var text: String = "" { didSet { needsDisplay = true } }
    var detail: String = "" { didSet { needsDisplay = true } }
    var alignDetailRight: Bool = true
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        MSnipUITheme.drawStatusDot(ctx: ctx, center: CGPoint(x: 6, y: bounds.midY), color: dotColor, halo: true)

        let titleFont = NSFont.systemFont(ofSize: 13.5, weight: .regular)
        let tW = GeekTheme.measureTextWidth(text, font: titleFont)
        GeekTheme.drawText(text, in: CGRect(x: 20, y: 0, width: max(20, bounds.width - 22), height: bounds.height), font: titleFont, color: GeekTheme.inkPrimary)

        if !detail.isEmpty {
            let detFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
            if alignDetailRight {
                GeekTheme.drawText(detail, in: CGRect(x: 20 + tW + 8, y: 0, width: max(20, bounds.width - 28 - tW), height: bounds.height), font: detFont, color: dotColor, align: .right)
            } else {
                GeekTheme.drawText(detail, in: CGRect(x: 20 + tW + 12, y: 0, width: max(20, bounds.width - 32 - tW), height: bounds.height), font: detFont, color: dotColor)
            }
        }
    }
}

/// 设置窗口暗黑/明亮/跟随系统外观切换联动扩展
extension TranslationSettingsWindow {
    func toggleDarkLightQuick() {
        applyAppearanceMode(GeekTheme.isDark ? .light : .dark, persist: true)
    }

    func applyAppearanceMode(_ mode: AppAppearanceMode, persist: Bool) {
        GeekTheme.currentMode = mode
        ResultWindowChrome.prefersDarkAppearance = GeekTheme.isDark
        if persist {
            onAppConfigMutated? { $0.appearanceMode = mode }
        }
        HotKeyConflictPopover.shared.closeIfShown()
        ProviderAddAndPresetPopover.shared.closeIfShown()
        LanguagePickerPopover.shared.closeIfShown()
        if let win = window {
            win.appearance = GeekTheme.windowAppearance
            win.backgroundColor = GeekTheme.windowBg
            if let root = win.contentView { ResultWindowChrome.invalidateSubtree(root) }
        }
        tableView?.reloadData()
        if let idx = AppAppearanceMode.allCases.firstIndex(of: mode) {
            modeControls.appearanceSegment?.selectedIndex = idx
        }
        let dark = GeekTheme.isDark
        modeControls.themeToggleBtn?.title = dark ? "明亮" : "暗黑"
        modeControls.themeToggleBtn?.symbolName = dark ? "sun.max" : "moon"
        modeControls.themeToggleBtn?.toolTip = dark ? "当前暗黑模式 · 点击一键切换明亮模式" : "当前明亮模式 · 点击一键切换暗黑模式"
    }
}
