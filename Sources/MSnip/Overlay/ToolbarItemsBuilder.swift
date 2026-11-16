import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 悬浮工具栏按钮项组装与自适应宽度计算扩展
extension ToolbarView {
    func rebuildItems() {
        var list: [HitItem] = []
        var x: CGFloat = 8
        let h: CGFloat = 30
        let y: CGFloat = (Self.barHeight - h) * 0.5

        // 1) 10 个圈记/荧光/步骤序号/打码/模糊/文字工具按钮
        for tool in ToolKind.allCases {
            let isSelected = (activeTool == tool)
            let rect = CGRect(x: x, y: y, width: 28, height: h)
            let symbolName: String
            if tool == .step {
                let clamped = min(50, max(1, nextStepNumber))
                let dynamicName = "\(clamped).circle.fill"
                symbolName = NSImage(systemSymbolName: dynamicName, accessibilityDescription: nil) != nil
                    ? dynamicName
                    : tool.sfSymbolName
            } else {
                symbolName = tool.sfSymbolName
            }
            list.append(HitItem(
                rect: rect,
                tooltip: tool.title,
                enabled: true,
                draw: { ctx, r, hov in
                    Self.drawButtonBg(ctx: ctx, rect: r, active: isSelected, hovered: hov)
                    Self.drawSymbol(symbolName, in: r, alpha: 0.95)
                },
                action: .selectTool(isSelected ? nil : tool)
            ))
            x += 30
        }

        // 文字工具激活时，紧随其后展示「胶囊底色文字」一键开关
        let capTip = textCapsule
            ? "已启用：圆角胶囊底色文字标签 (K / ⌘B 切回纯字)"
            : "开启圆角胶囊底色文字标签 (K / ⌘B)"
        list.append(iconAction(
            x: &x, y: y,
            symbol: "character.textbox",
            tip: capTip,
            enabled: true,
            active: textCapsule,
            tint: textCapsule ? .white : NSColor(white: 0.88, alpha: 1),
            action: .toggleTextCapsule
        ))

        x = appendDivider(at: x, into: &list)

        // 2) 3 档线宽圆点
        for stroke in AnnotationStyle.strokePresets {
            let isSelected = abs(lineWidth - stroke) < 1.0
            let rect = CGRect(x: x, y: y, width: 20, height: h)
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
            x += 21
        }

        x = appendDivider(at: x, into: &list)

        // 3) 6 个高对比度色块 + 吸管屏幕取色按钮（非贴图内联编辑时显示吸管）
        for (idx, color) in RGBAColor.presets.enumerated() {
            let isSelected = (customColor == nil && colorIndex == idx)
            let rect = CGRect(x: x, y: y, width: 20, height: h)
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
            x += 20
        }

        if !isPinEditorMode {
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
        }

        x = appendDivider(at: x, into: &list)

        // 4) 撤销 / 重做
        list.append(iconAction(x: &x, y: y, symbol: "arrow.uturn.backward", tip: "撤销 (⌘Z)", enabled: canUndo, action: .undo))
        list.append(iconAction(x: &x, y: y, symbol: "arrow.uturn.forward", tip: "重做 (⌘⇧Z)", enabled: canRedo, action: .redo))

        x = appendDivider(at: x, into: &list)

        if isPinEditorMode {
            list.append(iconAction(x: &x, y: y, symbol: "xmark", tip: "放弃本次修改 (Esc)", enabled: true, tint: .systemRed, action: .cancel))
            list.append(iconAction(x: &x, y: y, symbol: "checkmark", tip: "完成并更新贴图 (↩)", enabled: true, tint: .systemGreen, prominent: true, action: .confirmCopy))
        } else {
            // 5) 快捷增强动作：圆角截图 / 美化渐变衬底 / 识字提取 / 滚动长截图 / 录制 GIF·MP4
            let hasCorner = cornerRadiusPt > 0.5
            let cornerTip = hasCorner ? "圆角截图：\(Int(cornerRadiusPt))pt (B 切换)" : "圆角截图 (B)"
            list.append(iconAction(x: &x, y: y, symbol: "rectangle.roundedtop", tip: cornerTip, enabled: true, active: hasCorner, action: .cycleCornerRadius))

            let hasBackdrop = backdropStyle != .none
            let bdTip = hasBackdrop ? "美观背景衬底：\(backdropStyle.title) (P 切换)" : "美观背景衬底：圆角+阴影+渐变留白 (P)"
            list.append(iconAction(x: &x, y: y, symbol: "sparkles.rectangle.stack", tip: bdTip, enabled: true, active: hasBackdrop, action: .cycleBackdrop))

            list.append(iconAction(x: &x, y: y, symbol: "macwindow", tip: "独立窗口纯净透明阴影截图 (F / ⇧↩ 复制 · ⌥⇧↩ 贴图)", enabled: true, action: .captureWindow))
            list.append(iconAction(x: &x, y: y, symbol: "text.viewfinder", tip: "识别文字 / 二维码并复制 (T)", enabled: true, action: .extractText))
            list.append(iconAction(x: &x, y: y, symbol: "arrow.up.and.down.square", tip: "滚动长截图 (L)", enabled: true, action: .startLongShot))
            list.append(iconAction(x: &x, y: y, symbol: "record.circle", tip: "选区录制 GIF / MP4 动图 (V)", enabled: true, tint: .systemRed, action: .startRecording))

            x = appendDivider(at: x, into: &list)

            // 6) 输出动作组：贴图 / 保存 / 取消 / 完成复制
            list.append(iconAction(x: &x, y: y, symbol: "pin", tip: "贴到屏幕 (\(pinHint))", enabled: true, action: .pin))
            list.append(iconAction(x: &x, y: y, symbol: "square.and.arrow.down", tip: "保存 PNG（⌘S 另存… · ⌘⇧S 或 ⌥+点击 一键快存）", enabled: true, action: .save))
            list.append(iconAction(x: &x, y: y, symbol: "xmark", tip: "取消截图 (Esc)", enabled: true, tint: .systemRed, action: .cancel))
            list.append(iconAction(x: &x, y: y, symbol: "checkmark", tip: "复制到剪贴板 (↩ / 双击)", enabled: true, tint: .systemGreen, prominent: true, action: .confirmCopy))
        }

        items = list
        let totalW = x + 6
        if abs(frame.width - totalW) > 0.5 {
            setFrameSize(NSSize(width: totalW, height: Self.barHeight))
        }
    }

    func appendDivider(at x: CGFloat, into list: inout [HitItem]) -> CGFloat {
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

    func iconAction(
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
