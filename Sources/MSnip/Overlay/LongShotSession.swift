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
        case quickSaved(CGImage, CGFloat)
        case saved(CGImage, CGFloat)
        case pinned(CGImage, CGFloat, CGPoint, NSScreen)
        case pinAndAnnotate(CGImage, CGFloat, CGPoint, NSScreen)
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
    private var autoScrollStartHeightPx: Int = 0

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
                self.autoScrollStartHeightPx = self.stitcher.totalHeightPx
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
            fps: 36,
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

    private enum ExportMode { case copy, quickSave, save, pin, pinAndAnnotate, extractText, translateText }

    func handleControlAction(_ action: LongShotControlBarView.Action) {
        switch action {
        case .toggleAutoScroll:
            if stitcher.axis == .horizontal {
                ToastHUD.show(message: "横向长截图请手动按住 ⇧+滚轮 或双指横向滑动")
                return
            }
            let primaryH = NSScreen.screens.first?.frame.height ?? targetScreen.frame.height
            let quartzOriginY = primaryH - targetScreen.frame.maxY + captureLocalRect.minY
            // 优先落在右侧内容页边距（避开左侧固定侧边栏、右侧 16pt 滚动条与中央正文 Hover 高亮区）
            let insetRight = min(32.0, max(18.0, captureLocalRect.width * 0.08))
            let safeX = captureLocalRect.width >= 120 ? (captureLocalRect.maxX - insetRight) : captureLocalRect.midX
            let targetQuartz = CGPoint(
                x: targetScreen.frame.minX + safeX,
                y: quartzOriginY + captureLocalRect.height * 0.62
            )
            autoScroller.toggle(targetQuartzPoint: targetQuartz) {
                ToastHUD.show(message: "开启「辅助功能」后可用自动滚动，当前可直接手动滚轮")
                _ = RegionDetector.checkAccessibilityPermission(prompt: true)
            }
        case .toggleAxis:
            autoScroller.stop()
            let nextAxis: ScrollStitchAxis = (stitcher.axis == .vertical) ? .horizontal : .vertical
            stitcher.reset(axis: nextAxis)
            controlView?.axis = nextAxis
            controlView?.canUndoLast = false
            borderView?.statusStyle = .ready
            borderView?.statusText = nextAxis == .horizontal
                ? "横向长截图 · 在框内向右滑动页面拼接"
                : "纵向长截图 · 在框内向下滚轮拼接"
            if let initImg = fallbackInitialFrame {
                previewView?.previewImage = initImg
                previewView?.pixelWidth = initImg.width
                previewView?.pixelHeight = initImg.height
                previewView?.isFollowingTail = false
            }
        case .undoLast:
            performUndoLastAppend()
        case .annotate:      finishWithExport(mode: .pinAndAnnotate)
        case .extractText:   finishWithExport(mode: .extractText)
        case .translateText: finishWithExport(mode: .translateText)
        case .pin:           finishWithExport(mode: .pin)
        case .save:          finishWithExport(mode: .quickSave)
        case .saveAs:        finishWithExport(mode: .save)
        case .cancel:        finish(.cancelled)
        case .finishCopy:    finishWithExport(mode: .copy)
        }
    }

    private func performUndoLastAppend() {
        autoScroller.stop()
        guard stitcher.undoLastAppend() else {
            ToastHUD.show(message: "暂无可撤回的上一段拼接")
            return
        }
        let sz = stitcher.outputSizePx
        previewView?.previewImage = stitcher.renderPreviewImage() ?? fallbackInitialFrame
        previewView?.pixelWidth = sz.width
        previewView?.pixelHeight = sz.height
        previewView?.isFollowingTail = Double(max(sz.width, sz.height)) / Double(max(1, min(sz.width, sz.height))) > 2.8
        controlView?.canUndoLast = stitcher.canUndoAppend
        borderView?.statusStyle = .ready
        borderView?.statusText = "已撤回上一段 · \(sz.width) × \(sz.height) px · 可继续滚动"
    }

    private func applyStitchResult(_ step: ScrollStitcher.StepResult, preview: CGImage?) {
        guard !finished else { return }
        if let preview { previewView?.previewImage = preview }
        let sz = stitcher.outputSizePx
        previewView?.pixelWidth = sz.width
        previewView?.pixelHeight = sz.height
        let longSide = max(sz.width, sz.height), shortSide = max(1, min(sz.width, sz.height))
        previewView?.isFollowingTail = Double(longSide) / Double(shortSide) > 2.8
        controlView?.canUndoLast = stitcher.canUndoAppend

        switch step {
        case .initialized(let w, let h):
            borderView?.statusStyle = .ready
            borderView?.statusText = stitcher.axis == .horizontal
                ? "横向长截图 · 在框内向右滚动 (\(w) × \(h))"
                : "长截图 · 在框内向下滚轮 (\(w) × \(h))"
        case .appended:
            lastAppendTimestamp = ProcessInfo.processInfo.systemUptime
            borderView?.statusStyle = .stitching
            borderView?.statusText = "正在拼接 · \(sz.width) × \(sz.height) px · ⌘Z 撤回 · ⌘↩ 完成"
        case .mismatchLostOverlap:
            autoScroller.stop()
            borderView?.statusStyle = .warning
            borderView?.statusText = "⚠ 跨屏略快：往回滚可对齐，继续滚动自动续接"
        case .reachedHeightLimit:
            autoScroller.stop()
            borderView?.statusStyle = .finishedBottom
            borderView?.statusText = "已达最大拼接长度 (\(sz.width) × \(sz.height) px)，请点击完成"
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
                    let moved = self.stitcher.totalHeightPx > self.autoScrollStartHeightPx
                    self.autoScroller.stop()
                    if moved {
                        self.borderView?.statusStyle = .finishedBottom
                        self.borderView?.statusText = "✓ 已滚动到底部 · \(self.stitcher.widthPx) × \(self.stitcher.totalHeightPx) px"
                    } else {
                        self.borderView?.statusStyle = .warning
                        self.borderView?.statusText = "⚠ 未检测到页面滚动：请确认窗口焦点或手动在框内滚轮"
                    }
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        bottomWatchdog = t
    }

    private func setupKeyboardMonitors() {
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            let flags = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let ch = ev.charactersIgnoringModifiers?.lowercased() ?? ""
            if ev.keyCode == 53 {
                Task { @MainActor [weak self] in self?.finish(.cancelled) }
            } else if flags == .command && (ev.keyCode == 36 || ev.keyCode == 76) {
                Task { @MainActor [weak self] in self?.finishWithExport(mode: .copy) }
            } else if flags == .command && ch == "z" {
                Task { @MainActor [weak self] in self?.performUndoLastAppend() }
            }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self else { return ev }
            let flags = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let ch = ev.charactersIgnoringModifiers?.lowercased() ?? ""
            if ev.keyCode == 53 { self.finish(.cancelled); return nil }
            if ev.keyCode == 36 || ev.keyCode == 76 { self.finishWithExport(mode: .copy); return nil }
            if flags == .command && ch == "z" { self.performUndoLastAppend(); return nil }
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
        case .copy:           finish(.copied(finalImg, scaleFactor))
        case .quickSave:      finish(.quickSaved(finalImg, scaleFactor))
        case .save:           finish(.saved(finalImg, scaleFactor))
        case .pin:            finish(.pinned(finalImg, scaleFactor, captureLocalRect.origin, targetScreen))
        case .pinAndAnnotate: finish(.pinAndAnnotate(finalImg, scaleFactor, captureLocalRect.origin, targetScreen))
        case .extractText:    finish(.extractText(finalImg, scaleFactor, targetScreen))
        case .translateText:  finish(.translateText(finalImg, scaleFactor, targetScreen))
        }
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        FloatingTooltipHUD.hideAll()
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
