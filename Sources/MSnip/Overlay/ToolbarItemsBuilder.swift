import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 紧凑单行主工具栏组装扩展（分组工具带 `▾` 二级样式弹出指示，复刻参考图清爽白底工具条布局）
extension ToolbarView {
    func rebuildItems() {
        var list: [HitItem] = []
        var x: CGFloat = isPinEditorMode ? 8 : (Self.gripWidth + 4)
        let h: CGFloat = 28
        let y: CGFloat = (Self.barHeight - h) * 0.5

        if isRecordingMode && !isPinEditorMode {
            buildRecordingSetupItems(x: &x, y: y, h: h, into: &list)
            items = list
            let totalW = x + 6
            if abs(frame.width - totalW) > 0.5 { setFrameSize(NSSize(width: totalW, height: Self.barHeight)) }
            return
        }

        // 1) 6 组精简核心标注工具（形状▾ / 画笔▾ / 箭头 / 文字▾ / 序号① / 打码▾）
        let shapeActive = (activeTool == .rect || activeTool == .ellipse)
        let curShape = shapeActive ? activeTool! : lastShapeTool
        list.append(groupedToolItem(
            x: &x, y: y, h: h,
            symbol: curShape.sfSymbolName,
            hasChevron: true,
            active: shapeActive,
            tip: "形状：矩形 (R) / 椭圆 (⇧R)",
            targetTool: shapeActive ? nil : curShape
        ))

        let brushActive = (activeTool == .pen || activeTool == .highlighter || activeTool == .line)
        let curBrush = brushActive ? activeTool! : lastBrushTool
        let brushSym = (curBrush == .pen) ? "pencil" : curBrush.sfSymbolName
        list.append(groupedToolItem(
            x: &x, y: y, h: h,
            symbol: brushSym,
            hasChevron: true,
            active: brushActive,
            tip: "画笔 (D) / 荧光笔 (⇧D) / 直线 (4)",
            targetTool: brushActive ? nil : curBrush
        ))

        let arrowActive = (activeTool == .arrow)
        list.append(groupedToolItem(
            x: &x, y: y, h: h,
            symbol: ToolKind.arrow.sfSymbolName,
            hasChevron: true,
            active: arrowActive,
            tip: "箭头指示 (A)",
            targetTool: arrowActive ? nil : .arrow
        ))

        let textActive = (activeTool == .text)
        list.append(groupedToolItem(
            x: &x, y: y, h: h,
            symbol: "character",
            hasChevron: true,
            active: textActive,
            tip: "文字标注 (W · 按 K 切胶囊底色)",
            targetTool: textActive ? nil : .text
        ))

        let stepActive = (activeTool == .step)
        let clampedStep = min(50, max(1, nextStepNumber))
        let stepSym = NSImage(systemSymbolName: "\(clampedStep).circle", accessibilityDescription: nil) != nil
            ? "\(clampedStep).circle"
            : "1.circle"
        list.append(groupedToolItem(
            x: &x, y: y, h: h,
            symbol: stepSym,
            hasChevron: false,
            active: stepActive,
            tip: "步骤序号 ①②③ (N · 拖拽可拉出箭头)",
            targetTool: stepActive ? nil : .step
        ))

        let redactActive = (activeTool == .mosaic || activeTool == .gaussianBlur)
        let curRedact = redactActive ? activeTool! : lastRedactTool
        list.append(groupedToolItem(
            x: &x, y: y, h: h,
            symbol: curRedact.sfSymbolName,
            hasChevron: true,
            active: redactActive,
            tip: "马赛克 (M) / 高斯毛玻璃 (⇧M)",
            targetTool: redactActive ? nil : curRedact
        ))

        x = appendDivider(at: x, into: &list)

        // 2) 撤销 / 重做
        list.append(iconAction(x: &x, y: y, h: h, symbol: "arrow.uturn.backward", tip: "撤销 (⌘Z)", enabled: canUndo, action: .undo))
        list.append(iconAction(x: &x, y: y, h: h, symbol: "arrow.uturn.forward", tip: "重做 (⌘⇧Z)", enabled: canRedo, action: .redo))

        x = appendDivider(at: x, into: &list)

        if isPinEditorMode {
            list.append(iconAction(x: &x, y: y, h: h, symbol: "xmark", tip: "放弃修改 (Esc)", enabled: true, tint: MSnipUITheme.danger, action: .cancel))
            list.append(primaryConfirmItem(x: &x, y: y, h: h, label: "完成", tip: "更新贴图 (↩)"))
        } else {
            // 3) 页面内交互与多模态功能键（长截图 / 录视频 / 页内实况识字 / 页内翻译）
            list.append(iconAction(x: &x, y: y, h: h, symbol: "scissors", tip: "滚动长截图 (L)", enabled: true, action: .startLongShot))
            list.append(iconAction(x: &x, y: y, h: h, symbol: "video", tip: "选区录制 GIF / MP4 视频 (V)", enabled: true, action: .startRecording))
            list.append(iconAction(
                x: &x, y: y, h: h,
                symbol: "text.viewfinder",
                tip: inPlaceOCRActive
                    ? "正在页内实况识字：可直接划词复制（再次点击返回标注 · ⌥+点击打开双栏对照窗）"
                    : "在当前选区内直接识别并划选文字 (T · ⌥+点击打开双栏对照窗)",
                enabled: true,
                active: inPlaceOCRActive,
                tint: inPlaceOCRActive ? Self.accentBlue : Self.inkDark,
                action: .toggleInPlaceOCR
            ))
            list.append(iconAction(
                x: &x, y: y, h: h,
                symbol: "character.bubble",
                tip: inPlaceTranslateActive
                    ? "正在页内原位翻译：可按住画面对比原图，按 ↩ 复制翻译图（再次点击还原 · ⌥+点击打开双栏流式翻译窗）"
                    : "截图翻译：原位替换译文 (Y · ⌥+点击打开双栏流式对照翻译窗)",
                enabled: true,
                active: inPlaceTranslateActive,
                tint: inPlaceTranslateActive ? Self.accentBlue : Self.inkDark,
                action: .toggleInPlaceTranslate
            ))

            x = appendDivider(at: x, into: &list)

            // 4) 终态输出组：贴图 / 保存 / 关闭 / 醒目蓝色复制主胶囊
            list.append(iconAction(x: &x, y: y, h: h, symbol: "pin", tip: "贴到桌面 (P / \(pinHint))", enabled: true, action: .pin))
            let saveRect = CGRect(x: x, y: y, width: 34, height: h)
            x += 36
            list.append(HitItem(
                rect: saveRect,
                tooltip: "下载保存：点击快速选择目录（S 一键快存 · ⌘S 另存为）",
                enabled: true,
                draw: { ctx, r, hov in
                    Self.drawButtonBg(ctx: ctx, rect: r, active: false, hovered: hov)
                    Self.drawSymbol("square.and.arrow.down", in: CGRect(x: r.minX + 1, y: r.minY, width: 23, height: r.height), alpha: 0.94, tint: Self.inkDark)
                    Self.drawSmallChevron(ctx: ctx, x: r.maxX - 6.0, centerY: r.midY + 0.5, active: hov)
                },
                action: .save
            ))
            list.append(iconAction(x: &x, y: y, h: h, symbol: "xmark", tip: "退出截图 (Q / Esc / 右键)", enabled: true, tint: MSnipUITheme.inkSecondary, action: .cancel))
            list.append(primaryConfirmItem(x: &x, y: y, h: h, label: "复制", tip: "复制到剪贴板 (C / ↩ / 双击选区)"))
        }

        items = list
        let totalW = x + 6
        if abs(frame.width - totalW) > 0.5 {
            setFrameSize(NSSize(width: totalW, height: Self.barHeight))
        }
    }

    private func buildRecordingSetupItems(x: inout CGFloat, y: CGFloat, h: CGFloat, into list: inout [HitItem]) {
        for fmt in RecordingFormat.allCases {
            let active = (recordingFormat == fmt)
            let rect = CGRect(x: x, y: y, width: 44, height: h)
            x += 46
            list.append(HitItem(rect: rect, tooltip: "录屏输出格式：\(fmt.badgeTitle)", enabled: true, draw: { ctx, r, hov in
                Self.drawButtonBg(ctx: ctx, rect: r, active: active, hovered: hov)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: active ? Self.accentBlue : MSnipUITheme.inkSecondary
                ]
                let ns = fmt.badgeTitle as NSString; let sz = ns.size(withAttributes: attrs)
                ns.draw(at: CGPoint(x: round(r.midX - sz.width * 0.5), y: round(r.midY - sz.height * 0.5)), withAttributes: attrs)
            }, action: .selectRecordingFormat(fmt)))
        }
        let hudTip = recordingHUDEnabled
            ? "已开启：录屏显示点击波纹与按键提示（点击关闭）"
            : "已关闭：点击开启录屏点击波纹与按键提示"
        list.append(iconAction(
            x: &x, y: y, h: h, symbol: "cursorarrow.click.2", tip: hudTip, enabled: true,
            active: recordingHUDEnabled, tint: recordingHUDEnabled ? Self.accentBlue : Self.inkDark, action: .toggleRecordingHUD
        ))
        x = appendDivider(at: x, into: &list)
        list.append(iconAction(x: &x, y: y, h: h, symbol: "camera.viewfinder", tip: "切回截图工具栏 (V)", enabled: true, tint: Self.inkDark, action: .exitRecordingMode))
        list.append(iconAction(x: &x, y: y, h: h, symbol: "xmark", tip: "退出录屏 (Q / Esc)", enabled: true, tint: MSnipUITheme.inkSecondary, action: .cancel))
        let recRect = CGRect(x: x + 2, y: y, width: 94, height: h)
        x += 98
        list.append(HitItem(rect: recRect, tooltip: "开始录制当前选区 (↩ / 双击选区)", enabled: true, draw: { ctx, r, hov in
            MSnipUITheme.drawPrimaryCTA(ctx: ctx, rect: r, radius: 7.0, color: MSnipUITheme.danger, hovered: hov)
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white]
            let ns = "开始录制" as NSString; let sz = ns.size(withAttributes: attrs)
            let pairW = 7.0 + 6.0 + ceil(sz.width)
            let sx = round(r.midX - pairW * 0.5)
            MSnipUITheme.drawStatusDot(ctx: ctx, center: CGPoint(x: sx + 3.5, y: r.midY), color: .white, halo: false)
            ns.draw(at: CGPoint(x: sx + 13, y: round(r.midY - sz.height * 0.5 - 0.5)), withAttributes: attrs)
        }, action: .confirmBeginRecording))
    }

    private func groupedToolItem(
        x: inout CGFloat,
        y: CGFloat,
        h: CGFloat,
        symbol: String,
        hasChevron: Bool,
        active: Bool,
        tip: String,
        targetTool: ToolKind?
    ) -> HitItem {
        let w: CGFloat = hasChevron ? 35 : 28
        let rect = CGRect(x: x, y: y, width: w, height: h)
        x += w + 2
        return HitItem(
            rect: rect,
            tooltip: tip,
            enabled: true,
            draw: { ctx, r, hov in
                Self.drawButtonBg(ctx: ctx, rect: r, active: active, hovered: hov)
                let iconRect = hasChevron ? CGRect(x: r.minX + 1, y: r.minY, width: 24, height: r.height) : r
                let tint = active ? Self.accentBlue : Self.inkDark
                Self.drawSymbol(symbol, in: iconRect, alpha: 0.94, tint: tint)
                if hasChevron {
                    Self.drawSmallChevron(ctx: ctx, x: r.maxX - 6.5, centerY: r.midY + 0.5, active: active)
                }
            },
            action: .selectTool(targetTool)
        )
    }

    func appendDivider(at x: CGFloat, into list: inout [HitItem]) -> CGFloat {
        let divRect = CGRect(x: x + 3, y: 9, width: 1, height: Self.barHeight - 18)
        list.append(HitItem(
            rect: divRect,
            tooltip: "",
            enabled: false,
            draw: { ctx, r, _ in
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.10).cgColor)
                ctx.fill(r)
            },
            action: .cancel
        ))
        return x + 8
    }

    func iconAction(
        x: inout CGFloat,
        y: CGFloat,
        h: CGFloat,
        symbol: String,
        tip: String,
        enabled: Bool,
        active: Bool = false,
        tint: NSColor = ToolbarView.inkDark,
        prominent: Bool = false,
        action: Action
    ) -> HitItem {
        let w: CGFloat = prominent ? 32 : 28
        let rect = CGRect(x: x, y: y, width: w, height: h)
        x += w + 2
        return HitItem(
            rect: rect,
            tooltip: tip,
            enabled: enabled,
            draw: { ctx, r, hov in
                Self.drawButtonBg(ctx: ctx, rect: r, active: active || prominent, hovered: hov && enabled)
                Self.drawSymbol(symbol, in: r, alpha: enabled ? 0.94 : 0.30, tint: tint)
            },
            action: action
        )
    }

    private func primaryConfirmItem(
        x: inout CGFloat,
        y: CGFloat,
        h: CGFloat,
        label: String,
        tip: String
    ) -> HitItem {
        let w: CGFloat = 58
        let rect = CGRect(x: x + 2, y: y, width: w, height: h)
        x += w + 4
        return HitItem(
            rect: rect,
            tooltip: tip,
            enabled: true,
            draw: { ctx, r, hov in
                MSnipUITheme.drawPrimaryCTA(ctx: ctx, rect: r, radius: 6.5, hovered: hov)
                let iconRect = CGRect(x: r.minX + 6, y: r.minY, width: 15, height: r.height)
                Self.drawSymbol("checkmark", in: iconRect, alpha: 1.0, tint: .white)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.white
                ]
                let ns = label as NSString
                let sz = ns.size(withAttributes: attrs)
                ns.draw(
                    at: CGPoint(x: round(iconRect.maxX + 2), y: round(r.minY + (r.height - sz.height) * 0.5)),
                    withAttributes: attrs
                )
            },
            action: .confirmCopy
        )
    }
}
