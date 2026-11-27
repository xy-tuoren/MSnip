import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MSnipCore
import QuartzCore

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
            view.toolbar.ocrPresentation = ocrPresentation
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
            view.onSelectionActivated = { [weak self] sender in self?.activateView(sender) }
            view.onHoverFocusRequest = { [weak self] sender in
                guard let self else { return false }
                if self.views.contains(where: { $0 !== sender && $0.selection != nil }) { return false }
                self.activateView(sender)
                return true
            }
            view.onStyleChanged = { [weak self] cIdx, width in self?.onStyleUpdated?(cIdx, width) }
            view.onCapsuleChanged = { [weak self] enabled in self?.onCapsuleUpdated?(enabled) }
            view.onPrefsChanged = { [weak self, weak view] fmt, showTips in
                guard let self, let view else { return }
                self.onPrefsUpdated?(fmt, showTips)
                for sibling in self.views where sibling !== view {
                    sibling.colorCopyFormat = fmt
                    sibling.showShortcutTips = showTips
                }
            }
            view.onRecordingPrefsChanged = { [weak self, weak view] fmt, hud in
                guard let self, let view else { return }
                self.onRecordingPrefsUpdated?(fmt, hud)
                for sibling in self.views where sibling !== view {
                    sibling.toolbar.recordingFormat = fmt
                    sibling.toolbar.recordingHUDEnabled = hud
                }
            }
            view.onRecordingModeChanged = { [weak self, weak view] enabled in
                guard let self, let view else { return }
                for sibling in self.views where sibling !== view {
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
        FloatingTooltipHUD.hideAll()
        if let tok = interactiveActivityToken { ProcessInfo.processInfo.endActivity(tok); interactiveActivityToken = nil }
        NSCursor.pop()

        for v in views {
            v.stopOverlayVSync()
            v.barcodeScanTask?.cancel(); v.barcodeScanTask = nil
            v.deactivateInPlaceOCR(); v.deactivateInPlaceTranslate()
            v.magnifierLegendCache = nil; v.clearSessionCallbacks()
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

// MARK: - 覆盖层会话状态模型

/// 覆盖层快速启动直达模式
enum OverlayQuickLaunchMode: Equatable {
    case standard
    case quickOCR
    case quickSilentOCR
    case quickTranslate
    case quickLongShot
    case quickLatex
    case quickRecord

    var hudPrefix: String {
        switch self {
        case .standard:       return ""
        case .quickOCR:       return "识字 · "
        case .quickSilentOCR: return "静默识字 · "
        case .quickTranslate: return "翻译 · "
        case .quickLongShot:  return "长截图 · "
        case .quickLatex:     return "公式 · "
        case .quickRecord:    return "录屏 · "
        }
    }
}

/// 覆盖层交互阶段与拖拽状态
enum DragOperation {
    case pendingSnapOrCreate(anchor: CGPoint, snapRect: CGRect?)
    case creatingSelection(anchor: CGPoint)
    case movingSelection(initialRect: CGRect, mouseStart: CGPoint)
    case resizingSelection(handle: ResizeHandle, initialRect: CGRect, mouseStart: CGPoint)
    case drawingAnnotation(tool: ToolKind, start: CGPoint)
    case erasing(lastPoint: CGPoint, erased: Bool)
    case movingAnnotation(index: Int, lastPoint: CGPoint, moved: Bool)
    case resizingAnnotation(index: Int, handle: AnnotationHandle, initialPayload: AnnotationPayload, moved: Bool)
}

/// 自动矩阵识别预览与平滑过渡内聚状态模型（解耦 OverlayView 零散可变属性）
struct OverlayAutoSnapState {
    var stack: [CGRect] = []
    var index: Int = 0
    var scrollAccumulator: CGFloat = 0
    var tierAnchorPoint: CGPoint?
    var manualTierOffset: Int = 0
    var displayedRect: CGRect?
    var activeWindowRect: CGRect?
    var querySeq: UInt64 = 0
    var appliedSeq: UInt64 = 0
    var cancelToken: UInt64 = 0
    var lastQueryDispatchUptime: TimeInterval = 0
    var lastMoveUptime: TimeInterval = 0
    var smoothedSpeed: CGFloat = 0
    var settleTimer: Timer?
    var isGliding: Bool = false
    var vsyncTimer: Timer?
    var vsyncLink: AnyObject?
    var lastPolledScreenPoint: CGPoint?

    func hoveredRect(hasSelection: Bool) -> CGRect? {
        guard !hasSelection, stack.indices.contains(index) else { return nil }
        return stack[index]
    }

    mutating func clearTargets() {
        stack = []
        index = 0
        scrollAccumulator = 0
        tierAnchorPoint = nil
        manualTierOffset = 0
        displayedRect = nil
        activeWindowRect = nil
        lastMoveUptime = 0
        smoothedSpeed = 0
        cancelToken &+= 1
    }
}

/// 覆盖整个物理屏幕的无边框置顶窗口（禁用系统窗口弹出缩放动画与焦点抢占，实现 0ms 无抖动静默冻结）
final class OverlayWindow: NSPanel {
    init(screen: NSScreen, contentView: OverlayView, activateForMenu: Bool = false) {
        super.init(
            contentRect: screen.frame,
            styleMask: activateForMenu ? [.borderless] : [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.animationBehavior = .none
        self.isFloatingPanel = true
        // 必须在 isFloatingPanel = true 之后设置 level（AppKit 设置 isFloatingPanel 会把 level 重置为 .floating = 3，导致被程序坞与菜单栏遮挡）
        self.level = NSWindow.Level(rawValue: max(
            NSWindow.Level.screenSaver.rawValue,
            Int(CGShieldingWindowLevel())
        ))
        self.becomesKeyOnlyIfNeeded = false
        self.setFrame(screen.frame, display: false)
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.isOpaque = true
        self.hasShadow = false
        self.acceptsMouseMovedEvents = true

        // 静态 GPU 底图层托管冻结整屏 CGImage（WindowServer 合成器零拷贝直出，彻底免除 120Hz CPU 裁图重绘）
        let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        host.wantsLayer = true
        host.layer?.contents = contentView.snapshot.cgImage
        host.layer?.contentsGravity = .resize
        host.layer?.magnificationFilter = .nearest
        host.layer?.contentsScale = max(1.0, contentView.snapshot.scaleFactor)
        contentView.dimSnapView.frame = host.bounds
        host.addSubview(contentView.dimSnapView)
        contentView.frame = host.bounds
        contentView.wantsLayer = true
        contentView.layer?.isOpaque = false
        host.addSubview(contentView)
        self.contentView = host
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - 系统菜单焦点与事件防穿透守卫

/// 覆盖层菜单模态防卡死守护器：
/// - 检测抓取瞬间是否存在外部顶栏/右键/控制中心弹出菜单；
/// - 若存在外部菜单，在冻结覆盖层盖屏后激活 MSnip 释放 WindowServer 模态菜单抓取（若系统菜单仍滞留则安全投递带标签 Esc 解除）；
/// - 挂载兜底全局 Esc 监听，确保无论任何系统浮层抢焦点都不会让覆盖层陷入卡死无法退出的状态。
@MainActor
final class OverlayMenuFocusGuard {
    static let syntheticEscMagic: Int64 = 0x4D53_4E50_4553_4301

    private var didActivateForMenu = false
    private var previousFrontmostApp: NSRunningApplication?
    private var globalEscMonitor: Any?
    private var ignoreEscUntil: TimeInterval = 0
    private var pendingWorkItems: [DispatchWorkItem] = []

    nonisolated static func isPopupMenuWindow(layer: Int, rect: CGRect, ownerName: String) -> Bool {
        if layer >= 100 && layer <= 105 { return true } // kCGPopUpMenuWindowLevel = 101
        if layer == 25 && ownerName != "Window Server" && rect.height > 60 { return true } // 控制中心/状态栏大浮层
        return false
    }

    nonisolated static func hasExternalOpenPopupMenu() -> Bool {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let rawList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for entry in rawList {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != selfPID else { continue }
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0.05,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict),
                  rect.width >= 20, rect.height >= 20 else { continue }
            let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
            if isPopupMenuWindow(layer: layer, rect: rect, ownerName: owner) { return true }
        }
        return false
    }

    func activateOverlayIfNeeded(
        hasOpenPopupMenu: Bool,
        keyWindow: OverlayWindow?,
        initialView: OverlayView?,
        onForceCancel: @escaping @MainActor () -> Void
    ) {
        teardown(restorePreviousApp: false)

        globalEscMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard ev.keyCode == 53 else { return }
            if ev.cgEvent?.getIntegerValueField(.eventSourceUserData) == Self.syntheticEscMagic { return }
            Task { @MainActor [weak self] in
                guard let self, CACurrentMediaTime() >= self.ignoreEscUntil else { return }
                onForceCancel()
            }
        }

        guard hasOpenPopupMenu else { return }
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousFrontmostApp = front
        }
        didActivateForMenu = true
        NSApp.activate(ignoringOtherApps: true)
        keyWindow?.makeKeyAndOrderFront(nil)
        if let v = initialView { keyWindow?.makeFirstResponder(v) }

        // 25ms 后复检：若苹果菜单/系统菜单仍滞留在 WindowServer 模态循环中，发单次带标签 Esc 在幕后释放输入焦点
        let checkWork = DispatchWorkItem { [weak self, weak keyWindow, weak initialView] in
            MainActor.assumeIsolated {
                guard let self, let win = keyWindow, win.isVisible else { return }
                if Self.hasExternalOpenPopupMenu() {
                    self.ignoreEscUntil = CACurrentMediaTime() + 0.18
                    Self.postTaggedEscapeToReleaseSystemMenu()
                    let refocus = DispatchWorkItem { [weak win, weak initialView] in
                        MainActor.assumeIsolated {
                            guard let win, win.isVisible else { return }
                            NSApp.activate(ignoringOtherApps: true)
                            win.makeKeyAndOrderFront(nil)
                            if let v = initialView { win.makeFirstResponder(v) }
                        }
                    }
                    self.pendingWorkItems.append(refocus)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: refocus)
                } else if !win.isKeyWindow {
                    NSApp.activate(ignoringOtherApps: true)
                    win.makeKeyAndOrderFront(nil)
                    if let v = initialView { win.makeFirstResponder(v) }
                }
            }
        }
        pendingWorkItems.append(checkWork)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: checkWork)
    }

    func teardown(restorePreviousApp: Bool) {
        for item in pendingWorkItems { item.cancel() }
        pendingWorkItems.removeAll()
        if let m = globalEscMonitor { NSEvent.removeMonitor(m); globalEscMonitor = nil }
        if restorePreviousApp && didActivateForMenu {
            previousFrontmostApp?.activate(options: [])
        }
        didActivateForMenu = false
        previousFrontmostApp = nil
    }

    private static func postTaggedEscapeToReleaseSystemMenu() {
        guard AXIsProcessTrusted(),
              let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false) else { return }
        down.setIntegerValueField(.eventSourceUserData, value: syntheticEscMagic)
        up.setIntegerValueField(.eventSourceUserData, value: syntheticEscMagic)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
