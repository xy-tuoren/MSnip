import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 一次完整的截图会话控制器：管理多显示器覆盖层窗口、历史选区记忆，会话结束后立即销毁缓冲
@MainActor
final class OverlaySession {
    enum Outcome {
        case copied(CGImage, CGFloat)
        case copiedWithPath(CGImage, CGFloat)
        case saved(CGImage, CGFloat)
        case quickSaved(CGImage, CGFloat)
        case savedToFolder(CGImage, CGFloat, String)
        case pinned(CGImage, CGFloat, CGPoint, NSScreen, CGFloat?)
        case isolatedWindow(CGWindowID, CGFloat, BackdropStyle, Bool, CGPoint, NSScreen)
        case copiedColor(String, RGBAColor, NSPoint)
        case copiedCoordinate(String, NSPoint)
        case extractText(CGImage, CGFloat, NSScreen)
        case silentExtractText(CGImage, CGFloat, NSScreen)
        case recognizeLatex(CGImage, CGFloat, NSScreen)
        case translateText(CGImage, CGFloat, NSScreen)
        case openTranslationSettings
        case startLongShot(NSScreen, CGRect, CGImage?)
        case startRecording(NSScreen, CGRect, CGImage?)
        case cancelled
    }

    private static var lastSelectionByDisplay: [CGDirectDisplayID: CGRect] = [:]
    static var lastCaptureTarget: (displayID: CGDirectDisplayID, rect: CGRect)?

    private static func rememberSelection(_ rect: CGRect, on displayID: CGDirectDisplayID) {
        lastSelectionByDisplay[displayID] = rect
        lastCaptureTarget = (displayID, rect)
    }

    var onStyleUpdated: ((Int, CGFloat) -> Void)?
    var onCapsuleUpdated: ((Bool) -> Void)?
    var onPrefsUpdated: ((ColorCopyFormat, Bool) -> Void)?
    var onRecordingPrefsUpdated: ((RecordingFormat, Bool) -> Void)?
    var onGlowStrengthUpdated: ((CGFloat) -> Void)?
    var onQuickSaveInPlace: ((CGImage, CGFloat) -> Void)?
    var onComplete: ((Outcome) -> Void)?

    private var windows: [OverlayWindow] = []
    private var views: [OverlayView] = []
    private weak var activeView: OverlayView?
    private let focusGuard = OverlayMenuFocusGuard()
    private var interactiveActivityToken: NSObjectProtocol?
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
        recordingFormat: RecordingFormat = .gif,
        recordingHUDEnabled: Bool = true,
        launchMode: OverlayQuickLaunchMode = .standard,
        canvasKeyMap: [CanvasAction: String] = CanvasAction.defaultMap,
        activePinCombo: KeyCombo? = nil,
        ocrPresentation: OCRDefaultPresentation = .inPlace,
        translateAutoOpenDualPane: Bool = false,
        ocrAutoCopy: Bool = true,
        backdropAspectRatio: BackdropAspectRatio = .auto,
        backdropWatermark: String = "",
        pinGlowStrength: CGFloat = 0.45
    ) {
        let mouse = NSEvent.mouseLocation
        let actOpts: ProcessInfo.ActivityOptions = { if #available(macOS 13.0, *) { return [.userInteractive, .latencyCritical] }; return [.userInitiated, .latencyCritical] }()
        interactiveActivityToken = ProcessInfo.processInfo.beginActivity(options: actOpts, reason: "MSnip Interactive Overlay Capture")
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
            view.toolbar.recordingFormat = recordingFormat
            view.toolbar.recordingHUDEnabled = recordingHUDEnabled
            view.toolbar.canvasKeyMap = canvasKeyMap
            view.toolbar.ocrAutoOpenDualPane = (ocrPresentation == .dualPane)
            view.toolbar.translateAutoOpenDualPane = translateAutoOpenDualPane
            view.saveFolderOptions = saveFolderOptions
            view.quickLaunchMode = launchMode
            view.canvasKeyMap = canvasKeyMap
            view.activePinCombo = activePinCombo
            view.ocrPresentation = ocrPresentation
            view.translateAutoOpenDualPane = translateAutoOpenDualPane
            view.ocrAutoCopy = ocrAutoCopy
            view.backdropAspectRatio = backdropAspectRatio
            view.backdropWatermark = backdropWatermark
            view.defaultPinGlowStrength = pinGlowStrength
            view.onGlowStrengthChanged = { [weak self] g in self?.onGlowStrengthUpdated?(g) }
            if launchMode == .quickRecord { view.setRecordingMode(true, notifySiblings: false) }
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
            view.onRecordingPrefsChanged = { [weak self] fmt, hud in
                self?.onRecordingPrefsUpdated?(fmt, hud)
                for sibling in self?.views ?? [] where sibling !== view {
                    sibling.toolbar.recordingFormat = fmt
                    sibling.toolbar.recordingHUDEnabled = hud
                }
            }
            view.onRecordingModeChanged = { [weak self] enabled in
                for sibling in self?.views ?? [] where sibling !== view {
                    sibling.setRecordingMode(enabled, notifySiblings: false)
                }
            }
            view.onFinishCopy = { [weak self] img, scale, rect in
                Self.rememberSelection(rect, on: snap.displayID)
                self?.finish(.copied(img, scale))
            }
            view.onFinishCopyWithPath = { [weak self] img, scale, rect in
                Self.rememberSelection(rect, on: snap.displayID)
                self?.finish(.copiedWithPath(img, scale))
            }
            view.onFinishSave = { [weak self] img, scale, rect in
                Self.rememberSelection(rect, on: snap.displayID)
                self?.finish(.saved(img, scale))
            }
            view.onFinishSaveToFolder = { [weak self] img, scale, dir, rect in
                Self.rememberSelection(rect, on: snap.displayID)
                self?.finish(.savedToFolder(img, scale, dir))
            }
            view.onQuickSaveInPlace = { [weak self] img, scale, rect in
                Self.rememberSelection(rect, on: snap.displayID)
                self?.finish(.quickSaved(img, scale))
            }
            view.onFinishPin = { [weak self] img, scale, origin, screen, rect, glowOverride in
                Self.rememberSelection(rect, on: snap.displayID)
                self?.finish(.pinned(img, scale, origin, screen, glowOverride))
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
            view.onFinishSilentOCR = { [weak self] img, scale, scr, rect in
                Self.lastSelectionByDisplay[snap.displayID] = rect
                self?.finish(.silentExtractText(img, scale, scr))
            }
            view.onFinishRecognizeLatex = { [weak self] img, scale, scr, rect in
                Self.lastSelectionByDisplay[snap.displayID] = rect
                self?.finish(.recognizeLatex(img, scale, scr))
            }
            view.onFinishTranslateWindow = { [weak self] img, scale, scr, rect in Self.lastSelectionByDisplay[snap.displayID] = rect; self?.finish(.translateText(img, scale, scr)) }
            view.onOpenTranslationSettings = { [weak self] in self?.finish(.openTranslationSettings) }
            view.onStartLongShot = { [weak self] screen, rect, initialImg in Self.lastSelectionByDisplay[snap.displayID] = rect; self?.finish(.startLongShot(screen, rect, initialImg)) }
            view.onStartRecording = { [weak self] screen, rect, initialImg in Self.lastSelectionByDisplay[snap.displayID] = rect; self?.finish(.startRecording(screen, rect, initialImg)) }
            view.onCancel = { [weak self] in self?.finish(.cancelled) }

            let win = OverlayWindow(screen: snap.screen, contentView: view, activateForMenu: regionDetector.hasOpenPopupMenu)
            windows.append(win)
            views.append(view)
            if snap.screen.frame.contains(mouse) {
                targetWindowToFocus = win
                activeView = view
            }
        }

        // 1) 上屏前以 0.001ms 窗口级命中完成首帧冻结布局，不等待整屏像素解包
        for v in views { v.syncGPUChromeLayers() }
        let initialView = activeView ?? views.first
        if let initialView {
            let sf = initialView.snapshot.screen.frame
            let localPt = CGPoint(x: mouse.x - sf.minX, y: sf.maxY - mouse.y)
            if initialView.bounds.contains(localPt) {
                initialView.lastMousePoint = localPt
                initialView.updateAutoSnap(at: localPt, immediate: true, fastWindowOnly: !initialView.snapshot.isSamplerReady)
                initialView.syncMagnifierView()
            }
        }

        // 2) 不调用 NSApp.activate：底层前台窗口保持激活（标题栏与阴影 0px 跳变），同时通过 nonactivatingPanel 直接接管键盘焦点
        let keyWin = targetWindowToFocus ?? windows.first
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        for (win, view) in zip(windows, views) {
            win.makeFirstResponder(view)
            win.displayIfNeeded()
            if win !== keyWin {
                win.orderFrontRegardless()
            }
        }
        keyWin?.orderFrontRegardless()
        keyWin?.makeKey()
        NSAnimationContext.endGrouping()
        focusGuard.activateOverlayIfNeeded(
            hasOpenPopupMenu: regionDetector.hasOpenPopupMenu,
            keyWindow: keyWin,
            initialView: initialView
        ) { [weak self] in self?.cancel() }
        NSCursor.crosshair.push()
        for v in views { v.startOverlayVSync() }

        // 3) 冻结窗口已上屏后再在后台预热主屏 PixelSampler，就绪后自动补齐视觉子框、放大镜与副屏采样器
        if let initialView {
            initialView.snapshot.preheatSamplerInBackground { [weak self, weak initialView] in
                guard let self, !self.finished, let v = initialView else { return }
                if v.selection == nil { v.refreshAutoSnapAtCurrentMouse() }
                v.syncMagnifierView()
                for sibling in self.views where sibling !== v {
                    sibling.snapshot.preheatSamplerInBackground { [weak sibling] in sibling?.syncMagnifierView() }
                }
            }
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
        guard activeView !== selected else { return }
        activeView = selected
        for v in views where v !== selected {
            if v.selection != nil { v.clearSelectionFromSibling() }
            else { v.lastMousePoint = nil; v.syncMagnifierView(); v.syncGPUChromeLayers() }
        }
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        if let tok = interactiveActivityToken { ProcessInfo.processInfo.endActivity(tok); interactiveActivityToken = nil }
        NSCursor.pop()

        for v in views {
            v.stopOverlayVSync()
            v.barcodeScanTask?.cancel(); v.barcodeScanTask = nil
            v.deactivateInPlaceOCR()
            v.deactivateInPlaceTranslate()
            v.magnifierLegendCache = nil
        }
        for win in windows {
            win.contentView?.layer?.contents = nil
            win.contentView = nil
            win.orderOut(nil)
        }
        views.removeAll()
        windows.removeAll()
        AnnotationRenderer.purgeCaches()
        let shouldRestorePrev: Bool = switch outcome {
        case .copied, .copiedWithPath, .quickSaved, .savedToFolder, .copiedColor, .copiedCoordinate, .silentExtractText, .cancelled: true
        default: false
        }
        focusGuard.teardown(restorePreviousApp: shouldRestorePrev); onComplete?(outcome)
    }
}
