import AppKit
import Foundation
import MSnipCore

/// 轻量非抢焦悬浮胶囊提示（取色复制、坐标复制、OCR 识字反馈，1.2 秒自动渐隐销毁）
@MainActor
enum ToastHUD {
    private static var activePanel: NSPanel?
    private static var dismissWorkItem: DispatchWorkItem?

    static func show(message: String, swatch: RGBAColor? = nil, near screenPoint: NSPoint? = nil) {
        dismissWorkItem?.cancel()
        activePanel?.orderOut(nil)

        let contentView = ToastPillView(message: message, swatch: swatch)
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
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = contentView
        panel.alphaValue = 0.0
        panel.orderFrontRegardless()
        panel.animator().alphaValue = 1.0
        activePanel = panel

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25, execute: work)
    }
}

private final class ToastPillView: NSView {
    private let message: String
    private let swatch: RGBAColor?
    let intrinsicSize: NSSize

    init(message: String, swatch: RGBAColor?) {
        self.message = message
        self.swatch = swatch
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        ]
        let textSz = (message as NSString).size(withAttributes: attrs)
        let extraW: CGFloat = (swatch != nil) ? 22 : 0
        self.intrinsicSize = NSSize(width: ceil(textSz.width + 26 + extraW), height: 32)
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        NSColor(srgbRed: 0.10, green: 0.105, blue: 0.125, alpha: 0.92).setFill()
        bg.fill()
        NSColor.white.withAlphaComponent(0.18).setStroke()
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
    }
}
