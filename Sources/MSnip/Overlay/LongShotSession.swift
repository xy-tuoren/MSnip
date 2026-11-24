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
        case extractText(CGImage, CGFloat, NSScreen)
        case translateText(CGImage, CGFloat, NSScreen)
        case cancelled
    }

    var onComplete: ((Outcome) -> Void)?

    let stitcher = ScrollStitcher()
    let sampler = RegionStreamSampler()
    let autoScroller = AutoScroller()

    var borderPanel: NSPanel?
    var previewPanel: NSPanel?
    var controlPanel: NSPanel?
    var borderView: LongShotBorderView?
    var previewView: LongShotPreviewView?
    var controlView: LongShotControlBarView?

    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var bottomWatchdog: Timer?
    private var lastAppendTimestamp: TimeInterval = 0

    var targetScreen: NSScreen!
    var captureLocalRect: CGRect = .zero
    var scaleFactor: CGFloat = 2.0
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

    // MARK: - Actions & Stitch Updates

    private enum ExportMode { case copy, save, pin, extractText, translateText }

    func handleControlAction(_ action: LongShotControlBarView.Action) {
        switch action {
        case .toggleAutoScroll:
            let primaryH = NSScreen.screens.first?.frame.height ?? targetScreen.frame.height
            let quartzOriginY = primaryH - targetScreen.frame.maxY + captureLocalRect.minY
            let centerQuartz = CGPoint(
                x: targetScreen.frame.minX + captureLocalRect.midX,
                y: quartzOriginY + captureLocalRect.height * 0.5
            )
            autoScroller.toggle(targetQuartzPoint: centerQuartz) {
                ToastHUD.show(message: "开启「辅助功能」后可用自动滚动，当前可直接手动滚轮")
                _ = RegionDetector.checkAccessibilityPermission(prompt: true)
            }
        case .extractText:   finishWithExport(mode: .extractText)
        case .translateText: finishWithExport(mode: .translateText)
        case .pin:           finishWithExport(mode: .pin)
        case .save:          finishWithExport(mode: .save)
        case .cancel:        finish(.cancelled)
        case .finishCopy:    finishWithExport(mode: .copy)
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
            borderView?.statusText = "正在拼接 · \(stitcher.widthPx) × \(totalH) px · ⌘↩ 完成"
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
                if ProcessInfo.processInfo.systemUptime - self.lastAppendTimestamp >= 1.35 {
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
            let flags = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if ev.keyCode == 53 {
                Task { @MainActor [weak self] in self?.finish(.cancelled) }
            } else if flags == .command && (ev.keyCode == 36 || ev.keyCode == 76) {
                Task { @MainActor [weak self] in self?.finishWithExport(mode: .copy) }
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
        case .copy:          finish(.copied(finalImg, scaleFactor))
        case .save:          finish(.saved(finalImg, scaleFactor))
        case .pin:           finish(.pinned(finalImg, scaleFactor, captureLocalRect.origin, targetScreen))
        case .extractText:   finish(.extractText(finalImg, scaleFactor, targetScreen))
        case .translateText: finish(.translateText(finalImg, scaleFactor, targetScreen))
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

        borderPanel?.orderOut(nil); previewPanel?.orderOut(nil); controlPanel?.orderOut(nil)
        borderPanel = nil; previewPanel = nil; controlPanel = nil
        borderView = nil; previewView = nil; controlView = nil; fallbackInitialFrame = nil
        onComplete?(outcome)
    }
}
