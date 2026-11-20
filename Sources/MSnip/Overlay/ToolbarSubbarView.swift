import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 二级标注样式悬浮子栏：承载「子形态切换 + 连续可拖拽大小进度条（支持方向键/滚轮同步）+ 预设颜色 + 吸管」
final class ToolbarSubbarView: NSView {
    var onAction: ((ToolbarView.Action) -> Void)?

    var activeTool: ToolKind? { didSet { if oldValue != activeTool { refresh() } } }
    var lineWidth: CGFloat = 3.0 {
        didSet {
            let clamped = min(Self.maxStroke, max(Self.minStroke, lineWidth))
            if abs(lineWidth - clamped) > 0.001 { lineWidth = clamped }
            if abs(oldValue - lineWidth) > 0.001 { needsDisplay = true }
        }
    }
    var colorIndex: Int = 0 { didSet { if oldValue != colorIndex { refresh() } } }
    var customColor: RGBAColor? { didSet { if oldValue != customColor { refresh() } } }
    var eyedropperActive: Bool = false { didSet { if oldValue != eyedropperActive { refresh() } } }
    var textCapsule: Bool = false { didSet { if oldValue != textCapsule { refresh() } } }
    var isPinEditorMode: Bool = false { didSet { if oldValue != isPinEditorMode { refresh() } } }

    static let minStroke: CGFloat = 1.0
    static let maxStroke: CGFloat = 18.0
    static let subHeight: CGFloat = 34

    private struct Slot {
        let rect: CGRect
        let tip: String
        let action: ToolbarView.Action
        let draw: (CGContext, CGRect, Bool) -> Void
    }

    private var slots: [Slot] = []
    private var sepXs: [CGFloat] = []
    private var sliderHitRect: CGRect = .zero
    private var sliderTrackMinX: CGFloat = 0
    private var sliderTrackMaxX: CGFloat = 0
    private var sliderLabelX: CGFloat = 0
    private var hoveredIndex: Int?
    private var hoveredSlider = false { didSet { if oldValue != hoveredSlider { needsDisplay = true } } }
    private var isDraggingSlider = false { didSet { if oldValue != isDraggingSlider { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: Self.subHeight))
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 7
        layer?.shadowOffset = CGSize(width: 0, height: 2)
        refresh()
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

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let onSlider = sliderHitRect.contains(p)
        let idx = onSlider ? nil : slots.firstIndex(where: { $0.rect.contains(p) })
        if onSlider || idx != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        hoveredSlider = onSlider
        if idx != hoveredIndex {
            hoveredIndex = idx
            needsDisplay = true
        }
        if onSlider {
            toolTip = "拖动进度条调节大小（方向键 ↑↓←→ 或滚轮也可快速调大缩小）"
        } else {
            toolTip = idx.map { slots[$0].tip }
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        hoveredSlider = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if sliderHitRect.contains(p) {
            isDraggingSlider = true
            updateStroke(atX: p.x)
            return
        }
        if let hit = slots.first(where: { $0.rect.contains(p) }) {
            onAction?(hit.action)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingSlider else { return }
        let p = convert(event.locationInWindow, from: nil)
        updateStroke(atX: p.x)
    }

    override func mouseUp(with event: NSEvent) {
        isDraggingSlider = false
    }

    override func scrollWheel(with event: NSEvent) {
        let delta: CGFloat = event.scrollingDeltaY > 0 ? 1.0 : (event.scrollingDeltaY < 0 ? -1.0 : 0)
        guard abs(delta) > 0.01 else { return }
        let next = min(Self.maxStroke, max(Self.minStroke, (lineWidth + delta).rounded()))
        lineWidth = next
        onAction?(.selectStroke(next))
    }

    private func updateStroke(atX x: CGFloat) {
        let span = max(1, sliderTrackMaxX - sliderTrackMinX)
        let t = min(1.0, max(0.0, (x - sliderTrackMinX) / span))
        let raw = Self.minStroke + t * (Self.maxStroke - Self.minStroke)
        let snapped = raw.rounded()
        if abs(snapped - lineWidth) > 0.01 {
            lineWidth = snapped
            onAction?(.selectStroke(snapped))
        } else {
            needsDisplay = true
        }
    }

    func refresh() {
        sepXs.removeAll()
        var list: [Slot] = []
        var x: CGFloat = 8
        let h: CGFloat = 24
        let y: CGFloat = (Self.subHeight - h) * 0.5

        // 1) 同组工具二级子形态切换（形状组 / 画笔组 / 打码组 / 文字胶囊开关）
        if let tool = activeTool {
            let variants: [(ToolKind, String, String)] = {
                switch tool {
                case .rect, .ellipse:
                    return [(.rect, "rectangle", "矩形框 (R)"), (.ellipse, "circle", "椭圆圈记 (⇧R)")]
                case .pen, .highlighter, .line:
                    return [(.pen, "pencil", "自由画笔 (D)"), (.highlighter, "highlighter", "荧光马克笔 (⇧D)"), (.line, "line.diagonal", "直线 (4)")]
                case .mosaic, .gaussianBlur:
                    return [(.mosaic, "checkerboard.rectangle", "像素马赛克 (M)"), (.gaussianBlur, "drop.circle", "高斯毛玻璃 (⇧M)")]
                default:
                    return []
                }
            }()

            for (vTool, sym, tip) in variants {
                let sel = (tool == vTool)
                let r = CGRect(x: x, y: y, width: 26, height: h)
                x += 28
                list.append(Slot(rect: r, tip: tip, action: .selectTool(vTool)) { ctx, rect, hov in
                    ToolbarView.drawButtonBg(ctx: ctx, rect: rect, active: sel, hovered: hov)
                    ToolbarView.drawSymbol(sym, in: rect, alpha: 0.94, tint: sel ? ToolbarView.accentBlue : ToolbarView.inkDark)
                })
            }

            if tool == .text {
                let capOn = textCapsule
                let r = CGRect(x: x, y: y, width: 62, height: h)
                x += 64
                list.append(Slot(rect: r, tip: "切换圆角胶囊底色标签 (K / ⌘B)", action: .toggleTextCapsule) { ctx, rect, hov in
                    ToolbarView.drawButtonBg(ctx: ctx, rect: rect, active: capOn, hovered: hov)
                    let str = "胶囊底" as NSString
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                        .foregroundColor: capOn ? ToolbarView.accentBlue : ToolbarView.inkDark
                    ]
                    let sz = str.size(withAttributes: attrs)
                    str.draw(at: CGPoint(x: round(rect.midX - sz.width * 0.5), y: round(rect.midY - sz.height * 0.5)), withAttributes: attrs)
                })
            }

            if !variants.isEmpty || tool == .text {
                x = addSeparator(at: x)
            }
        }

        // 2) 小 / 中 / 大 3 档快选圆点 + 紧邻连续大小进度条（点击/拖拽/方向键/滚轮全联动）
        let quickSizes: [(CGFloat, CGFloat, String)] = [(2.0, 2.3, "小号 (2)"), (5.0, 3.8, "中号 (5)"), (10.0, 5.4, "大号 (10)")]
        for (presetW, dotR, tip) in quickSizes {
            let r = CGRect(x: x, y: y, width: 20, height: h)
            x += 20
            list.append(Slot(rect: r, tip: tip, action: .selectStroke(presetW)) { [weak self] ctx, rect, hov in
                let curW = self?.lineWidth ?? 3.0
                let sel = abs(curW - presetW) < 0.6
                ToolbarView.drawButtonBg(ctx: ctx, rect: rect, active: sel, hovered: hov)
                let col = sel ? ToolbarView.accentBlue : ToolbarView.inkDark.withAlphaComponent(0.65)
                ctx.setFillColor(col.cgColor)
                ctx.fillEllipse(in: CGRect(x: rect.midX - dotR, y: rect.midY - dotR, width: dotR * 2, height: dotR * 2))
            })
        }
        x += 4
        let sliderW: CGFloat = 108
        sliderHitRect = CGRect(x: x, y: 2, width: sliderW, height: Self.subHeight - 4)
        sliderTrackMinX = x + 6
        sliderTrackMaxX = x + 76
        sliderLabelX = x + 84
        x += sliderW

        // 马赛克/毛玻璃无需选颜色，隐藏右侧色板令子栏更精简
        let usesColor = (activeTool != .mosaic && activeTool != .gaussianBlur)
        if usesColor {
            x = addSeparator(at: x)
            for (idx, color) in RGBAColor.presets.enumerated() {
                let sel = (customColor == nil && colorIndex == idx)
                let r = CGRect(x: x, y: y, width: 20, height: h)
                x += 20
                list.append(Slot(rect: r, tip: "切换标注颜色", action: .selectColor(idx)) { ctx, rect, hov in
                    let side: CGFloat = sel ? 14 : (hov ? 13 : 11.5)
                    let sw = CGRect(x: rect.midX - side * 0.5, y: rect.midY - side * 0.5, width: side, height: side)
                    ctx.setFillColor(color.cgColor)
                    ctx.fillEllipse(in: sw)
                    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.22).cgColor)
                    ctx.setLineWidth(1.0)
                    ctx.strokeEllipse(in: sw)
                    if sel {
                        ctx.setStrokeColor(ToolbarView.accentBlue.cgColor)
                        ctx.setLineWidth(1.8)
                        ctx.strokeEllipse(in: sw.insetBy(dx: -2.2, dy: -2.2))
                    }
                })
            }

            if !isPinEditorMode {
                let pr = CGRect(x: x + 2, y: y, width: 26, height: h)
                x += 29
                let pickerOn = eyedropperActive
                let picked = customColor
                list.append(Slot(rect: pr, tip: "屏幕取色吸管 (I / ⌥+点击)", action: .toggleEyedropper) { ctx, rect, hov in
                    ToolbarView.drawEyedropperItem(ctx: ctx, rect: rect, active: pickerOn, customColor: picked, hovered: hov)
                })
            }
        }

        slots = list
        setFrameSize(NSSize(width: x + 6, height: Self.subHeight))
        needsDisplay = true
    }

    private func addSeparator(at x: CGFloat) -> CGFloat {
        sepXs.append(x + 3)
        return x + 8
    }

    private func formattedSizeReadout() -> String {
        switch activeTool {
        case .text:
            return "\(Int(min(64.0, max(12.0, round(10.0 + lineWidth * 3.0)))))"
        case .mosaic, .gaussianBlur:
            return "\(Int(min(36.0, max(5.0, round(4.0 + lineWidth * 1.8)))))"
        default:
            return "\(Int(lineWidth.rounded()))"
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        MSnipUITheme.drawPorcelainBar(ctx: ctx, bounds: bounds, radius: 8.5)
        ctx.saveGState()
        ctx.setFillColor(MSnipUITheme.borderHairline.cgColor)
        for sx in sepXs {
            ctx.fill(CGRect(x: sx, y: 8, width: 1, height: Self.subHeight - 16))
        }
        ctx.restoreGState()

        for (i, s) in slots.enumerated() {
            s.draw(ctx, s.rect, hoveredIndex == i)
        }
        drawSizeSlider(in: ctx)
    }

    private func drawSizeSlider(in ctx: CGContext) {
        let ratio = min(1.0, max(0.0, (lineWidth - Self.minStroke) / (Self.maxStroke - Self.minStroke)))
        ToolbarView.drawSubbarSizeSlider(
            ctx: ctx, boundsH: bounds.height,
            trackMinX: sliderTrackMinX, trackMaxX: sliderTrackMaxX, labelX: sliderLabelX,
            ratio: ratio, readout: formattedSizeReadout(), highlighted: isDraggingSlider || hoveredSlider
        )
    }
}
