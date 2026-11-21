import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 覆盖整个物理屏幕的无边框置顶窗口（禁用系统窗口弹出缩放动画与焦点抢占，实现 0ms 无抖动静默冻结）
private final class OverlayWindow: NSPanel {
    init(screen: NSScreen, contentView: NSView) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = .screenSaver
        self.animationBehavior = .none
        self.becomesKeyOnlyIfNeeded = false
        self.setFrame(screen.frame, display: false)
        self.isFloatingPanel = true
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.isOpaque = true
        self.hasShadow = false
        self.acceptsMouseMovedEvents = true
        self.contentView = contentView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 一次完整的截图会话控制器：管理多显示器覆盖层窗口、历史选区记忆，会话结束后立即销毁缓冲
@MainActor
final class OverlaySession {
    enum Outcome {
        case copied(CGImage, CGFloat)
        case saved(CGImage, CGFloat)
        case quickSaved(CGImage, CGFloat)
        case savedToFolder(CGImage, CGFloat, String)
        case pickDirectorySave(CGImage, CGFloat)
        case pinned(CGImage, CGFloat, CGPoint, NSScreen)
        case isolatedWindow(CGWindowID, CGFloat, BackdropStyle, Bool, CGPoint, NSScreen)
        case copiedColor(String, RGBAColor, NSPoint)
        case copiedCoordinate(String, NSPoint)
        case extractText(CGImage, CGFloat, NSScreen)
        case translateText(CGImage, CGFloat, NSScreen)
        case openTranslationSettings
        case startLongShot(NSScreen, CGRect, CGImage?)
        case startRecording(NSScreen, CGRect, CGImage?)
        case cancelled
    }

    private static var lastSelectionByDisplay: [CGDirectDisplayID: CGRect] = [:]

    var onStyleUpdated: ((Int, CGFloat) -> Void)?
    var onCapsuleUpdated: ((Bool) -> Void)?
    var onPrefsUpdated: ((ColorCopyFormat, Bool) -> Void)?
    var onQuickSaveInPlace: ((CGImage, CGFloat) -> Void)?
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
        textCapsule: Bool = false,
        pinHint: String,
        saveFolderOptions: [QuickSaveFolder] = [],
        quickOCRMode: Bool = false,
        quickTranslateMode: Bool = false
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
            view.style.textCapsule = textCapsule
            view.toolbar.textCapsule = textCapsule
            view.saveFolderOptions = saveFolderOptions
            view.quickOCRMode = quickOCRMode
            view.quickTranslateMode = quickTranslateMode
            view.onSelectionActivated = { [weak self] sender in
                self?.activateView(sender)
            }
            view.onStyleChanged = { [weak self] cIdx, width in
                self?.onStyleUpdated?(cIdx, width)
            }
            view.onCapsuleChanged = { [weak self] enabled in
                self?.onCapsuleUpdated?(enabled)
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
            view.onFinishSaveToFolder = { [weak self] img, scale, dir, rect in
                Self.lastSelectionByDisplay[snap.displayID] = rect
                self?.finish(.savedToFolder(img, scale, dir))
            }
            view.onFinishPickDirectorySave = { [weak self] img, scale, rect in
                Self.lastSelectionByDisplay[snap.displayID] = rect
                self?.finish(.pickDirectorySave(img, scale))
            }
            view.onQuickSaveInPlace = { [weak self] img, scale, rect in
                Self.lastSelectionByDisplay[snap.displayID] = rect
                self?.onQuickSaveInPlace?(img, scale)
            }
            view.onFinishPin = { [weak self] img, scale, origin, screen, rect in
                Self.lastSelectionByDisplay[snap.displayID] = rect
                self?.finish(.pinned(img, scale, origin, screen))
            }
            view.onFinishIsolatedWindow = { [weak self] winID, scale, backdrop, pin, origin, screen in
                self?.finish(.isolatedWindow(winID, scale, backdrop, pin, origin, screen))
            }
            view.onFinishCopyColor = { [weak self] value, color, pt in
                self?.finish(.copiedColor(value, color, pt))
            }
            view.onFinishCopyText = { [weak self] value, pt in
                self?.finish(.copiedCoordinate(value, pt))
            }
            view.onFinishExtractText = { [weak self] img, scale, scr, rect in
                Self.lastSelectionByDisplay[snap.displayID] = rect
                self?.finish(.extractText(img, scale, scr))
            }
            view.onFinishTranslateWindow = { [weak self] img, scale, scr, rect in
                Self.lastSelectionByDisplay[snap.displayID] = rect
                self?.finish(.translateText(img, scale, scr))
            }
            view.onOpenTranslationSettings = { [weak self] in
                self?.finish(.openTranslationSettings)
            }
            view.onStartLongShot = { [weak self] screen, rect, initialImg in
                Self.lastSelectionByDisplay[snap.displayID] = rect
                self?.finish(.startLongShot(screen, rect, initialImg))
            }
            view.onStartRecording = { [weak self] screen, rect, initialImg in
                Self.lastSelectionByDisplay[snap.displayID] = rect
                self?.finish(.startRecording(screen, rect, initialImg))
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

        // 1) 在窗口上屏前预先计算好首帧自动吸附矩阵与放大镜坐标，并完成离屏栅格化，杜绝两帧闪烁
        if let initialView = activeView ?? views.first {
            let sf = initialView.snapshot.screen.frame
            let localPt = CGPoint(x: mouse.x - sf.minX, y: sf.maxY - mouse.y)
            if initialView.bounds.contains(localPt) {
                initialView.lastMousePoint = localPt
                initialView.updateAutoSnap(at: localPt, immediate: true)
                initialView.syncMagnifierView()
            }
        }

        // 2) 不调用 NSApp.activate：底层前台窗口保持激活（标题栏与阴影 0px 跳变），同时通过 nonactivatingPanel 直接接管键盘焦点
        let keyWin = targetWindowToFocus ?? windows.first
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        for win in windows {
            if let v = win.contentView { win.makeFirstResponder(v) }
            win.displayIfNeeded()
            if win !== keyWin {
                win.orderFrontRegardless()
            }
        }
        keyWin?.makeKeyAndOrderFront(nil)
        NSAnimationContext.endGrouping()
        NSCursor.crosshair.push()
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
        AnnotationRenderer.purgeCaches()

        onComplete?(outcome)
    }
}
