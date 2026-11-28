import AppKit
import CoreGraphics
import Foundation
import MSnipCore
import QuartzCore

/// 高优先级非激活悬浮通知面板（四周预留真实投影边距，首击直达不吞事件）
final class ToastPanel: NSPanel {
    let interactive: Bool

    init(frame: NSRect, interactive: Bool) {
        self.interactive = interactive
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.animationBehavior = .none
        self.isFloatingPanel = true
        // 严格位于全屏覆盖层（CGShieldingWindowLevel）之上且低于光标层（kCGCursorWindowLevel）与系统最大保留层
        let safeToastMax = Int(CGWindowLevelForKey(.maximumWindow)) - 2
        self.level = NSWindow.Level(rawValue: min(safeToastMax, max(
            NSWindow.Level.screenSaver.rawValue + 1,
            Int(CGShieldingWindowLevel()) + 1
        )))
        self.becomesKeyOnlyIfNeeded = true
        self.hidesOnDeactivate = false
        self.acceptsMouseMovedEvents = interactive
        self.ignoresMouseEvents = !interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.appearance = GeekTheme.windowAppearance
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    override var canBecomeKey: Bool { interactive }
    override var canBecomeMain: Bool { false }
}

/// 陶瓷白立体悬浮通知卡片 HUD：
/// - 位于屏幕底部居中黄金视线区（Dock 上方），上滑回弹入场，不遮挡顶部标签栏与标题栏；
/// - 快存通知内置真实截图缩略图预览、底部倒计时细进度条（悬停自动暂停）与首击直达访达按钮。
@MainActor
enum ToastHUD {
    private static var activePanel: ToastPanel?
    private static var activeTargetFrame: NSRect = .zero
    private static var isHovering = false
    private static var dismissWorkItem: DispatchWorkItem?

    static func show(
        message: String,
        subtitle: String? = nil,
        preview: CGImage? = nil,
        swatch: RGBAColor? = nil,
        near screenPoint: NSPoint? = nil,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil
    ) {
        // 只记录失败类提示：普通提示可能携带二维码、取色等用户内容
        if DiagnosticLogText.looksLikeFailure(message) {
            MSnipLog.warning(.ui, "Toast: \(message)\(subtitle.map { " — \($0)" } ?? "")")
        }
        dismissImmediate()
        let isInteractive = (actionTitle != nil && onAction != nil)
        let holdSeconds: TimeInterval = isInteractive ? 6.0 : 2.3
        let contentView = ToastCardView(
            rawMessage: message,
            subtitle: subtitle,
            preview: preview,
            swatch: swatch,
            actionTitle: actionTitle,
            onTrigger: { dismissImmediate(); onAction?() },
            onClose: { dismissImmediate() },
            onHoverChanged: { handleHoverChanged($0, holdSeconds: holdSeconds) }
        )
        let size = contentView.panelSize
        contentView.frame = NSRect(origin: .zero, size: size)

        let probe = screenPoint ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(probe) })
            ?? NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let targetFrame: NSRect
        if let anchor = screenPoint {
            let x = min(max(vf.minX + 6, round(anchor.x - size.width * 0.5)), vf.maxX - size.width - 6)
            let prefY = round(anchor.y + 14)
            let y = (prefY + size.height <= vf.maxY) ? prefY : max(vf.minY + 6, round(anchor.y - size.height - 18))
            targetFrame = NSRect(x: x, y: y, width: size.width, height: size.height)
        } else {
            let x = round(vf.midX - size.width * 0.5)
            let y = round(vf.minY + max(40, min(68, vf.height * 0.055)))
            targetFrame = NSRect(x: x, y: y, width: size.width, height: size.height)
        }

        let startFrame = (screenPoint == nil) ? targetFrame.offsetBy(dx: 0, dy: -18) : targetFrame
        activeTargetFrame = targetFrame
        isHovering = false
        let panel = ToastPanel(frame: startFrame, interactive: isInteractive)
        panel.contentView = contentView
        panel.alphaValue = (screenPoint == nil) ? 0.85 : 1.0
        panel.orderFrontRegardless()
        if screenPoint == nil {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.30, 1.0)
                panel.animator().setFrame(targetFrame, display: true)
                panel.animator().alphaValue = 1.0
            }
        }
        activePanel = panel
        startCountdown(duration: holdSeconds, for: panel, view: contentView)
    }

    static func refreshAppearanceIfVisible() {
        activePanel?.appearance = GeekTheme.windowAppearance
        activePanel?.contentView?.needsDisplay = true
    }

    static func dismissImmediate() {
        dismissWorkItem?.cancel(); dismissWorkItem = nil
        isHovering = false
        activePanel?.orderOut(nil); activePanel = nil
    }

    private static func handleHoverChanged(_ hovering: Bool, holdSeconds: TimeInterval) {
        isHovering = hovering
        guard let panel = activePanel, let view = panel.contentView as? ToastCardView else { return }
        if hovering {
            dismissWorkItem?.cancel(); dismissWorkItem = nil
            panel.setFrame(activeTargetFrame, display: true)
            panel.alphaValue = 1.0
            view.resetProgressBarFull()
        } else {
            startCountdown(duration: min(holdSeconds, 3.0), for: panel, view: view)
        }
    }

    private static func startCountdown(duration: TimeInterval, for panel: ToastPanel, view: ToastCardView) {
        dismissWorkItem?.cancel(); dismissWorkItem = nil
        guard !isHovering else { view.resetProgressBarFull(); return }
        if view.hasAction { view.startProgressAnimation(duration: duration) }
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                guard let current = activePanel, current === panel, !isHovering else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.20
                    current.animator().alphaValue = 0.0
                    current.animator().setFrame(activeTargetFrame.offsetBy(dx: 0, dy: -10), display: true)
                } completionHandler: {
                    MainActor.assumeIsolated {
                        if activePanel === panel, !isHovering { panel.orderOut(nil); activePanel = nil }
                    }
                }
            }
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

// MARK: - 轻提示卡片自绘视图

/// 立体陶瓷白通知卡片视图（兼顾深色编辑器极亮反差与浅色网页多层环境深阴影，支持真实截图等比裁切缩略图）
private final class ToastCardView: NSView {
    static let shadowPadX: CGFloat = 24
    static let shadowPadTop: CGFloat = 16
    static let shadowPadBot: CGFloat = 28

    private let cleanMessage: String
    private let subtitle: String?
    private let preview: CGImage?
    private let swatch: RGBAColor?
    private let statusSymbol: String
    private let badgeColor: NSColor
    private let actionTitle: String?
    private let onTrigger: (() -> Void)?
    private let onClose: (() -> Void)?
    private let onHoverChanged: ((Bool) -> Void)?

    var hasAction: Bool { actionTitle != nil }
    private var cardRect: CGRect = .zero
    private var actionBtnRect: CGRect = .zero
    private var closeBtnRect: CGRect = .zero
    private var hoveredAction = false { didSet { if oldValue != hoveredAction { needsDisplay = true } } }
    private var hoveredClose = false { didSet { if oldValue != hoveredClose { needsDisplay = true } } }
    private var progressClipLayer: CALayer?
    private var progressBarLayer: CALayer?

    let panelSize: NSSize
    override var isFlipped: Bool { true }

    init(
        rawMessage: String,
        subtitle: String?,
        preview: CGImage?,
        swatch: RGBAColor?,
        actionTitle: String?,
        onTrigger: (() -> Void)?,
        onClose: (() -> Void)?,
        onHoverChanged: ((Bool) -> Void)?
    ) {
        var trimmed = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let tone = MessageTone.classify(trimmed)
        let isWarn = tone == .warning
        let isOK = tone == .success
        if trimmed.hasPrefix("✓") || trimmed.hasPrefix("⚠") {
            trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        self.cleanMessage = trimmed
        self.subtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.preview = preview.flatMap { Self.makeCompactThumb($0) }
        self.swatch = swatch
        self.actionTitle = actionTitle
        self.onTrigger = onTrigger
        self.onClose = onClose
        self.onHoverChanged = onHoverChanged
        self.statusSymbol = isWarn ? "exclamationmark" : (isOK ? "checkmark" : "info")
        self.badgeColor = isWarn
            ? NSColor(srgbRed: 0.95, green: 0.55, blue: 0.08, alpha: 1.0)
            : (isOK ? NSColor(srgbRed: 0.06, green: 0.68, blue: 0.44, alpha: 1.0) : MSnipUITheme.accent)

        let interactive = (actionTitle != nil)
        let hasSub = !(self.subtitle ?? "").isEmpty
        let titleW = (trimmed as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: interactive ? 14.0 : 13.5, weight: .semibold)]).width
        let subW: CGFloat = hasSub
            ? ((self.subtitle! as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .regular)]).width)
            : 0
        let textW = min(380, ceil(max(titleW, subW)))
        let leftW: CGFloat = (preview != nil) ? 78 : (interactive ? 58 : 48)
        let rightW: CGFloat = actionTitle.map {
            ceil(($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold)]).width + 32) + 46
        } ?? 20
        let cardW = max(interactive ? 440 : 216, leftW + textW + rightW)
        let cardH: CGFloat = interactive ? 64 : 44
        self.panelSize = NSSize(
            width: cardW + Self.shadowPadX * 2,
            height: cardH + Self.shadowPadTop + Self.shadowPadBot
        )
        super.init(frame: NSRect(origin: .zero, size: self.panelSize))
        self.wantsLayer = true
        recomputeRects()
        setupProgressLayerIfNeeded()
    }

    private func setupProgressLayerIfNeeded() {
        guard hasAction, let rootLayer = layer else { return }
        let clip = CALayer()
        clip.frame = cardRect; clip.cornerRadius = 15.5; clip.masksToBounds = true
        let bar = CALayer()
        bar.anchorPoint = CGPoint(x: 0, y: 0.5)
        bar.position = CGPoint(x: 0, y: cardRect.height - 1.25)
        bar.bounds = CGRect(x: 0, y: 0, width: cardRect.width, height: 2.5)
        bar.backgroundColor = MSnipUITheme.accent.withAlphaComponent(0.32).cgColor
        clip.addSublayer(bar); rootLayer.addSublayer(clip)
        progressClipLayer = clip; progressBarLayer = bar
    }

    func startProgressAnimation(duration: TimeInterval) {
        guard let bar = progressBarLayer else { return }
        bar.removeAllAnimations()
        let anim = CABasicAnimation(keyPath: "transform.scale.x")
        anim.fromValue = 1.0; anim.toValue = 0.0; anim.duration = duration
        anim.fillMode = .forwards; anim.isRemovedOnCompletion = false
        bar.add(anim, forKey: "countdown")
    }

    func resetProgressBarFull() {
        progressBarLayer?.removeAllAnimations()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        progressBarLayer?.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); recomputeRects() }

    private func recomputeRects() {
        cardRect = CGRect(
            x: Self.shadowPadX,
            y: Self.shadowPadTop,
            width: bounds.width - Self.shadowPadX * 2,
            height: bounds.height - Self.shadowPadTop - Self.shadowPadBot
        )
        guard let act = actionTitle, cardRect.width > 0 else { return }
        let actSz = (act as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold)])
        let btnW = ceil(actSz.width + 28), btnH: CGFloat = 34
        closeBtnRect = CGRect(x: cardRect.maxX - 34, y: round(cardRect.midY - 12), width: 24, height: 24)
        actionBtnRect = CGRect(x: closeBtnRect.minX - btnW - 8, y: round(cardRect.midY - btnH * 0.5), width: btnW, height: btnH)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        guard hasAction else { return }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true); updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updateHover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) {
        hoveredAction = false; hoveredClose = false; NSCursor.arrow.set(); onHoverChanged?(false)
    }

    private func updateHover(at pt: CGPoint) {
        guard cardRect.contains(pt) else {
            hoveredAction = false; hoveredClose = false; NSCursor.arrow.set(); return
        }
        hoveredClose = closeBtnRect.contains(pt)
        hoveredAction = !hoveredClose
        NSCursor.pointingHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard hasAction else { return }
        let pt = convert(event.locationInWindow, from: nil)
        guard cardRect.contains(pt) else { return }
        if closeBtnRect.contains(pt) { onClose?() } else { onTrigger?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        recomputeRects()
        guard let ctx = NSGraphicsContext.current?.cgContext, cardRect.width > 10 else { return }
        let isDark = GeekTheme.isDark
        let radius: CGFloat = hasAction ? 15.5 : 12.0
        let cardPath = CGPath(roundedRect: cardRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let cardFill = isDark ? NSColor(srgbRed: 0.118, green: 0.130, blue: 0.158, alpha: 0.97) : NSColor.white
        let borderColor = isDark ? NSColor.white.withAlphaComponent(0.14) : NSColor(srgbRed: 0.06, green: 0.10, blue: 0.18, alpha: 0.16)
        let titleColor = isDark ? NSColor(srgbRed: 0.94, green: 0.96, blue: 0.98, alpha: 1.0) : MSnipUITheme.inkPrimary
        let subColor = isDark ? NSColor(srgbRed: 0.65, green: 0.70, blue: 0.77, alpha: 1.0) : MSnipUITheme.inkSecondary
        progressClipLayer?.frame = cardRect

        // 1) 自适应深浅色投影与立体卡片面
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -7),
            blur: 22,
            color: NSColor(srgbRed: 0.02, green: 0.04, blue: 0.10, alpha: isDark ? 0.52 : 0.28).cgColor
        )
        ctx.setFillColor(cardFill.cgColor)
        ctx.addPath(cardPath); ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(borderColor.cgColor); ctx.setLineWidth(1.0)
        ctx.addPath(CGPath(roundedRect: cardRect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.strokePath(); ctx.restoreGState()

        // 2) 左侧：真实截图等比填充微缩略图（带状态小圆章）或实心圆角状态章
        let textX = drawLeadingVisual(in: ctx, cardFill: cardFill, isDark: isDark)

        // 3) 中间主副文案
        let maxTextW = max(40, (hasAction ? actionBtnRect.minX - 14 : cardRect.maxX - 16) - textX)
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingMiddle
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: hasAction ? 14.0 : 13.5, weight: .semibold),
            .foregroundColor: titleColor, .paragraphStyle: para
        ]
        let titleNs = cleanMessage as NSString
        let titleSz = titleNs.size(withAttributes: titleAttrs)
        if let sub = subtitle, !sub.isEmpty {
            let subAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
                .foregroundColor: subColor, .paragraphStyle: para
            ]
            let subNs = sub as NSString
            let subSz = subNs.size(withAttributes: subAttrs)
            let topY = round(cardRect.midY - (titleSz.height + 2 + subSz.height) * 0.5)
            titleNs.draw(in: CGRect(x: textX, y: topY, width: maxTextW, height: titleSz.height + 2), withAttributes: titleAttrs)
            subNs.draw(in: CGRect(x: textX, y: topY + titleSz.height + 2, width: maxTextW, height: subSz.height + 2), withAttributes: subAttrs)
        } else {
            titleNs.draw(in: CGRect(x: textX, y: round(cardRect.midY - titleSz.height * 0.5), width: maxTextW, height: titleSz.height + 2), withAttributes: titleAttrs)
        }

        // 4) 右侧醒目圆角主按钮 + 轻量关闭钮
        if let act = actionTitle {
            MSnipUITheme.drawPrimaryCTA(ctx: ctx, rect: actionBtnRect, radius: 8.5, hovered: hoveredAction)
            let actAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: NSColor.white]
            let actNs = act as NSString
            let actSz = actNs.size(withAttributes: actAttrs)
            actNs.draw(at: CGPoint(x: round(actionBtnRect.midX - actSz.width * 0.5), y: round(actionBtnRect.midY - actSz.height * 0.5)), withAttributes: actAttrs)
            if hoveredClose {
                ctx.setFillColor((isDark ? NSColor.white.withAlphaComponent(0.12) : MSnipUITheme.hoverFill).cgColor)
                ctx.fillEllipse(in: closeBtnRect)
            }
            ToolbarView.drawSymbol("xmark", in: closeBtnRect.insetBy(dx: 6.5, dy: 6.5), alpha: hoveredClose ? 0.92 : 0.52, tint: subColor)
        }
    }

    private func drawLeadingVisual(in ctx: CGContext, cardFill: NSColor, isDark: Bool) -> CGFloat {
        if let cg = preview, cg.width > 0, cg.height > 0 {
            let thumbRect = CGRect(x: cardRect.minX + 13, y: round(cardRect.midY - 20), width: 50, height: 40)
            let thumbPath = CGPath(roundedRect: thumbRect, cornerWidth: 7.0, cornerHeight: 7.0, transform: nil)
            ctx.saveGState()
            ctx.setFillColor((isDark ? NSColor.white.withAlphaComponent(0.06) : MSnipUITheme.subtleFill).cgColor)
            ctx.addPath(thumbPath); ctx.fillPath()
            ctx.addPath(thumbPath); ctx.clip()
            let scale = max(thumbRect.width / CGFloat(cg.width), thumbRect.height / CGFloat(cg.height))
            let dw = CGFloat(cg.width) * scale, dh = CGFloat(cg.height) * scale
            let drawR = CGRect(x: thumbRect.midX - dw * 0.5, y: thumbRect.midY - dh * 0.5, width: dw, height: dh)
            NSImage(cgImage: cg, size: drawR.size).draw(in: drawR, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
            ctx.restoreGState()
            ctx.setStrokeColor((isDark ? NSColor.white.withAlphaComponent(0.16) : MSnipUITheme.borderStrong).cgColor)
            ctx.setLineWidth(1.0); ctx.addPath(thumbPath); ctx.strokePath()

            let dot = CGRect(x: thumbRect.maxX - 9, y: thumbRect.maxY - 9, width: 15, height: 15)
            ctx.setFillColor(cardFill.cgColor); ctx.fillEllipse(in: dot.insetBy(dx: -1.5, dy: -1.5))
            ctx.setFillColor(badgeColor.cgColor); ctx.fillEllipse(in: dot)
            ToolbarView.drawSymbol("checkmark", in: dot.insetBy(dx: 3.2, dy: 3.2), alpha: 1.0, tint: .white)
            return thumbRect.maxX + 14
        }
        if let sw = swatch {
            let swRect = CGRect(x: cardRect.minX + 14, y: round(cardRect.midY - 11), width: 22, height: 22)
            let swPath = CGPath(roundedRect: swRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.setFillColor(sw.cgColor); ctx.addPath(swPath); ctx.fillPath()
            ctx.setStrokeColor((isDark ? NSColor.white.withAlphaComponent(0.22) : MSnipUITheme.borderStrong).cgColor)
            ctx.setLineWidth(1.0); ctx.addPath(swPath); ctx.strokePath()
            return swRect.maxX + 11
        }
        let sz: CGFloat = hasAction ? 32 : 24
        let bRect = CGRect(x: cardRect.minX + 14, y: round(cardRect.midY - sz * 0.5), width: sz, height: sz)
        let bPath = CGPath(roundedRect: bRect, cornerWidth: sz * 0.30, cornerHeight: sz * 0.30, transform: nil)
        ctx.setFillColor(badgeColor.cgColor); ctx.addPath(bPath); ctx.fillPath()
        ToolbarView.drawSymbol(statusSymbol, in: bRect.insetBy(dx: sz * 0.24, dy: sz * 0.24), alpha: 1.0, tint: .white)
        return bRect.maxX + 12
    }

    /// 初始化时一次性降采样为 `100×80 px` 微缩略图，立即释放外部传入的 5K 全屏 `CGImage`（省去 ~60 MB 驻留与 30fps 重缩放开销）
    private static func makeCompactThumb(_ src: CGImage) -> CGImage? {
        guard src.width > 120 || src.height > 96 else { return src }
        let w = 100, h = 80
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return src }
        let sc = max(CGFloat(w) / CGFloat(src.width), CGFloat(h) / CGFloat(src.height))
        let dw = CGFloat(src.width) * sc, dh = CGFloat(src.height) * sc
        ctx.interpolationQuality = .medium
        ctx.draw(src, in: CGRect(x: (CGFloat(w) - dw) * 0.5, y: (CGFloat(h) - dh) * 0.5, width: dw, height: dh))
        return ctx.makeImage() ?? src
    }
}

// MARK: - 全局高优先级悬浮图标提示气泡

/// 专用于全屏覆盖层 / 录屏控制条 / 长截图条 / 贴图悬浮条等高层级非激活面板的轻量提示气泡：
/// 解决 macOS 原生 `NSView.toolTip` 在高层级窗口（`.screenSaver` / `CGShieldingWindowLevel`）被遮挡及非激活态被系统抑制的问题。
@MainActor
enum FloatingTooltipHUD {
    private static var panel: NSPanel?
    private static var bubbleView: TooltipBubbleView?
    private static weak var ownerView: NSView?
    private static var pendingWork: DispatchWorkItem?
    private static var lastVisibleAt: TimeInterval = 0
    private static var currentText: String = ""
    private static var currentAnchor: NSRect = .zero

    static func show(_ text: String?, anchorRectInView: CGRect, of view: NSView) {
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let win = view.window, win.isVisible else {
            hide(for: view)
            return
        }
        let screenAnchor = win.convertToScreen(view.convert(anchorRectInView, to: nil))
        if ownerView === view, currentText == raw,
           (panel?.isVisible == true || pendingWork != nil),
           abs(currentAnchor.midX - screenAnchor.midX) < 1, abs(currentAnchor.midY - screenAnchor.midY) < 1 {
            return
        }
        ownerView = view
        currentText = raw
        currentAnchor = screenAnchor
        pendingWork?.cancel()
        pendingWork = nil

        let now = CACurrentMediaTime()
        let isWarm = (panel?.isVisible == true) || (now - lastVisibleAt < 0.28)
        if isWarm {
            present(text: raw, anchorScreenRect: screenAnchor, animated: panel?.isVisible != true)
        } else {
            let work = DispatchWorkItem { [weak view] in
                MainActor.assumeIsolated {
                    pendingWork = nil
                    guard let view, ownerView === view, view.window?.isVisible == true, !view.isHiddenOrHasHiddenAncestor else { return }
                    present(text: raw, anchorScreenRect: screenAnchor, animated: true)
                }
            }
            pendingWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
        }
    }

    static func hide(for view: NSView) {
        guard ownerView == nil || ownerView === view else { return }
        hideAll()
    }

    static func hideAll() {
        pendingWork?.cancel()
        pendingWork = nil
        if panel?.isVisible == true { lastVisibleAt = CACurrentMediaTime() }
        panel?.orderOut(nil)
        ownerView = nil
        currentText = ""
    }

    private static func present(text: String, anchorScreenRect: NSRect, animated: Bool) {
        let bv = bubbleView ?? TooltipBubbleView()
        bubbleView = bv
        bv.text = text
        let sz = bv.fittingPanelSize
        bv.frame = NSRect(origin: .zero, size: sz)

        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchorScreenRect.midX, y: anchorScreenRect.midY)) })
            ?? NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let pad = TooltipBubbleView.shadowPad
        let gap: CGFloat = 6

        let cardW = sz.width - pad * 2
        let cardH = sz.height - pad * 2
        let idealCardX = round(anchorScreenRect.midX - cardW * 0.5)
        let clampedCardX = min(max(vf.minX + 8, idealCardX), vf.maxX - cardW - 8)
        let aboveCardY = round(anchorScreenRect.maxY + gap)
        let belowCardY = round(anchorScreenRect.minY - gap - cardH)
        let cardY = (aboveCardY + cardH <= vf.maxY - 6) ? aboveCardY : max(vf.minY + 6, belowCardY)
        let frame = NSRect(x: clampedCardX - pad, y: cardY - pad, width: sz.width, height: sz.height)

        let p: NSPanel
        if let existing = panel {
            p = existing
        } else {
            let np = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            np.animationBehavior = .none
            np.isFloatingPanel = true
            // CGShieldingWindowLevel (2147483628) 上方 +2 为光标层、+3 为最大合法层；固定在 +1 确保严格高于全屏覆盖层且不遮挡软件光标
            let safeTipMax = Int(CGWindowLevelForKey(.maximumWindow)) - 2
            np.level = NSWindow.Level(rawValue: min(safeTipMax, max(
                NSWindow.Level.screenSaver.rawValue + 1,
                Int(CGShieldingWindowLevel()) + 1
            )))
            np.hidesOnDeactivate = false
            np.ignoresMouseEvents = true
            np.isOpaque = false
            np.backgroundColor = .clear
            np.hasShadow = false
            np.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            np.contentView = bv
            panel = np
            p = np
        }
        p.setFrame(frame, display: true)
        bv.needsDisplay = true
        if animated && !p.isVisible {
            p.alphaValue = 0.0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.09
                p.animator().alphaValue = 1.0
            }
        } else {
            p.alphaValue = 1.0
            p.orderFrontRegardless()
        }
        lastVisibleAt = CACurrentMediaTime()
    }
}

private final class TooltipBubbleView: NSView {
    static let shadowPad: CGFloat = 8
    private static let padX: CGFloat = 9
    private static let padY: CGFloat = 5
    private static let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)

    var text: String = ""
    override var isFlipped: Bool { true }

    var fittingPanelSize: NSSize {
        let sz = (text as NSString).size(withAttributes: [.font: Self.font])
        let w = min(380, ceil(sz.width) + Self.padX * 2)
        let h = ceil(sz.height) + Self.padY * 2
        return NSSize(width: w + Self.shadowPad * 2, height: h + Self.shadowPad * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !text.isEmpty else { return }
        let r = bounds.insetBy(dx: Self.shadowPad, dy: Self.shadowPad)
        let path = CGPath(roundedRect: r, cornerWidth: 7.5, cornerHeight: 7.5, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 8, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.setFillColor(NSColor(srgbRed: 0.10, green: 0.12, blue: 0.16, alpha: 0.94).cgColor)
        ctx.addPath(path); ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        ctx.setLineWidth(0.75)
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.4, dy: 0.4), cornerWidth: 7.5, cornerHeight: 7.5, transform: nil))
        ctx.strokePath()
        ctx.restoreGState()

        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: NSColor(srgbRed: 0.96, green: 0.97, blue: 0.99, alpha: 1.0),
            .paragraphStyle: para
        ]
        let ns = text as NSString
        let sz = ns.size(withAttributes: attrs)
        let tr = CGRect(x: r.minX + Self.padX, y: round(r.midY - sz.height * 0.5), width: max(10, r.width - Self.padX * 2), height: sz.height + 2)
        ns.draw(in: tr, withAttributes: attrs)
    }
}
