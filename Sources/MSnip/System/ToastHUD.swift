import AppKit
import Foundation
import MSnipCore

/// 轻量非抢焦悬浮胶囊提示（支持纯状态反馈自动渐隐，以及快存后带「在 Finder 显示」的可点击交互按钮）
@MainActor
enum ToastHUD {
    private static var activePanel: NSPanel?
    private static var dismissWorkItem: DispatchWorkItem?

    static func show(
        message: String,
        swatch: RGBAColor? = nil,
        near screenPoint: NSPoint? = nil,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil
    ) {
        dismissWorkItem?.cancel()
        activePanel?.orderOut(nil)

        let isInteractive = (actionTitle != nil && onAction != nil)
        let contentView = ToastPillView(
            message: message,
            swatch: swatch,
            actionTitle: actionTitle,
            onTrigger: {
                dismissImmediate()
                onAction?()
            }
        )
        let size = contentView.intrinsicSize
        contentView.frame = NSRect(origin: .zero, size: size)

        let anchor = screenPoint ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let x = min(max(vf.minX + 12, round(anchor.x - size.width * 0.5)), vf.maxX - size.width - 12)
        let preferredY = round(anchor.y + 22)
        let y = (preferredY + size.height + 12 <= vf.maxY) ? preferredY : max(vf.minY + 12, round(anchor.y - size.height - 26))

        let panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = !isInteractive
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = contentView
        panel.alphaValue = 0.0
        panel.orderFrontRegardless()
        panel.animator().alphaValue = 1.0
        activePanel = panel

        let holdDuration: TimeInterval = isInteractive ? 3.4 : 1.25
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                guard let current = activePanel, current === panel else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.22
                    current.animator().alphaValue = 0.0
                } completionHandler: {
                    MainActor.assumeIsolated {
                        if activePanel === panel {
                            panel.orderOut(nil)
                            activePanel = nil
                        }
                    }
                }
            }
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration, execute: work)
    }

    private static func dismissImmediate() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        activePanel?.orderOut(nil)
        activePanel = nil
    }
}

private final class ToastPillView: NSView {
    private let message: String
    private let swatch: RGBAColor?
    private let actionTitle: String?
    private let onTrigger: (() -> Void)?
    private var isHovered = false
    let intrinsicSize: NSSize

    init(message: String, swatch: RGBAColor?, actionTitle: String?, onTrigger: (() -> Void)?) {
        self.message = message
        self.swatch = swatch
        self.actionTitle = actionTitle
        self.onTrigger = onTrigger

        let msgAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        ]
        let textSz = (message as NSString).size(withAttributes: msgAttrs)
        let swatchW: CGFloat = (swatch != nil) ? 22 : 0
        var actionW: CGFloat = 0
        if let act = actionTitle {
            let actSz = (act as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: 12.0, weight: .semibold)
            ])
            actionW = ceil(actSz.width + 24)
        }
        self.intrinsicSize = NSSize(width: ceil(textSz.width + 26 + swatchW + actionW), height: 34)
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        guard actionTitle != nil else { return }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func resetCursorRects() {
        if actionTitle != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { if actionTitle != nil { onTrigger?() } }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        NSColor(srgbRed: 0.10, green: 0.105, blue: 0.125, alpha: isHovered ? 0.98 : 0.93).setFill()
        bg.fill()
        (isHovered ? NSColor.systemCyan.withAlphaComponent(0.55) : NSColor.white.withAlphaComponent(0.18)).setStroke()
        bg.lineWidth = 1.0
        bg.stroke()

        var textX: CGFloat = 13
        if let sw = swatch {
            let swRect = NSRect(x: 11, y: round((bounds.height - 14) * 0.5), width: 14, height: 14)
            let swPath = NSBezierPath(roundedRect: swRect, xRadius: 3.5, yRadius: 3.5)
            NSColor(srgbRed: CGFloat(sw.r) / 255.0, green: CGFloat(sw.g) / 255.0, blue: CGFloat(sw.b) / 255.0, alpha: 1.0).setFill()
            swPath.fill()
            NSColor.white.withAlphaComponent(0.85).setStroke()
            swPath.lineWidth = 1.0
            swPath.stroke()
            textX = swRect.maxX + 8
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let ns = message as NSString
        let sz = ns.size(withAttributes: attrs)
        ns.draw(at: NSPoint(x: textX, y: round((bounds.height - sz.height) * 0.5)), withAttributes: attrs)

        if let act = actionTitle {
            let actAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12.0, weight: .semibold),
                .foregroundColor: NSColor.systemCyan
            ]
            let actNs = act as NSString
            let actSz = actNs.size(withAttributes: actAttrs)
            let sepX = bounds.width - actSz.width - 20
            NSColor.white.withAlphaComponent(0.16).setFill()
            NSRect(x: sepX, y: 8, width: 1, height: bounds.height - 16).fill()
            actNs.draw(at: NSPoint(x: sepX + 9, y: round((bounds.height - actSz.height) * 0.5)), withAttributes: actAttrs)
        }
    }
}
