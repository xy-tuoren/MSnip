import AppKit
import CoreGraphics
import Foundation
import MSnipCore
import QuartzCore

/// 独立 120Hz 透明 GPU 图层承载的四向像素卡尺视图（零主画布重绘，@1x / @2x 均像素级锐利）
final class OverlayCaliperLayerView: NSView {
    weak var ownerOverlay: OverlayView?
    var measurement: PixelCaliperResult? { didSet { if oldValue != measurement { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let owner = ownerOverlay,
              let m = measurement else { return }

        let s = max(1.0, owner.snapshot.scaleFactor)
        let cx = (CGFloat(m.originX) + 0.5) / s
        let cy = (CGFloat(m.originY) + 0.5) / s
        let leftX = CGFloat(m.leftPx) / s
        let rightX = CGFloat(m.rightPx + 1) / s
        let topY = CGFloat(m.topPx) / s
        let bottomY = CGFloat(m.bottomPx + 1) / s

        let coral = NSColor(srgbRed: 0.965, green: 0.255, blue: 0.376, alpha: 1.0) // #F64160
        let halo = NSColor.black.withAlphaComponent(0.55)

        // 1) 淡珊瑚色测距区间微提示框（仅四边均命中有效 UI 边界且非整屏时轻柔描出轮廓）
        let rectW = rightX - leftX
        let rectH = bottomY - topY
        if m.hitLeft && m.hitRight && m.hitTop && m.hitBottom,
           rectW >= 4, rectH >= 4,
           rectW < bounds.width * 0.95 || rectH < bounds.height * 0.95 {
            let box = CGRect(x: leftX, y: topY, width: rectW, height: rectH)
            ctx.saveGState()
            ctx.setFillColor(coral.withAlphaComponent(0.06).cgColor)
            ctx.fill(box)
            ctx.setStrokeColor(coral.withAlphaComponent(0.32).cgColor)
            ctx.setLineWidth(1.0)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.stroke(box.insetBy(dx: 0.5, dy: 0.5))
            ctx.restoreGState()
        }

        // 2) 四向 1px 清晰珊瑚红测距射线 + 端帽（双层暗描边保底，亮/暗背景均高对比）
        let capHalf: CGFloat = 4.5
        let drawRays: (CGColor, CGFloat) -> Void = { color, width in
            ctx.saveGState()
            ctx.setStrokeColor(color)
            ctx.setLineWidth(width)
            // 水平射线 + 左右端帽
            ctx.move(to: CGPoint(x: leftX, y: cy)); ctx.addLine(to: CGPoint(x: rightX, y: cy))
            if m.hitLeft {
                ctx.move(to: CGPoint(x: leftX + 0.5, y: cy - capHalf)); ctx.addLine(to: CGPoint(x: leftX + 0.5, y: cy + capHalf))
            }
            if m.hitRight {
                ctx.move(to: CGPoint(x: rightX - 0.5, y: cy - capHalf)); ctx.addLine(to: CGPoint(x: rightX - 0.5, y: cy + capHalf))
            }
            // 垂直射线 + 上下端帽
            ctx.move(to: CGPoint(x: cx, y: topY)); ctx.addLine(to: CGPoint(x: cx, y: bottomY))
            if m.hitTop {
                ctx.move(to: CGPoint(x: cx - capHalf, y: topY + 0.5)); ctx.addLine(to: CGPoint(x: cx + capHalf, y: topY + 0.5))
            }
            if m.hitBottom {
                ctx.move(to: CGPoint(x: cx - capHalf, y: bottomY - 0.5)); ctx.addLine(to: CGPoint(x: cx + capHalf, y: bottomY - 0.5))
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
        drawRays(halo.cgColor, 2.5)
        drawRays(coral.cgColor, 1.2)

        // 3) 水平与垂直像素净距读数胶囊（自动避开十字中心与屏幕边界，零重叠）
        let hText = "\(m.widthPx) px"
        let vText = "\(m.heightPx) px"
        let hSz = Self.measureBadge(hText)
        let vSz = Self.measureBadge(vText)

        // 水平读数放在较宽一侧线段中点上方（避开十字中心与放大镜）
        let leftSegW = cx - leftX
        let rightSegW = rightX - cx
        let hAnchorX: CGFloat = (leftSegW >= rightSegW)
            ? (leftSegW >= hSz.width + 12 ? (leftX + leftSegW * 0.5) : (leftX + rectW * 0.5))
            : (rightSegW >= hSz.width + 12 ? (cx + rightSegW * 0.5) : (leftX + rectW * 0.5))
        let hY = (cy - hSz.height - 6 >= 8) ? (cy - hSz.height - 6) : (cy + 7)
        let hRect = CGRect(
            x: round(min(max(8, hAnchorX - hSz.width * 0.5), bounds.width - hSz.width - 8)),
            y: round(hY),
            width: hSz.width,
            height: hSz.height
        )

        // 垂直读数放在较长一侧线段中点右侧（与水平读数防碰撞）
        let topSegH = cy - topY
        let bottomSegH = bottomY - cy
        let vAnchorY: CGFloat = (topSegH >= bottomSegH)
            ? (topSegH >= vSz.height + 12 ? (topY + topSegH * 0.5) : (topY + rectH * 0.5))
            : (bottomSegH >= vSz.height + 12 ? (cy + bottomSegH * 0.5) : (topY + rectH * 0.5))
        let vX = (cx + 8 + vSz.width <= bounds.width - 8) ? (cx + 8) : (cx - vSz.width - 8)
        var vRect = CGRect(
            x: round(min(max(8, vX), bounds.width - vSz.width - 8)),
            y: round(min(max(8, vAnchorY - vSz.height * 0.5), bounds.height - vSz.height - 8)),
            width: vSz.width,
            height: vSz.height
        )
        if vRect.intersects(hRect.insetBy(dx: -4, dy: -4)) {
            let shiftedY = (cy + 10 + vSz.height <= bounds.height - 8) ? (cy + 10) : max(8, hRect.minY - vSz.height - 6)
            vRect.origin.y = round(shiftedY)
        }

        Self.drawBadge(ctx: ctx, rect: hRect, text: hText, bg: coral)
        Self.drawBadge(ctx: ctx, rect: vRect, text: vText, bg: coral)
    }

    private static let badgeAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11.0, weight: .bold),
        .foregroundColor: NSColor.white
    ]

    private static func measureBadge(_ text: String) -> CGSize {
        let sz = (text as NSString).size(withAttributes: badgeAttrs)
        return CGSize(width: ceil(sz.width + 12), height: 19)
    }

    private static func drawBadge(ctx: CGContext, rect: CGRect, text: String, bg: NSColor) {
        let p = CGPath(roundedRect: rect, cornerWidth: 5.0, cornerHeight: 5.0, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 4, color: NSColor.black.withAlphaComponent(0.32).cgColor)
        ctx.setFillColor(bg.cgColor)
        ctx.addPath(p); ctx.fillPath()
        ctx.restoreGState()

        let ns = text as NSString
        let sz = ns.size(withAttributes: badgeAttrs)
        ns.draw(
            at: CGPoint(x: round(rect.midX - sz.width * 0.5), y: round(rect.midY - sz.height * 0.5)),
            withAttributes: badgeAttrs
        )
    }
}

extension OverlayView {
    /// 同步 120Hz 四向像素卡尺图层状态与实时测距结果
    func syncCaliperView() {
        guard caliperActive, !isDraggingSelectionBox, !isEditingText,
              let sample = samplePixelAtCursor(),
              let res = PixelCaliper.measure(atX: sample.px, y: sample.py, in: snapshot.sampler) else {
            if !caliperView.isHidden { caliperView.isHidden = true }
            caliperView.measurement = nil
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if caliperView.frame != bounds { caliperView.frame = bounds }
        if caliperView.isHidden { caliperView.isHidden = false }
        CATransaction.commit()
        caliperView.measurement = res
    }
}

// MARK: - 画布快捷键提示浮层

/// 独立 GPU 快捷键提示卡布局调度 + 锁定选区描边与手柄绘制扩展（零全屏 `blur: 22` CPU 重绘）
extension OverlayView {
    /// 计算当前屏幕安全内边距（自动避让底部 Dock、侧边 Dock 与顶部菜单栏，并向屏幕内侧舒适内收防贴边）
    private func safeOverlayMargins() -> (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) {
        let sf = snapshot.screen.frame
        let vf = snapshot.screen.visibleFrame
        let dockLeft = max(0, vf.minX - sf.minX)
        let dockRight = max(0, sf.maxX - vf.maxX)
        let menuTop = max(0, sf.maxY - vf.maxY)
        let dockBottom = max(0, vf.minY - sf.minY)
        return (
            left: round(dockLeft + 58),
            right: round(dockRight + 58),
            top: round(menuTop + 44),
            bottom: round(dockBottom + 54)
        )
    }

    private func currentShortcutTipRows() -> [(key: String, desc: String)] {
        if isRecordingMode {
            return selection == nil
                ? [("单击 / 拖拽", "吸附窗口 / 框选录屏区"), ("滚轮 / 方向键", "切窗口层级 / 1px 微调"), (keyUpper(.record), "切换回截图模式"), ("右键 / Esc", "退出录屏")]
                : [("↩ / 双击", "开始 3-2-1 倒计时录屏"), ("方向键", "1px 微调录屏选区"), ("\(keyUpper(.snapWindow)) / \(keyUpper(.eraser))", "对齐窗口 / 上次选区"), (keyUpper(.record), "切换回截图模式"), ("右键 / Esc", "重选录屏区域")]
        }
        if selection == nil {
            return [
                ("\(keyUpper(.copy)) / Tab", "复制色值 / 切格式"),
                ("\(keyUpper(.caliper)) / \(keyUpper(.copyCoord))", "像素测距 / 复制坐标"),
                ("\(keyUpper(.backdropOrCoord)) / \(keyUpper(.toggleMagnifier))", "相对坐标 / 显隐放大镜"),
                ("\(keyUpper(.pin)) / \(keyUpper(.quickSave))", "直接贴图 / 一键快存"),
                ("\(keyUpper(.ocr)) / \(keyUpper(.translate))", "识字 / 原位翻译"),
                ("\(keyUpper(.longShot)) / \(keyUpper(.record))", "长截图 / 录视频"),
                ("\(keyUpper(.eraser)) / \(keyUpper(.snapWindow))", "上次选区 / 对齐窗口"),
                ("滚轮 / 方向键", "切层级 / 1px 微调")
            ]
        }
        let tools = [keyUpper(.rect), keyUpper(.arrow), keyUpper(.pen), keyUpper(.text), keyUpper(.mosaic), keyUpper(.eraser)].joined(separator: " ")
        return [
            ("\(keyUpper(.copy)) / ↩", "复制截图并退出"),
            ("\(keyUpper(.pin)) / \(keyUpper(.quickSave))", "贴图 / 一键快存"),
            (tools, "框 箭 笔 字 马赛克 橡皮"),
            ("↑↓←→ / ⌘Z", "调工具大小 / 撤销"),
            ("\(keyUpper(.ocr)) / ⇧\(keyUpper(.ocr)) / \(keyUpper(.translate))", "识字 / 公式 / 翻译"),
            ("\(keyUpper(.longShot)) / \(keyUpper(.record))", "长截图 / 录制视频"),
            ("右键 / Esc", "取消选框")
        ]
    }

    /// 更新独立 GPU 快捷键提示卡内容与避让位置（内容缓存零重复绘制，光标靠近时仅 GPU 平移坐标）
    func syncShortcutTipsView() {
        guard showShortcutTips, !isEditingText else {
            if !shortcutTipsView.isHidden { shortcutTipsView.isHidden = true }
            cachedTipsTriggerZone = .zero
            return
        }
        if let sel = selection, sel.width > bounds.width * 0.85, sel.height > bounds.height * 0.80 {
            if !shortcutTipsView.isHidden { shortcutTipsView.isHidden = true }
            return
        }

        let hideKey = keyUpper(.toggleTips)
        let sig = "\(isRecordingMode)|\(selection != nil)|\(hideKey)|\(keyUpper(.copy))\(keyUpper(.caliper))\(keyUpper(.copyCoord))\(keyUpper(.backdropOrCoord))\(keyUpper(.toggleMagnifier))\(keyUpper(.pin))\(keyUpper(.quickSave))\(keyUpper(.ocr))\(keyUpper(.translate))\(keyUpper(.longShot))\(keyUpper(.record))\(keyUpper(.eraser))\(keyUpper(.snapWindow))\(keyUpper(.rect))\(keyUpper(.arrow))\(keyUpper(.pen))\(keyUpper(.text))\(keyUpper(.mosaic))"
        let cardSize = shortcutTipsView.updateContentIfNeeded(signature: sig, rows: { currentShortcutTipRows() }, hideKey: hideKey)
        let m = safeOverlayMargins()

        var origin = CGPoint(x: m.left, y: max(m.top, round(bounds.height - m.bottom - cardSize.height)))
        let bottomTrigger = CGRect(origin: origin, size: cardSize).insetBy(dx: -24, dy: -24)
        cachedTipsTriggerZone = bottomTrigger

        let cursorNearBottom = lastMousePoint.map { bottomTrigger.contains($0) } ?? false
        let selNearBottom = selection.map { !$0.intersection(bottomTrigger).isNull } ?? false
        let barNearBottom = (!toolbar.isHidden && !toolbar.frame.intersection(bottomTrigger).isNull)
            || (!subbar.isHidden && !subbar.frame.intersection(bottomTrigger).isNull)
        if cursorNearBottom || selNearBottom || barNearBottom {
            origin = CGPoint(x: m.left, y: m.top)
            let topCandidate = CGRect(origin: origin, size: cardSize).insetBy(dx: -16, dy: -16)
            if let sel = selection, !sel.intersection(topCandidate).isNull {
                origin = CGPoint(
                    x: max(m.left, round(bounds.width - m.right - cardSize.width)),
                    y: max(m.top, round(bounds.height - m.bottom - cardSize.height))
                )
            }
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if shortcutTipsView.frame.origin != origin { shortcutTipsView.setFrameOrigin(origin) }
        if shortcutTipsView.isHidden { shortcutTipsView.isHidden = false }
        CATransaction.commit()
    }

    func selectionHudText(for sel: CGRect, cornerRadius: CGFloat) -> String {
        let s = snapshot.scaleFactor
        let pxX = Int((sel.minX * s).rounded()), pxY = Int((sel.minY * s).rounded())
        let pxW = Int((sel.width * s).rounded()), pxH = Int((sel.height * s).rounded())
        var parts = [isRecordingMode ? "录屏 · \(pxX),\(pxY)  \(pxW) × \(pxH) px" : "\(pxX),\(pxY)  \(pxW) × \(pxH) px"]
        if isRecordingMode {
            parts.append(toolbar.recordingFormat.badgeTitle)
        } else {
            if cornerRadius > 0.5 { parts.append("圆角 \(Int((cornerRadiusRatio * 100).rounded()))%") }
            if glowStrength > 0.005 { parts.append("发光边 \(Int((glowStrength * 100).rounded()))%") }
            if let trTag = inPlaceTranslateHUDTag { parts.append(trTag) }
        }
        return parts.joined(separator: "  ·  ")
    }

    func drawSelectionChrome(ctx: CGContext, sel: CGRect, cornerRadius: CGFloat) {
        ctx.saveGState()
        let borderCol = isRecordingMode ? MSnipUITheme.danger : NSColor(srgbRed: 0.16, green: 0.58, blue: 1.0, alpha: 1.0)
        ctx.setStrokeColor(borderCol.cgColor)
        ctx.setLineWidth(2.0)
        if cornerRadius > 0.5 {
            ctx.addPath(CGPath(roundedRect: sel, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
            ctx.strokePath()
        } else {
            ctx.stroke(sel)
        }

        for handle in ResizeHandle.allCases {
            let p = handle.point(in: sel)
            let hr = CGRect(x: p.x - 4.75, y: p.y - 4.75, width: 9.5, height: 9.5)
            ctx.setFillColor(borderCol.cgColor)
            ctx.fillEllipse(in: hr)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(2.0)
            ctx.strokeEllipse(in: hr)
        }
        ctx.restoreGState()
    }
}

// MARK: - 快存目标目录弹出菜单

/// 截图工具栏「下载保存」按钮的悬浮快捷目录选择弹层（渲染在 OverlayView 内部，零层级遮挡、点击目录秒存）
final class OverlaySaveMenuView: NSView {
    enum Choice {
        case folder(String)
        case saveAsPanel
    }

    private struct Row {
        let title: String
        let subtitle: String?
        let symbol: String
        let tint: NSColor
        let choice: Choice
        let rect: CGRect
    }

    var onChoice: ((Choice) -> Void)?

    private var rows: [Row] = []
    private var sepY: CGFloat = 0
    private var hoveredIdx: Int? { didSet { if oldValue != hoveredIdx { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    static let menuWidth: CGFloat = 204
    private static let rowH: CGFloat = 28

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.menuWidth, height: 180))
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor(srgbRed: 0.04, green: 0.08, blue: 0.16, alpha: 1.0).cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: 4)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

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

    func reload(folders: [QuickSaveFolder]) {
        var built: [Row] = []
        var y: CGFloat = 6
        let w = Self.menuWidth - 10

        for f in folders {
            let shortPath = f.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            built.append(Row(
                title: f.title,
                subtitle: shortPath,
                symbol: f.symbol,
                tint: f.isDefault ? MSnipUITheme.accent : MSnipUITheme.inkSecondary,
                choice: .folder(f.path),
                rect: CGRect(x: 5, y: y, width: w, height: Self.rowH)
            ))
            y += Self.rowH
        }

        sepY = y + 3
        y += 7

        built.append(Row(
            title: "另存为 / 其他位置…",
            subtitle: "自由选择文件夹或修改文件名 (⌘S / ⇧S)",
            symbol: "folder.badge.plus",
            tint: MSnipUITheme.accent,
            choice: .saveAsPanel,
            rect: CGRect(x: 5, y: y, width: w, height: Self.rowH)
        ))
        y += Self.rowH + 6

        rows = built
        hoveredIdx = nil
        setFrameSize(NSSize(width: Self.menuWidth, height: y))
        needsDisplay = true
    }

    override var isHidden: Bool {
        didSet { if isHidden { clearHover() } }
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(atLocalPoint: convert(event.locationInWindow, from: nil))
    }

    func updateHover(atLocalPoint p: CGPoint) {
        let idx = rows.firstIndex(where: { $0.rect.contains(p) })
        if idx != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        if hoveredIdx != idx { hoveredIdx = idx }
        if let i = idx, rows.indices.contains(i), let sub = rows[i].subtitle {
            FloatingTooltipHUD.show(sub, anchorRectInView: rows[i].rect, of: self)
        } else {
            FloatingTooltipHUD.hide(for: self)
        }
    }

    func clearHover() {
        FloatingTooltipHUD.hide(for: self)
        if hoveredIdx != nil { hoveredIdx = nil }
    }

    override func mouseExited(with event: NSEvent) { clearHover() }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { clearHover() }
    }

    override func mouseDown(with event: NSEvent) {
        FloatingTooltipHUD.hide(for: self)
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = rows.first(where: { $0.rect.contains(p) }) else { return }
        onChoice?(hit.choice)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        MSnipUITheme.drawPorcelainBar(ctx: ctx, bounds: bounds, radius: 9.5)

        ctx.saveGState()
        ctx.setFillColor(MSnipUITheme.borderHairline.cgColor)
        ctx.fill(CGRect(x: 10, y: sepY, width: bounds.width - 20, height: 1))
        ctx.restoreGState()

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        for (i, row) in rows.enumerated() {
            let hov = (hoveredIdx == i)
            if hov {
                ToolbarView.drawButtonBg(ctx: ctx, rect: row.rect, active: false, hovered: true)
            }
            let iconRect = CGRect(x: row.rect.minX + 7, y: row.rect.minY, width: 16, height: row.rect.height)
            ToolbarView.drawSymbol(row.symbol, in: iconRect, alpha: 0.94, tint: hov ? MSnipUITheme.accent : row.tint)

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12.0, weight: hov ? .semibold : .medium),
                .foregroundColor: hov ? MSnipUITheme.accent : MSnipUITheme.inkPrimary,
                .paragraphStyle: para
            ]
            let ns = row.title as NSString
            let sz = ns.size(withAttributes: attrs)
            ns.draw(
                in: CGRect(
                    x: round(iconRect.maxX + 6),
                    y: round(row.rect.midY - sz.height * 0.5),
                    width: row.rect.maxX - iconRect.maxX - 14,
                    height: sz.height + 2
                ),
                withAttributes: attrs
            )
        }
    }
}
