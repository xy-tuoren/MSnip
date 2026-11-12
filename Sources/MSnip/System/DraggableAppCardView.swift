import AppKit
import QuartzCore
import Foundation

/// ChatGPT 风格的悬浮蓝白贴纸上指箭头（GPU CoreAnimation 轻柔上弹拉伸，待机 0% CPU）
final class HintArrowView: NSView {
    private let glyphView = ArrowGlyphView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
        glyphView.frame = bounds
        glyphView.autoresizingMask = [.width, .height]
        addSubview(glyphView)
        startBounceAnimation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func startBounceAnimation() {
        guard let gl = glyphView.layer else { return }
        gl.removeAnimation(forKey: "chatgpt.arrow.bounce")

        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = 0.0
        move.toValue = 6.5

        let stretchY = CABasicAnimation(keyPath: "transform.scale.y")
        stretchY.fromValue = 1.0
        stretchY.toValue = 1.07

        let group = CAAnimationGroup()
        group.animations = [move, stretchY]
        group.duration = 0.82
        group.autoreverses = true
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        gl.add(group, forKey: "chatgpt.arrow.bounce")
    }
}

private final class ArrowGlyphView: NSView {
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let cx = bounds.midX
        let bottomY: CGFloat = 10
        let wingY: CGFloat = 24.5
        let tipY: CGFloat = 39.5
        let halfShaft: CGFloat = 5.2
        let halfWing: CGFloat = 12.6

        let pts: [(CGPoint, CGFloat)] = [
            (CGPoint(x: cx, y: tipY), 2.6),
            (CGPoint(x: cx - halfWing, y: wingY), 2.3),
            (CGPoint(x: cx - halfShaft, y: wingY), 1.0),
            (CGPoint(x: cx - halfShaft, y: bottomY), 2.4),
            (CGPoint(x: cx + halfShaft, y: bottomY), 2.4),
            (CGPoint(x: cx + halfShaft, y: wingY), 1.0),
            (CGPoint(x: cx + halfWing, y: wingY), 2.3)
        ]

        let path = CGMutablePath()
        let n = pts.count
        let midStart = CGPoint(x: (pts[n - 1].0.x + pts[0].0.x) * 0.5, y: (pts[n - 1].0.y + pts[0].0.y) * 0.5)
        path.move(to: midStart)
        for i in 0..<n {
            let curr = pts[i].0
            let next = pts[(i + 1) % n].0
            path.addArc(tangent1End: curr, tangent2End: next, radius: pts[i].1)
        }
        path.closeSubpath()

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2.0), blur: 5.5, color: NSColor.black.withAlphaComponent(0.30).cgColor)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(5.6)
        ctx.setLineJoin(.round)
        ctx.strokePath()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let colors = [
            NSColor(srgbRed: 0.14, green: 0.58, blue: 1.0, alpha: 1.0).cgColor,
            NSColor(srgbRed: 0.0, green: 0.44, blue: 0.96, alpha: 1.0).cgColor
        ] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: cx, y: tipY), end: CGPoint(x: cx, y: bottomY), options: [])
        }
        ctx.restoreGState()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

/// ChatGPT 风格的可拖拽应用条目行（44pt 高，拖起时整条卡片离位浮起，留下虚线凹槽）
final class DraggableAppRowView: NSView, NSDraggingSource {
    var onDragStateChanged: ((Bool) -> Void)?

    private var isHovered = false { didSet { if oldValue != isHovered { needsDisplay = true } } }
    private var isPressing = false { didSet { if oldValue != isPressing { needsDisplay = true } } }
    private var isDragging = false { didSet { if oldValue != isDragging { needsDisplay = true } } }
    private var mouseDownEvent: NSEvent?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        let menu = NSMenu()
        let item = NSMenuItem(title: "在访达中显示", action: #selector(revealInFinder), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        self.menu = menu
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func cursorUpdate(with event: NSEvent) { (isPressing ? NSCursor.closedHand : NSCursor.openHand).set() }
    override func mouseEntered(with event: NSEvent) { isHovered = true; NSCursor.openHand.set() }
    override func mouseExited(with event: NSEvent) { isHovered = false; isPressing = false; NSCursor.arrow.set() }
    override func mouseDown(with event: NSEvent) { isPressing = true; mouseDownEvent = event; NSCursor.closedHand.set() }
    override func mouseUp(with event: NSEvent) { isPressing = false; mouseDownEvent = nil; if isHovered { NSCursor.openHand.set() } }

    override func mouseDragged(with event: NSEvent) {
        guard let startEvent = mouseDownEvent else { return }
        let p0 = convert(startEvent.locationInWindow, from: nil)
        let p1 = convert(event.locationInWindow, from: nil)
        guard hypot(p1.x - p0.x, p1.y - p0.y) >= 2.0 else { return }

        mouseDownEvent = nil
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        let snapSize = NSSize(width: 156, height: 42)
        let snapImg = makeFloatingRowSnapshot(size: snapSize)
        let dragOrigin = NSPoint(x: max(0, min(bounds.width - snapSize.width, p1.x - 42)), y: p1.y - snapSize.height * 0.5)
        item.setDraggingFrame(NSRect(origin: dragOrigin, size: snapSize), contents: snapImg)

        isDragging = true
        onDragStateChanged?(true)
        let session = beginDraggingSession(with: [item], event: startEvent, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isPressing = false
        isDragging = false
        onDragStateChanged?(false)
    }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let boxRect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: boxRect, xRadius: 8, yRadius: 8)

        if isDragging {
            NSColor.labelColor.withAlphaComponent(isDark ? 0.03 : 0.025).setFill()
            path.fill()
            let dashPath = NSBezierPath(roundedRect: boxRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            dashPath.setLineDash([5, 3.5], count: 2, phase: 0)
            dashPath.lineWidth = 1.0
            NSColor.separatorColor.setStroke()
            dashPath.stroke()

            let ph = "拖到上方权限列表中松手" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
            let sz = ph.size(withAttributes: attrs)
            ph.draw(at: NSPoint(x: round((bounds.width - sz.width) * 0.5), y: round((bounds.height - sz.height) * 0.5)), withAttributes: attrs)
            return
        }

        if isDark {
            NSColor.white.withAlphaComponent(isHovered ? 0.12 : 0.08).setFill()
        } else {
            NSColor.white.withAlphaComponent(isHovered ? 1.0 : 0.90).setFill()
        }
        path.fill()

        let stroke: NSColor = isHovered
            ? NSColor.controlAccentColor.withAlphaComponent(0.70)
            : (isDark
                ? NSColor.white.withAlphaComponent(0.13)
                : NSColor(srgbRed: 0.86, green: 0.855, blue: 0.88, alpha: 1.0))
        stroke.setStroke()
        path.lineWidth = 1.0
        path.stroke()

        let iconSide: CGFloat = 32
        let iconRect = NSRect(x: 10, y: round((bounds.height - iconSide) * 0.5), width: iconSide, height: iconSide)
        appIcon(size: iconRect.size).draw(in: iconRect)

        let name = "MSnip" as NSString
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13.5, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        let nSz = name.size(withAttributes: nameAttrs)
        name.draw(at: NSPoint(x: iconRect.maxX + 10, y: round((bounds.height - nSz.height) * 0.5)), withAttributes: nameAttrs)

        let hint = "按住拖入上方" as NSString
        let hintColor = isHovered ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
        let hintAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: hintColor
        ]
        let hSz = hint.size(withAttributes: hintAttrs)
        let gripX = bounds.width - 18
        hint.draw(at: NSPoint(x: gripX - hSz.width - 8, y: round((bounds.height - hSz.height) * 0.5)), withAttributes: hintAttrs)

        // 右侧轻量 6 点抓握纹理
        hintColor.withAlphaComponent(0.65).setFill()
        let baseY = bounds.midY - 5
        for row in 0..<3 {
            for col in 0..<2 {
                let dot = NSRect(x: gripX + CGFloat(col) * 4, y: baseY + CGFloat(row) * 4.2, width: 2, height: 2)
                NSBezierPath(ovalIn: dot).fill()
            }
        }
    }

    private func makeFloatingRowSnapshot(size: NSSize) -> NSImage {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let img = NSImage(size: size)
        img.lockFocus()
        let r = NSRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        let p = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        (isDark ? NSColor(srgbRed: 0.20, green: 0.21, blue: 0.24, alpha: 0.96) : NSColor(white: 1.0, alpha: 0.97)).setFill()
        p.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.85).setStroke()
        p.lineWidth = 1.2
        p.stroke()

        appIcon(size: NSSize(width: 28, height: 28)).draw(in: NSRect(x: 9, y: (size.height - 28) * 0.5, width: 28, height: 28))
        let label = "MSnip" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: isDark ? NSColor.white : NSColor.black
        ]
        let sz = label.size(withAttributes: attrs)
        label.draw(at: NSPoint(x: 45, y: (size.height - sz.height) * 0.5), withAttributes: attrs)
        img.unlockFocus()
        return img
    }

    private func appIcon(size: NSSize) -> NSImage {
        let icon = (NSApp.applicationIconImage?.copy() as? NSImage) ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        icon.size = size
        return icon
    }
}
