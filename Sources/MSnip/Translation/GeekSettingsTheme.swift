import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 设置中心双模动态设计令牌（暗黑 Carbon Dark / 明亮 Daylight Porcelain，随外观实时零闪烁切换）
enum GeekTheme {
    @MainActor static var currentMode: AppAppearanceMode = .dark

    @MainActor static var isDark: Bool {
        switch currentMode {
        case .dark:   return true
        case .light:  return false
        case .system: return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    @MainActor static var windowAppearance: NSAppearance? {
        switch currentMode {
        case .dark:   return NSAppearance(named: .darkAqua)
        case .light:  return NSAppearance(named: .aqua)
        case .system: return nil
        }
    }

    @MainActor static var popoverAppearance: NSAppearance? {
        NSAppearance(named: isDark ? .darkAqua : .aqua)
    }

    static func resolvedCGColor(_ color: NSColor, for view: NSView) -> CGColor {
        var resolved = color.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        return resolved
    }

    private static func dyn(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { app in
            app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static let windowBg     = dyn(dark: NSColor(srgbRed: 0.067, green: 0.075, blue: 0.090, alpha: 1.0), light: NSColor(srgbRed: 0.953, green: 0.961, blue: 0.976, alpha: 1.0))
    static let barBg        = dyn(dark: NSColor(srgbRed: 0.082, green: 0.094, blue: 0.118, alpha: 1.0), light: NSColor(srgbRed: 0.980, green: 0.984, blue: 0.992, alpha: 1.0))
    static let cardBg       = dyn(dark: NSColor(srgbRed: 0.106, green: 0.122, blue: 0.149, alpha: 1.0), light: NSColor.white)
    static let controlBg    = dyn(dark: NSColor(srgbRed: 0.145, green: 0.165, blue: 0.204, alpha: 1.0), light: NSColor(srgbRed: 0.984, green: 0.988, blue: 0.996, alpha: 1.0))
    static let controlHover = dyn(dark: NSColor(srgbRed: 0.188, green: 0.216, blue: 0.267, alpha: 1.0), light: NSColor(srgbRed: 0.937, green: 0.949, blue: 0.973, alpha: 1.0))
    static let segTrackBg   = dyn(dark: NSColor(srgbRed: 0.075, green: 0.086, blue: 0.106, alpha: 1.0), light: NSColor(srgbRed: 0.933, green: 0.945, blue: 0.965, alpha: 1.0))
    static let segActiveBg  = dyn(dark: NSColor(srgbRed: 0.192, green: 0.220, blue: 0.275, alpha: 1.0), light: NSColor.white)
    static let switchOffBg  = dyn(dark: NSColor(srgbRed: 0.173, green: 0.196, blue: 0.239, alpha: 1.0), light: NSColor(srgbRed: 0.847, green: 0.871, blue: 0.906, alpha: 1.0))
    static let inputBg      = dyn(dark: NSColor(srgbRed: 0.075, green: 0.086, blue: 0.106, alpha: 1.0), light: NSColor(srgbRed: 0.961, green: 0.969, blue: 0.980, alpha: 1.0))
    static let hoverSoft    = dyn(dark: NSColor(white: 1.0, alpha: 0.045), light: NSColor(white: 0.0, alpha: 0.036))
    static let pillSubtle   = dyn(dark: NSColor(white: 1.0, alpha: 0.055), light: NSColor(white: 0.0, alpha: 0.048))
    static let inactiveDot  = dyn(dark: NSColor(white: 1.0, alpha: 0.160), light: NSColor(white: 0.0, alpha: 0.180))
    static let border       = dyn(dark: NSColor(white: 1.0, alpha: 0.080), light: NSColor(srgbRed: 0.06, green: 0.10, blue: 0.18, alpha: 0.095))
    static let borderStrong = dyn(dark: NSColor(white: 1.0, alpha: 0.160), light: NSColor(srgbRed: 0.06, green: 0.10, blue: 0.18, alpha: 0.165))
    static let divider      = dyn(dark: NSColor(white: 1.0, alpha: 0.060), light: NSColor(srgbRed: 0.06, green: 0.10, blue: 0.18, alpha: 0.065))
    static let softShadow   = dyn(dark: NSColor.black.withAlphaComponent(0.30), light: NSColor(srgbRed: 0.06, green: 0.10, blue: 0.18, alpha: 0.09))

    static let inkPrimary   = dyn(dark: NSColor(srgbRed: 0.949, green: 0.961, blue: 0.980, alpha: 1.0), light: NSColor(srgbRed: 0.078, green: 0.098, blue: 0.137, alpha: 1.0))
    static let inkSecondary = dyn(dark: NSColor(srgbRed: 0.624, green: 0.671, blue: 0.749, alpha: 1.0), light: NSColor(srgbRed: 0.318, green: 0.357, blue: 0.427, alpha: 1.0))
    static let inkMuted     = dyn(dark: NSColor(srgbRed: 0.443, green: 0.490, blue: 0.569, alpha: 1.0), light: NSColor(srgbRed: 0.475, green: 0.514, blue: 0.584, alpha: 1.0))

    static let accent       = dyn(dark: NSColor(srgbRed: 0.310, green: 0.565, blue: 1.000, alpha: 1.0), light: NSColor(srgbRed: 0.047, green: 0.431, blue: 0.953, alpha: 1.0))
    static let accentSoft   = dyn(dark: NSColor(srgbRed: 0.310, green: 0.565, blue: 1.000, alpha: 0.16), light: NSColor(srgbRed: 0.047, green: 0.431, blue: 0.953, alpha: 0.13))
    static let emerald      = dyn(dark: NSColor(srgbRed: 0.204, green: 0.827, blue: 0.600, alpha: 1.0), light: NSColor(srgbRed: 0.051, green: 0.580, blue: 0.408, alpha: 1.0))
    static let emeraldSoft  = dyn(dark: NSColor(srgbRed: 0.204, green: 0.827, blue: 0.600, alpha: 0.15), light: NSColor(srgbRed: 0.051, green: 0.580, blue: 0.408, alpha: 0.12))
    static let amber        = dyn(dark: NSColor(srgbRed: 0.961, green: 0.620, blue: 0.043, alpha: 1.0), light: NSColor(srgbRed: 0.847, green: 0.467, blue: 0.024, alpha: 1.0))
    static let danger       = dyn(dark: NSColor(srgbRed: 0.973, green: 0.443, blue: 0.443, alpha: 1.0), light: NSColor(srgbRed: 0.863, green: 0.149, blue: 0.149, alpha: 1.0))
}

class GeekFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 自动响应深浅外观变化的图层背景/描边容器（消除切换主题时的静态 CGColor 残留）
final class GeekSurfaceView: GeekFlippedView {
    var fillColor: NSColor? { didSet { syncLayerColors() } }
    var borderColor: NSColor? { didSet { syncLayerColors() } }

    init(frame: NSRect, fill: NSColor? = nil, border: NSColor? = nil, cornerRadius: CGFloat = 0, borderWidth: CGFloat = 0, masksToBounds: Bool = false) {
        self.fillColor = fill
        self.borderColor = border
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.borderWidth = borderWidth
        layer?.masksToBounds = masksToBounds
        syncLayerColors()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        syncLayerColors()
    }

    private func syncLayerColors() {
        layer?.backgroundColor = fillColor.map { GeekTheme.resolvedCGColor($0, for: self) }
        layer?.borderColor = borderColor.map { GeekTheme.resolvedCGColor($0, for: self) }
    }
}

final class GeekHoverRowView: NSView {
    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(GeekTheme.hoverSoft.cgColor)
        ctx.fill(bounds)
    }
}

final class GeekCardView: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 11.5
        layer?.borderWidth = 1.0
        layer?.masksToBounds = true
        syncLayerColors()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        syncLayerColors()
    }

    private func syncLayerColors() {
        layer?.backgroundColor = GeekTheme.resolvedCGColor(GeekTheme.cardBg, for: self)
        layer?.borderColor = GeekTheme.resolvedCGColor(GeekTheme.border, for: self)
    }

    func addHairline(atY y: CGFloat, insetX: CGFloat = 16) {
        addSubview(GeekSurfaceView(frame: NSRect(x: insetX, y: y, width: bounds.width - insetX * 2, height: 1), fill: GeekTheme.divider))
    }
}

final class GeekSettingsWindowPanel: NSWindow {
    var onKeyDownIntercept: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyDownIntercept?(event) == true { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDownIntercept?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// 极客暗色开关拨片（38 × 22，带细腻悬浮与旋钮阴影）
final class GeekToggleSwitch: NSView {
    var isOn: Bool = false { didSet { if oldValue != isOn { needsDisplay = true } } }
    var onToggle: ((Bool) -> Void)?
    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(isOn: Bool = false) {
        self.isOn = isOn
        super.init(frame: NSRect(x: 0, y: 0, width: 38, height: 22))
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
    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        onToggle?(isOn)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = CGPath(roundedRect: r, cornerWidth: r.height * 0.5, cornerHeight: r.height * 0.5, transform: nil)
        ctx.saveGState()
        let trackFill: NSColor = isOn ? GeekTheme.accent : (hovered ? GeekTheme.borderStrong : GeekTheme.switchOffBg)
        ctx.setFillColor(trackFill.cgColor)
        ctx.addPath(p); ctx.fillPath()
        ctx.setStrokeColor((isOn ? GeekTheme.accent : GeekTheme.border).cgColor)
        ctx.setLineWidth(1.0); ctx.addPath(p); ctx.strokePath()

        let d: CGFloat = 16
        let kx: CGFloat = isOn ? (bounds.width - d - 3) : 3
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 2.0, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: kx, y: 3, width: d, height: d))
        ctx.restoreGState()
    }
}

/// 行内点击即可直接录制的立体等宽键帽（支持已绑定、未设置、已自定义高亮与录入态）
final class GeekHotKeyPill: NSView {
    var onClick: (() -> Void)?
    private var text: String = ""
    private var isRecording = false
    private var isUnset = false
    private var isModified = false
    private var conflictSeverity: HotKeyConflictSeverity?
    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func configure(
        label: String?,
        recording: Bool,
        modified: Bool = false,
        conflict: HotKeyConflictSeverity? = nil,
        prompt: String = "按下双键…"
    ) {
        if recording {
            self.text = prompt
            self.isUnset = false
        } else if let label, !label.isEmpty {
            self.text = label
            self.isUnset = false
        } else {
            self.text = "未设置"
            self.isUnset = true
        }
        self.isRecording = recording
        self.isModified = modified
        self.conflictSeverity = recording ? nil : conflict
        needsDisplay = true
    }

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
        let p = CGPath(roundedRect: r, cornerWidth: 7.0, cornerHeight: 7.0, transform: nil)
        ctx.saveGState()
        let bgFill: NSColor
        let strokeCol: NSColor
        if isRecording {
            bgFill = GeekTheme.accentSoft; strokeCol = GeekTheme.accent
        } else if let sev = conflictSeverity {
            let tint = (sev == .blocking) ? GeekTheme.danger : GeekTheme.amber
            bgFill = hovered ? tint.withAlphaComponent(0.18) : tint.withAlphaComponent(0.10)
            strokeCol = tint.withAlphaComponent(hovered ? 0.85 : 0.62)
        } else {
            bgFill = hovered ? GeekTheme.controlHover : (isUnset ? GeekTheme.hoverSoft : GeekTheme.inputBg)
            strokeCol = hovered ? GeekTheme.borderStrong : (isModified ? GeekTheme.accent.withAlphaComponent(0.42) : GeekTheme.border)
        }
        ctx.setFillColor(bgFill.cgColor)
        ctx.addPath(p); ctx.fillPath()
        ctx.setStrokeColor(strokeCol.cgColor)
        ctx.setLineWidth(isRecording ? 1.5 : 1.0); ctx.addPath(p); ctx.strokePath()

        let font: NSFont = (isRecording || isUnset)
            ? .systemFont(ofSize: 12.0, weight: isRecording ? .semibold : .medium)
            : .monospacedSystemFont(ofSize: 13.5, weight: .semibold)
        let fg: NSColor = isRecording ? GeekTheme.accent : (isUnset ? GeekTheme.inkMuted : GeekTheme.inkPrimary)
        GeekTheme.drawText(text, in: bounds.insetBy(dx: 6, dy: 0), font: font, color: fg, align: .center)
        ctx.restoreGState()
    }
}
