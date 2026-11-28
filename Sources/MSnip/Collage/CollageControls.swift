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
    /// 左侧标题列宽度（较长译文时由外部按最宽标题统一放宽）
    var titleColumnWidth: CGFloat = 34 { didSet { needsDisplay = true } }
    static let titleFont = NSFont.systemFont(ofSize: 11.2, weight: .medium)
    var titleFittingWidth: CGFloat { ceil(GeekTheme.measureTextWidth(title, font: Self.titleFont)) + 6 }

    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    private var dragging = false { didSet { if oldValue != dragging { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(title: String, min: Int, max: Int, value: Int, defaultValue: Int? = nil, unit: String = "px") {
        self.title = title; self.minVal = min; self.maxVal = max
        self.intValue = value; self.defaultVal = defaultValue ?? value; self.unit = unit
        super.init(frame: .zero)
        self.toolTip = L("拖动微调%@，双击恢复默认 (%@%@)", title, self.defaultVal, unit)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var trackRect: CGRect {
        CGRect(x: titleColumnWidth, y: round(bounds.midY - 2.0), width: max(40, bounds.width - titleColumnWidth - 40), height: 4.0)
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
        guard p.x >= titleColumnWidth - 6 && p.x <= bounds.width - 34 else { return }
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
        GeekTheme.drawText(title, in: CGRect(x: 0, y: 0, width: titleColumnWidth - 4, height: bounds.height),
                           font: Self.titleFont, color: GeekTheme.inkSecondary)
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

    /// 完整显示最长一项（选中态粗体）所需的总宽度
    var fittingWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 10.2, weight: .semibold)
        let widest = items.map { GeekTheme.measureTextWidth($0, font: font) + 12 }.max() ?? 0
        return ceil(widest * CGFloat(items.count) + 4 * CGFloat(max(0, items.count - 1)))
    }
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
            label = L("透明底"); useMono = false
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

    var fittingWidth: CGFloat {
        ceil(GeekTheme.measureTextWidth(title, font: .systemFont(ofSize: 10.6, weight: .semibold))) + 7 + 5.5 + 4 + 8
    }
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
        GeekTheme.drawText(L("加图"), in: CGRect(x: 0, y: 29, width: bounds.width, height: 15), font: .systemFont(ofSize: 10.0, weight: .medium), color: tint, align: .center)
        ctx.restoreGState()
    }
}

// MARK: - 自定义背景色盘浮窗

/// 极客风自绘 Popover 弹出式取色板（2D 饱和度/明度画布 + 360° 色相滑条 + #HEX 输入 + 原生屏幕吸管 + 精选纯色与 5 款渐变，关闭即释放视图树）
@MainActor
final class CollageColorPickerPopover: NSObject, NSPopoverDelegate, NSTextFieldDelegate {
    enum Selection: Equatable {
        case solid(RGBAColor)
        case gradient(CollageGradientPreset)
        case transparent
    }

    static let quickSolids: [(name: String, color: RGBAColor)] = [
        (L("纯白"), RGBAColor(255, 255, 255)),
        (L("柔灰"), RGBAColor(244, 246, 250)),
        (L("暖米"), RGBAColor(250, 245, 237)),
        (L("冰雾蓝"), RGBAColor(236, 244, 255)),
        (L("深灰蓝"), RGBAColor(30, 41, 59)),
        (L("暗炭"), RGBAColor(24, 26, 32)),
        (L("纯黑"), RGBAColor(0, 0, 0))
    ]

    private let popover = NSPopover()
    private var svSquare: CollageSVSquareView?
    private var hueBar: CollageHueBarView?
    private var hexField: NSTextField?
    private var presetGrid: CollageSwatchPopoverGrid?

    private var hue: Double = 220
    private var sat: Double = 0.03
    private var val: Double = 0.98
    private var allowsTransparent = true
    private var suppressHexCallback = false
    var onSelect: ((Selection) -> Void)?

    override init() {
        super.init()
        popover.behavior = .semitransient
        popover.animates = true
        popover.delegate = self
    }

    func closeIfShown() {
        if popover.isShown { popover.performClose(nil) }
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        svSquare = nil; hueBar = nil; hexField = nil; presetGrid = nil
    }

    func show(anchoredTo anchor: NSView, options: CollageOptions, allowsTransparent: Bool, onSelect: @escaping (Selection) -> Void) {
        closeIfShown()
        self.allowsTransparent = allowsTransparent
        self.onSelect = onSelect

        let initRGB = options.effectiveSolidColor ?? RGBAColor(244, 246, 250)
        let hsv = ColorCopyFormat.rgbToHSV(r: Int(initRGB.r), g: Int(initRGB.g), b: Int(initRGB.b))
        self.hue = Double(hsv.h); self.sat = Double(hsv.s) / 100.0; self.val = Double(hsv.v) / 100.0

        let W: CGFloat = 236, H: CGFloat = 268
        let root = GeekSurfaceView(frame: NSRect(x: 0, y: 0, width: W, height: H), fill: GeekTheme.cardBg)
        let vc = NSViewController(); vc.view = root
        popover.appearance = GeekTheme.popoverAppearance
        popover.contentSize = NSSize(width: W, height: H)
        popover.contentViewController = vc

        let sv = CollageSVSquareView(frame: NSRect(x: 12, y: 12, width: W - 24, height: 112))
        sv.hue = hue; sv.sat = sat; sv.val = val
        sv.onChange = { [weak self] s, v in self?.applyHSV(h: self?.hue ?? 0, s: s, v: v, updateHex: true) }
        root.addSubview(sv)

        let hb = CollageHueBarView(frame: NSRect(x: 12, y: 132, width: W - 24, height: 14))
        hb.hue = hue
        hb.onChange = { [weak self] h in
            guard let self else { return }
            self.applyHSV(h: h, s: max(self.sat, 0.08), v: max(self.val, 0.15), updateHex: true)
        }
        root.addSubview(hb)

        let hf = NSTextField(frame: .zero)
        hf.delegate = self
        let hexBox = GeekInputBox(frame: NSRect(x: 12, y: 154, width: 142, height: 26), field: hf, placeholder: "#RRGGBB", mono: true)
        hf.stringValue = initRGB.formatted(as: .hex)
        root.addSubview(hexBox)

        let eyeBtn = GeekButton(title: L("吸色"), symbol: "eyedropper", style: .subtle)
        eyeBtn.frame = NSRect(x: 160, y: 154, width: 64, height: 26)
        eyeBtn.toolTip = L("用放大镜从屏幕或截图中吸取任意背景色")
        eyeBtn.onClick = { [weak self] in self?.pickColorFromScreen() }
        root.addSubview(eyeBtn)

        root.addSubview(GeekSurfaceView(frame: NSRect(x: 12, y: 188, width: W - 24, height: 1), fill: GeekTheme.divider))

        let grid = CollageSwatchPopoverGrid(frame: NSRect(x: 12, y: 196, width: W - 24, height: 60), allowsTransparent: allowsTransparent)
        grid.currentSelection = currentSelection(from: options)
        grid.onPick = { [weak self] sel in
            guard let self else { return }
            if case .solid(let c) = sel {
                let cHSV = ColorCopyFormat.rgbToHSV(r: Int(c.r), g: Int(c.g), b: Int(c.b))
                self.hue = Double(cHSV.h); self.sat = Double(cHSV.s) / 100.0; self.val = Double(cHSV.v) / 100.0
                self.svSquare?.hue = self.hue; self.svSquare?.sat = self.sat; self.svSquare?.val = self.val
                self.hueBar?.hue = self.hue
                self.suppressHexCallback = true; self.hexField?.stringValue = c.formatted(as: .hex); self.suppressHexCallback = false
            }
            self.presetGrid?.currentSelection = sel
            self.onSelect?(sel)
        }
        root.addSubview(grid)

        self.svSquare = sv; self.hueBar = hb; self.hexField = hf; self.presetGrid = grid
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minX)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !suppressHexCallback, let f = obj.object as? NSTextField, f === hexField,
              let parsed = RGBAColor.parseColorString(f.stringValue) else { return }
        let hsv = ColorCopyFormat.rgbToHSV(r: Int(parsed.r), g: Int(parsed.g), b: Int(parsed.b))
        applyHSV(h: Double(hsv.h), s: Double(hsv.s) / 100.0, v: Double(hsv.v) / 100.0, updateHex: false)
    }

    private func applyHSV(h: Double, s: Double, v: Double, updateHex: Bool) {
        hue = h; sat = s; val = v
        svSquare?.hue = h; svSquare?.sat = s; svSquare?.val = v
        hueBar?.hue = h
        let rgb = ColorCopyFormat.hsvToRGB(h: h, s: s, v: v)
        if updateHex {
            suppressHexCallback = true; hexField?.stringValue = rgb.formatted(as: .hex); suppressHexCallback = false
        }
        presetGrid?.currentSelection = .solid(rgb)
        onSelect?(.solid(rgb))
    }

    private func pickColorFromScreen() {
        NSColorSampler().show { [weak self] picked in
            guard let srgb = picked?.usingColorSpace(.sRGB) else { return }
            let r = Int((srgb.redComponent * 255).rounded())
            let g = Int((srgb.greenComponent * 255).rounded())
            let b = Int((srgb.blueComponent * 255).rounded())
            let hsv = ColorCopyFormat.rgbToHSV(r: min(255, max(0, r)), g: min(255, max(0, g)), b: min(255, max(0, b)))
            Task { @MainActor [weak self] in
                self?.applyHSV(h: Double(hsv.h), s: Double(hsv.s) / 100.0, v: Double(hsv.v) / 100.0, updateHex: true)
            }
        }
    }

    private func currentSelection(from opts: CollageOptions) -> Selection {
        if opts.background == .transparent { return .transparent }
        if opts.background == .gradient { return .gradient(opts.gradientPreset) }
        return .solid(opts.effectiveSolidColor ?? RGBAColor(244, 246, 250))
    }
}

/// 2D 饱和度 × 明度拾色画布
private final class CollageSVSquareView: NSView {
    var hue: Double = 220 { didSet { needsDisplay = true } }
    var sat: Double = 0.5 { didSet { needsDisplay = true } }
    var val: Double = 0.9 { didSet { needsDisplay = true } }
    var onChange: ((Double, Double) -> Void)?
    override var isFlipped: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) { handlePoint(convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { handlePoint(convert(event.locationInWindow, from: nil)) }

    private func handlePoint(_ p: CGPoint) {
        let s = Double(min(1, max(0, p.x / max(1, bounds.width))))
        let v = Double(1.0 - min(1, max(0, p.y / max(1, bounds.height))))
        onChange?(s, v)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: r, cornerWidth: 7.5, cornerHeight: 7.5, transform: nil)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let pure = ColorCopyFormat.hsvToRGB(h: hue, s: 1.0, v: 1.0)

        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        if let gH = CGGradient(colorsSpace: cs, colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), pure.cgColor] as CFArray, locations: [0, 1]),
           let gV = CGGradient(colorsSpace: cs, colors: [CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0), CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gH, start: CGPoint(x: r.minX, y: r.midY), end: CGPoint(x: r.maxX, y: r.midY), options: [])
            ctx.drawLinearGradient(gV, start: CGPoint(x: r.midX, y: r.minY), end: CGPoint(x: r.midX, y: r.maxY), options: [])
        }
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(GeekTheme.border.cgColor); ctx.setLineWidth(1.0); ctx.addPath(path); ctx.strokePath()
        let kx = r.minX + CGFloat(sat) * r.width, ky = r.minY + CGFloat(1.0 - val) * r.height
        let ring = CGRect(x: kx - 6, y: ky - 6, width: 12, height: 12)
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2.5, color: NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(2.0); ctx.strokeEllipse(in: ring)
        ctx.restoreGState()
    }
}

/// 360° 全彩光谱色相滑条
private final class CollageHueBarView: NSView {
    var hue: Double = 220 { didSet { needsDisplay = true } }
    var onChange: ((Double) -> Void)?
    override var isFlipped: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseDown(with event: NSEvent) { update(at: convert(event.locationInWindow, from: nil).x) }
    override func mouseDragged(with event: NSEvent) { update(at: convert(event.locationInWindow, from: nil).x) }
    private func update(at x: CGFloat) { onChange?(Double(min(1, max(0, x / max(1, bounds.width)))) * 360.0) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 0.5, dy: 2.0)
        let p = CGPath(roundedRect: r, cornerWidth: r.height * 0.5, cornerHeight: r.height * 0.5, transform: nil)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let stops: [CGColor] = stride(from: 0.0, through: 360.0, by: 60.0).map { ColorCopyFormat.hsvToRGB(h: $0, s: 1, v: 1).cgColor }
        ctx.saveGState()
        ctx.addPath(p); ctx.clip()
        if let g = CGGradient(colorsSpace: cs, colors: stops as CFArray, locations: [0, 1/6.0, 2/6.0, 3/6.0, 4/6.0, 5/6.0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: r.minX, y: r.midY), end: CGPoint(x: r.maxX, y: r.midY), options: [])
        }
        ctx.restoreGState()
        let kx = r.minX + CGFloat(min(1, max(0, hue / 360.0))) * r.width
        let knob = CGRect(x: kx - 6, y: round(bounds.midY - 6), width: 12, height: 12)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.setFillColor(NSColor.white.cgColor); ctx.fillEllipse(in: knob)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.22).cgColor); ctx.setLineWidth(0.8); ctx.strokeEllipse(in: knob)
        ctx.restoreGState()
    }
}

/// 气泡底部双行快捷格（第 1 行：透明 + 7 精选纯色圆点；第 2 行：5 款工作室渐变胶囊）
private final class CollageSwatchPopoverGrid: NSView {
    let allowsTransparent: Bool
    var currentSelection: CollageColorPickerPopover.Selection = .solid(RGBAColor(244, 246, 250)) { didSet { needsDisplay = true } }
    var onPick: ((CollageColorPickerPopover.Selection) -> Void)?
    override var isFlipped: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    init(frame: NSRect, allowsTransparent: Bool) { self.allowsTransparent = allowsTransparent; super.init(frame: frame) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var row1Items: [CollageColorPickerPopover.Selection] {
        var list = CollageColorPickerPopover.quickSolids.map { CollageColorPickerPopover.Selection.solid($0.color) }
        if allowsTransparent { list.insert(.transparent, at: 0) }
        return list
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if p.y < 28 {
            let items = row1Items
            let idx = min(items.count - 1, max(0, Int(p.x / (bounds.width / CGFloat(items.count)))))
            onPick?(items[idx])
        } else if p.y >= 32 {
            let grads = CollageGradientPreset.allCases
            let idx = min(grads.count - 1, max(0, Int(p.x / (bounds.width / CGFloat(grads.count)))))
            onPick?(.gradient(grads[idx]))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let items = row1Items, step1 = bounds.width / CGFloat(items.count)
        for (i, sel) in items.enumerated() {
            let dot = CGRect(x: round(CGFloat(i) * step1 + step1 * 0.5 - 9), y: 3, width: 18, height: 18)
            ctx.saveGState(); ctx.addEllipse(in: dot); ctx.clip()
            if case .transparent = sel {
                ctx.setFillColor(NSColor.white.cgColor); ctx.fill(dot)
                ctx.setFillColor(NSColor(white: 0.72, alpha: 1).cgColor)
                ctx.fill(CGRect(x: dot.minX, y: dot.minY, width: 9, height: 9)); ctx.fill(CGRect(x: dot.midX, y: dot.midY, width: 9, height: 9))
            } else if case .solid(let c) = sel {
                ctx.setFillColor(c.cgColor); ctx.fill(dot)
            }
            ctx.restoreGState()
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.20).cgColor); ctx.setLineWidth(0.75); ctx.strokeEllipse(in: dot)
            if sel == currentSelection {
                ctx.setStrokeColor(GeekTheme.accent.cgColor); ctx.setLineWidth(1.6); ctx.strokeEllipse(in: dot.insetBy(dx: -2.5, dy: -2.5))
            }
        }

        let grads = CollageGradientPreset.allCases, gap: CGFloat = 5
        let gw = (bounds.width - gap * CGFloat(grads.count - 1)) / CGFloat(grads.count)
        for (i, g) in grads.enumerated() {
            let r = CGRect(x: CGFloat(i) * (gw + gap), y: 34, width: gw, height: 22)
            let p = CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.saveGState(); ctx.addPath(p); ctx.clip()
            CollageOverlaysRenderer.drawGradient(g, in: r, ctx: ctx, topLeftToBottomRightInBottomUpCG: false)
            ctx.restoreGState()
            let active = (currentSelection == .gradient(g))
            ctx.setStrokeColor((active ? GeekTheme.accent : GeekTheme.border).cgColor)
            ctx.setLineWidth(active ? 1.8 : 0.8); ctx.addPath(p); ctx.strokePath()
        }
    }
}
