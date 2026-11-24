import AppKit
import AVFoundation
import CoreMedia
import Foundation

/// MP4 录后轻量首尾裁剪浮窗（原生 AVPlayer 预览 + 起止双滑块 + AVAssetExportPresetPassthrough 毫秒级无损裁切）
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
    private var sliderView: TrimRangeBarView?
    private var timeLabel: NSTextField?
    private var playBtn: NSButton?
    private var sourceURL: URL!
    private var totalSeconds: Double = 1.0
    private var onComplete: ((Result) -> Void)?
    private var activeExport: AVAssetExportSession?
    private var isExporting = false
    private var completed = false

    func present(videoURL: URL, on screen: NSScreen?, completion: @escaping (Result) -> Void) {
        self.sourceURL = videoURL
        self.onComplete = completion
        let asset = AVURLAsset(url: videoURL)
        self.totalSeconds = max(0.2, CMTimeGetSeconds(asset.duration).isFinite ? CMTimeGetSeconds(asset.duration) : 1.0)

        let W: CGFloat = 560, H: CGFloat = 420
        let vf = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: round(vf.midX - W * 0.5), y: round(vf.midY - H * 0.5), width: W, height: H)
        let win = NSPanel(contentRect: frame, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        win.title = "裁剪录屏 MP4"
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.level = .floating
        win.delegate = self

        let root = NSView(frame: NSRect(origin: .zero, size: frame.size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        win.contentView = root

        let videoBox = NSView(frame: NSRect(x: 16, y: 112, width: W - 32, height: H - 150))
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

        let bar = TrimRangeBarView(frame: NSRect(x: 16, y: 66, width: W - 32, height: 34))
        bar.onChanged = { [weak self] s, e, seekToStart in
            self?.handleRangeChanged(startFrac: s, endFrac: e, seekToStart: seekToStart)
        }
        root.addSubview(bar)

        let play = NSButton(title: "播放 / 暂停", target: self, action: #selector(togglePlay))
        play.bezelStyle = .rounded
        play.frame = NSRect(x: 16, y: 20, width: 92, height: 30)
        root.addSubview(play)

        let lbl = NSTextField(labelWithString: "")
        lbl.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        lbl.textColor = .secondaryLabelColor
        lbl.frame = NSRect(x: 116, y: 25, width: 204, height: 20)
        root.addSubview(lbl)

        let saveBtn = NSButton(title: "保存", target: self, action: #selector(exportSave))
        saveBtn.bezelStyle = .rounded
        saveBtn.toolTip = "保存裁剪版到默认目录（按住 ⌥ 另存为）"
        saveBtn.frame = NSRect(x: W - 180, y: 20, width: 74, height: 30)
        root.addSubview(saveBtn)

        let copyBtn = NSButton(title: "复制裁剪版", target: self, action: #selector(exportCopy))
        copyBtn.bezelStyle = .rounded
        copyBtn.keyEquivalent = "\r"
        copyBtn.frame = NSRect(x: W - 100, y: 20, width: 84, height: 30)
        root.addSubview(copyBtn)

        self.window = win; self.player = avPlayer; self.playerLayer = layer
        self.sliderView = bar; self.timeLabel = lbl; self.playBtn = play
        updateTimeLabel(start: 0, end: totalSeconds)

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        avPlayer.play()
    }

    private func handleRangeChanged(startFrac: Double, endFrac: Double, seekToStart: Bool) {
        let s = startFrac * totalSeconds, e = endFrac * totalSeconds
        updateTimeLabel(start: s, end: e)
        let seekT = CMTime(seconds: seekToStart ? s : e, preferredTimescale: 600)
        player?.pause()
        player?.seek(to: seekT, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func updateTimeLabel(start: Double, end: Double) {
        let dur = max(0.1, end - start)
        timeLabel?.stringValue = String(format: "%.1fs → %.1fs（共 %.1fs）", start, end, dur)
    }

    @objc private func togglePlay() {
        guard let p = player else { return }
        if p.rate > 0.01 {
            p.pause()
        } else {
            let s = (sliderView?.startFrac ?? 0) * totalSeconds
            let cur = CMTimeGetSeconds(p.currentTime())
            let e = (sliderView?.endFrac ?? 1) * totalSeconds
            if !cur.isFinite || cur < s || cur >= e - 0.05 {
                p.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            p.play()
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
        player?.pause()
        timeLabel?.stringValue = "正在无损裁切…"
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
                guard let self else { return }
                let completedOK = (self.activeExport?.status == .completed)
                self.activeExport = nil
                let finalURL = (completedOK && FileManager.default.fileExists(atPath: outURL.path)) ? outURL : self.sourceURL!
                if finalURL != self.sourceURL { try? FileManager.default.removeItem(at: self.sourceURL) }
                self.finishWith(mode == .copy ? .copy(finalURL) : (mode == .saveAs ? .saveAs(finalURL) : .quickSave(finalURL)))
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        if !completed { finishWith(.cancel) }
    }

    private func finishWith(_ result: Result) {
        guard !completed else { return }
        completed = true
        activeExport?.cancelExport(); activeExport = nil
        player?.pause(); player = nil; playerLayer = nil
        let cb = onComplete; onComplete = nil
        window?.delegate = nil; window?.orderOut(nil); window = nil
        cb?(result)
    }
}

private final class TrimRangeBarView: NSView {
    var startFrac: Double = 0.0 { didSet { needsDisplay = true } }
    var endFrac: Double = 1.0 { didSet { needsDisplay = true } }
    var onChanged: ((Double, Double, Bool) -> Void)?
    private enum DragEdge { case start, end }
    private var dragging: DragEdge?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var trackRect: CGRect { CGRect(x: 10, y: 7, width: max(20, bounds.width - 20), height: 20) }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let tr = trackRect
        let sx = tr.minX + CGFloat(startFrac) * tr.width, ex = tr.minX + CGFloat(endFrac) * tr.width
        dragging = abs(p.x - sx) <= abs(p.x - ex) ? .start : .end
        updateDrag(at: p.x)
    }

    override func mouseDragged(with event: NSEvent) {
        updateDrag(at: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) { dragging = nil }

    private func updateDrag(at x: CGFloat) {
        guard let edge = dragging else { return }
        let tr = trackRect
        let f = Double(min(1, max(0, (x - tr.minX) / tr.width)))
        if edge == .start {
            startFrac = min(f, endFrac - 0.04)
            onChanged?(startFrac, endFrac, true)
        } else {
            endFrac = max(f, startFrac + 0.04)
            onChanged?(startFrac, endFrac, false)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let tr = trackRect
        ctx.setFillColor(NSColor.labelColor.withAlphaComponent(0.10).cgColor)
        ctx.addPath(CGPath(roundedRect: tr, cornerWidth: 5, cornerHeight: 5, transform: nil)); ctx.fillPath()
        let sx = tr.minX + CGFloat(startFrac) * tr.width, ex = tr.minX + CGFloat(endFrac) * tr.width
        let sel = CGRect(x: sx, y: tr.minY, width: max(4, ex - sx), height: tr.height)
        ctx.setFillColor(MSnipUITheme.accent.withAlphaComponent(0.28).cgColor)
        ctx.fill(sel)
        ctx.setStrokeColor(MSnipUITheme.accent.cgColor); ctx.setLineWidth(2.0); ctx.stroke(sel)
        for hx in [sx, ex] {
            let hr = CGRect(x: hx - 5, y: tr.minY - 3, width: 10, height: tr.height + 6)
            ctx.setFillColor(MSnipUITheme.accent.cgColor)
            ctx.addPath(CGPath(roundedRect: hr, cornerWidth: 3, cornerHeight: 3, transform: nil)); ctx.fillPath()
        }
    }
}
