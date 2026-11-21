import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 长截图实时滚动拼接会话控制器：
/// 管理穿透取景框、右侧实时缩略预览栏、底部非抢焦操作栏、`SCStream` 采样流与自动滚轮。
@MainActor
final class LongShotSession {
    enum Outcome {
        case copied(CGImage, CGFloat)
        case saved(CGImage, CGFloat)
        case pinned(CGImage, CGFloat, CGPoint, NSScreen)
        case cancelled
    }

    var onComplete: ((Outcome) -> Void)?

    private let stitcher = ScrollStitcher()
    private let sampler = RegionStreamSampler()
    private let autoScroller = AutoScroller()

    private var borderPanel: NSPanel?
    private var previewPanel: NSPanel?
    private var controlPanel: NSPanel?
    private var borderView: LongShotBorderView?
    private var previewView: LongShotPreviewView?
    private var controlView: LongShotControlBarView?

    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var bottomWatchdog: Timer?
    private var lastAppendTimestamp: TimeInterval = 0

    private var targetScreen: NSScreen!
    private var captureLocalRect: CGRect = .zero
    private var scaleFactor: CGFloat = 2.0
    private var fallbackInitialFrame: CGImage?
    private var finished = false

    func start(
        screen: NSScreen,
        selectionLocalTopLeft: CGRect,
        initialCroppedFrame: CGImage?,
        pinHint: String
    ) {
        self.targetScreen = screen
        self.scaleFactor = max(1.0, screen.backingScaleFactor)
        // 对齐整数逻辑点，确保首帧快照与 SCStream 物理像素宽高 0px 误差
        let rounded = CGRect(
            x: round(selectionLocalTopLeft.minX),
            y: round(selectionLocalTopLeft.minY),
            width: max(48, round(selectionLocalTopLeft.width)),
            height: max(64, round(selectionLocalTopLeft.height))
        ).intersection(CGRect(origin: .zero, size: screen.frame.size))
        self.captureLocalRect = rounded

        setupPanels(screen: screen, localRect: rounded, pinHint: pinHint)
        setupKeyboardMonitors()

        autoScroller.onStateChanged = { [weak self] running in
            guard let self else { return }
            self.controlView?.isAutoScrolling = running
            if running {
                self.lastAppendTimestamp = ProcessInfo.processInfo.systemUptime
                self.startBottomWatchdog()
            } else {
                self.bottomWatchdog?.invalidate()
                self.bottomWatchdog = nil
            }
        }

        // 首帧快照仅作 0ms 瞬时预览与兜底；拼接状态机由 SCStream 首帧实时初始化，避免前后管线差异导致首页重复拼接
        self.fallbackInitialFrame = initialCroppedFrame
        if let initImg = initialCroppedFrame {
            previewView?.previewImage = initImg
            previewView?.pixelWidth = initImg.width
            previewView?.pixelHeight = initImg.height
            borderView?.statusStyle = .ready
            borderView?.statusText = "长截图 · 在框内向下滚轮 (\(initImg.width) × \(initImg.height))"
        }

        let stitcherRef = self.stitcher
        let previewGate = PreviewThrottleGate(minInterval: 0.075)
        sampler.start(
            screen: screen,
            localTopLeftRect: rounded,
            fps: 60,
            losslessBGRA: true,
            onFrameBackground: { [weak self] frame in
                let step = stitcherRef.ingest(frame: frame)
                guard step != .unchanged, step != .scrolledBackward else { return }
                let forcePreview = (step == .reachedHeightLimit)
                let preview = previewGate.shouldRender(force: forcePreview)
                    ? stitcherRef.renderPreviewImage()
                    : nil
                Task { @MainActor [weak self] in
                    self?.applyStitchResult(step, preview: preview)
                }
            },
            onError: { [weak self] msg in
                ToastHUD.show(message: msg)
                self?.finish(.cancelled)
            }
        )
    }

    func pinCurrentIfPossible() -> Bool {
        finishWithExport(mode: .pin)
        return true
    }

    func cancel() { finish(.cancelled) }

    // MARK: - Panel Construction & Layout

    private func setupPanels(screen: NSScreen, localRect: CGRect, pinHint: String) {
        let appKitSel = NSRect(
            x: screen.frame.minX + localRect.minX,
            y: screen.frame.maxY - localRect.maxY,
            width: localRect.width,
            height: localRect.height
        )

        // 1) 鼠标完全穿透的空心取景框窗口
        let pad = LongShotBorderView.sidePad
        let topSpace = LongShotBorderView.topBadgeSpace
        let borderFrame = NSRect(
            x: appKitSel.minX - pad,
            y: appKitSel.minY - pad,
            width: appKitSel.width + pad * 2,
            height: appKitSel.height + pad + topSpace
        )
        let bp = makePanel(frame: borderFrame, ignoresMouse: true)
        let bv = LongShotBorderView(frame: NSRect(origin: .zero, size: borderFrame.size))
        bp.contentView = bv
        self.borderPanel = bp
        self.borderView = bv

        // 2) 右侧（空间不足时自动翻到左侧）实时缩略预览窗口
        let prevW: CGFloat = 152
        let prevH: CGFloat = min(max(190, appKitSel.height), 380)
        let rightX = appKitSel.maxX + 12
        let leftX = appKitSel.minX - prevW - 12
        let prevX = (rightX + prevW + 8 <= screen.frame.maxX)
            ? rightX
            : (leftX >= screen.frame.minX + 8 ? leftX : screen.frame.maxX - prevW - 10)
        let prevY = min(max(screen.visibleFrame.minY + 10, appKitSel.maxY - prevH), screen.visibleFrame.maxY - prevH - 10)
        let prevFrame = NSRect(x: round(prevX), y: round(prevY), width: prevW, height: round(prevH))

        let pp = makePanel(frame: prevFrame, ignoresMouse: true)
        let pv = LongShotPreviewView(frame: NSRect(origin: .zero, size: prevFrame.size))
        pv.baseHeightPx = Int((localRect.height * scaleFactor).rounded())
        pp.contentView = pv
        self.previewPanel = pp
        self.previewView = pv

        // 3) 底部非抢焦控制栏窗口
        let barSz = LongShotControlBarView.barSize
        let barX = min(max(screen.frame.minX + 8, appKitSel.maxX - barSz.width), screen.frame.maxX - barSz.width - 8)
        let belowY = appKitSel.minY - barSz.height - 10
        let aboveY = borderFrame.maxY + 8
        let barY = (belowY >= screen.visibleFrame.minY + 6)
            ? belowY
            : (aboveY + barSz.height <= screen.visibleFrame.maxY ? aboveY : screen.visibleFrame.minY + 12)
        let cp = makePanel(frame: NSRect(x: round(barX), y: round(barY), width: barSz.width, height: barSz.height), ignoresMouse: false)
        let cv = LongShotControlBarView()
        cv.pinHint = pinHint
        cv.onAction = { [weak self] act in self?.handleControlAction(act) }
        cp.contentView = cv
        self.controlPanel = cp
        self.controlView = cv

        bp.orderFrontRegardless()
        pp.orderFrontRegardless()
        cp.orderFrontRegardless()
    }

    private func makePanel(frame: NSRect, ignoresMouse: Bool) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar; p.animationBehavior = .none
        p.isFloatingPanel = true; p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false; p.backgroundColor = .clear
        p.hasShadow = !ignoresMouse; p.ignoresMouseEvents = ignoresMouse
        return p
    }

    // MARK: - Actions & Stitch Updates

    private enum ExportMode { case copy, save, pin }

    private func handleControlAction(_ action: LongShotControlBarView.Action) {
        switch action {
        case .toggleAutoScroll:
            let primaryH = NSScreen.screens.first?.frame.height ?? targetScreen.frame.height
            let quartzOriginY = primaryH - targetScreen.frame.maxY + captureLocalRect.minY
            let centerQuartz = CGPoint(x: targetScreen.frame.minX + captureLocalRect.midX, y: quartzOriginY + captureLocalRect.height * 0.5)
            autoScroller.toggle(targetQuartzPoint: centerQuartz) {
                ToastHUD.show(message: "开启「辅助功能」后可用自动滚动，当前可直接手动滚轮")
                _ = RegionDetector.checkAccessibilityPermission(prompt: true)
            }
        case .pin:        finishWithExport(mode: .pin)
        case .save:       finishWithExport(mode: .save)
        case .cancel:     finish(.cancelled)
        case .finishCopy: finishWithExport(mode: .copy)
        }
    }

    private func applyStitchResult(_ step: ScrollStitcher.StepResult, preview: CGImage?) {
        guard !finished else { return }
        if let preview { previewView?.previewImage = preview }
        previewView?.pixelWidth = stitcher.widthPx
        previewView?.pixelHeight = stitcher.totalHeightPx

        switch step {
        case .initialized(let w, let h):
            borderView?.statusStyle = .ready
            borderView?.statusText = "长截图 · 在框内向下滚轮 (\(w) × \(h))"
        case .appended(_, let totalH):
            lastAppendTimestamp = ProcessInfo.processInfo.systemUptime
            borderView?.statusStyle = .stitching
            borderView?.statusText = "正在拼接 · \(stitcher.widthPx) × \(totalH) px"
        case .mismatchLostOverlap:
            autoScroller.stop()
            borderView?.statusStyle = .warning
            borderView?.statusText = "⚠ 跨屏略快：往回滚可对齐，继续下滚自动续接"
        case .reachedHeightLimit:
            autoScroller.stop()
            borderView?.statusStyle = .finishedBottom
            borderView?.statusText = "已达最大拼接高度 (\(stitcher.totalHeightPx) px)，请点击完成"
        case .unchanged, .scrolledBackward:
            break
        }
    }

    private func startBottomWatchdog() {
        bottomWatchdog?.invalidate()
        let t = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.autoScroller.isRunning else { return }
                let idle = ProcessInfo.processInfo.systemUptime - self.lastAppendTimestamp
                if idle >= 1.35 {
                    self.autoScroller.stop()
                    self.borderView?.statusStyle = .finishedBottom
                    self.borderView?.statusText = "✓ 已滚动到底部 · \(self.stitcher.widthPx) × \(self.stitcher.totalHeightPx) px"
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        bottomWatchdog = t
    }

    private func setupKeyboardMonitors() {
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            if ev.keyCode == 53 { // Esc 全局取消长截图
                Task { @MainActor [weak self] in self?.finish(.cancelled) }
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self else { return ev }
            if ev.keyCode == 53 { self.finish(.cancelled); return nil }
            if ev.keyCode == 36 || ev.keyCode == 76 { self.finishWithExport(mode: .copy); return nil }
            return ev
        }
    }

    private func finishWithExport(mode: ExportMode) {
        autoScroller.stop()
        sampler.stop()
        guard let finalImg = stitcher.renderFinalImage() ?? fallbackInitialFrame else {
            finish(.cancelled)
            return
        }
        switch mode {
        case .copy: finish(.copied(finalImg, scaleFactor))
        case .save: finish(.saved(finalImg, scaleFactor))
        case .pin:  finish(.pinned(finalImg, scaleFactor, captureLocalRect.origin, targetScreen))
        }
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        autoScroller.stop()
        sampler.stop()
        bottomWatchdog?.invalidate()
        bottomWatchdog = nil
        if let gm = globalKeyMonitor { NSEvent.removeMonitor(gm); globalKeyMonitor = nil }
        if let lm = localKeyMonitor { NSEvent.removeMonitor(lm); localKeyMonitor = nil }

        borderPanel?.orderOut(nil)
        previewPanel?.orderOut(nil)
        controlPanel?.orderOut(nil)
        borderPanel = nil; previewPanel = nil; controlPanel = nil

        onComplete?(outcome)
    }
}
