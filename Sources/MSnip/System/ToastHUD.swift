import AppKit
import CoreGraphics
import Foundation
import MSnipCore
import QuartzCore

/// 高优先级非激活悬浮通知面板（四周预留真实投影边距，首击直达不吞事件）
final class ToastPanel: NSPanel {
    let interactive: Bool

    init(frame: NSRect, interactive: Bool) {
        self.interactive = interactive
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.animationBehavior = .none
        self.isFloatingPanel = true
        self.level = NSWindow.Level(rawValue: max(
            NSWindow.Level.screenSaver.rawValue + 10,
            Int(CGShieldingWindowLevel()) + 10
        ))
        self.becomesKeyOnlyIfNeeded = true
        self.hidesOnDeactivate = false
        self.acceptsMouseMovedEvents = interactive
        self.ignoresMouseEvents = !interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    override var canBecomeKey: Bool { interactive }
    override var canBecomeMain: Bool { false }
}

/// 陶瓷白立体悬浮通知卡片 HUD：
/// - 位于屏幕底部居中黄金视线区（Dock 上方），上滑回弹入场，不遮挡顶部标签栏与标题栏；
/// - 快存通知内置真实截图缩略图预览、底部倒计时细进度条（悬停自动暂停）与首击直达访达按钮。
@MainActor
enum ToastHUD {
    private static var activePanel: ToastPanel?
    private static var dismissWorkItem: DispatchWorkItem?
    private static var progressTimer: Timer?

    static func show(
        message: String,
        subtitle: String? = nil,
        preview: CGImage? = nil,
        swatch: RGBAColor? = nil,
        near screenPoint: NSPoint? = nil,
        actionTitle: String? = nil,
        onAction: (() -> Void)? = nil
    ) {
        dismissImmediate()
        let isInteractive = (actionTitle != nil && onAction != nil)
        let holdSeconds: TimeInterval = isInteractive ? 6.0 : 2.3
        let contentView = ToastCardView(
            rawMessage: message,
            subtitle: subtitle,
            preview: preview,
            swatch: swatch,
            actionTitle: actionTitle,
            onTrigger: { dismissImmediate(); onAction?() },
            onClose: { dismissImmediate() },
            onHoverChanged: { handleHoverChanged($0, holdSeconds: holdSeconds) }
        )
        let size = contentView.panelSize
        contentView.frame = NSRect(origin: .zero, size: size)

        let probe = screenPoint ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(probe) })
            ?? NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let targetFrame: NSRect
        if let anchor = screenPoint {
            let x = min(max(vf.minX + 6, round(anchor.x - size.width * 0.5)), vf.maxX - size.width - 6)
            let prefY = round(anchor.y + 14)
            let y = (prefY + size.height <= vf.maxY) ? prefY : max(vf.minY + 6, round(anchor.y - size.height - 18))
            targetFrame = NSRect(x: x, y: y, width: size.width, height: size.height)
        } else {
            let x = round(vf.midX - size.width * 0.5)
            let y = round(vf.minY + max(40, min(68, vf.height * 0.055)))
            targetFrame = NSRect(x: x, y: y, width: size.width, height: size.height)
        }

        let startFrame = (screenPoint == nil) ? targetFrame.offsetBy(dx: 0, dy: -18) : targetFrame
        let panel = ToastPanel(frame: startFrame, interactive: isInteractive)
        panel.contentView = contentView
        panel.alphaValue = (screenPoint == nil) ? 0.85 : 1.0
        panel.orderFrontRegardless()
        if screenPoint == nil {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.30, 1.0)
                panel.animator().setFrame(targetFrame, display: true)
                panel.animator().alphaValue = 1.0
            }
        }
        activePanel = panel
        startCountdown(duration: holdSeconds, for: panel, view: contentView)
    }

    static func dismissImmediate() {
        dismissWorkItem?.cancel(); dismissWorkItem = nil
        progressTimer?.invalidate(); progressTimer = nil
        activePanel?.orderOut(nil); activePanel = nil
    }

    private static func handleHoverChanged(_ hovering: Bool, holdSeconds: TimeInterval) {
        guard let panel = activePanel, let view = panel.contentView as? ToastCardView else { return }
        if hovering {
            dismissWorkItem?.cancel(); dismissWorkItem = nil
            progressTimer?.invalidate(); progressTimer = nil
            panel.alphaValue = 1.0
            view.remainingProgress = 1.0
        } else {
            startCountdown(duration: min(holdSeconds, 3.0), for: panel, view: view)
        }
    }

    private static func startCountdown(duration: TimeInterval, for panel: ToastPanel, view: ToastCardView) {
        dismissWorkItem?.cancel()
        progressTimer?.invalidate()
        let startAt = CACurrentMediaTime()
        if view.hasAction {
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in
                MainActor.assumeIsolated {
                    guard activePanel === panel else { return }
                    let ratio = max(0.0, 1.0 - (CACurrentMediaTime() - startAt) / duration)
                    view.remainingProgress = CGFloat(ratio)
                }
            }
            RunLoop.main.add(t, forMode: .common)
            progressTimer = t
        }
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                guard let current = activePanel, current === panel else { return }
                progressTimer?.invalidate(); progressTimer = nil
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.20
                    current.animator().alphaValue = 0.0
                    current.animator().setFrame(current.frame.offsetBy(dx: 0, dy: -10), display: true)
                } completionHandler: {
                    MainActor.assumeIsolated {
                        if activePanel === panel { panel.orderOut(nil); activePanel = nil }
                    }
                }
            }
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
