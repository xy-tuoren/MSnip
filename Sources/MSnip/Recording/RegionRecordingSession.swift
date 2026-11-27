import AppKit
import Carbon
import CoreGraphics
import CoreVideo
import Foundation
import MSnipCore
import QuartzCore
import UniformTypeIdentifiers
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
    var onCaptureStopped: (() -> Void)?
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

        let scale = max(1.0, screen.backingScaleFactor)
        let mp4Size = recordingOptions.mp4Resolution.scaledEvenSize(
            width: max(64, Int((localCaptureRect.width * scale).rounded())),
            height: max(64, Int((localCaptureRect.height * scale).rounded()))
        )
        let resolvedMP4FPS = recordingOptions.mp4FPSMode.resolveFPS(
            displayMaxFPS: screen.maximumFramesPerSecond, outputWidth: mp4Size.width, outputHeight: mp4Size.height
        )
        let enc = MediaClipEncoder(format: fmt, outputURL: outURL, options: recordingOptions, targetMP4FPS: resolvedMP4FPS)
        self.encoder = enc; self.accumulatedActiveTime = 0; self.paused = false
        let now = CACurrentMediaTime(); self.segmentStartMediaTime = now

        controlBar.isRecording = true; controlBar.isPaused = false; controlBar.elapsedSeconds = 0
        borderView.statusStyle = .recording
        let fpsTag = fmt == .mp4 ? " \(resolvedMP4FPS)fps" : " \(recordingOptions.clampedGifFPS)fps"
        borderView.statusText = "正在录制 \(fmt.badgeTitle)\(fpsTag) · 框内可直接点击操作"
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
            fps: fmt == .gif ? recordingOptions.clampedGifFPS : resolvedMP4FPS,
            showsCursor: recordingOptions.showsCursor,
            maxLongSide: fmt == .mp4 ? recordingOptions.mp4Resolution.maxLongSide : nil,
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

        guard !closed else { return }
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

    var isShowingTrimWindow: Bool { trimController != nil }

    @discardableResult
    func focusTrimWindowIfNeeded() -> Bool {
        guard let trimmer = trimController else { return false }
        trimmer.bringToFront()
        return true
    }

    func finishActiveRecordingFromMenu() {
        if focusTrimWindowIfNeeded() { return }
        if controlBar.isRecording {
            finalizeRecording(saveMode: .copy)
        } else {
            cancel()
        }
    }
}

// MARK: - 录屏事件监听、帧同步与状态封装

/// 选区录制会话的倒计时驱动、窗口布局、全局点击/快捷键回显监听、保存面板与跨线程状态原子盒扩展
extension RegionRecordingSession {
    func startCountdownThenRecord() {
        guard !controlBar.isRecording, countdownTimer == nil, let screen = targetScreen else { return }
        countdownRemaining = 3
        countdownStartedAt = CACurrentMediaTime()
        borderView.countdownFormatBadge = controlBar.format.badgeTitle
        borderView.countdownProgress = 1.0
        applyCountdownDisplay(3, on: screen)
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceCountdown() }
        }
    }

    func skipCountdownAndRecord() {
        countdownTimer?.invalidate(); countdownTimer = nil
        countdownRemaining = 0
        borderView.countdownNumber = nil
        borderView.countdownProgress = 1.0
        controlBar.countdownNumber = nil
        beginStreamRecording()
    }

    private func advanceCountdown() {
        guard !closed, let screen = targetScreen else { return }
        let totalDur: TimeInterval = 2.55
        let elapsed = max(0, CACurrentMediaTime() - countdownStartedAt)
        let remain = totalDur - elapsed
        if remain <= 0 { skipCountdownAndRecord(); return }
        borderView.countdownProgress = CGFloat(remain / totalDur)
        let sec = min(3, max(1, Int(ceil(remain / 0.85))))
        if sec != countdownRemaining {
            countdownRemaining = sec
            applyCountdownDisplay(sec, on: screen)
        }
    }

    private func applyCountdownDisplay(_ n: Int, on screen: NSScreen) {
        borderView.countdownNumber = n
        borderView.statusStyle = .warning
        borderView.statusText = "即将录制 \(controlBar.format.badgeTitle) · \(n) 秒后开始（↩ 立即开始 · Esc 取消）"
        controlBar.countdownNumber = n
        repositionControlWindow(around: Self.toAppKitScreenRect(localTopLeft: localCaptureRect, on: screen), on: screen)
    }

    func finishSession(_ outcome: Outcome) {
        guard !closed else { return }
        closed = true
        countdownTimer?.invalidate(); countdownTimer = nil
        tickTimer?.invalidate(); tickTimer = nil
        streamSampler.stop()
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        if let g = globalKeyMonitor { NSEvent.removeMonitor(g); globalKeyMonitor = nil }
        if let gm = globalMouseMonitor { NSEvent.removeMonitor(gm); globalMouseMonitor = nil }
        FloatingTooltipHUD.hideAll()
        borderWindow?.orderOut(nil); borderWindow = nil
        drawWindow?.orderOut(nil); drawWindow = nil
        controlWindow?.orderOut(nil); controlWindow = nil
        drawOverlayView.clearAll(notify: false)
        trimController?.cancelAndClose()
        trimController = nil
        initialFrame = nil
        onComplete?(outcome)
    }

    func setupDrawOverlayCallbacks() {
        drawOverlayView.onBeginStroke = { [weak self] pt, isLaser in
            guard let self, self.controlBar.isRecording, !self.paused else { return }
            self.overlayCompositor.beginLiveStroke(normalizedPoint: pt, isLaser: isLaser, at: self.currentActiveDuration())
        }
        drawOverlayView.onAppendStrokePoint = { [weak self] pt in
            guard let self, self.controlBar.isRecording, !self.paused else { return }
            self.overlayCompositor.appendLiveStrokePoint(pt, at: self.currentActiveDuration())
        }
        drawOverlayView.onClearStrokes = { [weak self] in
            self?.overlayCompositor.clearLiveStrokes()
        }
    }

    func toggleLiveDrawingMode() {
        let next = !controlBar.isDrawingActive
        controlBar.isDrawingActive = next
        drawWindow?.ignoresMouseEvents = !next
        borderView.statusText = next
            ? "画笔标记模式 · 拖动绘制激光红线（按住 ⇧ 常驻，右键清屏）"
            : "正在录制 \(controlBar.format.badgeTitle) · 框内可直接点击操作"
        if let scr = targetScreen {
            repositionControlWindow(around: Self.toAppKitScreenRect(localTopLeft: localCaptureRect, on: scr), on: scr)
        }
    }

    func presentTrimSheet(videoURL: URL, format: RecordingFormat) {
        FloatingTooltipHUD.hideAll()
        borderWindow?.orderOut(nil); drawWindow?.orderOut(nil); controlWindow?.orderOut(nil)
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        if let g = globalKeyMonitor { NSEvent.removeMonitor(g); globalKeyMonitor = nil }
        if let gm = globalMouseMonitor { NSEvent.removeMonitor(gm); globalMouseMonitor = nil }
        let trimmer = RecordingTrimWindowController()
        self.trimController = trimmer
        onCaptureStopped?()
        trimmer.present(videoURL: videoURL, on: targetScreen) { [weak self] res in
            guard let self else { return }
            self.trimController = nil
            switch res {
            case .copy(let u):
                ClipboardAndSave.copyMediaFileToClipboard(fileURL: u)
                self.finishSession(.copiedFile(u, format))
            case .quickSave(let u):
                if let saved = self.quickSaveMedia(tempURL: u, format: format) {
                    self.finishSession(.savedFile(saved.url, format, saved.dir))
                } else {
                    ClipboardAndSave.copyMediaFileToClipboard(fileURL: u)
                    self.finishSession(.copiedFile(u, format))
                }
            case .saveAs(let u):
                if let saved = self.promptSaveMedia(tempURL: u, format: format) {
                    self.finishSession(.savedFile(saved.url, format, saved.dir))
                } else {
                    ClipboardAndSave.copyMediaFileToClipboard(fileURL: u)
                    self.finishSession(.copiedFile(u, format))
                }
            case .cancel:
                try? FileManager.default.removeItem(at: videoURL)
                self.finishSession(.cancelled)
            }
        }
    }

    func quickSaveMedia(tempURL: URL, format: RecordingFormat) -> (url: URL, dir: String)? {
        let dirURL = ClipboardAndSave.resolveQuickSaveDirectory(preferred: saveDirHint)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let dst = dirURL.appendingPathComponent("MSnip-\(df.string(from: Date())).\(format.rawValue)")
        guard (try? FileManager.default.copyItem(at: tempURL, to: dst)) != nil else { return nil }
        try? FileManager.default.removeItem(at: tempURL)
        return (dst, dirURL.standardizedFileURL.path)
    }

    func promptSaveMedia(tempURL: URL, format: RecordingFormat) -> (url: URL, dir: String)? {
        let panel = NSSavePanel()
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "MSnip-\(df.string(from: Date())).\(format.rawValue)"
        panel.allowedContentTypes = [format == .gif ? .gif : .mpeg4Movie]
        panel.canCreateDirectories = true
        panel.level = .modalPanel
        if let dir = saveDirHint, FileManager.default.fileExists(atPath: dir) {
            panel.directoryURL = URL(fileURLWithPath: dir, isDirectory: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dst = panel.url else { return nil }
        try? FileManager.default.removeItem(at: dst)
        guard (try? FileManager.default.copyItem(at: tempURL, to: dst)) != nil else { return nil }
        try? FileManager.default.removeItem(at: tempURL)
        return (dst, dst.deletingLastPathComponent().path)
    }

    /// 清理超过 2 小时的历史临时录屏文件，避免仅复制不另存的 GIF/MP4 长期堆积
    static func pruneStaleTempClips(in dir: URL, maxAgeSeconds: TimeInterval = 7200) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-maxAgeSeconds)
        for u in urls {
            if let mtime = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               mtime < cutoff {
                try? fm.removeItem(at: u)
            }
        }
    }

    func installKeyMonitors() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self else { return ev }
            if ev.keyCode == 53 { self.cancel(); return nil }
            if ev.keyCode == 49, self.controlBar.isRecording { self.togglePause(); return nil }
            if ev.keyCode == 36 || ev.keyCode == 76 {
                if self.controlBar.isRecording { self.finalizeRecording(saveMode: .copy) }
                else if self.countdownTimer != nil { self.skipCountdownAndRecord() }
                else { self.startCountdownThenRecord() }
                return nil
            }
            return ev
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            if ev.keyCode == 53 {
                Task { @MainActor in self?.cancel() }
                return
            }
            let badge = Self.formatSafeShortcutBadge(event: ev)
            guard let badge else { return }
            Task { @MainActor [weak self] in
                guard let self, self.controlBar.isRecording, !self.paused else { return }
                self.overlayCompositor.recordKeyBadge(badge, at: self.currentActiveDuration())
            }
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] ev in
            let isRight = (ev.type == .rightMouseDown)
            let pt = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                guard let self, self.controlBar.isRecording, !self.paused, let scr = self.targetScreen else { return }
                if let cWin = self.controlWindow, cWin.frame.contains(pt) { return }
                let capScreen = Self.toAppKitScreenRect(localTopLeft: self.localCaptureRect, on: scr)
                guard capScreen.width > 1, capScreen.height > 1, capScreen.contains(pt) else { return }
                let nx = (pt.x - capScreen.minX) / capScreen.width
                let ny = (capScreen.maxY - pt.y) / capScreen.height
                self.overlayCompositor.recordClick(
                    normalizedX: nx,
                    normalizedY: ny,
                    isRightClick: isRight,
                    at: self.currentActiveDuration()
                )
            }
        }
    }

    /// 仅格式化带修饰符（⌘/⌃/⌥）的组合快捷键或特殊功能键，绝不回显普通打字字符以保护密码隐私
    private static func formatSafeShortcutBadge(event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods = ""
        if flags.contains(.control) { mods += "⌃" }
        if flags.contains(.option)  { mods += "⌥" }
        if flags.contains(.shift)   { mods += "⇧" }
        if flags.contains(.command) { mods += "⌘" }

        let specialKey: String? = {
            switch Int(event.keyCode) {
            case kVK_Return, kVK_ANSI_KeypadEnter: return "↩"
            case kVK_Tab:           return "⇥"
            case kVK_Delete:        return "⌫"
            case kVK_ForwardDelete: return "⌦"
            case kVK_LeftArrow:     return "←"
            case kVK_RightArrow:    return "→"
            case kVK_UpArrow:       return "↑"
            case kVK_DownArrow:     return "↓"
            default:                return nil
            }
        }()

        if let sp = specialKey {
            return mods + sp
        }
        return KeyCombo.from(event: event)?.displayString
    }

    func repositionControlWindow(around screenRect: NSRect, on screen: NSScreen) {
        guard let cWin = controlWindow else { return }
        let sz = controlBar.frame.size
        let pad = RecordingControlBarView.shadowPad
        let barW = sz.width - pad * 2
        let barH = sz.height - pad * 2
        let vis = screen.visibleFrame
        let barX = min(max(vis.minX + 8, screenRect.maxX - barW), vis.maxX - barW - 8)
        let belowY = screenRect.minY - barH - 10
        let barY = belowY >= vis.minY + 6 ? belowY : min(screenRect.maxY + 36, vis.maxY - barH - 6)
        cWin.setFrame(NSRect(origin: NSPoint(x: round(barX - pad), y: round(barY - pad)), size: sz), display: true)
    }

    static func toAppKitScreenRect(localTopLeft r: CGRect, on screen: NSScreen) -> NSRect {
        NSRect(x: screen.frame.minX + r.minX, y: screen.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    static func makePanel(frame: NSRect, ignoresMouse: Bool, contentView: NSView) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.animationBehavior = .none; p.isFloatingPanel = true; p.level = .screenSaver
        p.hidesOnDeactivate = false; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
        p.ignoresMouseEvents = ignoresMouse; p.acceptsMouseMovedEvents = !ignoresMouse
        p.contentView = contentView
        return p
    }
}

private final class RecordingFlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _v = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _v }
        set { lock.lock(); _v = newValue; lock.unlock() }
    }
}

private final class RecordingTimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _v: TimeInterval
    init(_ v: TimeInterval) { _v = v }
    var value: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _v }
        set { lock.lock(); _v = newValue; lock.unlock() }
    }
}
