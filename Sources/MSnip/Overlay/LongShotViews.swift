import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 采集线程轻量节流闸门：保证 60Hz 高帧率拼接不被缩略图重绘阻塞导致 SCStream 丢帧
final class PreviewThrottleGate: @unchecked Sendable {
    private let minInterval: TimeInterval
    private var lastRenderUptime: TimeInterval = 0

    init(minInterval: TimeInterval) { self.minInterval = minInterval }

    func shouldRender(force: Bool) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if force || (now - lastRenderUptime) >= minInterval {
            lastRenderUptime = now
            return true
        }
        return false
    }
}

/// 长截图镂空穿透取景框视图（完全鼠标穿透 `ignoresMouseEvents = true`，不遮挡下方窗口滚轮）
final class LongShotBorderView: NSView {
    enum StatusStyle {
        case ready
        case stitching
        case recording
        case warning
        case finishedBottom
    }

    static let sidePad: CGFloat = 6
    static let topBadgeSpace: CGFloat = 32

    var statusText: String = "长截图 · 请在框内向下滚动滚轮" { didSet { needsDisplay = true } }
    var statusStyle: StatusStyle = .ready { didSet { needsDisplay = true } }
    var countdownNumber: Int? { didSet { needsDisplay = true } }
    var countdownProgress: CGFloat = 1.0 { didSet { needsDisplay = true } }
    var countdownFormatBadge: String = "GIF"
    var pinPillInsideTop: Bool = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let captureRect = CGRect(
            x: Self.sidePad,
            y: Self.topBadgeSpace,
            width: bounds.width - Self.sidePad * 2,
            height: bounds.height - Self.topBadgeSpace - Self.sidePad
        )
        guard captureRect.width > 8, captureRect.height > 8 else { return }

        let accent: NSColor
        switch statusStyle {
        case .ready:          accent = MSnipUITheme.accent
        case .stitching:      accent = MSnipUITheme.success
        case .recording:      accent = MSnipUITheme.danger
        case .warning:        accent = MSnipUITheme.warning
        case .finishedBottom: accent = MSnipUITheme.accent
        }

        // 1) 外侧镂空高光边框（严丝合缝贴在采集区外沿，不污染内部像素）
        let frameRect = captureRect.insetBy(dx: -1.5, dy: -1.5)
        ctx.saveGState()
        ctx.setStrokeColor(accent.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(2.0)
        ctx.setLineDash(phase: 0, lengths: statusStyle == .warning ? [6, 4] : [])
        ctx.stroke(frameRect)

        let arm: CGFloat = min(14, min(frameRect.width, frameRect.height) * 0.2)
        ctx.setLineDash(phase: 0, lengths: [])
        ctx.setLineWidth(3.2)
        ctx.setLineCap(.round)
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: frameRect.minX, y: frameRect.minY), 1, 1),
            (CGPoint(x: frameRect.maxX, y: frameRect.minY), -1, 1),
            (CGPoint(x: frameRect.minX, y: frameRect.maxY), 1, -1),
            (CGPoint(x: frameRect.maxX, y: frameRect.maxY), -1, -1)
        ]
        for (pt, sx, sy) in corners {
            ctx.move(to: CGPoint(x: pt.x + sx * arm, y: pt.y))
            ctx.addLine(to: pt)
            ctx.addLine(to: CGPoint(x: pt.x, y: pt.y + sy * arm))
        }
        ctx.strokePath()
        ctx.restoreGState()

        // 2) 顶部清爽浅色白底状态胶囊徽标
        let nsText = statusText as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: MSnipUITheme.inkPrimary
        ]
        let tSz = nsText.size(withAttributes: attrs)
        let pillW = min(bounds.width - 8, ceil(tSz.width + 28))
        let pillH: CGFloat = 24
        let pillY = pinPillInsideTop ? round(frameRect.minY + 8) : max(2, frameRect.minY - pillH - 5)
        let pillX = pinPillInsideTop ? round(frameRect.minX + 8) : frameRect.minX
        let pillRect = CGRect(x: pillX, y: pillY, width: pillW, height: pillH)

        ctx.saveGState()
        let pillPath = CGPath(roundedRect: pillRect, cornerWidth: 6.5, cornerHeight: 6.5, transform: nil)
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: NSColor.black.withAlphaComponent(0.16).cgColor)
        ctx.setFillColor(MSnipUITheme.cardBg.cgColor)
        ctx.addPath(pillPath)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(accent.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(pillPath)
        ctx.strokePath()

        MSnipUITheme.drawStatusDot(ctx: ctx, center: CGPoint(x: pillRect.minX + 11.5, y: pillRect.midY), color: accent, halo: true)

        nsText.draw(
            at: CGPoint(x: round(pillRect.minX + 21), y: round(pillRect.minY + (pillH - tSz.height) * 0.5)),
            withAttributes: attrs
        )
        ctx.restoreGState()

        // 3) 录屏开始前 3-2-1 居中商业级毛玻璃进度圆环倒计时徽章
        if let n = countdownNumber {
            let rawSide = min(94, max(54, min(captureRect.width, captureRect.height) * 0.45))
            let side = floor(rawSide / 2.0) * 2.0
            let badgeRect = CGRect(
                x: round(captureRect.midX - side * 0.5),
                y: round(captureRect.midY - side * 0.5),
                width: side,
                height: side
            )
            let coral = NSColor(srgbRed: 0.96, green: 0.25, blue: 0.37, alpha: 1.0)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 16, color: NSColor.black.withAlphaComponent(0.32).cgColor)
            ctx.setFillColor(NSColor(srgbRed: 0.08, green: 0.10, blue: 0.15, alpha: 0.90).cgColor)
            ctx.fillEllipse(in: badgeRect)
            ctx.restoreGState()

            ctx.saveGState()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
            ctx.setLineWidth(1.0)
            ctx.strokeEllipse(in: badgeRect.insetBy(dx: 0.5, dy: 0.5))

            let ringInset: CGFloat = max(4.5, round(side * 0.068))
            let ringW: CGFloat = side >= 76 ? 3.5 : 2.8
            let ringR = (side - ringInset * 2) * 0.5
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
            ctx.setLineWidth(ringW)
            ctx.strokeEllipse(in: badgeRect.insetBy(dx: ringInset, dy: ringInset))

            let startA: CGFloat = -.pi * 0.5
            let endA = startA + (.pi * 2.0) * max(0.02, min(1.0, countdownProgress))
            ctx.setStrokeColor(coral.cgColor)
            ctx.setLineWidth(ringW)
            ctx.setLineCap(.round)
            ctx.addArc(center: CGPoint(x: badgeRect.midX, y: badgeRect.midY), radius: ringR, startAngle: startA, endAngle: endA, clockwise: false)
            ctx.strokePath()

            let numSize = round(side * 0.44)
            let baseFont = NSFont.systemFont(ofSize: numSize, weight: .bold)
            let roundedFont = baseFont.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: numSize) } ?? baseFont
            let numStr = "\(n)" as NSString
            let numAttrs: [NSAttributedString.Key: Any] = [.font: roundedFont, .foregroundColor: NSColor.white]
            let nSz = numStr.size(withAttributes: numAttrs)
            let yOffset: CGFloat = side >= 78 ? -5.0 : 0.0
            numStr.draw(
                at: CGPoint(x: round(badgeRect.midX - nSz.width * 0.5), y: round(badgeRect.midY - nSz.height * 0.5 + yOffset)),
                withAttributes: numAttrs
            )
            if side >= 78 {
                let capAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .bold),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.62)
                ]
                let cNs = countdownFormatBadge as NSString
                let cSz = cNs.size(withAttributes: capAttrs)
                cNs.draw(
                    at: CGPoint(x: round(badgeRect.midX - cSz.width * 0.5), y: round(badgeRect.maxY - 26)),
                    withAttributes: capAttrs
                )
            }
            ctx.restoreGState()
        }
    }
}

/// 右侧实时拼接长图清爽白底缩略预览卡片
final class LongShotPreviewView: NSView {
    var previewImage: CGImage? { didSet { needsDisplay = true } }
    var pixelWidth: Int = 0 { didSet { needsDisplay = true } }
    var pixelHeight: Int = 0 { didSet { needsDisplay = true } }
    var baseHeightPx: Int = 1
    var isFollowingTail: Bool = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        MSnipUITheme.drawPorcelainBar(ctx: ctx, bounds: bounds, radius: 10)
        ctx.saveGState()

        ("长图预览" as NSString).draw(at: CGPoint(x: 10, y: 7), withAttributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: MSnipUITheme.inkPrimary
        ])
        if pixelHeight > 0, baseHeightPx > 0 {
            let ratio = Double(pixelHeight) / Double(max(1, baseHeightPx))
            let badge = String(format: "%.1f×", ratio) as NSString
            let bAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .bold),
                .foregroundColor: MSnipUITheme.success
            ]
            let bSz = badge.size(withAttributes: bAttrs)
            badge.draw(at: CGPoint(x: round(bounds.width - bSz.width - 10), y: 7.5), withAttributes: bAttrs)
        }

        let viewport = CGRect(x: 9, y: 27, width: bounds.width - 18, height: bounds.height - 52)
        ctx.setFillColor(MSnipUITheme.subtleFill.cgColor)
        ctx.addPath(CGPath(roundedRect: viewport, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()

        if let img = previewImage, img.width > 0, img.height > 0 {
            let aspect = CGFloat(img.height) / CGFloat(img.width)
            var drawW = viewport.width - 6
            var drawH = drawW * aspect
            if drawH > viewport.height - 6 {
                drawH = viewport.height - 6
                drawW = drawH / max(0.05, aspect)
            }
            let dst = CGRect(
                x: round(viewport.midX - drawW * 0.5),
                y: round(viewport.minY + 3),
                width: max(2, round(drawW)),
                height: max(2, round(drawH))
            )
            let nsImg = NSImage(cgImage: img, size: dst.size)
            nsImg.draw(in: dst, from: .zero, operation: .copy, fraction: 1.0, respectFlipped: true, hints: nil)

            if isFollowingTail, dst.height >= 40 {
                // 超长图尾部跟随模式：顶部轻渐隐提示上方仍有内容，并绘制底部进度游标
                let fadeH: CGFloat = min(18, dst.height * 0.14)
                if let grad = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [MSnipUITheme.subtleFill.withAlphaComponent(0.92).cgColor, MSnipUITheme.subtleFill.withAlphaComponent(0.0).cgColor] as CFArray,
                    locations: [0.0, 1.0]
                ) {
                    ctx.saveGState()
                    ctx.clip(to: CGRect(x: dst.minX, y: dst.minY, width: dst.width, height: fadeH))
                    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: dst.minY), end: CGPoint(x: 0, y: dst.minY + fadeH), options: [])
                    ctx.restoreGState()
                }
                let thumbH: CGFloat = max(16, min(36, dst.height * 0.22))
                let trackRect = CGRect(x: dst.maxX - 4.5, y: dst.maxY - thumbH - 3, width: 2.5, height: thumbH)
                ctx.setFillColor(MSnipUITheme.accent.withAlphaComponent(0.75).cgColor)
                ctx.addPath(CGPath(roundedRect: trackRect, cornerWidth: 1.25, cornerHeight: 1.25, transform: nil))
                ctx.fillPath()
            }

            ctx.setStrokeColor(MSnipUITheme.borderStrong.cgColor)
            ctx.setLineWidth(1.0)
            ctx.stroke(dst)
        }

        let dimStr = (pixelWidth > 0 ? "\(pixelWidth) × \(pixelHeight)" : "等待画面…") as NSString
        let dAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: MSnipUITheme.inkSecondary
        ]
        let dSz = dimStr.size(withAttributes: dAttrs)
        dimStr.draw(at: CGPoint(x: round((bounds.width - dSz.width) * 0.5), y: bounds.height - 19), withAttributes: dAttrs)
        ctx.restoreGState()
    }
}

// MARK: - 长截图底部悬浮控制栏

/// 长截图底部非抢焦悬浮操作栏（清爽浅色磨砂白底风 + 纵横切换/撤回上段/直达标注 + 蓝色主完成胶囊）
final class LongShotControlBarView: NSView {
    enum Action {
        case toggleAutoScroll
        case toggleAxis
        case undoLast
        case annotate
        case extractText
        case translateText
        case pin
        case save
        case saveAs
        case cancel
        case finishCopy
    }

    var onAction: ((Action) -> Void)?
    var isAutoScrolling = false { didSet { needsDisplay = true } }
    var axis: ScrollStitchAxis = .vertical { didSet { needsDisplay = true } }
    var canUndoLast = false { didSet { needsDisplay = true } }
    var pinHint: String = "⌘2"

    private struct ButtonSlot {
        let rect: CGRect
        let tip: String
        let action: Action
        let render: (CGContext, CGRect, Bool) -> Void
    }

    private var slots: [ButtonSlot] = []
    private var hoveredIdx: Int?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static let barSize = NSSize(width: 447, height: 40)

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.barSize))
        rebuildSlots()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

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

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = slots.firstIndex(where: { $0.rect.contains(p) })
        if idx != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        if idx != hoveredIdx {
            hoveredIdx = idx
            if let i = idx, slots.indices.contains(i) {
                FloatingTooltipHUD.show(slots[i].tip, anchorRectInView: slots[i].rect, of: self)
            } else {
                FloatingTooltipHUD.hide(for: self)
            }
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIdx = nil
        FloatingTooltipHUD.hide(for: self)
        needsDisplay = true
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { FloatingTooltipHUD.hide(for: self) }
    }

    override func mouseDown(with event: NSEvent) {
        FloatingTooltipHUD.hide(for: self)
        let p = convert(event.locationInWindow, from: nil)
        if let slot = slots.first(where: { $0.rect.contains(p) }) {
            if slot.action == .save && event.modifierFlags.contains(.option) {
                onAction?(.saveAs)
            } else {
                onAction?(slot.action)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        rebuildSlots()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        MSnipUITheme.drawPorcelainBar(ctx: ctx, bounds: bounds, radius: 9.5)
        for (i, s) in slots.enumerated() {
            s.render(ctx, s.rect, hoveredIdx == i)
        }
    }

    private func rebuildSlots() {
        var list: [ButtonSlot] = []
        let y: CGFloat = 5, h: CGFloat = 30
        var x: CGFloat = 7

        let autoW: CGFloat = 96
        let autoRect = CGRect(x: x, y: y, width: autoW, height: h)
        let running = isAutoScrolling
        list.append(ButtonSlot(
            rect: autoRect,
            tip: running ? "停止自动滚动" : "平滑自动向下滚动（需辅助功能权限）",
            action: .toggleAutoScroll,
            render: { ctx, r, hov in
                ToolbarView.drawButtonBg(ctx: ctx, rect: r, active: running, hovered: hov)
                let sym = running ? "pause.fill" : "play.fill"
                let fg = running ? MSnipUITheme.accent : MSnipUITheme.inkPrimary
                let iconR = CGRect(x: r.minX + 8, y: r.minY, width: 14, height: r.height)
                ToolbarView.drawSymbol(sym, in: iconR, alpha: 0.95, tint: fg)
                let label = (running ? "停止滚动" : "自动滚动") as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: fg
                ]
                let sz = label.size(withAttributes: attrs)
                label.draw(
                    at: CGPoint(x: round(iconR.maxX + 4), y: round(r.minY + (r.height - sz.height) * 0.5)),
                    withAttributes: attrs
                )
            }
        ))
        x += autoW + 8

        let axisSym = (axis == .vertical) ? "arrow.up.and.down" : "arrow.left.and.right"
        let axisTip = (axis == .vertical) ? "当前纵向长截图 · 点击切换为横向向右长截图" : "当前横向长截图 · 点击切换为纵向向下长截图"
        let undoTint = canUndoLast ? MSnipUITheme.inkPrimary : MSnipUITheme.inkSecondary.withAlphaComponent(0.35)
        let iconDefs: [(String, String, NSColor, Bool, Action)] = [
            (axisSym, axisTip, axis == .horizontal ? MSnipUITheme.accent : MSnipUITheme.inkPrimary, axis == .horizontal, .toggleAxis),
            ("arrow.uturn.backward", "撤回上一段拼接 (⌘Z)", undoTint, false, .undoLast),
            ("pencil.tip", "完成并直接进入标注编辑", MSnipUITheme.inkPrimary, false, .annotate),
            ("text.viewfinder", "长图识字 (OCR)", MSnipUITheme.inkPrimary, false, .extractText),
            ("character.bubble", "长图翻译", MSnipUITheme.inkPrimary, false, .translateText),
            ("pin", "长图贴到屏幕 (\(pinHint))", MSnipUITheme.inkPrimary, false, .pin),
            ("square.and.arrow.down", "保存长图到默认目录（按住 ⌥ 另存为）", MSnipUITheme.inkPrimary, false, .save),
            ("xmark", "取消长截图 (Esc)", MSnipUITheme.danger, false, .cancel)
        ]
        for (sym, tip, tint, active, act) in iconDefs {
            let r = CGRect(x: x, y: y, width: 28, height: h)
            x += 31
            list.append(ButtonSlot(rect: r, tip: tip, action: act) { ctx, rect, hov in
                ToolbarView.drawButtonBg(ctx: ctx, rect: rect, active: active, hovered: hov)
                ToolbarView.drawSymbol(sym, in: rect, alpha: 0.95, tint: tint)
            })
        }

        let okRect = CGRect(x: x + 2, y: y, width: 76, height: h)
        list.append(ButtonSlot(rect: okRect, tip: "完成并复制长图到剪贴板 (⌘↩ / ↩)", action: .finishCopy) { ctx, r, hov in
            MSnipUITheme.drawPrimaryCTA(ctx: ctx, rect: r, radius: 6.5, hovered: hov)
            let iconR = CGRect(x: r.minX + 10, y: r.minY, width: 14, height: r.height)
            ToolbarView.drawSymbol("checkmark", in: iconR, alpha: 1.0, tint: .white)
            let txt = "完成" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let sz = txt.size(withAttributes: attrs)
            txt.draw(
                at: CGPoint(x: round(iconR.maxX + 4), y: round(r.minY + (r.height - sz.height) * 0.5)),
                withAttributes: attrs
            )
        })
        slots = list
    }
}

// MARK: - LongShotSession Panel Construction & Layout

extension LongShotSession {
    func setupPanels(screen: NSScreen, localRect: CGRect, pinHint: String) {
        let appKitSel = NSRect(
            x: screen.frame.minX + localRect.minX,
            y: screen.frame.maxY - localRect.maxY,
            width: localRect.width,
            height: localRect.height
        )

        let pad = LongShotBorderView.sidePad
        let topSpace = LongShotBorderView.topBadgeSpace
        let borderFrame = NSRect(
            x: appKitSel.minX - pad,
            y: appKitSel.minY - pad,
            width: appKitSel.width + pad * 2,
            height: appKitSel.height + pad + topSpace
        )
        let bp = makeLongShotPanel(frame: borderFrame, ignoresMouse: true)
        let bv = LongShotBorderView(frame: NSRect(origin: .zero, size: borderFrame.size))
        bp.contentView = bv
        self.borderPanel = bp
        self.borderView = bv

        let prevW: CGFloat = 152
        let prevH: CGFloat = min(max(190, appKitSel.height), 380)
        let rightX = appKitSel.maxX + 12
        let leftX = appKitSel.minX - prevW - 12
        let prevX = (rightX + prevW + 8 <= screen.frame.maxX)
            ? rightX
            : (leftX >= screen.frame.minX + 8 ? leftX : screen.frame.maxX - prevW - 10)
        let prevY = min(max(screen.visibleFrame.minY + 10, appKitSel.maxY - prevH), screen.visibleFrame.maxY - prevH - 10)
        let prevFrame = NSRect(x: round(prevX), y: round(prevY), width: prevW, height: round(prevH))

        let pp = makeLongShotPanel(frame: prevFrame, ignoresMouse: true)
        let pv = LongShotPreviewView(frame: NSRect(origin: .zero, size: prevFrame.size))
        pv.baseHeightPx = Int((localRect.height * scaleFactor).rounded())
        pp.contentView = pv
        self.previewPanel = pp
        self.previewView = pv

        let barSz = LongShotControlBarView.barSize
        let barX = min(max(screen.frame.minX + 8, appKitSel.maxX - barSz.width), screen.frame.maxX - barSz.width - 8)
        let belowY = appKitSel.minY - barSz.height - 10
        let aboveY = borderFrame.maxY + 8
        let barY = (belowY >= screen.visibleFrame.minY + 6)
            ? belowY
            : (aboveY + barSz.height <= screen.visibleFrame.maxY ? aboveY : screen.visibleFrame.minY + 12)
        let cp = makeLongShotPanel(frame: NSRect(x: round(barX), y: round(barY), width: barSz.width, height: barSz.height), ignoresMouse: false)
        let cv = LongShotControlBarView()
        cv.pinHint = pinHint
        cv.onAction = { [weak self] act in self?.handleControlAction(act) }
        cp.contentView = cv
        self.controlPanel = cp
        self.controlView = cv

        bp.orderFrontRegardless()
        pp.orderFrontRegardless()
        cp.orderFrontRegardless()
    }

    private func makeLongShotPanel(frame: NSRect, ignoresMouse: Bool) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.animationBehavior = .none; p.isFloatingPanel = true
        p.level = .statusBar; p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false; p.backgroundColor = .clear
        p.hasShadow = !ignoresMouse; p.ignoresMouseEvents = ignoresMouse
        return p
    }
}
