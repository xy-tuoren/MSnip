import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 二级标注样式悬浮子栏：仅当激活任意标注工具或选中已有标注时弹出，承载「子形态切换 + 粗细 + 预设颜色 + 吸管」
final class ToolbarSubbarView: NSView {
    var onAction: ((ToolbarView.Action) -> Void)?

    var activeTool: ToolKind? { didSet { if oldValue != activeTool { refresh() } } }
    var lineWidth: CGFloat = 3.0 { didSet { if oldValue != lineWidth { refresh() } } }
    var colorIndex: Int = 0 { didSet { if oldValue != colorIndex { refresh() } } }
    var customColor: RGBAColor? { didSet { if oldValue != customColor { refresh() } } }
    var eyedropperActive: Bool = false { didSet { if oldValue != eyedropperActive { refresh() } } }
    var textCapsule: Bool = false { didSet { if oldValue != textCapsule { refresh() } } }
    var isPinEditorMode: Bool = false { didSet { if oldValue != isPinEditorMode { refresh() } } }

    private struct Slot {
        let rect: CGRect
        let tip: String
        let action: ToolbarView.Action
        let draw: (CGContext, CGRect, Bool) -> Void
    }

    private var slots: [Slot] = []
    private var hoveredIndex: Int?

    override var isFlipped: Bool { true }
    static let subHeight: CGFloat = 34

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: Self.subHeight))
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
        let idx = slots.firstIndex(where: { $0.rect.contains(p) })
        if idx != hoveredIndex {
            hoveredIndex = idx
            toolTip = idx.map { slots[$0].tip }
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = slots.first(where: { $0.rect.contains(p) }) {
            onAction?(hit.action)
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
                    return [(.rect, "rectangle", "矩形框 (1)"), (.ellipse, "circle", "椭圆圈记 (2)")]
                case .pen, .highlighter, .line:
                    return [(.pen, "pencil", "自由画笔 (5)"), (.highlighter, "highlighter", "荧光马克笔 (6)"), (.line, "line.diagonal", "直线 (4)")]
                case .mosaic, .gaussianBlur:
                    return [(.mosaic, "checkerboard.rectangle", "方格像素马赛克 (8)"), (.gaussianBlur, "drop.circle", "高斯毛玻璃模糊 (9)")]
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
                let r = CGRect(x: x, y: y, width: 64, height: h)
                x += 66
                list.append(Slot(rect: r, tip: "切换圆角胶囊底色标签 (K / ⌘B)", action: .toggleTextCapsule) { ctx, rect, hov in
                    ToolbarView.drawButtonBg(ctx: ctx, rect: rect, active: capOn, hovered: hov)
                    let str = "胶囊底" as NSString
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                        .foregroundColor: capOn ? ToolbarView.accentBlue : ToolbarView.inkDark
                    ]
                    let sz = str.size(withAttributes: attrs)
                    str.draw(at: CGPoint(x: rect.midX - sz.width * 0.5, y: rect.midY - sz.height * 0.5), withAttributes: attrs)
                })
            }

            if !variants.isEmpty || tool == .text {
                x = addSeparator(at: x)
            }
        }

        // 2) 3 档线宽 / 模糊强度圆点
        for stroke in AnnotationStyle.strokePresets {
            let sel = abs(lineWidth - stroke) < 1.0
            let r = CGRect(x: x, y: y, width: 20, height: h)
            x += 21
            let dotR = max(2.2, min(5.5, stroke * 0.85))
            list.append(Slot(rect: r, tip: "粗细 / 强度（可滚轮微调）", action: .selectStroke(stroke)) { ctx, rect, hov in
                ToolbarView.drawButtonBg(ctx: ctx, rect: rect, active: sel, hovered: hov)
                let dot = CGRect(x: rect.midX - dotR, y: rect.midY - dotR, width: dotR * 2, height: dotR * 2)
                let col = sel ? ToolbarView.accentBlue : ToolbarView.inkDark.withAlphaComponent(0.62)
                ctx.setFillColor(col.cgColor)
                ctx.fillEllipse(in: dot)
            })
        }

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

    private var sepXs: [CGFloat] = []
    private func addSeparator(at x: CGFloat) -> CGFloat {
        sepXs.append(x + 3)
        return x + 8
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let bgRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 7.5, cornerHeight: 7.5, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(NSColor(srgbRed: 0.965, green: 0.968, blue: 0.976, alpha: 0.96).cgColor)
        ctx.addPath(bgPath)
        ctx.fillPath()
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.11).cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(bgPath)
        ctx.strokePath()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.10).cgColor)
        for sx in sepXs {
            ctx.fill(CGRect(x: sx, y: 8, width: 1, height: Self.subHeight - 16))
        }
        ctx.restoreGState()

        for (i, s) in slots.enumerated() {
            s.draw(ctx, s.rect, hoveredIndex == i)
        }
    }
}
