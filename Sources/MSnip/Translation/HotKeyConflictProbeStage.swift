import AppKit
import CoreGraphics
import Foundation
import MSnipCore

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
        let hero = GeekFlippedView(frame: NSRect(x: 14, y: y, width: W - 28, height: heroH))
        hero.wantsLayer = true
        hero.layer?.cornerRadius = 11.0
        hero.layer?.backgroundColor = (isListening ? GeekTheme.accentSoft : GeekTheme.inputBg).cgColor
        hero.layer?.borderWidth = isListening ? 1.25 : 1.0
        hero.layer?.borderColor = (isListening ? GeekTheme.accent.withAlphaComponent(0.75) : GeekTheme.border).cgColor
        container.addSubview(hero)

        let badgeColor: NSColor = isListening ? GeekTheme.accent : GeekTheme.inkSecondary
        let iconBox = ProbeStageIconView(
            symbol: isListening ? "waveform" : "scope",
            tint: badgeColor,
            frame: NSRect(x: round((hero.bounds.width - 34) * 0.5), y: 15, width: 34, height: 34)
        )
        hero.addSubview(iconBox)

        let titleStr = isListening
            ? "正在实时监听… 剩余 \(max(1, remainingSeconds)) 秒（按 Esc 停止）"
            : "按下任意快捷键，现场检测占用它的具体应用"
        let titleLbl = NSTextField(labelWithString: titleStr)
        titleLbl.font = .systemFont(ofSize: 13.5, weight: .semibold)
        titleLbl.textColor = isListening ? GeekTheme.accent : GeekTheme.inkPrimary
        titleLbl.alignment = .center
        GeekTheme.placeCentered(titleLbl, x: 14, width: hero.bounds.width - 28, centerY: 63)
        hero.addSubview(titleLbl)

        let descStr = isListening
            ? "请直接按下你想检测的组合键（如 ⌥1、⌃⌘A、⌘␣）。若触发了其他软件的窗口或悬浮面板，MSnip 将立即捕获其名称。"
            : "无论对方是常规前台应用窗口，还是无焦点悬浮面板与全屏覆盖层，按下即可实时定位占用该快捷键的具体应用。"
        let descLbl = NSTextField(wrappingLabelWithString: descStr)
        descLbl.font = .systemFont(ofSize: 11.5, weight: .regular)
        descLbl.textColor = GeekTheme.inkSecondary
        descLbl.alignment = .center
        descLbl.frame = NSRect(x: 20, y: 76, width: hero.bounds.width - 40, height: 32)
        hero.addSubview(descLbl)

        let btnW: CGFloat = isListening ? 136 : 126
        let actBtn = GeekButton(
            title: isListening ? "停止监听" : "开始按键实测",
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
            let hdr = NSTextField(labelWithString: "最近实测记录")
            hdr.font = .systemFont(ofSize: 11.5, weight: .semibold)
            hdr.textColor = GeekTheme.inkMuted
            GeekTheme.placeCentered(hdr, x: 16, width: 120, centerY: y + 10)
            container.addSubview(hdr)

            let clr = GeekButton(title: "清空", style: .ghost)
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
