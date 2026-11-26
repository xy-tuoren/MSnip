import AppKit
import CoreGraphics
import Foundation
import MSnipCore
import QuartzCore

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
