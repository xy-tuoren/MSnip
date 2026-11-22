import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 悬浮工具栏（Daylight Porcelain 清爽浅色白底风格）的按钮底色、SF Symbol 位图缓存、拖拽手柄与主操作胶囊绘制
extension ToolbarView {
    private static var symbolMaskCache: [String: (cg: CGImage, size: NSSize)] = [:]

    static let inkDark = MSnipUITheme.inkPrimary
    static let accentBlue = MSnipUITheme.accent

    static func drawButtonBg(ctx: CGContext, rect: CGRect, active: Bool, hovered: Bool, darkSurface: Bool = false) {
        guard active || hovered else { return }
        let path = CGPath(roundedRect: rect, cornerWidth: 6.5, cornerHeight: 6.5, transform: nil)
        ctx.saveGState()
        if darkSurface {
            let color = active ? accentBlue.withAlphaComponent(0.88) : NSColor.white.withAlphaComponent(0.15)
            ctx.setFillColor(color.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        } else if active {
            ctx.setFillColor(MSnipUITheme.activeSoftFill.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.setStrokeColor(accentBlue.withAlphaComponent(0.32).cgColor)
            ctx.setLineWidth(1.0)
            ctx.addPath(path)
            ctx.strokePath()
        } else {
            ctx.setFillColor(MSnipUITheme.hoverFill.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    static func drawGripDots(ctx: CGContext, in rect: CGRect) {
        ctx.saveGState()
        ctx.setFillColor(MSnipUITheme.inkMuted.withAlphaComponent(0.55).cgColor)
        let cols: [CGFloat] = [round(rect.midX - 2.5), round(rect.midX + 2.5)]
        let rows: [CGFloat] = [round(rect.midY - 5.0), round(rect.midY), round(rect.midY + 5.0)]
        for cx in cols {
            for cy in rows {
                ctx.fillEllipse(in: CGRect(x: cx - 1.1, y: cy - 1.1, width: 2.2, height: 2.2))
            }
        }
        ctx.restoreGState()
    }

    static func drawSmallChevron(ctx: CGContext, x: CGFloat, centerY: CGFloat, active: Bool) {
        ctx.saveGState()
        let tint = active ? accentBlue : MSnipUITheme.inkSecondary.withAlphaComponent(0.75)
        ctx.setStrokeColor(tint.cgColor)
        ctx.setLineWidth(1.3)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.move(to: CGPoint(x: x - 2.5, y: centerY - 1.2))
        ctx.addLine(to: CGPoint(x: x, y: centerY + 1.5))
        ctx.addLine(to: CGPoint(x: x + 2.5, y: centerY - 1.2))
        ctx.strokePath()
        ctx.restoreGState()
    }

    static func drawSymbol(_ name: String, in rect: CGRect, alpha: CGFloat = 0.94, tint: NSColor = ToolbarView.inkDark) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let entry: (cg: CGImage, size: NSSize)
        if let cached = symbolMaskCache[name] {
            entry = cached
        } else {
            guard let baseImg = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
            let cfg = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .medium)
            let configured = baseImg.withSymbolConfiguration(cfg) ?? baseImg
            guard let cg = configured.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let created = (cg: cg, size: configured.size)
            symbolMaskCache[name] = created
            entry = created
        }

        let size = entry.size
        let dst = CGRect(
            x: round(rect.midX - size.width * 0.5),
            y: round(rect.midY - size.height * 0.5),
            width: size.width,
            height: size.height
        )
        ctx.saveGState()
        ctx.translateBy(x: 0, y: dst.minY + dst.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.clip(to: dst, mask: entry.cg)
        ctx.setFillColor(tint.withAlphaComponent(alpha).cgColor)
        ctx.fill(dst)
        ctx.restoreGState()
    }

    static func drawEyedropperItem(
        ctx: CGContext,
        rect: CGRect,
        active: Bool,
        customColor: RGBAColor?,
        hovered: Bool
    ) {
        drawButtonBg(ctx: ctx, rect: rect, active: active, hovered: hovered)
        let tint: NSColor = active ? accentBlue : inkDark
        drawSymbol("eyedropper", in: rect, alpha: 0.94, tint: tint)
        if let c = customColor {
            let dot = CGRect(x: rect.maxX - 8.5, y: rect.maxY - 8.5, width: 6, height: 6)
            ctx.setFillColor(c.cgColor)
            ctx.fillEllipse(in: dot)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.2)
            ctx.strokeEllipse(in: dot)
        }
    }

    /// 绘制二级样式栏内的连续大小进度条（紧随大中小快选圆点之后：蓝轨滑块 + 右侧等宽数值读数）
    static func drawSubbarSizeSlider(
        ctx: CGContext,
        boundsH: CGFloat,
        trackMinX: CGFloat,
        trackMaxX: CGFloat,
        labelX: CGFloat,
        ratio: CGFloat,
        readout: String,
        highlighted: Bool
    ) {
        let cy = boundsH * 0.5
        ctx.saveGState()

        let trackH: CGFloat = 4.5
        let trackW = trackMaxX - trackMinX
        let trackRect = CGRect(x: trackMinX, y: round(cy - trackH * 0.5), width: trackW, height: trackH)
        let bgPath = CGPath(roundedRect: trackRect, cornerWidth: 2.25, cornerHeight: 2.25, transform: nil)
        ctx.setFillColor(MSnipUITheme.sidebarBg.cgColor)
        ctx.addPath(bgPath); ctx.fillPath()
        ctx.setStrokeColor(MSnipUITheme.borderHairline.cgColor)
        ctx.setLineWidth(1.0); ctx.addPath(bgPath); ctx.strokePath()

        let fillW = max(0, min(trackW, trackW * ratio))
        if fillW > 1.0 {
            let fillRect = CGRect(x: trackMinX, y: trackRect.minY, width: fillW, height: trackH)
            ctx.setFillColor(MSnipUITheme.accent.cgColor)
            ctx.addPath(CGPath(roundedRect: fillRect, cornerWidth: 2.25, cornerHeight: 2.25, transform: nil))
            ctx.fillPath()
        }

        let thumbR: CGFloat = highlighted ? 6.8 : 5.8
        let thumbX = trackMinX + fillW
        let thumbRect = CGRect(x: thumbX - thumbR, y: cy - thumbR, width: thumbR * 2, height: thumbR * 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 3.0, color: NSColor.black.withAlphaComponent(0.20).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: thumbRect)
        ctx.restoreGState()
        ctx.setStrokeColor(MSnipUITheme.accent.cgColor)
        ctx.setLineWidth(1.8)
        ctx.strokeEllipse(in: thumbRect.insetBy(dx: 0.5, dy: 0.5))

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: MSnipUITheme.inkPrimary
        ]
        let ns = readout as NSString
        let sz = ns.size(withAttributes: attrs)
        ns.draw(at: CGPoint(x: round(labelX), y: round(cy - sz.height * 0.5)), withAttributes: attrs)
        ctx.restoreGState()
    }

    /// 录屏模式下的悬浮工具栏配置项（GIF/MP4、点击波纹回显、切回截图、退出、数学居中「● 开始录制」主按钮）
    func buildRecordingSetupItems(x: inout CGFloat, y: CGFloat, h: CGFloat, into list: inout [HitItem]) {
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
}
