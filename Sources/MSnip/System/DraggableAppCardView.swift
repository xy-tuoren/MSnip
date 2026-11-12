import AppKit
import Foundation

/// 可直接拖入 macOS「系统设置」（录屏 / 辅助功能列表）的应用图标拖拽卡片。
/// 通过 `NSURL` (`Bundle.main.bundleURL`) 作为 `NSPasteboardWriting`，自动附带沙盒文件扩展令牌，
/// 支持在未激活窗口状态下（`acceptsFirstMouse`）一键按住拖进右侧系统设置完成授权或更新签名。
final class DraggableAppCardView: NSView, NSDraggingSource {
    var onRevealInFinder: (() -> Void)?

    private var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }
    private var isPressing = false {
        didSet { if oldValue != isPressing { needsDisplay = true } }
    }
    private var mouseDownEvent: NSEvent?
    private let revealButton = NSButton(title: "在 Finder 中显示", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // 允许用户在「系统设置」处于焦点时，无需先点活本窗口即可一把按住图标拖走
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setupSubviews() {
        revealButton.bezelStyle = .inline
        revealButton.controlSize = .small
        revealButton.font = .systemFont(ofSize: 11, weight: .medium)
        revealButton.target = self
        revealButton.action = #selector(handleRevealClicked)
        addSubview(revealButton)
    }

    override func layout() {
        super.layout()
        revealButton.sizeToFit()
        let bw = revealButton.frame.width + 8
        let bh = revealButton.frame.height
        revealButton.frame = NSRect(
            x: bounds.width - bw - 14,
            y: 12,
            width: bw,
            height: bh
        )
    }

    @objc private func handleRevealClicked() {
        onRevealInFinder?()
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

    override func cursorUpdate(with event: NSEvent) {
        (isPressing ? NSCursor.closedHand : NSCursor.openHand).set()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        NSCursor.openHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressing = false
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if revealButton.frame.contains(pt) {
            super.mouseDown(with: event)
            return
        }
        isPressing = true
        mouseDownEvent = event
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startEvent = mouseDownEvent else { return }
        let p0 = convert(startEvent.locationInWindow, from: nil)
        let p1 = convert(event.locationInWindow, from: nil)
        guard hypot(p1.x - p0.x, p1.y - p0.y) >= 2.5 else { return }

        mouseDownEvent = nil
        let appURL = Bundle.main.bundleURL as NSURL
        let item = NSDraggingItem(pasteboardWriter: appURL)

        let iconSize = NSSize(width: 60, height: 60)
        let dragImage = appIconImage(size: iconSize)
        let dragOrigin = NSPoint(x: p1.x - iconSize.width * 0.5, y: p1.y - iconSize.height * 0.5)
        item.setDraggingFrame(NSRect(origin: dragOrigin, size: iconSize), contents: dragImage)

        let session = beginDraggingSession(with: [item], event: startEvent, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        isPressing = false
        mouseDownEvent = nil
        if isHovered { NSCursor.openHand.set() }
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        isPressing = false
    }

    // MARK: - Custom Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let cardRect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = CGPath(roundedRect: cardRect, cornerWidth: 12, cornerHeight: 12, transform: nil)

        ctx.saveGState()
        let fillAlpha: CGFloat = isPressing ? 0.14 : (isHovered ? 0.09 : 0.05)
        ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(fillAlpha).cgColor)
        ctx.addPath(path)
        ctx.fillPath()

        let strokeAlpha: CGFloat = (isHovered || isPressing) ? 0.85 : 0.45
        ctx.setStrokeColor(NSColor.controlAccentColor.withAlphaComponent(strokeAlpha).cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()

        // 左侧绘制应用高清图标
        let iconSide: CGFloat = 58
        let iconRect = NSRect(x: 18, y: (bounds.height - iconSide) * 0.5, width: iconSide, height: iconSide)
        let icon = appIconImage(size: NSSize(width: iconSide, height: iconSide))
        icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1.0)

        // 右侧引导文案与拖拽手势提示
        let textX = iconRect.maxX + 16
        let title = "按住此图标 ➔ 拖入右侧「系统设置」列表" as NSString
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold),
            .foregroundColor: NSColor.labelColor
        ]
        title.draw(at: NSPoint(x: textX, y: bounds.height * 0.5 + 12), withAttributes: titleAttrs)

        let appName = (Bundle.main.bundleURL.lastPathComponent)
        let sub = "\(appName) · 松手自动添加并开启权限开关" as NSString
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        sub.draw(at: NSPoint(x: textX, y: bounds.height * 0.5 - 8), withAttributes: subAttrs)
    }

    private func appIconImage(size: NSSize) -> NSImage {
        let icon = (NSApp.applicationIconImage?.copy() as? NSImage)
            ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        icon.size = size
        return icon
    }
}
