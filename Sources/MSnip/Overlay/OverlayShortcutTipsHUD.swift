import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 高对比度清晰竖排双栏快捷键提示面板 (`ShortcutTipsWidget`) + 顶部选区坐标尺寸胶囊 (`drawHUDPill`)
/// - 自动根据显示器 `visibleFrame` 避开底部程序坞 (Dock)、顶部菜单栏与屏幕物理边缘；
/// - 采用高对比悬浮深蓝灰卡片 + 高亮描边 + 纯白立体键帽 + 全整数像素对齐排版，在 `@1x` (1080p) 与 `@2x` 暗色/亮色背景下均清晰醒目。
extension OverlayView {
    private static let headerTitleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12.0, weight: .bold),
        .foregroundColor: MSnipUITheme.accent
    ]
    private static let headerHintAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11.0, weight: .medium),
        .foregroundColor: MSnipUITheme.inkMuted
    ]
    private static let keycapKeyAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12.5, weight: .bold),
        .foregroundColor: MSnipUITheme.inkPrimary
    ]
    private static let keycapDescAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13.5, weight: .medium),
        .foregroundColor: MSnipUITheme.inkPrimary
    ]
    private static var textSizeCache: [String: CGSize] = [:]

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
        } else {
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
    }

    private func measureTipsCardLayout(rows: [(key: String, desc: String)]) -> (size: CGSize, maxKeyCapW: CGFloat) {
        let padX: CGFloat = 18
        let headerH: CGFloat = 30
        let padBottom: CGFloat = 15
        let rowStride: CGFloat = 32
        let colGap: CGFloat = 14

        var maxCapW: CGFloat = 0
        var maxDescW: CGFloat = 0
        for row in rows {
            let kSz = Self.cachedSize(row.key, isKey: true)
            let dSz = Self.cachedSize(row.desc, isKey: false)
            maxCapW = max(maxCapW, max(26, ceil(kSz.width + 16)))
            maxDescW = max(maxDescW, ceil(dSz.width))
        }
        let w = ceil(padX * 2 + maxCapW + colGap + maxDescW)
        let h = ceil(headerH + 10 + CGFloat(rows.count) * rowStride - 6 + padBottom)
        return (CGSize(width: max(224, w), height: h), maxCapW)
    }

    func shortcutTipsBottomTriggerZone() -> CGRect {
        let layout = measureTipsCardLayout(rows: currentShortcutTipRows())
        let m = safeOverlayMargins()
        let base = CGRect(
            x: m.left,
            y: max(m.top, bounds.height - m.bottom - layout.size.height),
            width: layout.size.width,
            height: layout.size.height
        )
        return base.insetBy(dx: -24, dy: -24)
    }

    func drawShortcutTipsHUD(ctx: CGContext, dirtyRect: CGRect) {
        guard showShortcutTips, !isEditingText else { return }
        if let sel = selection, sel.width > bounds.width * 0.85, sel.height > bounds.height * 0.80 {
            return
        }

        let rows = currentShortcutTipRows()
        let layout = measureTipsCardLayout(rows: rows)
        let cardW = layout.size.width
        let cardH = layout.size.height
        let m = safeOverlayMargins()

        var origin = CGPoint(
            x: m.left,
            y: max(m.top, round(bounds.height - m.bottom - cardH))
        )
        let bottomTrigger = CGRect(origin: origin, size: layout.size).insetBy(dx: -24, dy: -24)
        let cursorNearBottom = lastMousePoint.map { bottomTrigger.contains($0) } ?? false
        let selNearBottom = selection.map { !$0.intersection(bottomTrigger).isNull } ?? false
        let barNearBottom = (!toolbar.isHidden && !toolbar.frame.intersection(bottomTrigger).isNull)
            || (!subbar.isHidden && !subbar.frame.intersection(bottomTrigger).isNull)
        if cursorNearBottom || selNearBottom || barNearBottom {
            origin = CGPoint(x: m.left, y: m.top)
            let topCandidate = CGRect(origin: origin, size: layout.size).insetBy(dx: -16, dy: -16)
            if let sel = selection, !sel.intersection(topCandidate).isNull {
                origin = CGPoint(
                    x: max(m.left, round(bounds.width - m.right - cardW)),
                    y: max(m.top, round(bounds.height - m.bottom - cardH))
                )
            }
        }

        let rect = CGRect(origin: origin, size: layout.size)
        guard rect.insetBy(dx: -26, dy: -26).intersects(dirtyRect) else { return }

        let path = CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil)

        // 1) 清爽浅色白底悬浮卡片 + 柔和投影 + 细腻深蓝灰边框（在截图半透明暗化遮罩上形成极高对比度）
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 22, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.setFillColor(MSnipUITheme.cardBg.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(MSnipUITheme.borderStrong.cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(path)
        ctx.strokePath()

        // 2) 卡片顶栏小标题与隐藏提示
        let padX: CGFloat = 18
        ("快捷键操作" as NSString).draw(
            at: CGPoint(x: round(rect.minX + padX), y: round(rect.minY + 9)),
            withAttributes: Self.headerTitleAttrs
        )
        let hideHint = "按 \(keyUpper(.toggleTips)) 隐藏" as NSString
        let hideSz = hideHint.size(withAttributes: Self.headerHintAttrs)
        hideHint.draw(
            at: CGPoint(x: round(rect.maxX - padX - hideSz.width), y: round(rect.minY + 9)),
            withAttributes: Self.headerHintAttrs
        )
        ctx.setFillColor(MSnipUITheme.borderHairline.cgColor)
        ctx.fill(CGRect(x: rect.minX + padX, y: rect.minY + 31, width: cardW - padX * 2, height: 1))

        // 3) 整数像素对齐的双栏浅色立体键帽与说明行
        let startY = rect.minY + 41
        let rowStride: CGFloat = 32
        let capH: CGFloat = 24
        let keySpineRightX = round(rect.minX + padX + layout.maxKeyCapW)
        let descLeftX = round(keySpineRightX + 14)

        for (idx, row) in rows.enumerated() {
            let rowTopY = round(startY + CGFloat(idx) * rowStride)
            let kSz = Self.cachedSize(row.key, isKey: true)
            let dSz = Self.cachedSize(row.desc, isKey: false)

            let capW = max(26, ceil(kSz.width + 16))
            let capRect = CGRect(x: keySpineRightX - capW, y: rowTopY, width: capW, height: capH)
            let capPath = CGPath(roundedRect: capRect, cornerWidth: 5.5, cornerHeight: 5.5, transform: nil)

            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 1.0, color: NSColor.black.withAlphaComponent(0.08).cgColor)
            ctx.setFillColor(MSnipUITheme.subtleFill.cgColor)
            ctx.addPath(capPath)
            ctx.fillPath()
            ctx.restoreGState()

            ctx.setStrokeColor(MSnipUITheme.borderStrong.cgColor)
            ctx.setLineWidth(1.0)
            ctx.addPath(capPath)
            ctx.strokePath()

            (row.key as NSString).draw(
                at: CGPoint(
                    x: round(capRect.minX + (capW - kSz.width) * 0.5),
                    y: round(capRect.minY + (capH - kSz.height) * 0.5)
                ),
                withAttributes: Self.keycapKeyAttrs
            )
            (row.desc as NSString).draw(
                at: CGPoint(
                    x: descLeftX,
                    y: round(rowTopY + (capH - dSz.height) * 0.5)
                ),
                withAttributes: Self.keycapDescAttrs
            )
        }
        ctx.restoreGState()
    }

    private static func cachedSize(_ str: String, isKey: Bool) -> CGSize {
        let token = isKey ? "K:\(str)" : "D:\(str)"
        if let hit = textSizeCache[token] { return hit }
        let sz = (str as NSString).size(withAttributes: isKey ? keycapKeyAttrs : keycapDescAttrs)
        textSizeCache[token] = sz
        return sz
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
        drawHUDPill(ctx: ctx, anchorRect: sel, text: parts.joined(separator: "  ·  "))
    }
}
