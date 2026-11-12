import AppKit
import CoreGraphics
import Foundation

/// 覆盖整个物理屏幕的无边框置顶窗口（高于菜单栏与 Dock，支持全屏 App 空间）
private final class OverlayWindow: NSPanel {
    init(screen: NSScreen, contentView: NSView) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.setFrame(screen.frame, display: false)
        self.level = .screenSaver
        self.isFloatingPanel = true
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.isOpaque = true
        self.hasShadow = false
        self.acceptsMouseMovedEvents = true
        self.contentView = contentView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 一次完整的截图会话控制器：管理多显示器覆盖层窗口，会话结束后立即销毁全部缓冲
@MainActor
final class OverlaySession {
    enum Outcome {
        case copied(CGImage, CGFloat)
        case saved(CGImage, CGFloat)
        case pinned(CGImage, CGFloat, CGPoint, NSScreen)
        case cancelled
    }

    var onStyleUpdated: ((Int, CGFloat) -> Void)?
    var onComplete: ((Outcome) -> Void)?

    private var windows: [OverlayWindow] = []
    private var views: [OverlayView] = []
    private weak var activeView: OverlayView?
    private var finished = false

    func start(
        snapshots: [ScreenSnapshot],
        regionDetector: RegionDetector,
        colorIndex: Int,
        lineWidth: CGFloat,
        pinHint: String
    ) {
        let mouse = NSEvent.mouseLocation
        var targetWindowToFocus: OverlayWindow?

        for snap in snapshots {
            let view = OverlayView(
                snapshot: snap,
                regionDetector: regionDetector,
                initialColorIndex: colorIndex,
                initialLineWidth: lineWidth,
                pinHint: pinHint
            )
            view.onSelectionActivated = { [weak self] sender in
                self?.activateView(sender)
            }
            view.onStyleChanged = { [weak self] cIdx, width in
                self?.onStyleUpdated?(cIdx, width)
            }
            view.onFinishCopy = { [weak self] img, scale in
                self?.finish(.copied(img, scale))
            }
            view.onFinishSave = { [weak self] img, scale in
                self?.finish(.saved(img, scale))
            }
            view.onFinishPin = { [weak self] img, scale, origin, screen in
                self?.finish(.pinned(img, scale, origin, screen))
            }
            view.onCancel = { [weak self] in
                self?.finish(.cancelled)
            }

            let win = OverlayWindow(screen: snap.screen, contentView: view)
            windows.append(win)
            views.append(view)
            if snap.screen.frame.contains(mouse) {
                targetWindowToFocus = win
                activeView = view
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        for win in windows {
            win.orderFrontRegardless()
        }
        let keyWin = targetWindowToFocus ?? windows.first
        keyWin?.makeKeyAndOrderFront(nil)
        if let v = keyWin?.contentView {
            keyWin?.makeFirstResponder(v)
        }
        NSCursor.crosshair.push()
        // 打开截图瞬间立即探测并高亮当前鼠标正下方的窗口/控件矩阵
        (activeView ?? views.first)?.refreshAutoSnapAtCurrentMouse()
    }

    /// 当用户在截图过程中按下全局贴图热键（如 `⌘2`）时，直接将当前正式选区或自动识别悬停框贴到桌面
    func pinCurrentSelectionIfPossible() -> Bool {
        guard let view = activeView ?? views.first(where: { ($0.selection ?? $0.hoveredAutoRect) != nil }),
              (view.selection ?? view.hoveredAutoRect) != nil else {
            return false
        }
        view.exportAndFinish(mode: .pin)
        return true
    }

    func cancel() {
        finish(.cancelled)
    }

    private func activateView(_ selected: OverlayView) {
        activeView = selected
        for v in views where v !== selected && v.selection != nil {
            v.clearSelectionFromSibling()
        }
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        NSCursor.pop()

        for win in windows {
            win.contentView = nil
            win.orderOut(nil)
        }
        views.removeAll()
        windows.removeAll()

        onComplete?(outcome)
    }
}
