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
        let shapeActive = (activeTool == .rect || activeTool == .ellipse || activeTool == .spotlight)
        let curShape = shapeActive ? activeTool! : lastShapeTool
        list.append(groupedToolItem(
            x: &x, y: y, h: h,
            symbol: curShape.sfSymbolName,
            hasChevron: true,
            active: shapeActive,
            tip: "形状：矩形 (\(keyUpper(.rect))) / 椭圆 (⇧\(keyUpper(.rect))) / 聚光灯高亮",
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
            tip: "画笔 (\(keyUpper(.pen))) / 荧光笔 (⇧\(keyUpper(.pen))) / 直线 (4)",
            targetTool: brushActive ? nil : curBrush
        ))

        let arrowActive = (activeTool == .arrow)
        list.append(groupedToolItem(
            x: &x, y: y, h: h,
            symbol: ToolKind.arrow.sfSymbolName,
            hasChevron: true,
            active: arrowActive,
            tip: "箭头指示 (\(keyUpper(.arrow)))",
            targetTool: arrowActive ? nil : .arrow
        ))

        let textActive = (activeTool == .text)
        list.append(groupedToolItem(
            x: &x, y: y, h: h,
            symbol: "character",
            hasChevron: true,
            active: textActive,
            tip: "文字标注 (\(keyUpper(.text)) · 按 \(keyUpper(.textCapsule)) 切胶囊底色)",
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
            tip: "步骤序号 ①②③ (\(keyUpper(.step)) · 拖拽可拉出箭头)",
            targetTool: stepActive ? nil : .step
        ))

        let redactActive = (activeTool == .mosaic || activeTool == .gaussianBlur)
        let curRedact = redactActive ? activeTool! : lastRedactTool
        list.append(groupedToolItem(
            x: &x, y: y, h: h,
            symbol: curRedact.sfSymbolName,
            hasChevron: true,
            active: redactActive,
            tip: "马赛克 (\(keyUpper(.mosaic))) / 高斯毛玻璃 (⇧\(keyUpper(.mosaic)))",
            targetTool: redactActive ? nil : curRedact
        ))

        let eraserActive = (activeTool == .eraser)
        list.append(groupedToolItem(
            x: &x, y: y, h: h,
            symbol: "eraser",
            hasChevron: false,
            active: eraserActive,
            tip: "橡皮擦：点击或涂抹擦除标注 (\(keyUpper(.eraser)))",
            targetTool: eraserActive ? nil : .eraser
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
            list.append(iconAction(x: &x, y: y, h: h, symbol: "scissors", tip: "滚动长截图 (\(keyUpper(.longShot)))", enabled: true, action: .startLongShot))
            list.append(iconAction(x: &x, y: y, h: h, symbol: "video", tip: "选区录制 GIF / MP4 视频 (\(keyUpper(.record)))", enabled: true, action: .startRecording))
            let ocrTip: String = switch (inPlaceOCRActive, ocrPresentation) {
            case (true, _):           "正在页内实况识字：可直接划词复制（再次点击返回标注 · ⌥+点击打开双栏面板）"
            case (false, .inPlace):   "提取文字：在当前选区内直接划选文字 (\(keyUpper(.ocr)) · ⌥+点击打开双栏面板)"
            case (false, .dualPane):  "提取文字：直接打开双栏对照面板 (\(keyUpper(.ocr)) · ⌥+点击页内划词)"
            case (false, .silentCopy): "提取文字：直接关闭截图并静默识别复制 (\(keyUpper(.ocr)) · ⌥+点击打开双栏面板)"
            }
            list.append(iconAction(
                x: &x, y: y, h: h,
                symbol: "text.viewfinder",
                tip: ocrTip,
                enabled: true,
                active: inPlaceOCRActive,
                tint: inPlaceOCRActive ? Self.accentBlue : Self.inkDark,
                action: .toggleInPlaceOCR
            ))
            list.append(iconAction(
                x: &x, y: y, h: h,
                symbol: "function",
                tip: "识别 LaTeX 数学公式与实时预览 (⇧\(keyUpper(.ocr)))",
                enabled: true,
                tint: Self.inkDark,
                action: .recognizeLatex
            ))
            let trTip: String = inPlaceTranslateActive
                ? "正在页内原位翻译：按住画面对比原图，按 ↩ 复制翻译图（再次点击还原 · ⌥+点击打开双栏面板）"
                : (translateAutoOpenDualPane
                    ? "截图翻译：直接打开双栏流式翻译面板 (\(keyUpper(.translate)) · ⌥+点击原位译文)"
                    : "截图翻译：原位替换译文 (\(keyUpper(.translate)) · ⌥+点击打开双栏流式面板)")
            list.append(iconAction(
                x: &x, y: y, h: h,
                symbol: "character.bubble",
                tip: trTip,
                enabled: true,
                active: inPlaceTranslateActive,
                tint: inPlaceTranslateActive ? Self.accentBlue : Self.inkDark,
                action: .toggleInPlaceTranslate
            ))

            x = appendDivider(at: x, into: &list)

            // 4) 终态输出组：贴图 / 保存 / 关闭 / 醒目蓝色复制主胶囊
            let pinTip = pinHint.isEmpty ? "贴到桌面 (\(keyUpper(.pin)))" : "贴到桌面 (\(keyUpper(.pin)) / \(pinHint))"
            list.append(iconAction(x: &x, y: y, h: h, symbol: "pin", tip: pinTip, enabled: true, action: .pin))
            let saveIconRect = CGRect(x: x, y: y, width: 26, height: h)
            x += 26
            list.append(HitItem(
                rect: saveIconRect,
                tooltip: "一键保存到默认目录 (\(keyUpper(.quickSave)) · ⌘S 另存为)",
                enabled: true,
                draw: { ctx, r, hov in
                    Self.drawButtonBg(ctx: ctx, rect: r, active: false, hovered: hov)
                    Self.drawSymbol("square.and.arrow.down", in: r, alpha: 0.94, tint: Self.inkDark)
                },
                action: .quickSave
            ))
            let saveMenuRect = CGRect(x: x, y: y, width: 14, height: h)
            x += 16
            list.append(HitItem(
                rect: saveMenuRect,
                tooltip: "选择其他保存目录 / 另存为 (⌘S)",
                enabled: true,
                draw: { ctx, r, hov in
                    Self.drawButtonBg(ctx: ctx, rect: r, active: false, hovered: hov)
                    Self.drawSmallChevron(ctx: ctx, x: r.midX, centerY: r.midY + 0.5, active: hov)
                },
                action: .save
            ))
            list.append(iconAction(x: &x, y: y, h: h, symbol: "xmark", tip: "退出截图 (\(keyUpper(.cancel)) / Esc / 右键)", enabled: true, tint: MSnipUITheme.inkSecondary, action: .cancel))
            list.append(primaryConfirmItem(x: &x, y: y, h: h, label: "复制", tip: "复制到剪贴板 (\(keyUpper(.copy)) / ↩ / 双击选区)"))
        }

        items = list
        let totalW = x + 6
        if abs(frame.width - totalW) > 0.5 {
            setFrameSize(NSSize(width: totalW, height: Self.barHeight))
        }
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

// MARK: - 二级属性工具栏视图

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

    override var isHidden: Bool {
        didSet { if isHidden { clearHover() } }
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(atLocalPoint: convert(event.locationInWindow, from: nil))
    }

    func updateHover(atLocalPoint p: CGPoint) {
        guard !isDraggingSlider else { return }
        let onSlider = sliderHitRect.contains(p)
        let idx = onSlider ? nil : slots.firstIndex(where: { $0.rect.contains(p) })
        if onSlider || idx != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        if hoveredSlider != onSlider || idx != hoveredIndex {
            hoveredSlider = onSlider
            hoveredIndex = idx
            needsDisplay = true
        }
        if onSlider {
            FloatingTooltipHUD.show("拖动进度条调节大小（方向键 ↑↓←→ 或滚轮也可快速调大缩小）", anchorRectInView: sliderHitRect, of: self)
        } else if let i = idx, slots.indices.contains(i) {
            FloatingTooltipHUD.show(slots[i].tip, anchorRectInView: slots[i].rect, of: self)
        } else {
            FloatingTooltipHUD.hide(for: self)
        }
    }

    func clearHover() {
        FloatingTooltipHUD.hide(for: self)
        if hoveredIndex != nil || hoveredSlider {
            hoveredIndex = nil; hoveredSlider = false; needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) { clearHover() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { clearHover() }
    }

    override func mouseDown(with event: NSEvent) {
        FloatingTooltipHUD.hide(for: self)
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
                case .rect, .ellipse, .spotlight:
                    return [(.rect, "rectangle", "矩形框 (R)"), (.ellipse, "circle", "椭圆圈记 (⇧R)"), (.spotlight, "light.max", "聚光灯高亮（框内清晰、框外柔和压暗）")]
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

        // 马赛克/毛玻璃/橡皮擦/聚光灯无需选颜色；马赛克/毛玻璃右侧提供「一键隐码」，橡皮擦右侧提供「清空」
        let usesColor = (activeTool != .mosaic && activeTool != .gaussianBlur && activeTool != .eraser && activeTool != .spotlight)
        if activeTool == .mosaic || activeTool == .gaussianBlur {
            x = addSeparator(at: x)
            let redRect = CGRect(x: x, y: y, width: 78, height: h); x += 80
            list.append(Slot(rect: redRect, tip: "一键智能隐私打码：自动识别并遮盖 API Key、邮箱、手机号、身份证与 IP", action: .autoRedact) { ctx, rect, hov in
                ToolbarView.drawButtonBg(ctx: ctx, rect: rect, active: false, hovered: hov)
                ToolbarView.drawSymbol("eye.slash", in: CGRect(x: rect.minX + 4, y: rect.minY, width: 16, height: rect.height), alpha: 0.92, tint: ToolbarView.accentBlue)
                let s = "一键隐码" as NSString
                let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: ToolbarView.accentBlue]
                let sz = s.size(withAttributes: a)
                s.draw(at: CGPoint(x: round(rect.minX + 23), y: round(rect.midY - sz.height * 0.5 - 0.5)), withAttributes: a)
            })
        } else if activeTool == .eraser {
            x = addSeparator(at: x)
            let clrRect = CGRect(x: x, y: y, width: 66, height: h)
            x += 68
            list.append(Slot(rect: clrRect, tip: "清空当前全部标注（可用 ⌘Z 撤销）", action: .clearAnnotations) { ctx, rect, hov in
                ToolbarView.drawButtonBg(ctx: ctx, rect: rect, active: false, hovered: hov)
                ToolbarView.drawSymbol("trash", in: CGRect(x: rect.minX + 4, y: rect.minY, width: 16, height: rect.height), alpha: 0.9, tint: MSnipUITheme.danger)
                let s = "清空" as NSString
                let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: MSnipUITheme.danger]
                let sz = s.size(withAttributes: a)
                s.draw(at: CGPoint(x: round(rect.minX + 24), y: round(rect.midY - sz.height * 0.5 - 0.5)), withAttributes: a)
            })
        } else if usesColor {
            x = addSeparator(at: x)
            for (idx, color) in RGBAColor.presets.enumerated() {
                let sel = (customColor == nil && colorIndex == idx)
                let r = CGRect(x: x, y: y, width: 20, height: h); x += 20
                list.append(Slot(rect: r, tip: "切换标注颜色", action: .selectColor(idx)) { ctx, rect, hov in
                    let side: CGFloat = sel ? 14 : (hov ? 13 : 11.5)
                    let sw = CGRect(x: rect.midX - side * 0.5, y: rect.midY - side * 0.5, width: side, height: side)
                    ctx.setFillColor(color.cgColor); ctx.fillEllipse(in: sw)
                    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.22).cgColor); ctx.setLineWidth(1.0); ctx.strokeEllipse(in: sw)
                    if sel { ctx.setStrokeColor(ToolbarView.accentBlue.cgColor); ctx.setLineWidth(1.8); ctx.strokeEllipse(in: sw.insetBy(dx: -2.2, dy: -2.2)) }
                })
            }
            if !isPinEditorMode {
                let pr = CGRect(x: x + 2, y: y, width: 26, height: h); x += 29
                let pickerOn = eyedropperActive; let picked = customColor
                list.append(Slot(rect: pr, tip: "屏幕取色吸管 (I / ⌥+点击)", action: .toggleEyedropper) { ctx, rect, hov in
                    ToolbarView.drawEyedropperItem(ctx: ctx, rect: rect, active: pickerOn, customColor: picked, hovered: hov)
                })
            }
        }
        slots = list; setFrameSize(NSSize(width: x + 6, height: Self.subHeight)); needsDisplay = true
    }

    private func addSeparator(at x: CGFloat) -> CGFloat { sepXs.append(x + 3); return x + 8 }

    private func formattedSizeReadout() -> String {
        switch activeTool {
        case .text: return "\(Int(min(64.0, max(12.0, round(10.0 + lineWidth * 3.0)))))"
        case .mosaic, .gaussianBlur, .eraser: return "\(Int(min(36.0, max(6.0, round(4.0 + lineWidth * 1.8)))))"
        default: return "\(Int(lineWidth.rounded()))"
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
