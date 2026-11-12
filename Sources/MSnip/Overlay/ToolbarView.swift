import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 截图选区下方的原生毛玻璃深色悬浮工具栏（含标注、吸管取色、圆角截图、识字提取与导出动作）
final class ToolbarView: NSView {
    enum Action {
        case selectTool(ToolKind?)
        case selectColor(Int)
        case toggleEyedropper
        case selectStroke(CGFloat)
        case undo
        case redo
        case cycleCornerRadius
        case extractText
        case pin
        case save
        case cancel
        case confirmCopy
    }

    var onAction: ((Action) -> Void)?

    var activeTool: ToolKind? { didSet { needsDisplay = true } }
    var colorIndex: Int = 0 { didSet { needsDisplay = true } }
    var customColor: RGBAColor? { didSet { needsDisplay = true } }
    var eyedropperActive: Bool = false { didSet { needsDisplay = true } }
    var lineWidth: CGFloat = 3.0 { didSet { needsDisplay = true } }
    var cornerRadiusPt: CGFloat = 0 { didSet { needsDisplay = true } }
    var canUndo: Bool = false { didSet { needsDisplay = true } }
    var canRedo: Bool = false { didSet { needsDisplay = true } }
    var pinHint: String = "⌘2" { didSet { needsDisplay = true } }

    private struct HitItem {
        let rect: CGRect
        let tooltip: String
        let enabled: Bool
        let draw: (CGContext, CGRect, Bool) -> Void
        let action: Action
    }

    private var items: [HitItem] = []
    private var hoveredIndex: Int?

    override var isFlipped: Bool { true }

    static let barHeight: CGFloat = 42
    static let barWidth: CGFloat = 744

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.barWidth, height: Self.barHeight))
        rebuildItems()
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

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    func refreshState() {
        rebuildItems()
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = items.firstIndex(where: { $0.rect.contains(p) && $0.enabled })
        if idx != hoveredIndex {
            hoveredIndex = idx
            toolTip = idx.map { items[$0].tooltip }
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let item = items.first(where: { $0.rect.contains(p) && $0.enabled }) {
            onAction?(item.action)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        rebuildItems()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let bgRect = bounds.insetBy(dx: 1, dy: 1)
        let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 9, cornerHeight: 9, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(NSColor(calibratedWhite: 0.12, alpha: 0.92).cgColor)
        ctx.addPath(bgPath)
        ctx.fillPath()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(bgPath)
        ctx.strokePath()
        ctx.restoreGState()

        for (i, item) in items.enumerated() {
            item.draw(ctx, item.rect, hoveredIndex == i)
        }
    }

    // MARK: - Layout & Item Builders

    private func rebuildItems() {
        var list: [HitItem] = []
        var x: CGFloat = 8
        let h: CGFloat = 30
        let y: CGFloat = (Self.barHeight - h) * 0.5

        // 1) 7 个标注工具按钮
        for tool in ToolKind.allCases {
            let isSelected = (activeTool == tool)
            let rect = CGRect(x: x, y: y, width: 29, height: h)
            list.append(HitItem(
                rect: rect,
                tooltip: tool.title,
                enabled: true,
                draw: { ctx, r, hov in
                    Self.drawButtonBg(ctx: ctx, rect: r, active: isSelected, hovered: hov)
                    Self.drawSymbol(tool.sfSymbolName, in: r, alpha: 0.95)
                },
                action: .selectTool(isSelected ? nil : tool)
            ))
            x += 31
        }

        x = appendDivider(at: x, into: &list)

        // 2) 3 档线宽圆点
        for stroke in AnnotationStyle.strokePresets {
            let isSelected = abs(lineWidth - stroke) < 1.0
            let rect = CGRect(x: x, y: y, width: 21, height: h)
            let dotR = max(2.2, min(6.0, stroke * 0.9))
            list.append(HitItem(
                rect: rect,
                tooltip: "粗细 \(Int(stroke))pt（可滚轮微调）",
                enabled: true,
                draw: { ctx, r, hov in
                    Self.drawButtonBg(ctx: ctx, rect: r, active: isSelected, hovered: hov)
                    let dot = CGRect(x: r.midX - dotR, y: r.midY - dotR, width: dotR * 2, height: dotR * 2)
                    ctx.setFillColor(NSColor.white.withAlphaComponent(isSelected ? 1.0 : 0.65).cgColor)
                    ctx.fillEllipse(in: dot)
                },
                action: .selectStroke(stroke)
            ))
            x += 22
        }

        x = appendDivider(at: x, into: &list)

        // 3) 6 个高对比度色块 + 吸管屏幕取色按钮
        for (idx, color) in RGBAColor.presets.enumerated() {
            let isSelected = (customColor == nil && colorIndex == idx)
            let rect = CGRect(x: x, y: y, width: 21, height: h)
            list.append(HitItem(
                rect: rect,
                tooltip: "标注颜色",
                enabled: true,
                draw: { ctx, r, hov in
                    let side: CGFloat = isSelected ? 15 : (hov ? 14 : 12)
                    let swatch = CGRect(x: r.midX - side * 0.5, y: r.midY - side * 0.5, width: side, height: side)
                    ctx.setFillColor(color.cgColor)
                    ctx.fillEllipse(in: swatch)
                    if isSelected {
                        ctx.setStrokeColor(NSColor.white.cgColor)
                        ctx.setLineWidth(2.0)
                        ctx.strokeEllipse(in: swatch.insetBy(dx: -2, dy: -2))
                    }
                },
                action: .selectColor(idx)
            ))
            x += 21
        }

        let pickerRect = CGRect(x: x + 2, y: y, width: 28, height: h)
        let isPickerActive = eyedropperActive
        let pickedColor = customColor
        list.append(HitItem(
            rect: pickerRect,
            tooltip: "吸取屏幕颜色用于标注 (I / ⌥+点击)",
            enabled: true,
            draw: { ctx, r, hov in
                Self.drawEyedropperItem(ctx: ctx, rect: r, active: isPickerActive, customColor: pickedColor, hovered: hov)
            },
            action: .toggleEyedropper
        ))
        x += 31

        x = appendDivider(at: x, into: &list)

        // 4) 撤销 / 重做
        list.append(iconAction(x: &x, y: y, symbol: "arrow.uturn.backward", tip: "撤销 (⌘Z)", enabled: canUndo, action: .undo))
        list.append(iconAction(x: &x, y: y, symbol: "arrow.uturn.forward", tip: "重做 (⌘⇧Z)", enabled: canRedo, action: .redo))

        x = appendDivider(at: x, into: &list)

        // 5) PixPin 快捷增强动作：圆角截图 / 识字与二维码提取
        let hasCorner = cornerRadiusPt > 0.5
        let cornerTip = hasCorner ? "圆角截图：\(Int(cornerRadiusPt))pt (B 切换)" : "圆角截图 (B)"
        list.append(iconAction(x: &x, y: y, symbol: "rectangle.roundedtop", tip: cornerTip, enabled: true, active: hasCorner, action: .cycleCornerRadius))
        list.append(iconAction(x: &x, y: y, symbol: "text.viewfinder", tip: "识别文字 / 二维码并复制 (T)", enabled: true, action: .extractText))

        x = appendDivider(at: x, into: &list)

        // 6) 输出动作组：贴图 / 保存 / 取消 / 完成复制
        list.append(iconAction(x: &x, y: y, symbol: "pin", tip: "贴到屏幕 (\(pinHint))", enabled: true, action: .pin))
        list.append(iconAction(x: &x, y: y, symbol: "square.and.arrow.down", tip: "保存 PNG (⌘S)", enabled: true, action: .save))
        list.append(iconAction(x: &x, y: y, symbol: "xmark", tip: "取消截图 (Esc)", enabled: true, tint: .systemRed, action: .cancel))
        list.append(iconAction(x: &x, y: y, symbol: "checkmark", tip: "复制到剪贴板 (↩ / 双击)", enabled: true, tint: .systemGreen, prominent: true, action: .confirmCopy))

        items = list
        let totalW = x + 6
        if abs(frame.width - totalW) > 0.5 {
            setFrameSize(NSSize(width: totalW, height: Self.barHeight))
        }
    }

    private func appendDivider(at x: CGFloat, into list: inout [HitItem]) -> CGFloat {
        let divRect = CGRect(x: x + 3, y: 10, width: 1, height: Self.barHeight - 20)
        list.append(HitItem(
            rect: divRect,
            tooltip: "",
            enabled: false,
            draw: { ctx, r, _ in
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.16).cgColor)
                ctx.fill(r)
            },
            action: .cancel
        ))
        return x + 8
    }

    private func iconAction(
        x: inout CGFloat,
        y: CGFloat,
        symbol: String,
        tip: String,
        enabled: Bool,
        active: Bool = false,
        tint: NSColor = .white,
        prominent: Bool = false,
        action: Action
    ) -> HitItem {
        let w: CGFloat = prominent ? 34 : 28
        let rect = CGRect(x: x, y: y, width: w, height: 30)
        x += w + 3
        return HitItem(
            rect: rect,
            tooltip: tip,
            enabled: enabled,
            draw: { ctx, r, hov in
                if prominent {
                    let bg = CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil)
                    ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(hov ? 1.0 : 0.88).cgColor)
                    ctx.addPath(bg)
                    ctx.fillPath()
                    Self.drawSymbol(symbol, in: r, alpha: 1.0, tint: .white)
                } else {
                    Self.drawButtonBg(ctx: ctx, rect: r, active: active, hovered: hov && enabled)
                    Self.drawSymbol(symbol, in: r, alpha: enabled ? 0.95 : 0.3, tint: tint)
                }
            },
            action: action
        )
    }
}
