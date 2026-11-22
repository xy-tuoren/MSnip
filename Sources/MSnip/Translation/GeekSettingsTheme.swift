import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 极客简约暗炭黑设置窗设计令牌（Linear / Raycast 风格，高可读字阶 + 1px 像素对齐）
enum GeekTheme {
    static let windowBg     = NSColor(srgbRed: 0.078, green: 0.086, blue: 0.102, alpha: 1.0) // #14161A
    static let barBg        = NSColor(srgbRed: 0.094, green: 0.104, blue: 0.124, alpha: 1.0) // #181B20
    static let cardBg       = NSColor(srgbRed: 0.114, green: 0.125, blue: 0.149, alpha: 1.0) // #1D2026
    static let controlBg    = NSColor(srgbRed: 0.149, green: 0.165, blue: 0.196, alpha: 1.0) // #262A32
    static let controlHover = NSColor(srgbRed: 0.192, green: 0.212, blue: 0.251, alpha: 1.0) // #313640
    static let inputBg      = NSColor(srgbRed: 0.086, green: 0.096, blue: 0.114, alpha: 1.0) // #16181D
    static let border       = NSColor(white: 1.0, alpha: 0.085)
    static let borderStrong = NSColor(white: 1.0, alpha: 0.165)
    static let divider      = NSColor(white: 1.0, alpha: 0.065)

    static let inkPrimary   = NSColor(srgbRed: 0.945, green: 0.957, blue: 0.976, alpha: 1.0) // #F1F4F9
    static let inkSecondary = NSColor(srgbRed: 0.620, green: 0.663, blue: 0.733, alpha: 1.0) // #9EA9BB
    static let inkMuted     = NSColor(srgbRed: 0.435, green: 0.478, blue: 0.553, alpha: 1.0) // #6F7A8D

    static let accent       = NSColor(srgbRed: 0.298, green: 0.553, blue: 1.000, alpha: 1.0) // #4C8DFF
    static let accentSoft   = NSColor(srgbRed: 0.298, green: 0.553, blue: 1.000, alpha: 0.16)
    static let emerald      = NSColor(srgbRed: 0.204, green: 0.827, blue: 0.600, alpha: 1.0) // #34D399
    static let emeraldSoft  = NSColor(srgbRed: 0.204, green: 0.827, blue: 0.600, alpha: 0.15)
    static let amber        = NSColor(srgbRed: 0.961, green: 0.620, blue: 0.043, alpha: 1.0) // #F59E0B
    static let danger       = NSColor(srgbRed: 0.973, green: 0.443, blue: 0.443, alpha: 1.0) // #F87171
}

final class GeekFlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class GeekCardView: NSView {
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = GeekTheme.cardBg.cgColor
        layer?.cornerRadius = 10.0
        layer?.borderWidth = 1.0
        layer?.borderColor = GeekTheme.border.cgColor
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

/// 极客暗色开关拨片（38 × 22，宽敞易点）
final class GeekToggleSwitch: NSView {
    var isOn: Bool = false { didSet { if oldValue != isOn { needsDisplay = true } } }
    var onToggle: ((Bool) -> Void)?
    override var isFlipped: Bool { true }

    init(isOn: Bool = false) {
        self.isOn = isOn
        super.init(frame: NSRect(x: 0, y: 0, width: 38, height: 22))
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

        let d: CGFloat = 16
        let kx: CGFloat = isOn ? (bounds.width - d - 3) : 3
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: kx, y: 3, width: d, height: d))
        ctx.restoreGState()
    }
}

/// 行内点击即可直接录制的立体等宽键帽（14pt 等宽字号，清晰醒目）
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
        let p = CGPath(roundedRect: r, cornerWidth: 7.0, cornerHeight: 7.0, transform: nil)
        ctx.saveGState()
        ctx.setFillColor((isRecording ? GeekTheme.accentSoft : (hovered ? GeekTheme.controlHover : GeekTheme.inputBg)).cgColor)
        ctx.addPath(p); ctx.fillPath()
        ctx.setStrokeColor((isRecording ? GeekTheme.accent : (hovered ? GeekTheme.borderStrong : GeekTheme.border)).cgColor)
        ctx.setLineWidth(isRecording ? 1.5 : 1.0); ctx.addPath(p); ctx.strokePath()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: isRecording ? 12.0 : 14.0, weight: .semibold),
            .foregroundColor: isRecording ? GeekTheme.accent : GeekTheme.inkPrimary
        ]
        let ns = text as NSString
        let sz = ns.size(withAttributes: attrs)
        ns.draw(at: CGPoint(x: round(bounds.midX - sz.width * 0.5), y: round(bounds.midY - sz.height * 0.5)), withAttributes: attrs)
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

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14.0, weight: .medium),
            .foregroundColor: GeekTheme.inkPrimary
        ]
        let tSz = (text as NSString).size(withAttributes: titleAttrs)
        (text as NSString).draw(at: CGPoint(x: 24, y: round(bounds.midY - tSz.height * 0.5)), withAttributes: titleAttrs)

        if !detail.isEmpty {
            let detAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13.0, weight: .medium),
                .foregroundColor: dotColor
            ]
            let dSz = (detail as NSString).size(withAttributes: detAttrs)
            let dx = alignDetailRight ? round(bounds.width - dSz.width) : round(24 + tSz.width + 12)
            (detail as NSString).draw(at: CGPoint(x: dx, y: round(bounds.midY - dSz.height * 0.5)), withAttributes: detAttrs)
        }
    }
}

/// 翻译服务列表行视图（38px 宽敞行高 + 清晰「使用中 / 已就绪 / 填 Key」状态胶囊，一眼看懂）
final class ProviderRowCellView: NSTableCellView {
    private let titleText: String
    private let isPrimary: Bool
    private let isReady: Bool
    private let isRowSelected: Bool
    private let dotColor: NSColor

    init(title: String, isPrimary: Bool, isReady: Bool, isSelected: Bool, dotColor: NSColor) {
        self.titleText = title; self.isPrimary = isPrimary; self.isReady = isReady
        self.isRowSelected = isSelected; self.dotColor = dotColor
        super.init(frame: .zero)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if isRowSelected {
            let bg = CGPath(roundedRect: bounds.insetBy(dx: 4, dy: 2), cornerWidth: 7.0, cornerHeight: 7.0, transform: nil)
            ctx.setFillColor(GeekTheme.controlHover.cgColor); ctx.addPath(bg); ctx.fillPath()
            ctx.setStrokeColor(GeekTheme.borderStrong.cgColor); ctx.setLineWidth(1.0); ctx.addPath(bg); ctx.strokePath()
        }
        MSnipUITheme.drawStatusDot(ctx: ctx, center: CGPoint(x: 15, y: bounds.midY), color: dotColor, halo: isPrimary)

        let badgeText: String = isPrimary ? "使用中" : (isReady ? "已就绪" : "填 Key")
        let badgeBg: NSColor = isPrimary ? GeekTheme.emeraldSoft : (isReady ? GeekTheme.accentSoft : NSColor(white: 1.0, alpha: 0.05))
        let badgeFg: NSColor = isPrimary ? GeekTheme.emerald : (isReady ? GeekTheme.accent : GeekTheme.inkMuted)
        let bw: CGFloat = 44, bh: CGFloat = 18
        let br = CGRect(x: bounds.width - bw - 8, y: round((bounds.height - bh) * 0.5), width: bw, height: bh)
        ctx.setFillColor(badgeBg.cgColor)
        ctx.addPath(CGPath(roundedRect: br, cornerWidth: 4.5, cornerHeight: 4.5, transform: nil)); ctx.fillPath()
        let bAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: badgeFg]
        let bSz = (badgeText as NSString).size(withAttributes: bAttrs)
        (badgeText as NSString).draw(at: CGPoint(x: round(br.midX - bSz.width * 0.5), y: round(br.midY - bSz.height * 0.5)), withAttributes: bAttrs)
        let rightReserve = bw + 14

        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13.0, weight: (isRowSelected || isPrimary) ? .semibold : .medium),
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

/// 极客暗色文本输入壳（13pt 清晰字号，点击任意区域聚焦内部文本框）
final class GeekInputBox: NSView {
    override var isFlipped: Bool { true }
    let field: NSTextField

    init(frame: NSRect, field: NSTextField, placeholder: String, mono: Bool) {
        self.field = field
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = GeekTheme.inputBg.cgColor
        layer?.cornerRadius = 7.0
        layer?.borderWidth = 1.0
        layer?.borderColor = GeekTheme.border.cgColor

        field.isBordered = false; field.isBezeled = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = mono ? .monospacedSystemFont(ofSize: 12.5, weight: .regular) : .systemFont(ofSize: 13.0, weight: .regular)
        field.textColor = GeekTheme.inkPrimary
        field.setGeekPlaceholder(placeholder)
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true; field.cell?.wraps = false
        field.frame = NSRect(x: 10, y: round((frame.height - 19) * 0.5), width: frame.width - 20, height: 19)
        addSubview(field)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(field) }
}

extension NSTextField {
    func setGeekPlaceholder(_ text: String) {
        placeholderAttributedString = NSAttributedString(
            string: text,
            attributes: [.font: font ?? NSFont.systemFont(ofSize: 13.0), .foregroundColor: GeekTheme.inkMuted]
        )
    }
}
