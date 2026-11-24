import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import MSnipCore
import QuartzCore
import VideoToolbox

/// 选区动图 / 视频录制会话控制器（复用镂空鼠标穿透取景框与 `SCStream` 局部采样流）
@MainActor
final class RegionRecordingSession {
    enum Outcome {
        case copiedFile(URL, RecordingFormat)
        case savedFile(URL, RecordingFormat, String)
        case cancelled
    }

    var onFormatChanged: ((RecordingFormat) -> Void)?
    var onHUDPrefChanged: ((Bool) -> Void)?
    var onComplete: ((Outcome) -> Void)?

    var borderWindow: NSPanel?
    var drawWindow: NSPanel?
    var controlWindow: NSPanel?
    var trimController: RecordingTrimWindowController?
    let borderView = LongShotBorderView()
    let drawOverlayView = RecordingDrawOverlayView()
    let controlBar = RecordingControlBarView()
    let streamSampler = RegionStreamSampler()
    let overlayCompositor = RecordingOverlayCompositor(isEnabled: true)
    var recordingOptions = RecordingOptions()

    var encoder: MediaClipEncoder?
    var initialFrame: CGImage?
    var targetScreen: NSScreen?
    var localCaptureRect: CGRect = .zero
    var saveDirHint: String?

    var countdownTimer: Timer?
    var countdownRemaining: Int = 0
    var countdownStartedAt: TimeInterval = 0
    var tickTimer: Timer?
    var localKeyMonitor: Any?
    var globalKeyMonitor: Any?
    var globalMouseMonitor: Any?
    var accumulatedActiveTime: TimeInterval = 0
    var segmentStartMediaTime: TimeInterval?
    var paused = false
    var closed = false

    private var pauseFlagBox: RecordingFlagBox?
    private var timeOffsetBox: RecordingTimeBox?
    private var segStartBox: RecordingTimeBox?

    func start(
        screen: NSScreen,
        selectionLocalTopLeft: CGRect,
        initialCroppedFrame: CGImage?,
        defaultFormat: RecordingFormat,
        interactionHUD: Bool = true,
        recordingOptions: RecordingOptions = RecordingOptions(),
        initialSaveDirectory: String?,
        autoStartCountdown: Bool = false
    ) {
        self.targetScreen = screen
        self.localCaptureRect = selectionLocalTopLeft
        self.initialFrame = initialCroppedFrame
        self.recordingOptions = recordingOptions
        self.saveDirHint = initialSaveDirectory

        controlBar.format = defaultFormat
        controlBar.interactionHUDEnabled = interactionHUD
        overlayCompositor.isEnabled = interactionHUD
        borderView.statusStyle = .ready
        borderView.statusText = "选区录屏就绪 · 选择 GIF/MP4 后点击开始录制"

        let screenRect = Self.toAppKitScreenRect(localTopLeft: selectionLocalTopLeft, on: screen)
        borderView.pinPillInsideTop = (screenRect.maxY + LongShotBorderView.topBadgeSpace > screen.visibleFrame.maxY)
        let bFrame = NSRect(
            x: screenRect.minX - LongShotBorderView.sidePad,
            y: screenRect.minY - LongShotBorderView.sidePad,
            width: screenRect.width + LongShotBorderView.sidePad * 2,
            height: screenRect.height + LongShotBorderView.sidePad + LongShotBorderView.topBadgeSpace
        )
        let bWin = Self.makePanel(frame: bFrame, ignoresMouse: true, contentView: borderView)
        let dWin = Self.makePanel(frame: screenRect, ignoresMouse: true, contentView: drawOverlayView)
        let cWin = Self.makePanel(frame: controlBar.frame, ignoresMouse: false, contentView: controlBar)
        self.borderWindow = bWin; self.drawWindow = dWin; self.controlWindow = cWin
        setupDrawOverlayCallbacks()
        repositionControlWindow(around: screenRect, on: screen)
        controlBar.onAction = { [weak self] act in self?.handleBarAction(act) }
        installKeyMonitors()
        if autoStartCountdown { startCountdownThenRecord() }
        bWin.orderFrontRegardless(); dWin.orderFrontRegardless(); cWin.orderFrontRegardless()
    }

    private func handleBarAction(_ action: RecordingControlBarView.Action) {
        switch action {
        case .selectFormat(let fmt):
            guard !controlBar.isRecording else { return }
            controlBar.format = fmt
            onFormatChanged?(fmt)
            if let scr = targetScreen {
                repositionControlWindow(around: Self.toAppKitScreenRect(localTopLeft: localCaptureRect, on: scr), on: scr)
            }
        case .toggleInteractionHUD:
            let next = !controlBar.interactionHUDEnabled
            controlBar.interactionHUDEnabled = next; overlayCompositor.isEnabled = next; onHUDPrefChanged?(next)
            if let scr = targetScreen { repositionControlWindow(around: Self.toAppKitScreenRect(localTopLeft: localCaptureRect, on: scr), on: scr) }
        case .toggleDrawing:  toggleLiveDrawingMode()
        case .clearDrawings:  drawOverlayView.clearAll(notify: true)
        case .startRecording: if countdownTimer != nil { skipCountdownAndRecord() } else { startCountdownThenRecord() }
        case .togglePause:    togglePause()
        case .finishTrim:     finalizeRecording(saveMode: .trim)
        case .finishCopy:     finalizeRecording(saveMode: .copy)
        case .finishSave:     finalizeRecording(saveMode: .quickSave)
        case .finishSaveAs:   finalizeRecording(saveMode: .saveAs)
        case .cancel:         cancel()
        }
    }

    func beginStreamRecording() {
        guard !controlBar.isRecording, let screen = targetScreen else { return }
        countdownTimer?.invalidate(); countdownTimer = nil
        borderView.countdownNumber = nil
        controlBar.countdownNumber = nil
        let fmt = controlBar.format
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MSnipClips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Self.pruneStaleTempClips(in: dir)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let outURL = dir.appendingPathComponent("MSnip-\(stamp).\(fmt.rawValue)")

        let enc = MediaClipEncoder(format: fmt, outputURL: outURL, options: recordingOptions)
        self.encoder = enc
        self.accumulatedActiveTime = 0
        self.paused = false
        let now = CACurrentMediaTime()
        self.segmentStartMediaTime = now

        controlBar.isRecording = true
        controlBar.isPaused = false
        controlBar.elapsedSeconds = 0
        borderView.statusStyle = .recording
        borderView.statusText = "正在录制 \(fmt.badgeTitle) · 框内可直接点击操作"
        repositionControlWindow(around: Self.toAppKitScreenRect(localTopLeft: localCaptureRect, on: screen), on: screen)

        let pausedBox = RecordingFlagBox()
        let timeOffsetBox = RecordingTimeBox(accumulatedActiveTime)
        let segStartBox = RecordingTimeBox(now)
        self.pauseFlagBox = pausedBox
        self.timeOffsetBox = timeOffsetBox
        self.segStartBox = segStartBox

        let compositor = self.overlayCompositor
        var mp4ZeroCopyCallback: (@Sendable (CVPixelBuffer) -> Void)?
        if fmt == .mp4 {
            mp4ZeroCopyCallback = { pb in
                guard !pausedBox.value else { return }
                let virtualTime = timeOffsetBox.value + max(0, CACurrentMediaTime() - segStartBox.value)
                if !compositor.hasActiveVisuals(at: virtualTime),
                   enc.appendPixelBuffer(pb, at: virtualTime) {
                    return
                }
                var cg: CGImage?
                if VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &cg) == noErr, let img = cg {
                    enc.appendFrame(compositor.compositeIfNeeded(onto: img, at: virtualTime), at: virtualTime)
                }
            }
        }
        let wantAudio = (fmt == .mp4 && recordingOptions.captureSystemAudio)
        var audioCB: (@Sendable (CMSampleBuffer) -> Void)?
        if wantAudio {
            audioCB = { sb in
                guard !pausedBox.value else { return }
                let virtualTime = timeOffsetBox.value + max(0, CACurrentMediaTime() - segStartBox.value)
                enc.appendAudioSampleBuffer(sb, at: virtualTime)
            }
        }
        streamSampler.start(
            screen: screen,
            localTopLeftRect: localCaptureRect,
            fps: fmt == .gif ? recordingOptions.clampedGifFPS : recordingOptions.clampedMp4FPS,
            showsCursor: recordingOptions.showsCursor,
            capturesAudio: wantAudio,
            onFrameBackground: { frame in
                guard !pausedBox.value else { return }
                let virtualTime = timeOffsetBox.value + max(0, CACurrentMediaTime() - segStartBox.value)
                enc.appendFrame(compositor.compositeIfNeeded(onto: frame, at: virtualTime), at: virtualTime)
            },
            onPixelBufferBackground: mp4ZeroCopyCallback,
            onAudioSampleBackground: audioCB,
            onError: { [weak self] msg in
                ToastHUD.show(message: msg)
                self?.cancel()
            }
        )

        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick() }
        }
    }

    func currentActiveDuration() -> TimeInterval {
        if paused { return accumulatedActiveTime }
        let seg = segmentStartMediaTime.map { max(0, CACurrentMediaTime() - $0) } ?? 0
        return accumulatedActiveTime + seg
    }

    func togglePause() {
        guard controlBar.isRecording, !controlBar.isEncoding else { return }
        if !paused {
            accumulatedActiveTime = currentActiveDuration()
            segmentStartMediaTime = nil
            paused = true
            pauseFlagBox?.value = true
            timeOffsetBox?.value = accumulatedActiveTime
            controlBar.isPaused = true
            borderView.statusStyle = .warning
            borderView.statusText = "录制已暂停 · 点击继续或完成导出"
        } else {
            let now = CACurrentMediaTime()
            segmentStartMediaTime = now
            paused = false
            segStartBox?.value = now
            pauseFlagBox?.value = false
            controlBar.isPaused = false
            borderView.statusStyle = .recording
            borderView.statusText = "正在录制 \(controlBar.format.badgeTitle) · 框内可直接点击操作"
        }
    }

    enum RecordingSaveMode { case copy, quickSave, saveAs, trim }

    private func onTick() {
        let dur = currentActiveDuration()
        controlBar.elapsedSeconds = dur
        if dur >= controlBar.format.maxDurationSeconds {
            finalizeRecording(saveMode: .copy)
        }
    }

    func finalizeRecording(saveMode: RecordingSaveMode) {
        guard let enc = encoder, !controlBar.isEncoding else { return }
        let finalDur = max(0.15, currentActiveDuration())
        tickTimer?.invalidate(); tickTimer = nil
        streamSampler.stop()
        controlBar.isEncoding = true
        borderView.statusStyle = .stitching
        borderView.statusText = "正在封装 \(controlBar.format.badgeTitle)…"

        if enc.capturedFrameCount == 0, let fallback = initialFrame {
            enc.appendFrame(fallback, at: 0.0)
        }
        let fmt = controlBar.format
        Task { @MainActor [weak self] in
            let url = await enc.finish(finalTimestamp: finalDur)
            guard let self, !self.closed else { return }
            guard let url else {
                ToastHUD.show(message: "录制时间过短或未采集到有效画面")
                self.finishSession(.cancelled)
                return
            }
            switch saveMode {
            case .trim:
                self.presentTrimSheet(videoURL: url, format: fmt)
                return
            case .quickSave:
                if let saved = self.quickSaveMedia(tempURL: url, format: fmt) {
                    self.finishSession(.savedFile(saved.url, fmt, saved.dir))
                    return
                }
            case .saveAs:
                if let saved = self.promptSaveMedia(tempURL: url, format: fmt) {
                    self.finishSession(.savedFile(saved.url, fmt, saved.dir))
                    return
                }
            case .copy:
                break
            }
            ClipboardAndSave.copyMediaFileToClipboard(fileURL: url)
            self.finishSession(.copiedFile(url, fmt))
        }
    }

    func cancel() {
        encoder?.cancel()
        encoder = nil
        finishSession(.cancelled)
    }
}
