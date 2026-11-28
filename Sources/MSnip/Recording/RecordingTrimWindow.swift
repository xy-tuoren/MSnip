import AppKit
import AVFoundation
import CoreMedia
import Foundation
import MSnipCore

/// MP4 录后轻量首尾裁剪浮窗（原生 AVPlayer 实时追帧预览 + 胶片缩略图时间轴 + 起止双滑块 + AVAssetExportPresetPassthrough 毫秒级无损裁切）
@MainActor
final class RecordingTrimWindowController: NSObject, NSWindowDelegate {
    enum Result {
        case copy(URL)
        case quickSave(URL)
        case saveAs(URL)
        case cancel
    }

    private var window: NSPanel?
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var timeObserver: Any?
    private var imageGenerator: AVAssetImageGenerator?
    private var appearanceObserver: NSObjectProtocol?
    private var sliderView: TrimRangeBarView?
    private var timeLabel: NSTextField?
    private var playBtn: NSButton?
    private var saveBtn: NSButton?
    private var copyBtn: NSButton?
    private var sourceURL: URL!
    private var totalSeconds: Double = 1.0
    private var onComplete: ((Result) -> Void)?
    private var activeExport: AVAssetExportSession?
    private var isExporting = false
    private var completed = false

    // 平滑追帧定位状态：始终最多保留 1 个在途解码请求，避免连续拖拽滑块时把 AVPlayer 管线打满导致画面冻结
    private var isSeekInProgress = false
    private var pendingSeekSeconds: Double?
    private var playAfterSeek = false

    deinit {
        if let obs = appearanceObserver { NotificationCenter.default.removeObserver(obs) }
    }

    func present(videoURL: URL, on screen: NSScreen?, completion: @escaping (Result) -> Void) {
        self.sourceURL = videoURL
        self.onComplete = completion
        let asset = AVURLAsset(url: videoURL)
        self.totalSeconds = max(0.2, CMTimeGetSeconds(asset.duration).isFinite ? CMTimeGetSeconds(asset.duration) : 1.0)

        let W: CGFloat = 580, H: CGFloat = 446
        let vf = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: round(vf.midX - W * 0.5), y: round(vf.midY - H * 0.5), width: W, height: H)
        let win = TrimPanel(contentRect: frame, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        win.title = L("裁剪录屏 MP4")
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.hidesOnDeactivate = false
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        win.appearance = GeekTheme.windowAppearance
        win.level = .floating
        win.delegate = self

        // 不手工覆盖 layer 背景色，由 NSPanel 随 win.appearance 自动渲染浅/深色背景
        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        win.contentView = root

        let videoBox = NSView(frame: NSRect(x: 16, y: 128, width: W - 32, height: H - 166))
        videoBox.wantsLayer = true
        videoBox.layer?.backgroundColor = NSColor.black.cgColor
        videoBox.layer?.cornerRadius = 8
        videoBox.layer?.masksToBounds = true
        let avPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        let layer = AVPlayerLayer(player: avPlayer)
        layer.frame = videoBox.bounds
        layer.videoGravity = .resizeAspect
        videoBox.layer?.addSublayer(layer)
        root.addSubview(videoBox)

        let bar = TrimRangeBarView(frame: NSRect(x: 16, y: 60, width: W - 32, height: 58))
        bar.totalSeconds = totalSeconds
        bar.onRangeChanged = { [weak self] s, e, seekFrac in
            self?.handleRangeChanged(startFrac: s, endFrac: e, seekFrac: seekFrac)
        }
        bar.onScrubPlayhead = { [weak self] frac in
            self?.handleScrubPlayhead(frac: frac)
        }
        root.addSubview(bar)

        let play = NSButton(title: L("播放 / 暂停"), target: self, action: #selector(togglePlay))
        play.bezelStyle = .rounded
        play.keyEquivalent = " "
        // 按钮宽度取设计宽度与标题所需宽度的较大者（英文标题更长）
        let fit = { (b: NSButton, w: CGFloat) -> CGFloat in max(w, ceil(b.fittingSize.width)) }
        let playW = fit(play, 96)
        play.frame = NSRect(x: 16, y: 18, width: playW, height: 30)
        root.addSubview(play)

        let lbl = NSTextField(labelWithString: "")
        lbl.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        lbl.textColor = .secondaryLabelColor
        lbl.frame = NSRect(x: 24 + playW, y: 23, width: 220, height: 20)
        root.addSubview(lbl)

        let saveBtn = NSButton(title: L("保存"), target: self, action: #selector(exportSave))
        saveBtn.bezelStyle = .rounded
        saveBtn.toolTip = L("保存裁剪版到默认目录（按住 ⌥ 另存为）")
        root.addSubview(saveBtn)

        let copyBtn = NSButton(title: L("复制裁剪版"), target: self, action: #selector(exportCopy))
        copyBtn.bezelStyle = .rounded
        copyBtn.keyEquivalent = "\r"
        let copyW = fit(copyBtn, 88), saveW = fit(saveBtn, 74)
        copyBtn.frame = NSRect(x: W - 16 - copyW, y: 18, width: copyW, height: 30)
        saveBtn.frame = NSRect(x: copyBtn.frame.minX - 6 - saveW, y: 18, width: saveW, height: 30)
        root.addSubview(copyBtn)

        self.window = win; self.player = avPlayer; self.playerLayer = layer
        self.sliderView = bar; self.timeLabel = lbl; self.playBtn = play
        self.saveBtn = saveBtn; self.copyBtn = copyBtn
        updateTimeLabel(start: 0, end: totalSeconds)

        if appearanceObserver == nil {
            appearanceObserver = NotificationCenter.default.addObserver(forName: .msnipAppearanceDidChange, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.window?.appearance = GeekTheme.windowAppearance
                    self?.sliderView?.needsDisplay = true
                }
            }
        }

        // 实时同步播放指针，到达裁剪终点自动暂停归位
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = avPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, !self.isSeekInProgress, let bar = self.sliderView else { return }
                let sec = CMTimeGetSeconds(t)
                guard sec.isFinite else { return }
                let frac = min(1.0, max(0.0, sec / self.totalSeconds))
                bar.playheadFrac = frac
                if (self.player?.rate ?? 0) > 0.01 && frac >= bar.endFrac {
                    self.player?.pause()
                    bar.playheadFrac = bar.endFrac
                }
            }
        }

        loadFilmstripThumbnails(from: asset, count: 10)

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        avPlayer.play()
    }

    private func loadFilmstripThumbnails(from asset: AVAsset, count: Int) {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 140, height: 90)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)
        self.imageGenerator = gen

        let n = max(2, count)
        let dur = totalSeconds
        let times: [NSValue] = (0..<n).map { i in
            let sec = dur * (Double(i) + 0.5) / Double(n)
            return NSValue(time: CMTime(seconds: min(dur, max(0, sec)), preferredTimescale: 600))
        }
        var slots = Array<CGImage?>(repeating: nil, count: n)
        var finishedCount = 0
        let lock = NSLock()
        self.sliderView?.thumbnails = slots

        gen.generateCGImagesAsynchronously(forTimes: times) { [weak self] reqTime, cgImage, _, _, _ in
            let reqSec = CMTimeGetSeconds(reqTime)
            let idx = min(n - 1, max(0, Int((reqSec / max(0.001, dur)) * Double(n))))
            lock.lock()
            if let cg = cgImage { slots[idx] = cg }
            finishedCount += 1
            let shouldPush = (finishedCount == n) || (finishedCount % 3 == 0)
            let snapshot = shouldPush ? slots : nil
            lock.unlock()
            if let snapshot {
                Task { @MainActor [weak self] in
                    guard let self, !self.completed else { return }
                    self.sliderView?.thumbnails = snapshot
                }
            }
        }
    }

    private func handleRangeChanged(startFrac: Double, endFrac: Double, seekFrac: Double) {
        guard !isExporting else { return }
        let s = startFrac * totalSeconds, e = endFrac * totalSeconds
        updateTimeLabel(start: s, end: e)
        sliderView?.playheadFrac = seekFrac
        playAfterSeek = false
        player?.pause()
        seekSmoothly(to: seekFrac * totalSeconds)
    }

    private func handleScrubPlayhead(frac: Double) {
        guard !isExporting else { return }
        sliderView?.playheadFrac = frac
        playAfterSeek = false
        player?.pause()
        seekSmoothly(to: frac * totalSeconds)
    }

    private func seekSmoothly(to seconds: Double, playWhenDone: Bool = false) {
        let clamped = min(totalSeconds, max(0, seconds))
        if playWhenDone { playAfterSeek = true }
        if isSeekInProgress {
            pendingSeekSeconds = clamped
            return
        }
        performSeek(to: clamped)
    }

    private func performSeek(to seconds: Double) {
        guard let p = player else { isSeekInProgress = false; pendingSeekSeconds = nil; playAfterSeek = false; return }
        isSeekInProgress = true
        pendingSeekSeconds = nil
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        p.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.completed else { return }
                if let next = self.pendingSeekSeconds {
                    self.performSeek(to: next)
                } else {
                    self.isSeekInProgress = false
                    if self.playAfterSeek && !self.isExporting {
                        self.playAfterSeek = false
                        self.player?.play()
                    }
                }
            }
        }
    }

    private func updateTimeLabel(start: Double, end: Double) {
        let dur = max(0.1, end - start)
        let sec = { (v: Double) in String(format: "%.1fs", v) }
        timeLabel?.stringValue = L("%@ → %@（共 %@）", sec(start), sec(end), sec(dur))
    }

    @objc private func togglePlay() {
        guard !isExporting, let p = player else { return }
        if p.rate > 0.01 {
            playAfterSeek = false
            p.pause()
        } else {
            let sFrac = sliderView?.startFrac ?? 0
            let eFrac = sliderView?.endFrac ?? 1
            let s = sFrac * totalSeconds
            let cur = isSeekInProgress
                ? ((sliderView?.playheadFrac ?? sFrac) * totalSeconds)
                : CMTimeGetSeconds(p.currentTime())
            let e = eFrac * totalSeconds
            if !cur.isFinite || cur < s || cur >= e - 0.05 {
                sliderView?.playheadFrac = sFrac
                seekSmoothly(to: s, playWhenDone: true)
            } else if isSeekInProgress {
                playAfterSeek = true
            } else {
                p.play()
            }
        }
    }

    @objc private func exportCopy() { runExport(mode: .copy) }
    @objc private func exportSave() {
        let saveAs = NSEvent.modifierFlags.contains(.option)
        runExport(mode: saveAs ? .saveAs : .quickSave)
    }

    private enum ExportTarget { case copy, quickSave, saveAs }

    private func runExport(mode: ExportTarget) {
        guard !isExporting else { return }
        let sFrac = sliderView?.startFrac ?? 0.0, eFrac = sliderView?.endFrac ?? 1.0
        if sFrac <= 0.005 && eFrac >= 0.995 {
            finishWith(mode == .copy ? .copy(sourceURL) : (mode == .saveAs ? .saveAs(sourceURL) : .quickSave(sourceURL)))
            return
        }
        isExporting = true
        playAfterSeek = false
        sliderView?.isInteractive = false
        playBtn?.isEnabled = false
        saveBtn?.isEnabled = false
        copyBtn?.isEnabled = false
        player?.pause()
        timeLabel?.stringValue = L("正在无损裁切…")
        let startSec = sFrac * totalSeconds, endSec = max(startSec + 0.15, eFrac * totalSeconds)
        let outURL = sourceURL.deletingLastPathComponent().appendingPathComponent("MSnip-trim-\(Int(Date().timeIntervalSince1970 * 1000)).mp4")
        try? FileManager.default.removeItem(at: outURL)

        let asset = AVURLAsset(url: sourceURL)
        let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough)
            ?? AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)
        guard let exp = session else {
            finishWith(mode == .copy ? .copy(sourceURL) : (mode == .saveAs ? .saveAs(sourceURL) : .quickSave(sourceURL)))
            return
        }
        exp.outputURL = outURL
        exp.outputFileType = .mp4
        exp.timeRange = CMTimeRange(
            start: CMTime(seconds: startSec, preferredTimescale: 600),
            end: CMTime(seconds: endSec, preferredTimescale: 600)
        )
        self.activeExport = exp
        exp.exportAsynchronously { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.completed else {
                    try? FileManager.default.removeItem(at: outURL)
                    return
                }
                let completedOK = (self.activeExport?.status == .completed)
                self.activeExport = nil
                let hasOut = completedOK && FileManager.default.fileExists(atPath: outURL.path)
                if !hasOut { try? FileManager.default.removeItem(at: outURL) }
                let finalURL = hasOut ? outURL : self.sourceURL!
                if finalURL != self.sourceURL { try? FileManager.default.removeItem(at: self.sourceURL) }
                self.finishWith(mode == .copy ? .copy(finalURL) : (mode == .saveAs ? .saveAs(finalURL) : .quickSave(finalURL)))
            }
        }
    }

    func bringToFront() {
        guard let win = window else { return }
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func cancelAndClose() {
        finishWith(.cancel)
    }

    func windowWillClose(_ notification: Notification) {
        if !completed { finishWith(.cancel) }
    }

    private func finishWith(_ result: Result) {
        guard !completed else { return }
        completed = true
        if let obs = appearanceObserver { NotificationCenter.default.removeObserver(obs); appearanceObserver = nil }
        imageGenerator?.cancelAllCGImageGeneration(); imageGenerator = nil
        if let obs = timeObserver { player?.removeTimeObserver(obs); timeObserver = nil }
        sliderView?.thumbnails = []
        activeExport?.cancelExport(); activeExport = nil
        player?.pause(); player = nil; playerLayer = nil
        let cb = onComplete; onComplete = nil
        window?.delegate = nil; window?.orderOut(nil); window = nil
        cb?(result)
    }
}

/// 支持 `Esc` 与 `⌘W` 关闭的 MP4 裁剪浮窗面板
private final class TrimPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// 带视频胶片帧预览、左右裁剪手柄、实时播放指针与拖拽时间气泡的时间轴控件
private final class TrimRangeBarView: NSView {
    var totalSeconds: Double = 1.0
    var startFrac: Double = 0.0 { didSet { needsDisplay = true } }
    var endFrac: Double = 1.0 { didSet { needsDisplay = true } }
    var playheadFrac: Double = 0.0 { didSet { needsDisplay = true } }
    var thumbnails: [CGImage?] = [] { didSet { needsDisplay = true } }
    var isInteractive: Bool = true { didSet { if !isInteractive { dragging = nil } } }

    var onRangeChanged: ((Double, Double, Double) -> Void)?
    var onScrubPlayhead: ((Double) -> Void)?

    private enum DragTarget { case start, end, playhead }
    private var dragging: DragTarget? { didSet { needsDisplay = true } }
    private var hoveredTarget: DragTarget?

    override var isFlipped: Bool { true }
    // 关键：禁止点击/拖拽时间轴时触发 isMovableByWindowBackground 带着整个窗口一起移动
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var trackRect: CGRect { CGRect(x: 12, y: 20, width: max(24, bounds.width - 24), height: 32) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    private func hitTarget(at p: CGPoint) -> DragTarget {
        let tr = trackRect
        let sx = tr.minX + CGFloat(startFrac) * tr.width
        let ex = tr.minX + CGFloat(endFrac) * tr.width
        let ds = abs(p.x - sx), de = abs(p.x - ex)
        let handleHitRadius: CGFloat = 14
        if ds <= handleHitRadius || de <= handleHitRadius {
            return ds <= de ? .start : .end
        }
        return .playhead
    }

    override func mouseMoved(with event: NSEvent) {
        guard isInteractive else { hoveredTarget = nil; NSCursor.arrow.set(); return }
        let p = convert(event.locationInWindow, from: nil)
        guard trackRect.insetBy(dx: -12, dy: -4).contains(p) else {
            hoveredTarget = nil; NSCursor.arrow.set(); return
        }
        let target = hitTarget(at: p)
        hoveredTarget = target
        if target == .start || target == .end { NSCursor.resizeLeftRight.set() }
        else { NSCursor.pointingHand.set() }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredTarget = nil
        if dragging == nil { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        guard isInteractive else { return }
        let p = convert(event.locationInWindow, from: nil)
        dragging = hitTarget(at: p)
        if dragging == .start || dragging == .end { NSCursor.resizeLeftRight.set() }
        updateDrag(at: p.x)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInteractive else { return }
        updateDrag(at: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = nil
        NSCursor.arrow.set()
    }

    private func updateDrag(at x: CGFloat) {
        guard let target = dragging else { return }
        let tr = trackRect
        let f = Double(min(1, max(0, (x - tr.minX) / tr.width)))
        let minSpan = min(0.08, max(0.02, 0.25 / max(1.0, totalSeconds)))
        switch target {
        case .start:
            startFrac = min(f, endFrac - minSpan)
            onRangeChanged?(startFrac, endFrac, startFrac)
        case .end:
            endFrac = max(f, startFrac + minSpan)
            onRangeChanged?(startFrac, endFrac, endFrac)
        case .playhead:
            let clamped = min(endFrac, max(startFrac, f))
            playheadFrac = clamped
            onScrubPlayhead?(clamped)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let tr = trackRect
        let trackPath = CGPath(roundedRect: tr, cornerWidth: 6, cornerHeight: 6, transform: nil)

        // 1) 视频胶片帧缩略图底带（所见即所得定位首尾画面）
        ctx.saveGState()
        ctx.addPath(trackPath); ctx.clip()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.fill(tr)
        if !thumbnails.isEmpty {
            let tileW = tr.width / CGFloat(thumbnails.count)
            for (i, cgOpt) in thumbnails.enumerated() {
                guard let cg = cgOpt else { continue }
                let tile = CGRect(x: tr.minX + CGFloat(i) * tileW, y: tr.minY, width: ceil(tileW) + 0.5, height: tr.height)
                ctx.saveGState()
                ctx.clip(to: tile)
                let iw = max(1, CGFloat(cg.width)), ih = max(1, CGFloat(cg.height))
                let sc = max(tile.width / iw, tile.height / ih)
                let dw = iw * sc, dh = ih * sc
                let dst = CGRect(x: tile.midX - dw * 0.5, y: tile.midY - dh * 0.5, width: dw, height: dh)
                ctx.translateBy(x: 0, y: dst.minY + dst.maxY); ctx.scaleBy(x: 1, y: -1)
                ctx.interpolationQuality = .medium
                ctx.draw(cg, in: dst)
                ctx.restoreGState()
            }
        }

        // 2) 被裁掉的首尾暗化遮罩
        let sx = tr.minX + CGFloat(startFrac) * tr.width
        let ex = tr.minX + CGFloat(endFrac) * tr.width
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.62).cgColor)
        if sx > tr.minX { ctx.fill(CGRect(x: tr.minX, y: tr.minY, width: sx - tr.minX, height: tr.height)) }
        if ex < tr.maxX { ctx.fill(CGRect(x: ex, y: tr.minY, width: tr.maxX - ex, height: tr.height)) }
        ctx.restoreGState()

        // 3) 保留区间蓝色高亮边框
        let sel = CGRect(x: sx, y: tr.minY, width: max(4, ex - sx), height: tr.height)
        ctx.setStrokeColor(MSnipUITheme.accent.cgColor)
        ctx.setLineWidth(2.4)
        ctx.stroke(sel)

        // 4) 当前播放 / 预览时间指针
        let px = tr.minX + CGFloat(min(1, max(0, playheadFrac))) * tr.width
        let needle = CGRect(x: round(px) - 1.25, y: tr.minY - 2, width: 2.5, height: tr.height + 4)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 3, color: NSColor.black.withAlphaComponent(0.65).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addPath(CGPath(roundedRect: needle, cornerWidth: 1.25, cornerHeight: 1.25, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()

        // 5) 左右双裁剪手柄（带白色细竖纹抓取提示）
        for hx in [sx, ex] {
            let hr = CGRect(x: round(hx - 6), y: tr.minY - 2, width: 12, height: tr.height + 4)
            ctx.setFillColor(MSnipUITheme.accent.cgColor)
            ctx.addPath(CGPath(roundedRect: hr, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.88).cgColor)
            ctx.fill(CGRect(x: hr.midX - 1, y: hr.midY - 6, width: 2, height: 12))
        }

        // 6) 拖拽时在手柄/指针上方实时显示当前精确时间（如 2.4s）
        if let active = dragging {
            let frac: Double = (active == .start) ? startFrac : (active == .end ? endFrac : playheadFrac)
            let bx = tr.minX + CGFloat(frac) * tr.width
            let text = String(format: "%.1fs", frac * totalSeconds)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let sz = (text as NSString).size(withAttributes: attrs)
            let pw = ceil(sz.width) + 10, ph: CGFloat = 16
            let pillX = min(max(tr.minX, round(bx - pw * 0.5)), tr.maxX - pw)
            let pillR = CGRect(x: pillX, y: 1, width: pw, height: ph)
            ctx.setFillColor(MSnipUITheme.accent.cgColor)
            ctx.addPath(CGPath(roundedRect: pillR, cornerWidth: 5, cornerHeight: 5, transform: nil))
            ctx.fillPath()
            (text as NSString).draw(at: NSPoint(x: round(pillR.midX - sz.width * 0.5), y: round(pillR.midY - sz.height * 0.5)), withAttributes: attrs)
        }
    }
}
