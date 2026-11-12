import AppKit
import CoreGraphics
import Foundation
import MSnipCore

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

/// 一次完整的截图会话控制器：管理多显示器覆盖层窗口、历史选区记忆，会话结束后立即销毁缓冲
@MainActor
final class OverlaySession {
    enum Outcome {
        case copied(CGImage, CGFloat)
        case saved(CGImage, CGFloat)
        case pinned(CGImage, CGFloat, CGPoint, NSScreen)
        case copiedColor(String, RGBAColor, NSPoint)
        case copiedCoordinate(String, NSPoint)
        case extractText(CGImage, NSPoint)
        case cancelled
    }

    private static var lastSelectionByDisplay: [CGDirectDisplayID: CGRect] = [:]

    var onStyleUpdated: ((Int, CGFloat) -> Void)?
    var onPrefsUpdated: ((ColorCopyFormat, Bool) -> Void)?
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
        colorCopyFormat: ColorCopyFormat,
        showShortcutTips: Bool,
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
                colorCopyFormat: colorCopyFormat,
                showShortcutTips: showShortcutTips,
                lastHistorySelection: Self.lastSelectionByDisplay[snap.displayID],
                pinHint: pinHint
            )
            view.onSelectionActivated = { [weak self] sender in
                self?.activateView(sender)
            }
            view.onStyleChanged = { [weak self] cIdx, width in
                self?.onStyleUpdated?(cIdx, width)
            }
            view.onPrefsChanged = { [weak self] fmt, showTips in
                self?.onPrefsUpdated?(fmt, showTips)
                for sibling in self?.views ?? [] where sibling !== view {
                    sibling.colorCopyFormat = fmt
                    sibling.showShortcutTips = showTips
                }
            }
            view.onFinishCopy = { [weak self] img, scale, rect in
                Self.lastSelectionByDisplay[snap.displayID] = rect
                self?.finish(.copied(img, scale))
            }
            view.onFinishSave = { [weak self] img, scale, rect in
                Self.lastSelectionByDisplay[snap.displayID] = rect
                self?.finish(.saved(img, scale))
            }
            view.onFinishPin = { [weak self] img, scale, origin, screen, rect in
                Self.lastSelectionByDisplay[snap.displayID] = rect
                self?.finish(.pinned(img, scale, origin, screen))
            }
            view.onFinishCopyColor = { [weak self] value, color, pt in
                self?.finish(.copiedColor(value, color, pt))
            }
            view.onFinishCopyText = { [weak self] value, pt in
                self?.finish(.copiedCoordinate(value, pt))
            }
            view.onFinishExtractText = { [weak self] img, pt, rect in
                Self.lastSelectionByDisplay[snap.displayID] = rect
                self?.finish(.extractText(img, pt))
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

        if let initialView = activeView ?? views.first, let win = initialView.window {
            let localPt = initialView.convert(win.convertPoint(fromScreen: mouse), from: nil)
            if initialView.bounds.contains(localPt) {
                initialView.lastMousePoint = localPt
            }
            initialView.refreshAutoSnapAtCurrentMouse()
        }
    }

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
        for v in views where v !== selected {
            if v.selection != nil {
                v.clearSelectionFromSibling()
            } else {
                v.lastMousePoint = nil
                v.needsDisplay = true
            }
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
