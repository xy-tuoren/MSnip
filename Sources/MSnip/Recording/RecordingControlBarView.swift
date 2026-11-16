import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 选区动图/视频录制的深色毛玻璃悬浮控制条（录制前可切换 GIF/MP4，录制中显示计时、暂停、另存与完成复制）
final class RecordingControlBarView: NSView {
    enum Action {
        case selectFormat(RecordingFormat)
        case toggleInteractionHUD
        case startRecording
        case togglePause
        case finishSave
        case finishCopy
        case cancel
    }

    static let barHeight: CGFloat = 40

    var onAction: ((Action) -> Void)?
    var format: RecordingFormat = .gif { didSet { refreshLayout() } }
    var interactionHUDEnabled: Bool = true { didSet { refreshLayout() } }
    var isRecording: Bool = false { didSet { refreshLayout() } }
    var isPaused: Bool = false { didSet { refreshLayout() } }
    var isEncoding: Bool = false { didSet { refreshLayout() } }
    var elapsedSeconds: TimeInterval = 0 { didSet { needsDisplay = true } }

    private struct HitSlot {
        let rect: CGRect
        let tip: String
        let action: Action
        let draw: (CGContext, CGRect, Bool) -> Void
    }

    private var slots: [HitSlot] = []
    private var hoveredIdx: Int?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 290, height: Self.barHeight))
        refreshLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let next = slots.firstIndex(where: { $0.rect.contains(p) })
        if next != hoveredIdx {
            hoveredIdx = next
            toolTip = next.map { slots[$0].tip }
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) { hoveredIdx = nil; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        guard !isEncoding else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let s = slots.first(where: { $0.rect.contains(p) }) {
            onAction?(s.action)
        }
    }

    func refreshLayout() {
        var list: [HitSlot] = []
        var x: CGFloat = 8
        let y: CGFloat = 5
        let h: CGFloat = 30

        if isEncoding {
            setFrameSize(NSSize(width: 210, height: Self.barHeight))
            slots = []
            needsDisplay = true
            return
        }

        let hudTip = interactionHUDEnabled
            ? "已开启：录屏显示鼠标点击波纹与快捷键角标（点击关闭）"
            : "已关闭：点击开启录屏鼠标波纹与快捷键角标回显"

        if !isRecording {
            for fmt in RecordingFormat.allCases {
                let active = (format == fmt)
                let r = CGRect(x: x, y: y, width: 44, height: h)
                list.append(HitSlot(rect: r, tip: "切换为 \(fmt.badgeTitle) 格式", action: .selectFormat(fmt)) { ctx, rect, hov in
                    ToolbarView.drawButtonBg(ctx: ctx, rect: rect, active: active, hovered: hov)
                    Self.drawLabel(fmt.badgeTitle, in: rect, color: active ? .white : NSColor(white: 0.78, alpha: 1))
                })
                x += 46
            }
            list.append(iconSlot(x: &x, y: y, symbol: "cursorarrow.click.2", tip: hudTip, tint: interactionHUDEnabled ? .systemCyan : .white, active: interactionHUDEnabled, action: .toggleInteractionHUD))
            x += 4
            let recRect = CGRect(x: x, y: y, width: 96, height: h)
            list.append(HitSlot(rect: recRect, tip: "开始录制选区画面 (↩)", action: .startRecording) { ctx, rect, hov in
                let p = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
                ctx.setFillColor(NSColor.systemRed.withAlphaComponent(hov ? 1.0 : 0.88).cgColor)
                ctx.addPath(p)
                ctx.fillPath()
                Self.drawLabel("● 开始录制", in: rect, color: .white)
            })
            x += 100
            list.append(iconSlot(x: &x, y: y, symbol: "xmark", tip: "取消 (Esc)", tint: .white, action: .cancel))
        } else {
            // 留出左侧 106pt 绘制动态计时器
            x = 114
            list.append(iconSlot(x: &x, y: y, symbol: "cursorarrow.click.2", tip: hudTip, tint: interactionHUDEnabled ? .systemCyan : .white, active: interactionHUDEnabled, action: .toggleInteractionHUD))
            let pauseSym = isPaused ? "play.fill" : "pause.fill"
            let pauseTip = isPaused ? "继续录制 (Space)" : "暂停录制 (Space)"
            list.append(iconSlot(x: &x, y: y, symbol: pauseSym, tip: pauseTip, tint: isPaused ? .systemYellow : .white, action: .togglePause))
            list.append(iconSlot(x: &x, y: y, symbol: "square.and.arrow.down", tip: "结束并另存为 \(format.badgeTitle)…", tint: .white, action: .finishSave))
            list.append(iconSlot(x: &x, y: y, symbol: "xmark", tip: "放弃录制 (Esc)", tint: .systemRed, action: .cancel))
            let okRect = CGRect(x: x, y: y, width: 34, height: h)
            x += 37
            list.append(HitSlot(rect: okRect, tip: "完成并复制 \(format.badgeTitle) 到剪贴板 (↩)", action: .finishCopy) { ctx, rect, hov in
                let p = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
                ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(hov ? 1.0 : 0.88).cgColor)
                ctx.addPath(p)
                ctx.fillPath()
                ToolbarView.drawSymbol("checkmark", in: rect, alpha: 1.0, tint: .white)
            })
        }

        slots = list
        setFrameSize(NSSize(width: x + 6, height: Self.barHeight))
        needsDisplay = true
    }

    private func iconSlot(x: inout CGFloat, y: CGFloat, symbol: String, tip: String, tint: NSColor, active: Bool = false, action: Action) -> HitSlot {
        let r = CGRect(x: x, y: y, width: 28, height: 30)
        x += 31
        return HitSlot(rect: r, tip: tip, action: action) { ctx, rect, hov in
            ToolbarView.drawButtonBg(ctx: ctx, rect: rect, active: active, hovered: hov)
            ToolbarView.drawSymbol(symbol, in: rect, alpha: 0.95, tint: tint)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let bg = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 9, cornerHeight: 9, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(NSColor(calibratedWhite: 0.11, alpha: 0.93).cgColor)
        ctx.addPath(bg)
        ctx.fillPath()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(bg)
        ctx.strokePath()
        ctx.restoreGState()

        if isEncoding {
            Self.drawLabel("正在合成 \(format.badgeTitle) 动图…", in: bounds, color: .systemCyan)
            return
        }

        if isRecording {
            let dot = CGRect(x: 12, y: (Self.barHeight - 8) * 0.5, width: 8, height: 8)
            ctx.setFillColor((isPaused ? NSColor.systemYellow : NSColor.systemRed).cgColor)
            ctx.fillEllipse(in: dot)

            let mins = Int(elapsedSeconds) / 60
            let secs = Int(elapsedSeconds) % 60
            let txt = String(format: "%02d:%02d · %@", mins, secs, format.badgeTitle)
            Self.drawLabel(txt, in: CGRect(x: 24, y: 0, width: 84, height: Self.barHeight), color: .white, alignLeft: true)

            ctx.setFillColor(NSColor.white.withAlphaComponent(0.16).cgColor)
            ctx.fill(CGRect(x: 109, y: 10, width: 1, height: Self.barHeight - 20))
        }

        for (i, s) in slots.enumerated() {
            s.draw(ctx, s.rect, hoveredIdx == i)
        }
    }

    private static func drawLabel(_ text: String, in rect: CGRect, color: NSColor, alignLeft: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: color
        ]
        let ns = text as NSString
        let sz = ns.size(withAttributes: attrs)
        let x = alignLeft ? rect.minX : rect.minX + (rect.width - sz.width) * 0.5
        ns.draw(at: CGPoint(x: x, y: rect.minY + (rect.height - sz.height) * 0.5), withAttributes: attrs)
    }
}
