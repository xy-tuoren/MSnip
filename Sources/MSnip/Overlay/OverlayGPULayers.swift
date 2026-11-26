import AppKit
import CoreGraphics
import Foundation
import MSnipCore
import QuartzCore

/// 覆盖层光标形态去重枚举（杜绝 `mouseMoved` 每次触发都发起同步 WindowServer `NSCursor.set()` IPC）
enum OverlayCursorKind: Equatable {
    case crosshair
    case arrow
    case openHand

    func apply() {
        switch self {
        case .crosshair: NSCursor.crosshair.set()
        case .arrow:     NSCursor.arrow.set()
        case .openHand:  NSCursor.openHand.set()
        }
    }
}

/// 纯 GPU 硬件合成的四边暗化遮罩 + 自动吸附高亮框（零 CPU 全屏位图重绘、零 GPU 纹理上传）
final class OverlayDimAndSnapView: NSView {
    private let dimTop = CALayer()
    private let dimBottom = CALayer()
    private let dimLeft = CALayer()
    private let dimRight = CALayer()
    private let snapBorder = CALayer()

    private static let dimColor = NSColor.black.withAlphaComponent(0.46).cgColor

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        guard let root = layer else { return }
        root.isGeometryFlipped = true
        for l in [dimTop, dimBottom, dimLeft, dimRight] {
            l.backgroundColor = Self.dimColor
            l.isOpaque = false
            root.addSublayer(l)
        }
        snapBorder.backgroundColor = nil
        snapBorder.borderWidth = 2.0
        snapBorder.isHidden = true
        root.addSublayer(snapBorder)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(highlightRect: CGRect?, showDim: Bool, showSnapBorder: Bool, borderColor: CGColor) {
        let w = bounds.width, h = bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if !showDim {
            dimTop.isHidden = true; dimBottom.isHidden = true
            dimLeft.isHidden = true; dimRight.isHidden = true
        } else if let raw = highlightRect, raw.width > 0, raw.height > 0 {
            let hl = raw.intersection(bounds)
            if hl.isNull || hl.width <= 0 || hl.height <= 0 {
                dimTop.isHidden = false; dimTop.frame = bounds
                dimBottom.isHidden = true; dimLeft.isHidden = true; dimRight.isHidden = true
            } else {
                let topH = max(0, hl.minY), botH = max(0, h - hl.maxY)
                let leftW = max(0, hl.minX), rightW = max(0, w - hl.maxX)
                dimTop.isHidden = topH <= 0; dimTop.frame = CGRect(x: 0, y: 0, width: w, height: topH)
                dimBottom.isHidden = botH <= 0; dimBottom.frame = CGRect(x: 0, y: hl.maxY, width: w, height: botH)
                dimLeft.isHidden = leftW <= 0; dimLeft.frame = CGRect(x: 0, y: hl.minY, width: leftW, height: hl.height)
                dimRight.isHidden = rightW <= 0; dimRight.frame = CGRect(x: hl.maxX, y: hl.minY, width: rightW, height: hl.height)
            }
        } else {
            dimTop.isHidden = false; dimTop.frame = bounds
            dimBottom.isHidden = true; dimLeft.isHidden = true; dimRight.isHidden = true
        }

        if showSnapBorder, let raw = highlightRect, raw.width > 0, raw.height > 0 {
            snapBorder.isHidden = false
            snapBorder.borderColor = borderColor
            snapBorder.frame = raw.insetBy(dx: -0.5, dy: -0.5)
        } else {
            snapBorder.isHidden = true
        }
    }
}

/// 独立缓存的尺寸/状态胶囊视图（带静态 `shadowPath`，过渡滑行期间仅 GPU 移动坐标，零文本重绘）
final class OverlayHudPillView: NSView {
    private static let textAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12.0, weight: .semibold),
        .foregroundColor: MSnipUITheme.inkPrimary
    ]

    private var currentText: String = ""
    private var textSize: CGSize = .zero

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(text: String?, anchorRect: CGRect?, containerBounds: CGRect) {
        guard let text, !text.isEmpty, let anchor = anchorRect else {
            if !isHidden { isHidden = true }
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let textChanged = (text != currentText)
        if textChanged {
            currentText = text
            textSize = (text as NSString).size(withAttributes: Self.textAttrs)
            let w = ceil(textSize.width + 16), h: CGFloat = 24
            if frame.size != NSSize(width: w, height: h) {
                setFrameSize(NSSize(width: w, height: h))
                layer?.shadowPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: 6, cornerHeight: 6, transform: nil)
            }
            needsDisplay = true
        }
        let w = frame.width, h = frame.height
        let bx = round(min(max(8, anchor.minX), containerBounds.width - w - 8))
        let by = round(anchor.minY >= (h + 10) ? (anchor.minY - h - 7) : (anchor.minY + 7))
        let origin = NSPoint(x: bx, y: by)
        if frame.origin != origin { setFrameOrigin(origin) }
        if isHidden { isHidden = false }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !currentText.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let pill = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 6.0, cornerHeight: 6.0, transform: nil)
        ctx.setFillColor(MSnipUITheme.cardBg.cgColor)
        ctx.addPath(pill); ctx.fillPath()
        ctx.setStrokeColor(MSnipUITheme.borderStrong.cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(pill); ctx.strokePath()
        (currentText as NSString).draw(
            at: CGPoint(x: round(8), y: round((bounds.height - textSize.height) * 0.5)),
            withAttributes: Self.textAttrs
        )
    }
}

/// 独立 GPU 缓存的快捷键提示卡（内容仅在模式切换时绘制一次，避让移动零 `blur: 22` 重绘）
final class OverlayShortcutTipsView: NSView {
    private static let headerTitleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12.0, weight: .bold),
        .foregroundColor: MSnipUITheme.accent
    ]
    private static let headerHintAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11.0, weight: .medium),
        .foregroundColor: MSnipUITheme.inkMuted
    ]
    private static let keycapKeyAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12.5, weight: .bold),
        .foregroundColor: MSnipUITheme.inkPrimary
    ]
    private static let keycapDescAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13.5, weight: .medium),
        .foregroundColor: MSnipUITheme.inkPrimary
    ]
    private static var textSizeCache: [String: CGSize] = [:]

    private var rows: [(key: String, desc: String)] = []
    private var hideKey: String = "H"
    private var maxKeyCapW: CGFloat = 0
    private var contentSignature: String = ""

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.28
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -8)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func cachedSize(_ str: String, isKey: Bool) -> CGSize {
        let token = isKey ? "K:\(str)" : "D:\(str)"
        if let hit = textSizeCache[token] { return hit }
        let sz = (str as NSString).size(withAttributes: isKey ? keycapKeyAttrs : keycapDescAttrs)
        textSizeCache[token] = sz
        return sz
    }

    func updateContentIfNeeded(signature: String, rows: () -> [(key: String, desc: String)], hideKey: String) -> CGSize {
        if signature == contentSignature, frame.width > 10, frame.height > 10 { return frame.size }
        self.contentSignature = signature
        self.rows = rows()
        self.hideKey = hideKey
        var maxCap: CGFloat = 0, maxDesc: CGFloat = 0
        for row in self.rows {
            maxCap = max(maxCap, max(26, ceil(Self.cachedSize(row.key, isKey: true).width + 16)))
            maxDesc = max(maxDesc, ceil(Self.cachedSize(row.desc, isKey: false).width))
        }
        self.maxKeyCapW = maxCap
        let sz = CGSize(width: max(224, ceil(36 + maxCap + 14 + maxDesc)), height: ceil(40 + CGFloat(self.rows.count) * 32 - 6 + 15))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        setFrameSize(sz)
        layer?.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: sz), cornerWidth: 12, cornerHeight: 12, transform: nil)
        CATransaction.commit()
        needsDisplay = true
        return sz
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !rows.isEmpty, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds
        let path = CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 12, cornerHeight: 12, transform: nil)
        ctx.setFillColor(MSnipUITheme.cardBg.cgColor)
        ctx.addPath(path); ctx.fillPath()
        ctx.setStrokeColor(MSnipUITheme.borderStrong.cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(path); ctx.strokePath()

        let padX: CGFloat = 18
        ("快捷键操作" as NSString).draw(at: CGPoint(x: padX, y: 9), withAttributes: Self.headerTitleAttrs)
        let hideHint = "按 \(hideKey) 隐藏" as NSString
        let hideSz = hideHint.size(withAttributes: Self.headerHintAttrs)
        hideHint.draw(at: CGPoint(x: round(rect.width - padX - hideSz.width), y: 9), withAttributes: Self.headerHintAttrs)
        ctx.setFillColor(MSnipUITheme.borderHairline.cgColor)
        ctx.fill(CGRect(x: padX, y: 31, width: rect.width - padX * 2, height: 1))

        let keySpineRightX = round(padX + maxKeyCapW), descLeftX = round(keySpineRightX + 14)
        for (idx, row) in rows.enumerated() {
            let rowTopY = round(41 + CGFloat(idx) * 32)
            let kSz = Self.cachedSize(row.key, isKey: true), dSz = Self.cachedSize(row.desc, isKey: false)
            let capW = max(26, ceil(kSz.width + 16))
            let capRect = CGRect(x: keySpineRightX - capW, y: rowTopY, width: capW, height: 24)
            let capPath = CGPath(roundedRect: capRect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 5.5, cornerHeight: 5.5, transform: nil)
            ctx.setFillColor(MSnipUITheme.subtleFill.cgColor)
            ctx.addPath(capPath); ctx.fillPath()
            ctx.setStrokeColor(MSnipUITheme.borderStrong.cgColor)
            ctx.setLineWidth(1.0)
            ctx.addPath(capPath); ctx.strokePath()
            (row.key as NSString).draw(at: CGPoint(x: round(capRect.minX + (capW - kSz.width) * 0.5), y: round(capRect.minY + (24 - kSz.height) * 0.5)), withAttributes: Self.keycapKeyAttrs)
            (row.desc as NSString).draw(at: CGPoint(x: descLeftX, y: round(rowTopY + (24 - dSz.height) * 0.5)), withAttributes: Self.keycapDescAttrs)
        }
    }
}
