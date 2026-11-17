import AppKit
import Foundation
import MSnipCore

/// 清爽浅色白底非抢焦悬浮胶囊提示（自动匹配语义 SF Symbol 矢量徽标，支持可点击快捷动作）
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
            rawMessage: message,
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

        let x = min(max(vf.minX + 14, round(anchor.x - size.width * 0.5)), vf.maxX - size.width - 14)
        let preferredY = round(anchor.y + 22)
        let y = (preferredY + size.height + 14 <= vf.maxY) ? preferredY : max(vf.minY + 14, round(anchor.y - size.height - 26))

        let panel = NSPanel(
            contentRect: NSRect(x: x, y: y, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
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

        let holdDuration: TimeInterval = isInteractive ? 3.5 : 1.35
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                guard let current = activePanel, current === panel else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.20
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
    private let cleanMessage: String
    private let statusSymbol: String
    private let statusTint: NSColor
    private let swatch: RGBAColor?
    private let actionTitle: String?
    private let onTrigger: (() -> Void)?
    private var isHovered = false
    let intrinsicSize: NSSize
    override var isFlipped: Bool { true }

    init(rawMessage: String, swatch: RGBAColor?, actionTitle: String?, onTrigger: (() -> Void)?) {
        var trimmed = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let isWarn = trimmed.hasPrefix("⚠") || trimmed.contains("失败") || trimmed.contains("未") || trimmed.contains("请先")
        let isOK = trimmed.hasPrefix("✓") || trimmed.contains("已")
        if trimmed.hasPrefix("✓") || trimmed.hasPrefix("⚠") {
            trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        self.cleanMessage = trimmed
        self.statusSymbol = isWarn ? "exclamationmark.triangle.fill" : (isOK ? "checkmark.circle.fill" : "info.circle.fill")
        self.statusTint = isWarn ? MSnipUITheme.warning : (isOK ? MSnipUITheme.success : MSnipUITheme.accent)
        self.swatch = swatch
        self.actionTitle = actionTitle
        self.onTrigger = onTrigger

        let msgAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold)]
        let textSz = (trimmed as NSString).size(withAttributes: msgAttrs)
        var actionW: CGFloat = 0
        if let act = actionTitle {
            let actSz = (act as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.0, weight: .semibold)])
            actionW = ceil(actSz.width + 26)
        }
        self.intrinsicSize = NSSize(width: ceil(textSz.width + 46 + actionW), height: 36)
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
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        MSnipUITheme.drawPorcelainBar(ctx: ctx, bounds: bounds, radius: 10)
        if isHovered {
            ctx.saveGState()
            ctx.setStrokeColor(MSnipUITheme.accent.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(1.2)
            ctx.addPath(CGPath(roundedRect: bounds.insetBy(dx: 0.6, dy: 0.6), cornerWidth: 10, cornerHeight: 10, transform: nil))
            ctx.strokePath()
            ctx.restoreGState()
        }

        if let sw = swatch {
            let swRect = CGRect(x: 12, y: round((bounds.height - 14) * 0.5), width: 14, height: 14)
            ctx.saveGState()
            ctx.setFillColor(sw.cgColor)
            ctx.addPath(CGPath(roundedRect: swRect, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
            ctx.fillPath()
            ctx.setStrokeColor(MSnipUITheme.borderStrong.cgColor)
            ctx.setLineWidth(1.0)
            ctx.addPath(CGPath(roundedRect: swRect, cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
            ctx.strokePath()
            ctx.restoreGState()
        } else {
            let iconRect = CGRect(x: 11, y: 0, width: 16, height: bounds.height)
            ToolbarView.drawSymbol(statusSymbol, in: iconRect, alpha: 1.0, tint: statusTint)
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: MSnipUITheme.inkPrimary
        ]
        let ns = cleanMessage as NSString
        let sz = ns.size(withAttributes: attrs)
        ns.draw(at: CGPoint(x: 33, y: round((bounds.height - sz.height) * 0.5)), withAttributes: attrs)

        if let act = actionTitle {
            let actAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12.0, weight: .semibold),
                .foregroundColor: MSnipUITheme.accent
            ]
            let actNs = act as NSString
            let actSz = actNs.size(withAttributes: actAttrs)
            let sepX = round(bounds.width - actSz.width - 20)
            ctx.setFillColor(MSnipUITheme.borderHairline.cgColor)
            ctx.fill(CGRect(x: sepX, y: 8, width: 1, height: bounds.height - 16))
            actNs.draw(at: CGPoint(x: sepX + 9, y: round((bounds.height - actSz.height) * 0.5)), withAttributes: actAttrs)
        }
    }
}
