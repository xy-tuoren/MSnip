import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 选区动图/视频录制的商业级磨砂白底悬浮控制条（倒计时、录制中、封装中均保持同心圆角与精确像素对齐）
final class RecordingControlBarView: NSView {
    enum Action {
        case selectFormat(RecordingFormat)
        case toggleInteractionHUD
        case toggleDrawing
        case clearDrawings
        case startRecording
        case togglePause
        case finishTrim
        case finishSave
        case finishSaveAs
        case finishCopy
        case cancel
    }

    static let barHeight: CGFloat = 44
    static let shadowPad: CGFloat = 12
    private static let outerPad: CGFloat = 7
    private static let btnH: CGFloat = 30
    private static let btnRadius: CGFloat = 7.5
    private static let coral = NSColor(srgbRed: 0.93, green: 0.21, blue: 0.31, alpha: 1.0)

    var onAction: ((Action) -> Void)?
    var format: RecordingFormat = .gif { didSet { refreshLayout() } }
    var interactionHUDEnabled: Bool = true { didSet { refreshLayout() } }
    var isDrawingActive: Bool = false { didSet { refreshLayout() } }
    var countdownNumber: Int? { didSet { refreshLayout() } }
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
    private var dividerX: CGFloat?
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: Self.barHeight + Self.shadowPad * 2))
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
        if next != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
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
        guard let s = slots.first(where: { $0.rect.contains(p) }) else { return }
        if case .finishSave = s.action, event.modifierFlags.contains(.option) { onAction?(.finishSaveAs) }
        else if case .toggleDrawing = s.action, event.modifierFlags.contains(.option) { onAction?(.clearDrawings) }
        else { onAction?(s.action) }
    }

    func refreshLayout() {
        var list: [HitSlot] = []
        let pad = Self.shadowPad
        let y = pad + Self.outerPad
        let h = Self.btnH
        dividerX = nil

        if isEncoding {
            setFrameSize(NSSize(width: 224 + pad * 2, height: Self.barHeight + pad * 2))
            slots = []
            needsDisplay = true
            return
        }

        let hudTip = interactionHUDEnabled
            ? "已开启：录屏显示鼠标点击波纹与快捷键角标（点击关闭）"
            : "已关闭：点击开启录屏鼠标波纹与快捷键角标回显"
        let tagW = Self.formatTagWidth(for: format.badgeTitle)
        var x: CGFloat = pad + Self.outerPad

        if countdownNumber != nil {
            let lblW = ceil(("即将录屏" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold)]).width)
            let divX = round(pad + 12 + 22 + 8 + lblW + 7 + tagW + 10)
            dividerX = divX
            x = divX + 11
            let nowRect = CGRect(x: x, y: y, width: 94, height: h)
            list.append(HitSlot(rect: nowRect, tip: "跳过倒计时立即开始录制 (↩)", action: .startRecording) { ctx, rect, hov in
                MSnipUITheme.drawPrimaryCTA(ctx: ctx, rect: rect, radius: Self.btnRadius, color: MSnipUITheme.danger, hovered: hov)
                Self.drawIconAndLabel(symbol: "play.fill", symPt: 9.5, text: "立即开始", in: rect, color: .white)
            })
            x += 94 + 6
            list.append(iconSlot(x: &x, y: y, symbol: "xmark", tip: "取消录制 (Esc)", tint: MSnipUITheme.inkSecondary, filledBg: true, action: .cancel))
        } else if !isRecording {
            for fmt in RecordingFormat.allCases {
                let active = (format == fmt)
                let r = CGRect(x: x, y: y, width: 46, height: h)
                list.append(HitSlot(rect: r, tip: "切换为 \(fmt.badgeTitle) 格式", action: .selectFormat(fmt)) { ctx, rect, hov in
                    ToolbarView.drawButtonBg(ctx: ctx, rect: rect, active: active, hovered: hov)
                    Self.drawOpticalLabel(fmt.badgeTitle, in: rect, font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), color: active ? MSnipUITheme.accent : MSnipUITheme.inkSecondary)
                })
                x += 48
            }
            list.append(iconSlot(x: &x, y: y, symbol: "cursorarrow.click.2", tip: hudTip, tint: interactionHUDEnabled ? MSnipUITheme.accent : MSnipUITheme.inkPrimary, active: interactionHUDEnabled, action: .toggleInteractionHUD))
            x += 4
            let recRect = CGRect(x: x, y: y, width: 96, height: h)
            list.append(HitSlot(rect: recRect, tip: "开始录制选区画面 (↩)", action: .startRecording) { ctx, rect, hov in
                MSnipUITheme.drawPrimaryCTA(ctx: ctx, rect: rect, radius: Self.btnRadius, color: MSnipUITheme.danger, hovered: hov)
                Self.drawDotAndLabel(text: "开始录制", in: rect, color: .white)
            })
            x += 96 + 6
            list.append(iconSlot(x: &x, y: y, symbol: "xmark", tip: "取消 (Esc)", tint: MSnipUITheme.inkSecondary, filledBg: true, action: .cancel))
        } else {
            let timerW = ceil(("00:00" as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)]).width)
            let divX = round(pad + 12 + 12 + 7 + timerW + 7 + tagW + 10)
            dividerX = divX
            x = divX + 10
            list.append(iconSlot(x: &x, y: y, symbol: "cursorarrow.click.2", tip: hudTip, tint: interactionHUDEnabled ? MSnipUITheme.accent : MSnipUITheme.inkPrimary, active: interactionHUDEnabled, action: .toggleInteractionHUD))
            let drawTip = isDrawingActive ? "画笔标记中（默认激光渐隐，按住 ⇧ 常驻，右键或 ⌥+点此清屏）" : "开启录屏实时画笔标记（按住 ⌥ 点此清屏）"
            list.append(iconSlot(x: &x, y: y, symbol: "pencil.tip.crop.circle", tip: drawTip, tint: isDrawingActive ? MSnipUITheme.danger : MSnipUITheme.inkPrimary, active: isDrawingActive, action: .toggleDrawing))
            let pauseSym = isPaused ? "play.fill" : "pause.fill"
            let pauseTip = isPaused ? "继续录制 (Space)" : "暂停录制 (Space)"
            list.append(iconSlot(x: &x, y: y, symbol: pauseSym, tip: pauseTip, tint: isPaused ? MSnipUITheme.warning : MSnipUITheme.inkPrimary, action: .togglePause))
            if format == .mp4 {
                list.append(iconSlot(x: &x, y: y, symbol: "scissors", tip: "结束录制并打开首尾裁剪预览 (MP4)", tint: MSnipUITheme.inkPrimary, action: .finishTrim))
            }
            list.append(iconSlot(x: &x, y: y, symbol: "square.and.arrow.down", tip: "结束并保存 \(format.badgeTitle) 到默认目录（按住 ⌥ 另存为）", tint: MSnipUITheme.inkPrimary, action: .finishSave))
            list.append(iconSlot(x: &x, y: y, symbol: "xmark", tip: "放弃录制 (Esc)", tint: MSnipUITheme.danger, action: .cancel))
            x += 2
            let okRect = CGRect(x: x, y: y, width: 68, height: h)
            list.append(HitSlot(rect: okRect, tip: "完成并复制 \(format.badgeTitle) 到剪贴板 (↩)", action: .finishCopy) { ctx, rect, hov in
                MSnipUITheme.drawPrimaryCTA(ctx: ctx, rect: rect, radius: Self.btnRadius, hovered: hov)
                Self.drawIconAndLabel(symbol: "checkmark", symPt: 10.5, text: "完成", in: rect, color: .white)
            })
            x += 68
        }

        slots = list
        let rightEdge = list.last?.rect.maxX ?? x
        setFrameSize(NSSize(width: round(rightEdge + Self.outerPad + pad), height: Self.barHeight + pad * 2))
        needsDisplay = true
    }

    private func iconSlot(x: inout CGFloat, y: CGFloat, symbol: String, tip: String, tint: NSColor, active: Bool = false, filledBg: Bool = false, action: Action) -> HitSlot {
        let r = CGRect(x: x, y: y, width: Self.btnH, height: Self.btnH)
        x += Self.btnH + 4
        return HitSlot(rect: r, tip: tip, action: action) { ctx, rect, hov in
            if filledBg && !hov && !active {
                let p = CGPath(roundedRect: rect, cornerWidth: Self.btnRadius, cornerHeight: Self.btnRadius, transform: nil)
                ctx.setFillColor(MSnipUITheme.subtleFill.cgColor)
                ctx.addPath(p); ctx.fillPath()
            } else {
                ToolbarView.drawButtonBg(ctx: ctx, rect: rect, active: active, hovered: hov)
            }
            ToolbarView.drawSymbol(symbol, in: rect, alpha: 0.95, tint: tint)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let pad = Self.shadowPad
        let barRect = bounds.insetBy(dx: pad, dy: pad)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: NSColor.black.withAlphaComponent(0.20).cgColor)
        ctx.setFillColor(MSnipUITheme.cardBg.cgColor)
        ctx.addPath(CGPath(roundedRect: barRect, cornerWidth: 12.0, cornerHeight: 12.0, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
        MSnipUITheme.drawPorcelainBar(ctx: ctx, bounds: barRect, radius: 12.0)

        if isEncoding {
            Self.drawOpticalLabel("正在封装 \(format.badgeTitle)…", in: barRect, font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), color: MSnipUITheme.accent)
            return
        }

        if let cd = countdownNumber {
            let chipSize: CGFloat = 22
            let chipRect = CGRect(x: pad + 12, y: round(barRect.midY - chipSize * 0.5), width: chipSize, height: chipSize)
            ctx.setFillColor(Self.coral.withAlphaComponent(0.14).cgColor)
            ctx.fillEllipse(in: chipRect)
            ctx.setStrokeColor(Self.coral.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(1.25)
            ctx.strokeEllipse(in: chipRect.insetBy(dx: 0.75, dy: 0.75))
            Self.drawOpticalLabel("\(cd)", in: chipRect, font: NSFont.monospacedDigitSystemFont(ofSize: 12.0, weight: .bold), color: Self.coral, yBias: 0)

            let lblFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
            let lblW = ceil(("即将录屏" as NSString).size(withAttributes: [.font: lblFont]).width)
            let lblRect = CGRect(x: chipRect.maxX + 8, y: barRect.minY, width: lblW, height: barRect.height)
            Self.drawOpticalLabel("即将录屏", in: lblRect, font: lblFont, color: MSnipUITheme.inkPrimary)
            Self.drawFormatTag(format.badgeTitle, atX: lblRect.maxX + 7, midY: barRect.midY, in: ctx)
        } else if isRecording {
            MSnipUITheme.drawStatusDot(ctx: ctx, center: CGPoint(x: pad + 18, y: barRect.midY), color: isPaused ? MSnipUITheme.warning : MSnipUITheme.danger, halo: true)
            let txt = String(format: "%02d:%02d", Int(elapsedSeconds) / 60, Int(elapsedSeconds) % 60)
            let tFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
            let tW = ceil((txt as NSString).size(withAttributes: [.font: tFont]).width)
            let tRect = CGRect(x: pad + 31, y: barRect.minY, width: tW, height: barRect.height)
            Self.drawOpticalLabel(txt, in: tRect, font: tFont, color: MSnipUITheme.inkPrimary, yBias: 0)
            Self.drawFormatTag(format.badgeTitle, atX: tRect.maxX + 7, midY: barRect.midY, in: ctx)
        }

        if let dx = dividerX {
            ctx.setFillColor(MSnipUITheme.borderHairline.cgColor)
            ctx.fill(CGRect(x: dx, y: round(barRect.midY - 10), width: 1, height: 20))
        }

        for (i, s) in slots.enumerated() {
            s.draw(ctx, s.rect, hoveredIdx == i)
        }
    }

    private static func formatTagWidth(for badge: String) -> CGFloat {
        let f = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .bold)
        return ceil((badge as NSString).size(withAttributes: [.font: f]).width + 12)
    }

    private static func drawFormatTag(_ badge: String, atX x: CGFloat, midY: CGFloat, in ctx: CGContext) {
        let w = formatTagWidth(for: badge)
        let r = CGRect(x: round(x), y: round(midY - 9.5), width: w, height: 19)
        let p = CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.setFillColor(MSnipUITheme.subtleFill.cgColor); ctx.addPath(p); ctx.fillPath()
        ctx.setStrokeColor(MSnipUITheme.borderHairline.cgColor); ctx.setLineWidth(1.0); ctx.addPath(p); ctx.strokePath()
        drawOpticalLabel(badge, in: r, font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .bold), color: MSnipUITheme.inkSecondary, yBias: 0)
    }

    private static func drawIconAndLabel(symbol: String, symPt: CGFloat, text: String, in rect: CGRect, color: NSColor) {
        let font = NSFont.systemFont(ofSize: 12.0, weight: .semibold)
        let sz = (text as NSString).size(withAttributes: [.font: font])
        let iconW: CGFloat = 11, gap: CGFloat = 5
        let sx = round(rect.midX - (iconW + gap + ceil(sz.width)) * 0.5)
        if let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let img = base.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: symPt, weight: .bold)) ?? base
            let isz = img.size
            let tinted = NSImage(size: isz, flipped: false) { b in img.draw(in: b); color.setFill(); b.fill(using: .sourceAtop); return true }
            let dst = CGRect(x: round(sx + (iconW - isz.width) * 0.5), y: round(rect.midY - isz.height * 0.5), width: isz.width, height: isz.height)
            tinted.draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
        }
        drawOpticalLabel(text, in: CGRect(x: sx + iconW + gap, y: rect.minY, width: ceil(sz.width), height: rect.height), font: font, color: color)
    }

    private static func drawDotAndLabel(text: String, in rect: CGRect, color: NSColor) {
        let font = NSFont.systemFont(ofSize: 12.0, weight: .semibold)
        let sz = (text as NSString).size(withAttributes: [.font: font])
        let sx = round(rect.midX - (7 + 6 + ceil(sz.width)) * 0.5)
        MSnipUITheme.drawStatusDot(ctx: NSGraphicsContext.current!.cgContext, center: CGPoint(x: sx + 3.5, y: rect.midY), color: color, halo: false)
        drawOpticalLabel(text, in: CGRect(x: sx + 13, y: rect.minY, width: ceil(sz.width), height: rect.height), font: font, color: color)
    }

    private static func drawOpticalLabel(_ text: String, in rect: CGRect, font: NSFont, color: NSColor, yBias: CGFloat = -0.5) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let ns = text as NSString
        let sz = ns.size(withAttributes: attrs)
        ns.draw(at: CGPoint(x: round(rect.midX - sz.width * 0.5), y: round(rect.midY - sz.height * 0.5 + yBias)), withAttributes: attrs)
    }
}
