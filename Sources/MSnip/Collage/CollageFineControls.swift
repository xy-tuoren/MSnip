import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 极细轨道自绘滑条行（4pt 圆角进度轨 + 12pt 悬浮白玉旋钮 + 双击恢复默认值，告别原生 NSSlider 突兀感）
final class CollageFineSliderRow: NSView {
    let title: String
    let minVal: Int
    let maxVal: Int
    let defaultVal: Int
    let unit: String
    var intValue: Int { didSet { if oldValue != intValue { needsDisplay = true } } }
    var onChange: ((Int) -> Void)?

    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    private var dragging = false { didSet { if oldValue != dragging { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(title: String, min: Int, max: Int, value: Int, defaultValue: Int? = nil, unit: String = "px") {
        self.title = title; self.minVal = min; self.maxVal = max
        self.intValue = value; self.defaultVal = defaultValue ?? value; self.unit = unit
        super.init(frame: .zero)
        self.toolTip = "拖动微调\(title)，双击恢复默认 (\(self.defaultVal)\(unit))"
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var trackRect: CGRect {
        CGRect(x: 34, y: round(bounds.midY - 2.0), width: max(40, bounds.width - 74), height: 4.0)
    }

    override func resetCursorRects() { addCursorRect(trackRect.insetBy(dx: -6, dy: -8), cursor: .pointingHand) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            intValue = defaultVal; onChange?(intValue); return
        }
        let p = convert(event.locationInWindow, from: nil)
        guard p.x >= 28 && p.x <= bounds.width - 34 else { return }
        dragging = true; updateValue(atX: p.x)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        updateValue(atX: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) { dragging = false }

    private func updateValue(atX x: CGFloat) {
        let tr = trackRect
        let t = min(1.0, max(0.0, (x - tr.minX) / max(1.0, tr.width)))
        let next = minVal + Int((Double(maxVal - minVal) * Double(t)).rounded())
        if next != intValue { intValue = next; onChange?(next) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        GeekTheme.drawText(title, in: CGRect(x: 0, y: 0, width: 30, height: bounds.height),
                           font: .systemFont(ofSize: 11.2, weight: .medium), color: GeekTheme.inkSecondary)
        GeekTheme.drawText("\(intValue)\(unit)", in: CGRect(x: bounds.width - 36, y: 0, width: 36, height: bounds.height),
                           font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold), color: GeekTheme.inkPrimary, align: .right)

        let tr = trackRect
        let t = CGFloat(intValue - minVal) / CGFloat(max(1, maxVal - minVal))
        let knobX = round(tr.minX + tr.width * min(1, max(0, t)))

        ctx.saveGState()
        let bgPath = CGPath(roundedRect: tr, cornerWidth: 2, cornerHeight: 2, transform: nil)
        ctx.setFillColor((GeekTheme.isDark ? NSColor(white: 1, alpha: 0.11) : NSColor(white: 0, alpha: 0.09)).cgColor)
        ctx.addPath(bgPath); ctx.fillPath()

        if knobX > tr.minX + 1 {
            let fp = CGPath(roundedRect: CGRect(x: tr.minX, y: tr.minY, width: knobX - tr.minX, height: tr.height), cornerWidth: 2, cornerHeight: 2, transform: nil)
            ctx.setFillColor(GeekTheme.accent.cgColor); ctx.addPath(fp); ctx.fillPath()
        }

        let r: CGFloat = (hovered || dragging) ? 6.5 : 5.5
        let knobRect = CGRect(x: knobX - r, y: round(bounds.midY - r), width: r * 2, height: r * 2)
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2.5, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.setFillColor(NSColor.white.cgColor); ctx.fillEllipse(in: knobRect)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setStrokeColor((dragging ? GeekTheme.accent : NSColor.black.withAlphaComponent(0.18)).cgColor)
        ctx.setLineWidth(dragging ? 1.5 : 0.7); ctx.strokeEllipse(in: knobRect)
        ctx.restoreGState()
    }
}

/// 标题行内联轻量预设胶囊组（紧贴 / 标准 / 展示）
final class CollageInlinePresetBar: NSView {
    var items: [String]
    var selectedIndex: Int = 1 { didSet { if oldValue != selectedIndex { needsDisplay = true } } }
    var onSelect: ((Int) -> Void)?
    private var hoveredIdx: Int? { didSet { if oldValue != hoveredIdx { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(items: [String], selectedIndex: Int = 1) { self.items = items; self.selectedIndex = selectedIndex; super.init(frame: .zero) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard !items.isEmpty else { return }
        let x = convert(event.locationInWindow, from: nil).x
        hoveredIdx = min(items.count - 1, max(0, Int(x / (bounds.width / CGFloat(items.count)))))
    }
    override func mouseExited(with event: NSEvent) { hoveredIdx = nil }

    override func mouseDown(with event: NSEvent) {
        guard !items.isEmpty else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let idx = min(items.count - 1, max(0, Int(x / (bounds.width / CGFloat(items.count)))))
        selectedIndex = idx; onSelect?(idx)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !items.isEmpty else { return }
        let gap: CGFloat = 4, w = (bounds.width - gap * CGFloat(items.count - 1)) / CGFloat(items.count)
        for (i, title) in items.enumerated() {
            let r = CGRect(x: CGFloat(i) * (w + gap), y: 0.5, width: w, height: bounds.height - 1)
            let p = CGPath(roundedRect: r, cornerWidth: r.height * 0.46, cornerHeight: r.height * 0.46, transform: nil)
            let active = (i == selectedIndex)
            ctx.saveGState()
            if active {
                ctx.setFillColor(GeekTheme.accentSoft.cgColor); ctx.addPath(p); ctx.fillPath()
                ctx.setStrokeColor(GeekTheme.accent.withAlphaComponent(0.55).cgColor); ctx.setLineWidth(0.9); ctx.addPath(p); ctx.strokePath()
            } else if hoveredIdx == i {
                ctx.setFillColor(GeekTheme.hoverSoft.cgColor); ctx.addPath(p); ctx.fillPath()
            }
            GeekTheme.drawText(title, in: r, font: .systemFont(ofSize: 10.2, weight: active ? .semibold : .medium),
                               color: active ? GeekTheme.accent : GeekTheme.inkMuted, align: .center)
            ctx.restoreGState()
        }
    }
}

/// 底色取色板弹出触发胶囊（展示实时色块 / 渐变 / 透明棋盘格 + `#HEX` 或渐变名 + 下拉微箭头）
final class CollageBgTriggerPill: NSView {
    var style: CollageBackgroundStyle = .lightGray { didSet { needsDisplay = true } }
    var customColor: RGBAColor? { didSet { needsDisplay = true } }
    var gradientPreset: CollageGradientPreset = .aurora { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = CGPath(roundedRect: r, cornerWidth: 6.5, cornerHeight: 6.5, transform: nil)
        ctx.saveGState()
        ctx.setFillColor((hovered ? GeekTheme.controlHover : GeekTheme.controlBg).cgColor)
        ctx.addPath(p); ctx.fillPath()
        ctx.setStrokeColor((hovered ? GeekTheme.borderStrong : GeekTheme.border).cgColor)
        ctx.setLineWidth(1.0); ctx.addPath(p); ctx.strokePath()

        let sw = CGRect(x: r.minX + 5.5, y: round(r.midY - 6.5), width: 13, height: 13)
        let swP = CGPath(roundedRect: sw, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
        ctx.saveGState(); ctx.addPath(swP); ctx.clip()
        let label: String
        let useMono: Bool
        switch style {
        case .transparent:
            ctx.setFillColor(NSColor.white.cgColor); ctx.fill(sw)
            ctx.setFillColor(NSColor(white: 0.72, alpha: 1).cgColor)
            ctx.fill(CGRect(x: sw.minX, y: sw.minY, width: 6.5, height: 6.5))
            ctx.fill(CGRect(x: sw.midX, y: sw.midY, width: 6.5, height: 6.5))
            label = "透明底"; useMono = false
        case .gradient:
            CollageOverlaysRenderer.drawGradient(gradientPreset, in: sw, ctx: ctx, topLeftToBottomRightInBottomUpCG: false)
            label = gradientPreset.title; useMono = false
        default:
            let c = customColor ?? style.rgbaColor ?? RGBAColor(244, 246, 250)
            ctx.setFillColor(c.cgColor); ctx.fill(sw)
            label = c.formatted(as: .hex); useMono = true
        }
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.22).cgColor); ctx.setLineWidth(0.6); ctx.addPath(swP); ctx.strokePath()

        let font: NSFont = useMono ? .monospacedSystemFont(ofSize: 10.2, weight: .medium) : .systemFont(ofSize: 10.5, weight: .medium)
        GeekTheme.drawText(label, in: CGRect(x: sw.maxX + 5, y: 0, width: r.maxX - sw.maxX - 18, height: bounds.height), font: font, color: GeekTheme.inkPrimary)

        ctx.setStrokeColor((hovered ? GeekTheme.inkPrimary : GeekTheme.inkSecondary).cgColor)
        ctx.setLineWidth(1.25); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        let cx = bounds.width - 9.5, cy = bounds.midY
        ctx.move(to: CGPoint(x: cx - 2.6, y: cy - 1.3))
        ctx.addLine(to: CGPoint(x: cx, y: cy + 1.4))
        ctx.addLine(to: CGPoint(x: cx + 2.6, y: cy - 1.3))
        ctx.strokePath()
        ctx.restoreGState()
    }
}

/// 轻量胶囊开关（如「柔影」）
final class CollageMiniTogglePill: NSView {
    var title: String
    var isOn: Bool { didSet { if oldValue != isOn { needsDisplay = true } } }
    var onToggle: ((Bool) -> Void)?
    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(title: String, isOn: Bool) { self.title = title; self.isOn = isOn; super.init(frame: .zero) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { isOn.toggle(); onToggle?(isOn) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = CGPath(roundedRect: r, cornerWidth: r.height * 0.48, cornerHeight: r.height * 0.48, transform: nil)
        ctx.saveGState()
        ctx.setFillColor((isOn ? GeekTheme.accentSoft : (hovered ? GeekTheme.hoverSoft : GeekTheme.segTrackBg)).cgColor)
        ctx.addPath(p); ctx.fillPath()
        ctx.setStrokeColor((isOn ? GeekTheme.accent.withAlphaComponent(0.55) : GeekTheme.border).cgColor)
        ctx.setLineWidth(0.9); ctx.addPath(p); ctx.strokePath()
        let dotR = CGRect(x: r.minX + 7, y: round(r.midY - 2.75), width: 5.5, height: 5.5)
        ctx.setFillColor((isOn ? GeekTheme.accent : GeekTheme.inactiveDot).cgColor); ctx.fillEllipse(in: dotR)
        GeekTheme.drawText(title, in: CGRect(x: dotR.maxX + 4, y: 0, width: r.maxX - dotR.maxX - 7, height: bounds.height),
                           font: .systemFont(ofSize: 10.6, weight: isOn ? .semibold : .medium),
                           color: isOn ? GeekTheme.accent : GeekTheme.inkSecondary)
        ctx.restoreGState()
    }
}

/// 素材条末尾虚线「+ 加图」卡片
final class CollageAddTileView: NSView {
    var onClick: (() -> Void)?
    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 1, dy: 1), p = CGPath(roundedRect: r, cornerWidth: 7.5, cornerHeight: 7.5, transform: nil)
        ctx.saveGState()
        ctx.setFillColor((hovered ? GeekTheme.hoverSoft : GeekTheme.segTrackBg).cgColor); ctx.addPath(p); ctx.fillPath()
        ctx.setStrokeColor((hovered ? GeekTheme.accent : GeekTheme.borderStrong).cgColor)
        ctx.setLineWidth(1.0); ctx.setLineDash(phase: 0, lengths: [3.5, 2.5]); ctx.addPath(p); ctx.strokePath()
        let tint = hovered ? GeekTheme.accent : GeekTheme.inkSecondary
        GeekTheme.drawSymbol("plus", pointSize: 13.5, weight: .semibold, in: CGRect(x: 0, y: 9, width: bounds.width, height: 18), alpha: 0.92, tint: tint)
        GeekTheme.drawText("加图", in: CGRect(x: 0, y: 29, width: bounds.width, height: 15), font: .systemFont(ofSize: 10.0, weight: .medium), color: tint, align: .center)
        ctx.restoreGState()
    }
}
