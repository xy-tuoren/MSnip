import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 快捷键行前置极客小图标底座
final class GeekShortcutIconBadge: NSView {
    private let symbol: String
    private let ptSize: CGFloat
    override var isFlipped: Bool { true }
    init(symbol: String, pointSize: CGFloat = 13.0, frame: NSRect) {
        self.symbol = symbol
        self.ptSize = pointSize
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = GeekTheme.controlBg.cgColor
        layer?.cornerRadius = 7.5
        layer?.borderWidth = 1.0
        layer?.borderColor = GeekTheme.border.cgColor
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        GeekTheme.drawSymbol(symbol, pointSize: ptSize, weight: .medium, in: bounds, alpha: 0.94, tint: GeekTheme.inkPrimary)
    }
}

/// 强制优先接管一键开关卡片与实时状态同步扩展
extension TranslationSettingsWindow {
    func buildPriorityTakeoverCard(in container: GeekFlippedView, cardW: CGFloat) {
        let prioCard = GeekCardView(frame: NSRect(x: 28, y: 58, width: cardW, height: 44))
        container.addSubview(prioCard)
        prioCard.addSubview(GeekShortcutIconBadge(symbol: "bolt.shield", pointSize: 12.5, frame: NSRect(x: 16, y: 8, width: 28, height: 28)))

        let prioTitle = NSTextField(labelWithString: "冲突时强制优先接管")
        prioTitle.font = .systemFont(ofSize: 13.5, weight: .semibold); prioTitle.textColor = GeekTheme.inkPrimary
        GeekTheme.placeCentered(prioTitle, x: 54, width: 136, centerY: 22.0)
        prioCard.addSubview(prioTitle)

        let prioStatus = NSTextField(labelWithString: "已关闭 · 零底层监听（一键开关无副作用）")
        prioStatus.font = .systemFont(ofSize: 12.0, weight: .regular); prioStatus.textColor = GeekTheme.inkMuted
        prioStatus.lineBreakMode = .byTruncatingTail
        GeekTheme.placeCentered(prioStatus, x: 194, width: cardW - 332, centerY: 22.0)
        shortcutAudit.priorityStatusLabel = prioStatus
        prioCard.addSubview(prioStatus)

        let permBtn = GeekButton(title: "去授权", style: .amberSoft)
        permBtn.frame = NSRect(x: cardW - 128, y: 9, width: 64, height: 26)
        permBtn.isHidden = true
        permBtn.onClick = { [weak self] in self?.onOpenPermissionGuide?() }
        shortcutAudit.priorityPermBtn = permBtn
        prioCard.addSubview(permBtn)

        let prioSw = GeekToggleSwitch(isOn: false)
        prioSw.toolTip = "开启后使用头部优先事件接管压过冲突应用与系统热键（需辅助功能权限）；关闭即彻底卸载监听、零残留无副作用"
        prioSw.frame = NSRect(x: cardW - 54, y: 11, width: 38, height: 22)
        prioSw.onToggle = { [weak self] on in
            guard let self else { return }
            self.onAppConfigMutated? { $0.forcePriorityHotKeys = on; if on { $0.hotKeysEnabled = true } }
            if on && !(self.isPriorityTapActiveProvider?() ?? false) {
                self.onOpenPermissionGuide?()
            }
            self.refreshGeneralAndPermissionsUI()
        }
        shortcutAudit.prioritySwitch = prioSw
        prioCard.addSubview(prioSw)
    }

    func syncPriorityTakeoverStatus(with cfg: AppConfig) -> Bool {
        if cfg.hotKeysEnabled && cfg.forcePriorityHotKeys && !(isPriorityTapActiveProvider?() ?? false),
           activeRecordingSlot == nil && !shortcutAudit.liveDetective.isListening,
           RegionDetector.checkAccessibilityPermission(prompt: false) {
            onReapplyHotKeys?()
        }
        let active = cfg.hotKeysEnabled && cfg.forcePriorityHotKeys && (isPriorityTapActiveProvider?() ?? false)
        shortcutAudit.prioritySwitch?.isOn = cfg.forcePriorityHotKeys
        if !cfg.forcePriorityHotKeys {
            shortcutAudit.priorityStatusLabel?.setTextWithTooltip("已关闭 · 零底层监听（一键开关无副作用）", color: GeekTheme.inkMuted)
            shortcutAudit.priorityPermBtn?.isHidden = true
        } else if !cfg.hotKeysEnabled {
            shortcutAudit.priorityStatusLabel?.setTextWithTooltip("全局热键总开关关闭中 · 开启总开关后生效", color: GeekTheme.inkSecondary)
            shortcutAudit.priorityPermBtn?.isHidden = true
        } else if active {
            shortcutAudit.priorityStatusLabel?.setTextWithTooltip("● 已生效 · 优先压过冲突应用与系统热键（关闭即彻底卸载）", color: GeekTheme.emerald)
            shortcutAudit.priorityPermBtn?.isHidden = true
        } else {
            shortcutAudit.priorityStatusLabel?.setTextWithTooltip("⚠ 需先授予「辅助功能」权限，当前自动回退常规热键", color: GeekTheme.amber)
            shortcutAudit.priorityPermBtn?.isHidden = false
        }
        return active
    }
}

/// 设置页快捷键冲突体检、优先接管开关、实测侦探与行内徽标共享状态盒（保持主窗口文件精简）
@MainActor
final class ShortcutConflictUIState {
    var auditButton: GeekButton?
    var rowBadges: [GlobalHotKeyAction: HotKeyConflictBadgeView] = [:]
    var rowSubLabels: [GlobalHotKeyAction: NSTextField] = [:]
    var prioritySwitch: GeekToggleSwitch?
    var priorityStatusLabel: NSTextField?
    var priorityPermBtn: GeekButton?
    var snapshot: HotKeyConflictSnapshot = .empty
    var pendingForceCombo: KeyCombo?
    var failedHotKeyActionsProvider: (() -> Set<GlobalHotKeyAction>)?
    let liveDetective = HotKeyLiveDetective()
}

/// 快捷键列表行内冲突/接管微胶囊（冲突时红/橙预警，开启强制接管后转为清爽蓝色「已优先接管」）
final class HotKeyConflictBadgeView: NSView {
    var onClick: (() -> Void)?
    private var text: String = ""
    private var severity: HotKeyConflictSeverity = .warning
    private var isOverridden = false
    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func configure(conflict: HotKeyConflict?, overridden: Bool = false) {
        guard let c = conflict else {
            isHidden = true; text = ""; isOverridden = false; toolTip = nil; return
        }
        isHidden = false
        isOverridden = overridden && (c.owner != "MSnip")
        text = isOverridden ? "已优先接管" : c.shortBadge
        severity = c.severity
        toolTip = isOverridden
            ? "已开启头部优先接管，将压过冲突：\(c.detailMessage)"
            : (c.detailMessage + "（点击查看冲突体检或开启强制优先接管）")
        needsDisplay = true
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        guard !isHidden, !text.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let fg: NSColor = isOverridden ? GeekTheme.accent : ((severity == .blocking) ? GeekTheme.danger : GeekTheme.amber)
        let symName = isOverridden ? "bolt.fill" : "exclamationmark.triangle.fill"
        let bgAlpha: CGFloat = hovered ? 0.24 : 0.14
        let font = NSFont.systemFont(ofSize: 11.0, weight: .semibold)
        let tw = GeekTheme.measureTextWidth(text, font: font)
        let symW = GeekTheme.symbolEntry(symName, pointSize: 10.0, weight: .semibold)?.pointSize.width ?? 11
        let pillW = min(bounds.width, ceil(symW + 4 + tw + 14))
        let pillH: CGFloat = 22
        let r = CGRect(x: bounds.width - pillW, y: GeekTheme.snap((bounds.height - pillH) * 0.5), width: pillW, height: pillH)
        let p = CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 6.0, cornerHeight: 6.0, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(fg.withAlphaComponent(bgAlpha).cgColor); ctx.addPath(p); ctx.fillPath()
        ctx.setStrokeColor(fg.withAlphaComponent(0.45).cgColor); ctx.setLineWidth(1.0); ctx.addPath(p); ctx.strokePath()
        let sx = r.minX + 7
        GeekTheme.drawSymbol(symName, pointSize: 10.0, weight: .semibold, in: CGRect(x: sx, y: r.minY, width: symW, height: r.height), alpha: 0.96, tint: fg)
        GeekTheme.drawText(text, in: CGRect(x: sx + symW + 4, y: r.minY, width: max(12, r.maxX - (sx + symW + 10)), height: r.height), font: font, color: fg)
        ctx.restoreGState()
    }
}

final class PopoverStatusDot: NSView {
    let color: NSColor
    override var isFlipped: Bool { true }
    init(color: NSColor, frame: NSRect) { self.color = color; super.init(frame: frame) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        MSnipUITheme.drawStatusDot(ctx: ctx, center: CGPoint(x: bounds.midX, y: bounds.midY), color: color, halo: color != GeekTheme.inkMuted)
    }
}

final class PopoverKeyCapView: NSView {
    let text: String; let highlight: NSColor?
    override var isFlipped: Bool { true }
    init(text: String, highlight: NSColor?, frame: NSRect) { self.text = text; self.highlight = highlight; super.init(frame: frame) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 5.5, cornerHeight: 5.5, transform: nil)
        ctx.setFillColor((highlight?.withAlphaComponent(0.14) ?? GeekTheme.inputBg).cgColor); ctx.addPath(p); ctx.fillPath()
        ctx.setStrokeColor((highlight?.withAlphaComponent(0.55) ?? GeekTheme.borderStrong).cgColor); ctx.setLineWidth(1.0); ctx.addPath(p); ctx.strokePath()
        GeekTheme.drawText(text, in: bounds.insetBy(dx: 4, dy: 0), font: .monospacedSystemFont(ofSize: 12.0, weight: .semibold), color: highlight ?? GeekTheme.inkPrimary, align: .center)
    }
}
