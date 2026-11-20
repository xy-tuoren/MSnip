import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 极客简约暗炭黑设置窗设计令牌（Carbon HUD 风格，@1x 物理像素对齐）
enum GeekTheme {
    static let windowBg     = NSColor(srgbRed: 0.071, green: 0.078, blue: 0.094, alpha: 1.0) // #121418
    static let barBg        = NSColor(srgbRed: 0.090, green: 0.100, blue: 0.122, alpha: 1.0) // #171A1F
    static let cardBg       = NSColor(srgbRed: 0.106, green: 0.118, blue: 0.145, alpha: 1.0) // #1B1E25
    static let controlBg    = NSColor(srgbRed: 0.137, green: 0.153, blue: 0.188, alpha: 1.0) // #232730
    static let controlHover = NSColor(srgbRed: 0.176, green: 0.196, blue: 0.243, alpha: 1.0) // #2D323E
    static let inputBg      = NSColor(srgbRed: 0.078, green: 0.088, blue: 0.108, alpha: 1.0) // #14161C
    static let border       = NSColor(white: 1.0, alpha: 0.085)
    static let borderStrong = NSColor(white: 1.0, alpha: 0.16)
    static let divider      = NSColor(white: 1.0, alpha: 0.065)

    static let inkPrimary   = NSColor(srgbRed: 0.945, green: 0.957, blue: 0.976, alpha: 1.0) // #F1F4F9
    static let inkSecondary = NSColor(srgbRed: 0.569, green: 0.612, blue: 0.686, alpha: 1.0) // #919CAF
    static let inkMuted     = NSColor(srgbRed: 0.376, green: 0.416, blue: 0.490, alpha: 1.0) // #606A7D

    static let accent       = NSColor(srgbRed: 0.220, green: 0.741, blue: 0.973, alpha: 1.0) // #38BDF8
    static let accentSoft   = NSColor(srgbRed: 0.220, green: 0.741, blue: 0.973, alpha: 0.16)
    static let emerald      = NSColor(srgbRed: 0.204, green: 0.827, blue: 0.600, alpha: 1.0) // #34D399
    static let amber        = NSColor(srgbRed: 0.961, green: 0.620, blue: 0.043, alpha: 1.0) // #F59E0B
    static let danger       = NSColor(srgbRed: 0.973, green: 0.443, blue: 0.443, alpha: 1.0) // #F87171
}

/// 顶向下坐标系容器视图（简化像素级精准排版）
final class GeekFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 1px 极细冷白描边极客圆角卡片容器
final class GeekCardView: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = GeekTheme.cardBg.cgColor
        layer?.cornerRadius = 9.0
        layer?.borderWidth = 1.0
        layer?.borderColor = GeekTheme.border.cgColor
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func addHairline(atY y: CGFloat, insetX: CGFloat = 12) {
        let sep = NSView(frame: NSRect(x: insetX, y: y, width: bounds.width - insetX * 2, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = GeekTheme.divider.cgColor
        addSubview(sep)
    }
}

/// 支持行内快捷键拦截录制与 ⌘W 快速关闭的极客设置窗口
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

/// 紧凑极客暗色开关拨片（32 × 18）
final class GeekToggleSwitch: NSView {
    var isOn: Bool = false { didSet { if oldValue != isOn { needsDisplay = true } } }
    var onToggle: ((Bool) -> Void)?
    override var isFlipped: Bool { true }

    init(isOn: Bool = false) {
        self.isOn = isOn
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 18))
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        onToggle?(isOn)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let p = CGPath(roundedRect: r, cornerWidth: r.height * 0.5, cornerHeight: r.height * 0.5, transform: nil)
        ctx.saveGState()
        ctx.setFillColor((isOn ? GeekTheme.accent : GeekTheme.controlBg).cgColor)
        ctx.addPath(p); ctx.fillPath()
        ctx.setStrokeColor((isOn ? GeekTheme.accent : GeekTheme.borderStrong).cgColor)
        ctx.setLineWidth(1.0); ctx.addPath(p); ctx.strokePath()

        let d: CGFloat = 12
        let kx: CGFloat = isOn ? (bounds.width - d - 3) : 3
        ctx.setFillColor((isOn ? GeekTheme.windowBg : GeekTheme.inkPrimary).cgColor)
        ctx.fillEllipse(in: CGRect(x: kx, y: 3, width: d, height: d))
        ctx.restoreGState()
    }
}

/// 行内点击即可直接录制的极客等宽键帽控件
final class GeekHotKeyPill: NSView {
    var onClick: (() -> Void)?
    private var text: String = ""
    private var isRecording = false
    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    override var isFlipped: Bool { true }

    func configure(label: String, recording: Bool) {
        self.text = recording ? "按下组合键…" : label
        self.isRecording = recording
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
        let p = CGPath(roundedRect: r, cornerWidth: 5.5, cornerHeight: 5.5, transform: nil)
        ctx.saveGState()
        ctx.setFillColor((isRecording ? GeekTheme.accentSoft : (hovered ? GeekTheme.controlHover : GeekTheme.inputBg)).cgColor)
        ctx.addPath(p); ctx.fillPath()
        ctx.setStrokeColor((isRecording ? GeekTheme.accent : (hovered ? GeekTheme.borderStrong : GeekTheme.border)).cgColor)
        ctx.setLineWidth(isRecording ? 1.4 : 1.0); ctx.addPath(p); ctx.strokePath()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: isRecording ? 10.5 : 12.0, weight: .semibold),
            .foregroundColor: isRecording ? GeekTheme.accent : GeekTheme.inkPrimary
        ]
        let ns = text as NSString
        let sz = ns.size(withAttributes: attrs)
        ns.draw(at: CGPoint(x: round(bounds.midX - sz.width * 0.5), y: round(bounds.midY - sz.height * 0.5)), withAttributes: attrs)
        ctx.restoreGState()
    }
}

/// 权限状态圆点徽章视图
final class GeekDotLabel: NSView {
    var dotColor: NSColor = GeekTheme.emerald { didSet { needsDisplay = true } }
    var text: String = "" { didSet { needsDisplay = true } }
    var detail: String = "" { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        MSnipUITheme.drawStatusDot(ctx: ctx, center: CGPoint(x: 8, y: bounds.midY), color: dotColor, halo: true)

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: GeekTheme.inkPrimary
        ]
        let tSz = (text as NSString).size(withAttributes: titleAttrs)
        (text as NSString).draw(at: CGPoint(x: 22, y: round(bounds.midY - tSz.height * 0.5)), withAttributes: titleAttrs)

        let detAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11.0, weight: .medium),
            .foregroundColor: dotColor
        ]
        let dSz = (detail as NSString).size(withAttributes: detAttrs)
        (detail as NSString).draw(at: CGPoint(x: round(22 + tSz.width + 10), y: round(bounds.midY - dSz.height * 0.5)), withAttributes: detAttrs)
    }
}

/// 暗炭黑极客翻译服务列表行视图（带状态光点、极简「主」标签与自定义暗色选中胶囊）
final class ProviderRowCellView: NSTableCellView {
    private let titleText: String
    private let isPrimary: Bool
    private let isRowSelected: Bool
    private let dotColor: NSColor

    init(title: String, isPrimary: Bool, isSelected: Bool, dotColor: NSColor) {
        self.titleText = title; self.isPrimary = isPrimary; self.isRowSelected = isSelected; self.dotColor = dotColor
        super.init(frame: .zero)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if isRowSelected {
            let bg = CGPath(roundedRect: bounds.insetBy(dx: 3, dy: 2), cornerWidth: 6.0, cornerHeight: 6.0, transform: nil)
            ctx.setFillColor(GeekTheme.controlHover.cgColor); ctx.addPath(bg); ctx.fillPath()
            ctx.setStrokeColor(GeekTheme.borderStrong.cgColor); ctx.setLineWidth(1.0); ctx.addPath(bg); ctx.strokePath()
        }
        MSnipUITheme.drawStatusDot(ctx: ctx, center: CGPoint(x: 14, y: bounds.midY), color: dotColor, halo: isPrimary)
        var rightReserve: CGFloat = 8
        if isPrimary {
            let br = CGRect(x: bounds.width - 28, y: round((bounds.height - 16) * 0.5), width: 20, height: 16)
            ctx.setFillColor(GeekTheme.accentSoft.cgColor)
            ctx.addPath(CGPath(roundedRect: br, cornerWidth: 4.0, cornerHeight: 4.0, transform: nil)); ctx.fillPath()
            let bAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5, weight: .bold), .foregroundColor: GeekTheme.accent]
            let bSz = ("主" as NSString).size(withAttributes: bAttrs)
            ("主" as NSString).draw(at: CGPoint(x: round(br.midX - bSz.width * 0.5), y: round(br.midY - bSz.height * 0.5)), withAttributes: bAttrs)
            rightReserve = 34
        }
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.0, weight: (isRowSelected || isPrimary) ? .semibold : .medium),
            .foregroundColor: isRowSelected ? GeekTheme.inkPrimary : GeekTheme.inkSecondary,
            .paragraphStyle: para
        ]
        let sz = (titleText as NSString).size(withAttributes: attrs)
        (titleText as NSString).draw(
            in: CGRect(x: 26, y: round((bounds.height - sz.height) * 0.5), width: max(30, bounds.width - 26 - rightReserve), height: sz.height + 2),
            withAttributes: attrs
        )
    }
}

/// 极客暗色文本输入壳（无系统粗糙边框，点击任意区域聚焦内部文本框）
final class GeekInputBox: NSView {
    override var isFlipped: Bool { true }
    let field: NSTextField

    init(frame: NSRect, field: NSTextField, placeholder: String, mono: Bool) {
        self.field = field
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = GeekTheme.inputBg.cgColor
        layer?.cornerRadius = 6.0
        layer?.borderWidth = 1.0
        layer?.borderColor = GeekTheme.border.cgColor

        field.isBordered = false; field.isBezeled = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = mono ? .monospacedSystemFont(ofSize: 11.5, weight: .regular) : .systemFont(ofSize: 12.0, weight: .regular)
        field.textColor = GeekTheme.inkPrimary
        field.setGeekPlaceholder(placeholder)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true; field.cell?.wraps = false
        field.frame = NSRect(x: 8, y: round((frame.height - 17) * 0.5), width: frame.width - 16, height: 17)
        addSubview(field)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(field) }
}

extension NSTextField {
    func setGeekPlaceholder(_ text: String) {
        placeholderAttributedString = NSAttributedString(
            string: text,
            attributes: [.font: font ?? NSFont.systemFont(ofSize: 11.5), .foregroundColor: GeekTheme.inkMuted]
        )
    }
}
