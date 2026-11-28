import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import MSnipCore
import ScreenCaptureKit
import VideoToolbox

/// 单块显示器的冻结快照数据（线程安全惰性解包采样器，窗口瞬时冻结后再后台预热）
final class ScreenSnapshot: @unchecked Sendable {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let cgImage: CGImage
    let scaleFactor: CGFloat

    private let samplerLock = NSLock()
    private var _sampler: PixelSampler?

    var isSamplerReady: Bool {
        samplerLock.lock()
        defer { samplerLock.unlock() }
        return _sampler != nil
    }

    var sampler: PixelSampler {
        samplerLock.lock()
        if let existing = _sampler {
            samplerLock.unlock()
            return existing
        }
        samplerLock.unlock()
        let created = PixelSampler(cgImage: cgImage)
        samplerLock.lock()
        if let existing = _sampler {
            samplerLock.unlock()
            return existing
        }
        _sampler = created
        samplerLock.unlock()
        return created
    }

    func preheatSamplerInBackground(completion: @escaping @MainActor () -> Void) {
        if isSamplerReady {
            Task { @MainActor in completion() }
            return
        }
        Task.detached(priority: .high) { [weak self] in
            guard let self else { return }
            _ = self.sampler
            await MainActor.run { completion() }
        }
    }

    init(screen: NSScreen, displayID: CGDirectDisplayID, cgImage: CGImage) {
        self.screen = screen
        self.displayID = displayID
        self.cgImage = cgImage
        let screenWidthPt = max(1.0, screen.frame.width)
        self.scaleFactor = CGFloat(cgImage.width) / screenWidthPt
    }
}

/// 跨 macOS 版本极速零色差屏幕抓取引擎：
/// - 缓存显示器 `SCContentFilter` 免除每次热键枚举窗口 IPC（延迟立降 50%），保留显示器原生 ICC 色彩空间实现 100% 原图零色差；
/// - 显示器热插拔或分辨率变化时自动失效重建缓存。
enum ScreenCapturer {
    @MainActor static var runtimeVerifiedAccess = false
    @MainActor private static var cachedDisplayFilters: [CGDirectDisplayID: AnyObject] = [:]
    @MainActor private static var screenObserverRegistered = false

    @MainActor
    private static func registerScreenObserverIfNeeded() {
        guard !screenObserverRegistered else { return }
        screenObserverRegistered = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { cachedDisplayFilters.removeAll() }
        }
    }

    @MainActor
    static func hasScreenCapturePermission() async -> Bool {
        if runtimeVerifiedAccess || CGPreflightScreenCaptureAccess() {
            runtimeVerifiedAccess = true
            return true
        }
        if #available(macOS 14.0, *) {
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
               !content.displays.isEmpty {
                runtimeVerifiedAccess = true
                for d in content.displays {
                    cachedDisplayFilters[d.displayID] = SCContentFilter(display: d, excludingWindows: [])
                }
                return true
            }
        }
        return false
    }

    @MainActor
    static func ensurePermission() -> Bool {
        if runtimeVerifiedAccess || CGPreflightScreenCaptureAccess() {
            runtimeVerifiedAccess = true
            return true
        }
        _ = CGRequestScreenCaptureAccess()
        let granted = CGPreflightScreenCaptureAccess()
        MSnipLog.info(.permission, "Requested screen recording permission → \(granted ? "granted" : "still missing")")
        return granted
    }

    @MainActor
    static func captureAllScreens() async -> [ScreenSnapshot] {
        registerScreenObserverIfNeeded()
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return [] }
        return await captureScreens(screens)
    }

    /// 仅抓取指定单块显示器（供「重截上次区域」直通使用，跳过副屏抓拍与整屏位图解包）
    @MainActor
    static func captureScreen(displayID: CGDirectDisplayID) async -> ScreenSnapshot? {
        registerScreenObserverIfNeeded()
        let screens = NSScreen.screens
        guard let target = screens.first(where: { screenDisplayID($0) == displayID }) ?? screens.first else {
            return nil
        }
        return await captureScreens([target]).first
    }

    @MainActor
    private static func captureScreens(_ screens: [NSScreen]) async -> [ScreenSnapshot] {
        if #available(macOS 14.0, *) {
            if let sck = await captureViaScreenCaptureKit(screens: screens), !sck.isEmpty {
                runtimeVerifiedAccess = true
                return sck
            }
            MSnipLog.warning(.capture, "ScreenCaptureKit capture failed for \(screens.count) display(s); falling back to CoreGraphics")
        }
        let legacy = captureViaLegacyCoreGraphics(screens: screens)
        if !legacy.isEmpty {
            runtimeVerifiedAccess = true
        } else {
            MSnipLog.error(.capture, "All capture paths returned no image (displays=\(screens.count), preflight=\(CGPreflightScreenCaptureAccess()))")
        }
        return legacy
    }

    @available(macOS 14.0, *)
    @MainActor
    private static func ensureDisplayFilters(for screens: [NSScreen]) async -> [CGDirectDisplayID: SCContentFilter]? {
        let neededIDs = screens.compactMap(screenDisplayID)
        var out: [CGDirectDisplayID: SCContentFilter] = [:]
        for id in neededIDs {
            if let hit = cachedDisplayFilters[id] as? SCContentFilter { out[id] = hit }
        }
        if out.count == neededIDs.count && !out.isEmpty { return out }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            MSnipLog.warning(.capture, "SCShareableContent unavailable", error: error)
            return nil
        }
        cachedDisplayFilters.removeAll()
        out.removeAll()
        for d in content.displays {
            let f = SCContentFilter(display: d, excludingWindows: [])
            cachedDisplayFilters[d.displayID] = f
            out[d.displayID] = f
        }
        return out
    }

    @available(macOS 14.0, *)
    @MainActor
    private static func captureViaScreenCaptureKit(screens: [NSScreen]) async -> [ScreenSnapshot]? {
        guard let filterMap = await ensureDisplayFilters(for: screens) else { return nil }

        struct CaptureSpec: @unchecked Sendable {
            let index: Int
            let displayID: CGDirectDisplayID
            let filter: SCContentFilter
            let cfg: SCStreamConfiguration
        }

        var specs: [CaptureSpec] = []
        for (idx, screen) in screens.enumerated() {
            guard let id = screenDisplayID(screen), let filter = filterMap[id] else { continue }
            let cfg = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            cfg.width = Int((screen.frame.width * scale).rounded())
            cfg.height = Int((screen.frame.height * scale).rounded())
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.showsCursor = false
            cfg.capturesAudio = false
            specs.append(CaptureSpec(index: idx, displayID: id, filter: filter, cfg: cfg))
        }
        guard !specs.isEmpty else { return nil }

        if specs.count == 1 {
            let s = specs[0]
            do {
                let img = try await SCScreenshotManager.captureImage(contentFilter: s.filter, configuration: s.cfg)
                return [ScreenSnapshot(screen: screens[s.index], displayID: s.displayID, cgImage: img)]
            } catch {
                MSnipLog.warning(.capture, "SCScreenshotManager capture failed; retrying with fresh filters", error: error)
            }
            // 若旧缓存 filter 因显示器状态变更失效，清理重试一次
            cachedDisplayFilters.removeAll()
            guard let fresh = await ensureDisplayFilters(for: screens), let f2 = fresh[s.displayID] else { return nil }
            do {
                let img2 = try await SCScreenshotManager.captureImage(contentFilter: f2, configuration: s.cfg)
                return [ScreenSnapshot(screen: screens[s.index], displayID: s.displayID, cgImage: img2)]
            } catch {
                MSnipLog.error(.capture, "SCScreenshotManager retry failed", error: error)
                return nil
            }
        }

        let captureBatch: ([CaptureSpec]) async -> [(Int, CGDirectDisplayID, CGImage)] = { batch in
            await withTaskGroup(of: (Int, CGDirectDisplayID, CGImage)?.self) { group in
                for s in batch {
                    group.addTask {
                        guard let img = try? await SCScreenshotManager.captureImage(contentFilter: s.filter, configuration: s.cfg) else {
                            return nil
                        }
                        return (s.index, s.displayID, img)
                    }
                }
                var out: [(Int, CGDirectDisplayID, CGImage)] = []
                for await item in group { if let item { out.append(item) } }
                return out
            }
        }
        var capturedPairs = await captureBatch(specs)
        if capturedPairs.count < specs.count {
            MSnipLog.warning(.capture, "Multi-display capture got \(capturedPairs.count)/\(specs.count) displays; retrying with fresh filters")
            cachedDisplayFilters.removeAll()
            if let fresh = await ensureDisplayFilters(for: screens) {
                let refreshedSpecs = specs.compactMap { s -> CaptureSpec? in
                    guard let f = fresh[s.displayID] else { return nil }
                    return CaptureSpec(index: s.index, displayID: s.displayID, filter: f, cfg: s.cfg)
                }
                if !refreshedSpecs.isEmpty { capturedPairs = await captureBatch(refreshedSpecs) }
            }
        }
        return capturedPairs.sorted { $0.0 < $1.0 }.map { ScreenSnapshot(screen: screens[$0.0], displayID: $0.1, cgImage: $0.2) }
    }

    @MainActor
    private static func captureViaLegacyCoreGraphics(screens: [NSScreen]) -> [ScreenSnapshot] {
        typealias LegacyCaptureFn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGDisplayCreateImage") else { return [] }
        let createImage = unsafeBitCast(sym, to: LegacyCaptureFn.self)
        return screens.compactMap { screen in
            guard let id = screenDisplayID(screen), let img = createImage(id)?.takeRetainedValue() else { return nil }
            return ScreenSnapshot(screen: screen, displayID: id, cgImage: img)
        }
    }

    static func screenDisplayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    @MainActor
    static func captureIsolatedWindow(
        windowID: CGWindowID,
        scaleFactor: CGFloat,
        backdropStyle: BackdropStyle = .none
    ) async -> CGImage? {
        let scale = max(1.0, scaleFactor)
        if #available(macOS 14.0, *),
           let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
           let scWin = content.windows.first(where: { $0.windowID == windowID }) {
            let filter = SCContentFilter(desktopIndependentWindow: scWin)
            let cfg = SCStreamConfiguration()
            cfg.width = max(16, Int((scWin.frame.width * scale).rounded()))
            cfg.height = max(16, Int((scWin.frame.height * scale).rounded()))
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.showsCursor = false
            cfg.capturesAudio = false
            cfg.shouldBeOpaque = false
            cfg.backgroundColor = .clear
            cfg.ignoreShadowsSingleWindow = true

            if let rawWin = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) {
                if backdropStyle != .none {
                    return BackdropBeautifier.apply(to: rawWin, style: backdropStyle, imageScale: scale, innerCornerRadiusPt: 12)
                }
                return BackdropBeautifier.applyTransparentWindowShadow(to: rawWin, imageScale: scale)
            }
        }

        typealias LegacyWinCaptureFn = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let fn = unsafeBitCast(sym, to: LegacyWinCaptureFn.self)
        let listOpt = CGWindowListOption.optionIncludingWindow.rawValue
        let imgOpt: UInt32 = (backdropStyle != .none) ? CGWindowImageOption.boundsIgnoreFraming.rawValue : 0
        guard let raw = fn(.null, listOpt, windowID, imgOpt)?.takeRetainedValue() else { return nil }
        if backdropStyle != .none {
            return BackdropBeautifier.apply(to: raw, style: backdropStyle, imageScale: scale, innerCornerRadiusPt: 12)
        }
        return raw
    }
}

// MARK: - 局部选区实时采集流 (SCStream)

/// 面向长截图与区域录屏的局部选区实时帧采集器：
/// 基于 `SCStream` 仅抓取选区矩形，并自动在 `SCContentFilter` 中剔除 `MSnip` 自身全部窗口。
@MainActor
final class RegionStreamSampler {
    private var activeStream: AnyObject?
    private var outputProxy: AnyObject?
    private let captureQueue = DispatchQueue(label: "top.xy.msnip.longshot.capture", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "top.xy.msnip.recording.audio", qos: .userInteractive)
    private var stopped = false
    private var sessionGen: UInt64 = 0

    func start(
        screen: NSScreen,
        localTopLeftRect: CGRect,
        fps: Int = 20,
        showsCursor: Bool = false,
        losslessBGRA: Bool = false,
        maxLongSide: Int? = nil,
        capturesAudio: Bool = false,
        onFrameBackground: @escaping @Sendable (CGImage) -> Void,
        onPixelBufferBackground: (@Sendable (CVPixelBuffer) -> Void)? = nil,
        onAudioSampleBackground: (@Sendable (CMSampleBuffer) -> Void)? = nil,
        onError: @escaping @MainActor (String) -> Void
    ) {
        stopped = false
        sessionGen &+= 1
        let myGen = sessionGen
        guard #available(macOS 13.0, *) else {
            MSnipLog.warning(.capture, "Region stream requires macOS 13+")
            onError("长截图实时流需要 macOS 13.0 及以上系统")
            return
        }
        guard let displayID = ScreenCapturer.screenDisplayID(screen) else {
            MSnipLog.error(.capture, "Region stream: display ID unavailable")
            onError("无法识别目标显示器")
            return
        }

        let clampedRect = localTopLeftRect.intersection(CGRect(origin: .zero, size: screen.frame.size))
        guard clampedRect.width >= 24, clampedRect.height >= 32 else {
            onError("长截图选区过小")
            return
        }
        let scale = max(1.0, screen.backingScaleFactor)

        Task { @MainActor [weak self] in
            guard let self, !self.stopped, self.sessionGen == myGen else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard !self.stopped, self.sessionGen == myGen else { return }
                guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                    MSnipLog.error(.capture, "Region stream: display \(displayID) not in shareable content (\(content.displays.count) displays)")
                    onError("未找到目标屏幕采集源")
                    return
                }

                let selfPID = ProcessInfo.processInfo.processIdentifier
                let ownApps = content.applications.filter { $0.processID == selfPID }
                let filter: SCContentFilter
                if !ownApps.isEmpty {
                    // 按进程级排除 MSnip 自身全部现有与未来悬浮窗（刻意不设 sharingType = .none，保证远程桌面/投屏下自身取景框与提示正常可见）
                    filter = SCContentFilter(display: scDisplay, excludingApplications: ownApps, exceptingWindows: [])
                } else {
                    let ownWindows = content.windows.filter { $0.owningApplication?.processID == selfPID }
                    filter = SCContentFilter(display: scDisplay, excludingWindows: ownWindows)
                }

                let cfg = SCStreamConfiguration()
                if losslessBGRA {
                    // 长截图模式：严格对齐物理整数像素并使用无损 32BGRA + 显示器原生 ICC，杜绝二次缩放与色差
                    let pxX = round(clampedRect.minX * scale)
                    let pxY = round(clampedRect.minY * scale)
                    let pxW = max(24, Int((clampedRect.width * scale).rounded()))
                    let pxH = max(32, Int((clampedRect.height * scale).rounded()))
                    cfg.sourceRect = CGRect(
                        x: pxX / scale,
                        y: pxY / scale,
                        width: CGFloat(pxW) / scale,
                        height: CGFloat(pxH) / scale
                    )
                    cfg.width = pxW
                    cfg.height = pxH
                    cfg.pixelFormat = kCVPixelFormatType_32BGRA
                    cfg.queueDepth = 4
                } else {
                    // 视频编码模式：按清晰度预设在 GPU 采集端直接等比缩放并保持偶数像素，确保 H.264 零拷贝直通
                    let rawW = max(24, Int((clampedRect.width * scale).rounded()) & ~1)
                    let rawH = max(32, Int((clampedRect.height * scale).rounded()) & ~1)
                    let outW: Int, outH: Int
                    if let limit = maxLongSide, max(rawW, rawH) > limit {
                        let ratio = Double(limit) / Double(max(rawW, rawH))
                        outW = max(64, Int((Double(rawW) * ratio).rounded()) & ~1)
                        outH = max(64, Int((Double(rawH) * ratio).rounded()) & ~1)
                    } else {
                        outW = rawW; outH = rawH
                    }
                    cfg.sourceRect = CGRect(
                        x: clampedRect.minX,
                        y: clampedRect.minY,
                        width: CGFloat(rawW) / scale,
                        height: CGFloat(rawH) / scale
                    )
                    cfg.width = outW
                    cfg.height = outH
                    cfg.pixelFormat = kCVPixelFormatType_32BGRA
                    cfg.colorSpaceName = CGColorSpace.sRGB
                    cfg.queueDepth = fps > 60 ? 8 : 5
                }
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(5, fps)))
                cfg.showsCursor = showsCursor
                let wantAudio = capturesAudio && onAudioSampleBackground != nil
                cfg.capturesAudio = wantAudio
                if wantAudio {
                    cfg.excludesCurrentProcessAudio = true
                    cfg.sampleRate = 48_000
                    cfg.channelCount = 2
                }

                let proxy = StreamOutputProxy(
                    onFrame: onFrameBackground,
                    onPixelBuffer: onPixelBufferBackground,
                    onAudioSample: wantAudio ? onAudioSampleBackground : nil
                )
                let stream = SCStream(filter: filter, configuration: cfg, delegate: proxy)
                try stream.addStreamOutput(proxy, type: .screen, sampleHandlerQueue: self.captureQueue)
                if wantAudio {
                    do {
                        try stream.addStreamOutput(proxy, type: .audio, sampleHandlerQueue: self.audioQueue)
                    } catch {
                        MSnipLog.warning(.recording, "System audio output unavailable; recording video only", error: error)
                    }
                }
                MSnipLog.info(.capture, "Region stream start \(cfg.width)×\(cfg.height) fps=\(fps) audio=\(wantAudio) lossless=\(losslessBGRA)")
                try await stream.startCapture()

                if self.stopped || self.sessionGen != myGen {
                    try? await stream.stopCapture()
                    return
                }
                self.outputProxy = proxy
                self.activeStream = stream
            } catch {
                if !self.stopped {
                    MSnipLog.error(.capture, "Region stream failed to start", error: error)
                    onError("启动实时画面采集流失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func stop() {
        stopped = true
        if #available(macOS 13.0, *), let stream = activeStream as? SCStream {
            activeStream = nil
            outputProxy = nil
            Task { try? await stream.stopCapture() }
        } else {
            activeStream = nil
            outputProxy = nil
        }
    }
}

@available(macOS 13.0, *)
private final class StreamOutputProxy: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let onFrame: @Sendable (CGImage) -> Void
    private let onPixelBuffer: (@Sendable (CVPixelBuffer) -> Void)?
    private let onAudioSample: (@Sendable (CMSampleBuffer) -> Void)?

    init(
        onFrame: @escaping @Sendable (CGImage) -> Void,
        onPixelBuffer: (@Sendable (CVPixelBuffer) -> Void)?,
        onAudioSample: (@Sendable (CMSampleBuffer) -> Void)?
    ) {
        self.onFrame = onFrame
        self.onPixelBuffer = onPixelBuffer
        self.onAudioSample = onAudioSample
    }

    /// 系统中途终止采集流（权限被撤销、显示器断开等）时只记录日志，不改变既有会话行为
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        MSnipLog.error(.capture, "Region stream stopped by system", error: error)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        if outputType == .audio {
            onAudioSample?(sampleBuffer)
            return
        }
        guard outputType == .screen else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let statusRaw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if let onPixelBuffer {
            onPixelBuffer(pixelBuffer)
            return
        }
        var cgImage: CGImage?
        let err = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        if err == noErr, let img = cgImage {
            onFrame(img)
        }
    }
}
