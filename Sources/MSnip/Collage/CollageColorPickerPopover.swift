import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 极客风自绘 Popover 弹出式取色板（2D 饱和度/明度画布 + 360° 色相滑条 + #HEX 输入 + 原生屏幕吸管 + 精选纯色与 5 款渐变，关闭即释放视图树）
@MainActor
final class CollageColorPickerPopover: NSObject, NSPopoverDelegate, NSTextFieldDelegate {
    enum Selection: Equatable {
        case solid(RGBAColor)
        case gradient(CollageGradientPreset)
        case transparent
    }

    static let quickSolids: [(name: String, color: RGBAColor)] = [
        ("纯白", RGBAColor(255, 255, 255)),
        ("柔灰", RGBAColor(244, 246, 250)),
        ("暖米", RGBAColor(250, 245, 237)),
        ("冰雾蓝", RGBAColor(236, 244, 255)),
        ("深灰蓝", RGBAColor(30, 41, 59)),
        ("暗炭", RGBAColor(24, 26, 32)),
        ("纯黑", RGBAColor(0, 0, 0))
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

        let eyeBtn = GeekButton(title: "吸色", symbol: "eyedropper", style: .subtle)
        eyeBtn.frame = NSRect(x: 160, y: 154, width: 64, height: 26)
        eyeBtn.toolTip = "用放大镜从屏幕或截图中吸取任意背景色"
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
