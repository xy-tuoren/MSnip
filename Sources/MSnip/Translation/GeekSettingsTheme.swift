import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 极客简约暗炭黑设置窗设计令牌（Linear / Raycast 风格，高可读层级、柔光边界与像素级对齐）
enum GeekTheme {
    static let windowBg     = NSColor(srgbRed: 0.067, green: 0.075, blue: 0.090, alpha: 1.0) // #111317
    static let barBg        = NSColor(srgbRed: 0.082, green: 0.094, blue: 0.118, alpha: 1.0) // #15181E
    static let cardBg       = NSColor(srgbRed: 0.106, green: 0.122, blue: 0.149, alpha: 1.0) // #1B1F26
    static let controlBg    = NSColor(srgbRed: 0.141, green: 0.161, blue: 0.200, alpha: 1.0) // #242933
    static let controlHover = NSColor(srgbRed: 0.180, green: 0.208, blue: 0.259, alpha: 1.0) // #2E3542
    static let inputBg      = NSColor(srgbRed: 0.075, green: 0.086, blue: 0.106, alpha: 1.0) // #13161B
    static let border       = NSColor(white: 1.0, alpha: 0.080)
    static let borderStrong = NSColor(white: 1.0, alpha: 0.160)
    static let divider      = NSColor(white: 1.0, alpha: 0.060)

    static let inkPrimary   = NSColor(srgbRed: 0.949, green: 0.961, blue: 0.980, alpha: 1.0) // #F2F5FA
    static let inkSecondary = NSColor(srgbRed: 0.624, green: 0.671, blue: 0.749, alpha: 1.0) // #9FABBF
    static let inkMuted     = NSColor(srgbRed: 0.443, green: 0.490, blue: 0.569, alpha: 1.0) // #717D91

    static let accent       = NSColor(srgbRed: 0.310, green: 0.565, blue: 1.000, alpha: 1.0) // #4F90FF
    static let accentSoft   = NSColor(srgbRed: 0.310, green: 0.565, blue: 1.000, alpha: 0.16)
    static let emerald      = NSColor(srgbRed: 0.204, green: 0.827, blue: 0.600, alpha: 1.0) // #34D399
    static let emeraldSoft  = NSColor(srgbRed: 0.204, green: 0.827, blue: 0.600, alpha: 0.15)
    static let amber        = NSColor(srgbRed: 0.961, green: 0.620, blue: 0.043, alpha: 1.0) // #F59E0B
    static let danger       = NSColor(srgbRed: 0.973, green: 0.443, blue: 0.443, alpha: 1.0) // #F87171
}

final class GeekFlippedView: NSView {
    override var isFlipped: Bool { true }
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
        ctx.setFillColor(NSColor(white: 1.0, alpha: 0.032).cgColor)
        ctx.fill(bounds)
    }
}

final class GeekCardView: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = GeekTheme.cardBg.cgColor
        layer?.cornerRadius = 11.5
        layer?.borderWidth = 1.0
        layer?.borderColor = GeekTheme.border.cgColor
        layer?.masksToBounds = true
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func addHairline(atY y: CGFloat, insetX: CGFloat = 16) {
        let sep = NSView(frame: NSRect(x: insetX, y: y, width: bounds.width - insetX * 2, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = GeekTheme.divider.cgColor
        addSubview(sep)
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
        let trackFill: NSColor = isOn ? GeekTheme.accent : (hovered ? GeekTheme.controlHover : GeekTheme.controlBg)
        ctx.setFillColor(trackFill.cgColor)
        ctx.addPath(p); ctx.fillPath()
        ctx.setStrokeColor((isOn ? GeekTheme.accent : GeekTheme.borderStrong).cgColor)
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
            bgFill = hovered ? GeekTheme.controlHover : (isUnset ? NSColor(white: 1.0, alpha: 0.025) : GeekTheme.inputBg)
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

/// 权限状态行视图（14pt 主标题 + 右侧或紧邻清晰语义状态）
final class GeekDotLabel: NSView {
    var dotColor: NSColor = GeekTheme.emerald { didSet { needsDisplay = true } }
    var text: String = "" { didSet { needsDisplay = true } }
    var detail: String = "" { didSet { needsDisplay = true } }
    var alignDetailRight: Bool = true
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        MSnipUITheme.drawStatusDot(ctx: ctx, center: CGPoint(x: 8, y: bounds.midY), color: dotColor, halo: true)

        let titleFont = NSFont.systemFont(ofSize: 14.0, weight: .medium)
        let tW = GeekTheme.measureTextWidth(text, font: titleFont)
        GeekTheme.drawText(text, in: CGRect(x: 22, y: 0, width: max(20, bounds.width - 24), height: bounds.height), font: titleFont, color: GeekTheme.inkPrimary)

        if !detail.isEmpty {
            let detFont = NSFont.systemFont(ofSize: 13.0, weight: .medium)
            if alignDetailRight {
                GeekTheme.drawText(detail, in: CGRect(x: 22 + tW + 8, y: 0, width: max(20, bounds.width - 30 - tW), height: bounds.height), font: detFont, color: dotColor, align: .right)
            } else {
                GeekTheme.drawText(detail, in: CGRect(x: 22 + tW + 12, y: 0, width: max(20, bounds.width - 34 - tW), height: bounds.height), font: detFont, color: dotColor)
            }
        }
    }
}
