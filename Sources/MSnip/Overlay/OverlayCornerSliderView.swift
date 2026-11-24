import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 选区右侧滑块模式（圆角比例 / 发光边强度）
enum OverlaySideSliderMode: Equatable {
    case corner
    case glow
}

/// 选区右侧进度条悬浮胶囊（供圆角比例与发光边强度共用：支持点击跳转、丝滑拖拽 0%~100%、滚轮微调与一键归零）
final class OverlayCornerSliderView: NSView {
    var mode: OverlaySideSliderMode = .corner { didSet { needsDisplay = true } }
    var ratio: CGFloat = 0 {
        didSet {
            let clamped = min(1.0, max(0.0, ratio))
            if abs(ratio - clamped) > 0.0001 {
                ratio = clamped
            }
            needsDisplay = true
        }
    }

    var onRatioChanged: ((CGFloat) -> Void)?
    private var isDraggingThumb = false { didSet { needsDisplay = true } }
    private var hoveredReset = false { didSet { needsDisplay = true } }
    private var hoveredTrack = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    static let barSize = NSSize(width: 178, height: 32)
    private let trackMinX: CGFloat = 13
    private let trackMaxX: CGFloat = 113

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.barSize))
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor(srgbRed: 0.04, green: 0.08, blue: 0.16, alpha: 1.0).cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: 3)
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

    private var resetRect: CGRect {
        CGRect(x: bounds.width - 25, y: 5, width: 21, height: 22)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        NSCursor.pointingHand.set()
        hoveredReset = resetRect.contains(p)
        hoveredTrack = !hoveredReset && bounds.contains(p)
        if mode == .glow {
            toolTip = hoveredReset ? "关闭发光边 (0%)" : "左右拖拽或滚轮调节发光边强度（0%–100%）"
        } else {
            toolTip = hoveredReset ? "归零圆角 (0%)" : "左右拖拽或滚轮调节圆角比例（100% 为胶囊/正圆）"
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredReset = false
        hoveredTrack = false
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if resetRect.contains(p) {
            applyNewRatio(0)
            return
        }
        isDraggingThumb = true
        updateRatio(atX: p.x)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingThumb else { return }
        let p = convert(event.locationInWindow, from: nil)
        updateRatio(atX: p.x)
    }

    override func mouseUp(with event: NSEvent) {
        isDraggingThumb = false
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? (-event.scrollingDeltaY * 0.004) : (event.scrollingDeltaY > 0 ? 0.02 : -0.02)
        guard abs(delta) > 0.0005 else { return }
        applyNewRatio(min(1.0, max(0.0, ratio + delta)))
    }

    private func updateRatio(atX x: CGFloat) {
        let span = max(1, trackMaxX - trackMinX)
        var raw = (x - trackMinX) / span
        if raw < 0.02 { raw = 0.0 }
        else if raw > 0.98 { raw = 1.0 }
        applyNewRatio(min(1.0, max(0.0, raw)))
    }

    private func applyNewRatio(_ next: CGFloat) {
        ratio = next
        onRatioChanged?(next)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        MSnipUITheme.drawPorcelainBar(ctx: ctx, bounds: bounds, radius: 9.0)

        let cy = bounds.height * 0.5
        let trackH: CGFloat = 5.0
        let trackW = trackMaxX - trackMinX
        let trackRect = CGRect(x: trackMinX, y: round(cy - trackH * 0.5), width: trackW, height: trackH)

        // 1) 进度槽底轨
        ctx.saveGState()
        let bgTrack = CGPath(roundedRect: trackRect, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
        ctx.setFillColor(MSnipUITheme.sidebarBg.cgColor)
        ctx.addPath(bgTrack)
        ctx.fillPath()
        ctx.setStrokeColor(MSnipUITheme.borderHairline.cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(bgTrack)
        ctx.strokePath()

        // 2) 已填充蓝色圆角比例进度条
        let fillW = max(0, min(trackW, trackW * ratio))
        if fillW > 1.0 {
            let fillRect = CGRect(x: trackMinX, y: trackRect.minY, width: fillW, height: trackH)
            ctx.setFillColor(MSnipUITheme.accent.cgColor)
            ctx.addPath(CGPath(roundedRect: fillRect, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
            ctx.fillPath()
        }

        // 3) 白色立体圆形滑块手柄
        let thumbR: CGFloat = (isDraggingThumb || hoveredTrack) ? 7.5 : 6.5
        let thumbX = trackMinX + fillW
        let thumbRect = CGRect(x: thumbX - thumbR, y: cy - thumbR, width: thumbR * 2, height: thumbR * 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 3.0, color: NSColor.black.withAlphaComponent(0.20).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: thumbRect)
        ctx.restoreGState()

        ctx.setStrokeColor(MSnipUITheme.accent.cgColor)
        ctx.setLineWidth(2.0)
        ctx.strokeEllipse(in: thumbRect.insetBy(dx: 0.5, dy: 0.5))

        // 4) 百分比数字读数
        let pct = Int((ratio * 100).rounded())
        let pctStr = "\(pct)%" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: pct > 0 ? MSnipUITheme.accent : MSnipUITheme.inkSecondary
        ]
        let sz = pctStr.size(withAttributes: attrs)
        pctStr.draw(
            at: CGPoint(x: round(trackMaxX + 7), y: round(cy - sz.height * 0.5)),
            withAttributes: attrs
        )

        // 5) 右端一键归零微按钮
        if hoveredReset {
            ToolbarView.drawButtonBg(ctx: ctx, rect: resetRect, active: false, hovered: true)
        }
        ToolbarView.drawSymbol(
            "arrow.counterclockwise",
            in: resetRect,
            alpha: ratio > 0.005 ? 0.90 : 0.35,
            tint: MSnipUITheme.inkSecondary
        )
        ctx.restoreGState()
    }
}

extension OverlayView {
    func setupFloatingControls(initialColorIndex: Int, initialLineWidth: CGFloat, pinHint: String) {
        toolbar.colorIndex = initialColorIndex
        toolbar.lineWidth = initialLineWidth
        toolbar.pinHint = pinHint
        toolbar.isHidden = true
        toolbar.onAction = { [weak self] action in self?.handleToolbarAction(action) }
        toolbar.onDraggedOrigin = { [weak self] origin in
            self?.manualToolbarOrigin = origin
            self?.repositionSubbar()
        }

        subbar.colorIndex = initialColorIndex
        subbar.lineWidth = initialLineWidth
        subbar.isHidden = true
        subbar.onAction = { [weak self] action in self?.handleToolbarAction(action) }

        sidePills.isHidden = true
        sidePills.onAction = { [weak self] act in
            guard let self else { return }
            switch act {
            case .cycleCorner(let opt): self.toggleCornerRadiusSlider(resetOnly: opt)
            case .toggleGlow(let opt):  self.toggleGlowSlider(resetOnly: opt)
            case .snapWindow(let opt):
                if opt { self.captureCurrentWindowAndFinish(pin: false) }
                else { self.snapSelectionToUnderlyingWindow() }
            }
        }
        sidePills.onScrollAdjust = { [weak self] slotIdx, delta in
            guard let self else { return }
            if slotIdx == 0 {
                if self.selection == nil, let snap = self.hoveredAutoRect { self.selection = snap }
                self.activeSideSlider = .corner
                self.cornerRadiusRatio = min(1.0, max(0.0, self.cornerRadiusRatio + delta))
                self.updateToolbarLayout()
            } else if slotIdx == 1 {
                if self.selection == nil, let snap = self.hoveredAutoRect { self.selection = snap }
                self.activeSideSlider = .glow
                let base = self.didAdjustGlow ? self.glowStrength : self.defaultPinGlowStrength
                self.applyGlowStrength(min(1.0, max(0.0, base + delta)))
                self.updateToolbarLayout()
            }
        }

        cornerSlider.isHidden = true
        cornerSlider.onRatioChanged = { [weak self] r in
            guard let self else { return }
            if self.activeSideSlider == .glow { self.applyGlowStrength(r) }
            else { self.cornerRadiusRatio = r }
        }

        saveMenu.isHidden = true
        saveMenu.onChoice = { [weak self] choice in
            guard let self else { return }
            self.isSaveMenuVisible = false
            self.updateToolbarLayout()
            switch choice {
            case .folder(let dir): self.exportAndFinish(mode: .saveToFolder(dir))
            case .saveAsPanel:     self.exportAndFinish(mode: .save)
            }
        }

        caliperView.ownerOverlay = self
        caliperView.frame = bounds
        magnifierView.ownerOverlay = self

        addSubview(sidePills)
        addSubview(cornerSlider)
        addSubview(toolbar)
        addSubview(subbar)
        addSubview(saveMenu)
        addSubview(caliperView)
        addSubview(magnifierView)
    }

    func toggleCornerRadiusSlider(resetOnly: Bool = false) {
        if selection == nil, let snap = hoveredAutoRect { selection = snap }
        if resetOnly { cornerRadiusRatio = 0; if activeSideSlider == .corner { activeSideSlider = nil }; updateToolbarLayout(); return }
        if activeSideSlider != .corner { activeSideSlider = .corner; if cornerRadiusRatio < 0.01 { cornerRadiusRatio = 0.16 } }
        else { activeSideSlider = nil }
        updateToolbarLayout()
    }

    func toggleGlowSlider(resetOnly: Bool = false) {
        if selection == nil, let snap = hoveredAutoRect { selection = snap }
        if resetOnly { applyGlowStrength(0); if activeSideSlider == .glow { activeSideSlider = nil }; updateToolbarLayout(); return }
        if activeSideSlider != .glow {
            activeSideSlider = .glow
            if !didAdjustGlow && glowStrength < 0.01 { applyGlowStrength(max(0.20, defaultPinGlowStrength)) }
        } else { activeSideSlider = nil }
        updateToolbarLayout()
    }

    func applyGlowStrength(_ raw: CGFloat) {
        let clamped = min(1.0, max(0.0, raw))
        didAdjustGlow = true; glowStrength = clamped; defaultPinGlowStrength = clamped
        onGlowStrengthChanged?(clamped)
    }
}
