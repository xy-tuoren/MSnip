import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 动图与录屏输出封装格式（100% Apple 原生 ImageIO / AVAssetWriter，零 ffmpeg 依赖）
public enum RecordingFormat: String, CaseIterable, Codable, Sendable {
    case gif = "gif"
    case mp4 = "mp4"

    public var badgeTitle: String {
        switch self {
        case .gif: return "GIF"
        case .mp4: return "MP4"
        }
    }

    public var maxDurationSeconds: TimeInterval {
        switch self {
        case .gif: return 30.0
        case .mp4: return 120.0
        }
    }
}

/// 纯原生局部录屏编码器：
/// - MP4：基于 `AVAssetWriter` 实时流式硬件 H.264 + 可选 AAC 48kHz 系统音频，支持 30/60/120fps 高精度 `60_000` 时基与零拷贝 `CVPixelBuffer` 直通；
/// - GIF：委托 `GIFDiskSpooler` 执行 LZ4 磁盘流式暂存，录制全程零 `CGImage` 数组驻留内存。
public final class MediaClipEncoder: @unchecked Sendable {
    private static let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let videoTimescale: CMTimeScale = 60_000

    public let format: RecordingFormat
    public let outputURL: URL
    public let options: RecordingOptions
    public let targetMP4FPS: Int
    public var spoolFileURL: URL { gifSpooler.spoolFileURL }

    private let lock = NSLock()
    private var isCancelled = false
    private var isFinished = false

    private let gifSpooler: GIFDiskSpooler
    private let maxGIFFrames: Int
    private let gifMinInterval: TimeInterval
    private let minVideoStepTicks: Int64

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var mp4Size: (w: Int, h: Int) = (0, 0)
    private var startTime: TimeInterval?
    private var lastPTSTicks: Int64 = -1
    private var lastAudioPTS: CMTime = .invalid
    private var lastCGFrame: CGImage?
    private var _capturedFrameCount: Int = 0
    public var capturedFrameCount: Int { lock.lock(); defer { lock.unlock() }; return _capturedFrameCount }

    public init(
        format: RecordingFormat,
        outputURL: URL,
        options: RecordingOptions = RecordingOptions(),
        targetMP4FPS: Int? = nil
    ) {
        self.format = format
        self.outputURL = outputURL
        self.options = options
        let resolvedFPS = max(24, min(120, targetMP4FPS ?? options.mp4FPSMode.resolveFPS(displayMaxFPS: 60, outputWidth: 1920, outputHeight: 1080)))
        self.targetMP4FPS = resolvedFPS
        self.maxGIFFrames = options.maxGIFFrames
        self.gifMinInterval = max(0.05, 1.0 / Double(options.clampedGifFPS) * 0.92)
        // 60_000 时基下按目标帧率动态设置最小单调步进（120fps 约 3.75ms，避免 120Hz 帧被量化降帧）
        self.minVideoStepTicks = max(60, Int64((Double(Self.videoTimescale) / Double(resolvedFPS) * 0.45).rounded()))
        let spoolURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".msnip-gifspool-\(UUID().uuidString).bin")
        self.gifSpooler = GIFDiskSpooler(spoolFileURL: spoolURL, maxLongSide: options.clampedGifMaxLongSide)
        try? FileManager.default.removeItem(at: outputURL)
    }

    /// 零拷贝直接向 MP4 硬件编码器追加 `CVPixelBuffer`（无特效帧免除 CGImage 转码；返回 false 时由调用方回退至 CGImage 缩放路径）
    @discardableResult
    public func appendPixelBuffer(_ pixelBuffer: CVPixelBuffer, at timestamp: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard format == .mp4, !isCancelled, !isFinished else { return true }
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return false }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w >= 64, h >= 64, (w & 1) == 0, (h & 1) == 0 else { return false }
        if startTime == nil { startTime = timestamp }
        let elapsed = max(0.0, timestamp - (startTime ?? timestamp))

        if assetWriter == nil {
            guard setupMP4Writer(width: w, height: h) else { return false }
        }
        guard w == mp4Size.w, h == mp4Size.h else { return false }
        guard let input = videoInput, let adaptor, input.isReadyForMoreMediaData else { return true }
        let ptsTicks = nextMonotonicTicks(for: elapsed)
        if adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: ptsTicks, timescale: Self.videoTimescale)) {
            lastPTSTicks = ptsTicks
            lastCGFrame = nil
            _capturedFrameCount += 1
        }
        return true
    }

    /// 追加实时系统音频采样缓冲（保留每样本真实时长并用样本计数单调推进 PTS，杜绝 960× 时长膨胀与墙钟抖动爆音）
    public func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, at timestamp: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard format == .mp4, options.captureSystemAudio, !isCancelled, !isFinished,
              let start = startTime, let aInput = audioInput, aInput.isReadyForMoreMediaData else { return }
        var origTiming = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &origTiming) == noErr else { return }
        let wallPTS = CMTime(seconds: max(0.0, timestamp - start), preferredTimescale: 48_000)
        let targetPTS: CMTime = (lastAudioPTS.isValid && abs(CMTimeGetSeconds(wallPTS) - CMTimeGetSeconds(lastAudioPTS)) < 0.18)
            ? lastAudioPTS : (lastAudioPTS.isValid ? max(wallPTS, lastAudioPTS) : wallPTS)
        var timing = CMSampleTimingInfo(duration: origTiming.duration, presentationTimeStamp: targetPTS, decodeTimeStamp: .invalid)
        var retimed: CMSampleBuffer?
        let st = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &retimed)
        if st == noErr, let buf = retimed, aInput.append(buf) {
            let sr = (origTiming.duration.isValid && origTiming.duration.value > 0) ? origTiming.duration.timescale : 48_000
            lastAudioPTS = CMTimeAdd(targetPTS, CMTime(value: CMTimeValue(max(1, CMSampleBufferGetNumSamples(sampleBuffer))), timescale: sr))
        }
    }

    /// 追加一帧实时采集画面（`timestamp` 为单调秒数，如 `CACurrentMediaTime()`）
    public func appendFrame(_ cgImage: CGImage, at timestamp: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled, !isFinished else { return }

        if startTime == nil { startTime = timestamp }
        let elapsed = max(0.0, timestamp - (startTime ?? timestamp))

        switch format {
        case .gif:
            guard gifSpooler.frameCount < maxGIFFrames else { return }
            if let prev = gifSpooler.lastFrameTime, (elapsed - prev) < gifMinInterval { return }
            if gifSpooler.append(cgImage, elapsed: elapsed) { _capturedFrameCount = gifSpooler.frameCount }

        case .mp4:
            if assetWriter == nil {
                guard setupMP4Writer(width: cgImage.width, height: cgImage.height) else { return }
            }
            let ptsTicks = nextMonotonicTicks(for: elapsed)
            if writeMP4Frame(cgImage, ptsTicks: ptsTicks) {
                lastPTSTicks = ptsTicks
                lastCGFrame = cgImage
                _capturedFrameCount += 1
            }
        }
    }

    /// 结束录制并封装输出文件（成功返回目标 `outputURL`）
    public func finish(finalTimestamp: TimeInterval) async -> URL? {
        guard let baseStart = markFinishedAndSnapshotStart(fallback: finalTimestamp) else { return nil }
        switch format {
        case .gif:
            let outURL = outputURL, spooler = gifSpooler, dur = max(0.12, finalTimestamp - baseStart)
            return await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: spooler.finalizeGIF(to: outURL, totalElapsed: dur))
                }
            }
        case .mp4:
            return await finalizeMP4(finalTimestamp: finalTimestamp)
        }
    }

    private func nextMonotonicTicks(for elapsed: TimeInterval) -> Int64 {
        var ticks = Int64((elapsed * Double(Self.videoTimescale)).rounded())
        if ticks <= lastPTSTicks { ticks = lastPTSTicks + minVideoStepTicks }
        return ticks
    }

    private func markFinishedAndSnapshotStart(fallback: TimeInterval) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled, !isFinished else { return nil }
        isFinished = true
        return startTime ?? fallback
    }

    public func cancel() {
        lock.lock()
        isCancelled = true
        let writer = assetWriter
        assetWriter = nil; videoInput = nil; audioInput = nil; adaptor = nil; lastCGFrame = nil
        gifSpooler.cleanup()
        lock.unlock()

        writer?.cancelWriting()
        try? FileManager.default.removeItem(at: outputURL)
    }

    // MARK: - Native H.264 + Optional AAC MP4 Encoding

    private func setupMP4Writer(width: Int, height: Int) -> Bool {
        let (outW, outH) = options.mp4Resolution.scaledEvenSize(width: width, height: height)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        } catch {
            MSnipLog.error(.recording, "AVAssetWriter init failed", error: error)
            return false
        }
        let bitrate = RecordingOptions.recommendedMP4Bitrate(width: outW, height: outH, fps: targetMP4FPS)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: targetMP4FPS,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let pbAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: outW,
            kCVPixelBufferHeightKey as String: outH
        ]
        let adp = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: pbAttrs)
        guard writer.canAdd(input) else {
            MSnipLog.error(.recording, "AVAssetWriter rejected H.264 input \(outW)×\(outH)@\(targetMP4FPS)fps")
            return false
        }
        writer.add(input)

        var aInput: AVAssetWriterInput?
        if options.captureSystemAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ]
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            ai.expectsMediaDataInRealTime = true
            if writer.canAdd(ai) {
                writer.add(ai); aInput = ai
            } else {
                MSnipLog.warning(.recording, "AVAssetWriter rejected AAC input; recording video only")
            }
        }

        guard writer.startWriting() else {
            MSnipLog.error(.recording, "AVAssetWriter startWriting failed \(outW)×\(outH)", error: writer.error)
            return false
        }
        MSnipLog.info(.recording, "MP4 writer ready \(outW)×\(outH)@\(targetMP4FPS)fps bitrate=\(bitrate) audio=\(aInput != nil)")
        writer.startSession(atSourceTime: .zero)
        self.mp4Size = (outW, outH); self.assetWriter = writer
        self.videoInput = input; self.audioInput = aInput; self.adaptor = adp
        return true
    }

    private func writeMP4Frame(_ cgImage: CGImage, ptsTicks: Int64) -> Bool {
        guard let input = videoInput, let adaptor, input.isReadyForMoreMediaData,
              let pool = adaptor.pixelBufferPool else { return false }
        var pbOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) == kCVReturnSuccess, let pb = pbOut else { return false }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb), width: mp4Size.w, height: mp4Size.h,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: Self.srgbSpace, bitmapInfo: bitmapInfo
        ) else { return false }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: mp4Size.w, height: mp4Size.h))
        return adaptor.append(pb, withPresentationTime: CMTime(value: ptsTicks, timescale: Self.videoTimescale))
    }

    private func finalizeMP4(finalTimestamp: TimeInterval) async -> URL? {
        let pack: (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInput?, CMTime?)? = {
            lock.lock()
            defer { lock.unlock() }
            guard let writer = assetWriter, let input = videoInput else { return nil }
            var endSessionTime: CMTime?
            if let s = startTime {
                let rawEnd = Int64((max(0, finalTimestamp - s) * Double(Self.videoTimescale)).rounded())
                let endTicks = max(lastPTSTicks + minVideoStepTicks, rawEnd)
                if let tail = lastCGFrame {
                    _ = writeMP4Frame(tail, ptsTicks: endTicks)
                } else {
                    endSessionTime = CMTime(value: endTicks, timescale: Self.videoTimescale)
                }
            }
            let aIn = audioInput
            lastCGFrame = nil; assetWriter = nil; videoInput = nil; audioInput = nil; adaptor = nil
            return (writer, input, aIn, endSessionTime)
        }()
        guard let (writer, input, aInput, endTime) = pack else { return nil }
        guard writer.status == .writing else {
            MSnipLog.error(.recording, "MP4 writer not writing at finish (status=\(writer.status.rawValue))", error: writer.error)
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
        input.markAsFinished()
        aInput?.markAsFinished()
        if let endTime { writer.endSession(atSourceTime: endTime) }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        let cancelled: Bool = { lock.lock(); defer { lock.unlock() }; return isCancelled }()
        if writer.status != .completed || cancelled {
            if !cancelled {
                MSnipLog.error(.recording, "MP4 finishWriting failed (status=\(writer.status.rawValue))", error: writer.error)
            }
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
        return outputURL
    }
}

// MARK: - GIF LZ4 磁盘流式暂存缓冲池

/// 基于 LZ4 磁盘流式暂存的线程安全 GIF 帧缓冲池：
/// 录制期间内存中仅保留单帧复用字节缓冲与 40B/帧偏移索引，彻底消除驻留数百张 `CGImage` 造成的内存峰值，支持安全并发取消。
final class GIFDiskSpooler: @unchecked Sendable {
    private struct FrameMeta {
        let offset: UInt64
        let byteCount: Int
        let compressed: Bool
        let width: Int
        let height: Int
        let time: TimeInterval
    }

    static let defaultMaxLongSide = 880

    let spoolFileURL: URL
    let maxLongSide: Int
    private let lock = NSLock()
    private var isCancelled = false
    private var metaList: [FrameMeta] = []
    private var scratchRGBA: [UInt8] = []
    private var writeHandle: FileHandle?
    private var writeOffset: UInt64 = 0

    var frameCount: Int { lock.lock(); defer { lock.unlock() }; return metaList.count }
    var lastFrameTime: TimeInterval? { lock.lock(); defer { lock.unlock() }; return metaList.last?.time }

    init(spoolFileURL: URL, maxLongSide: Int = GIFDiskSpooler.defaultMaxLongSide) {
        self.spoolFileURL = spoolFileURL
        self.maxLongSide = max(320, maxLongSide)
    }

    deinit { cleanup() }

    func append(_ src: CGImage, elapsed: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled, src.width >= 2, src.height >= 2 else { return false }

        let longSide = max(src.width, src.height)
        let outW: Int, outH: Int
        if longSide <= maxLongSide {
            outW = src.width; outH = src.height
        } else {
            let ratio = Double(maxLongSide) / Double(longSide)
            outW = max(16, Int((Double(src.width) * ratio).rounded()) & ~1)
            outH = max(16, Int((Double(src.height) * ratio).rounded()) & ~1)
        }

        let rawLen = outW * outH * 4
        if scratchRGBA.count != rawLen { scratchRGBA = [UInt8](repeating: 0, count: rawLen) }
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let rendered: Bool = scratchRGBA.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress,
                  let ctx = CGContext(
                      data: base, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: outW * 4,
                      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(src, in: CGRect(x: 0, y: 0, width: outW, height: outH))
            return true
        }
        guard rendered else { return false }

        if writeHandle == nil {
            let dir = spoolFileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            _ = FileManager.default.createFile(
                atPath: spoolFileURL.path, contents: nil,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
            )
            writeHandle = try? FileHandle(forWritingTo: spoolFileURL)
        }
        guard let handle = writeHandle else { return false }

        let (payload, isCompressed): (Data, Bool) = scratchRGBA.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else { return (Data(), false) }
            let rawNS = NSData(bytesNoCopy: base, length: rawLen, freeWhenDone: false)
            if let lz4 = try? rawNS.compressed(using: .lz4) as Data, lz4.count < rawLen {
                return (lz4, true)
            }
            return (Data(bytes: base, count: rawLen), false)
        }
        guard !payload.isEmpty, (try? handle.write(contentsOf: payload)) != nil else { return false }

        metaList.append(FrameMeta(
            offset: writeOffset, byteCount: payload.count, compressed: isCompressed,
            width: outW, height: outH, time: elapsed
        ))
        writeOffset += UInt64(payload.count)
        return true
    }

    func finalizeGIF(to outputURL: URL, totalElapsed: TimeInterval) -> URL? {
        let frames: [FrameMeta] = {
            lock.lock()
            defer { lock.unlock() }
            if isCancelled { return [] }
            let copy = metaList
            try? writeHandle?.close(); writeHandle = nil
            metaList.removeAll()
            scratchRGBA.removeAll(keepingCapacity: false)
            return copy
        }()
        defer { cleanup(markCancelled: false) }

        guard !frames.isEmpty,
              let readHandle = try? FileHandle(forReadingFrom: spoolFileURL),
              let dest = CGImageDestinationCreateWithURL(
                  outputURL as CFURL, UTType.gif.identifier as CFString, frames.count, nil
              ) else {
            if !frames.isEmpty { MSnipLog.error(.recording, "GIF finalize: cannot open spool or create destination (frames=\(frames.count))") }
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
        defer { try? readHandle.close() }

        let fileProps: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        for i in frames.indices {
            let cancelled: Bool = { lock.lock(); defer { lock.unlock() }; return isCancelled }()
            if cancelled { try? FileManager.default.removeItem(at: outputURL); return nil }

            let ok: Bool = autoreleasepool {
                let m = frames[i]
                guard (try? readHandle.seek(toOffset: m.offset)) != nil,
                      let chunk = try? readHandle.read(upToCount: m.byteCount),
                      chunk.count == m.byteCount else { return false }
                let rawData: Data = m.compressed
                    ? ((try? (chunk as NSData).decompressed(using: .lz4) as Data) ?? Data())
                    : chunk
                guard rawData.count == m.width * m.height * 4,
                      let provider = CGDataProvider(data: rawData as CFData),
                      let cg = CGImage(
                          width: m.width, height: m.height, bitsPerComponent: 8, bitsPerPixel: 32,
                          bytesPerRow: m.width * 4, space: cs,
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                          provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
                      ) else { return false }

                let rawDelay = (i + 1 < frames.count) ? (frames[i + 1].time - m.time) : max(0.10, totalElapsed - m.time)
                let clampedDelay = min(1.5, max(0.06, rawDelay))
                let frameProps: [CFString: Any] = [
                    kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFDelayTime: clampedDelay,
                        kCGImagePropertyGIFUnclampedDelayTime: clampedDelay
                    ]
                ]
                CGImageDestinationAddImage(dest, cg, frameProps as CFDictionary)
                return true
            }
            if !ok {
                MSnipLog.error(.recording, "GIF finalize: frame \(i)/\(frames.count) unreadable from spool")
                try? FileManager.default.removeItem(at: outputURL)
                return nil
            }
        }
        let finalized = CGImageDestinationFinalize(dest)
        let cancelledEnd: Bool = { lock.lock(); defer { lock.unlock() }; return isCancelled }()
        if !finalized || cancelledEnd {
            if !finalized && !cancelledEnd { MSnipLog.error(.recording, "GIF CGImageDestinationFinalize failed (frames=\(frames.count))") }
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
        return outputURL
    }

    func cleanup(markCancelled: Bool = true) {
        lock.lock()
        if markCancelled { isCancelled = true }
        try? writeHandle?.close()
        writeHandle = nil
        metaList.removeAll()
        scratchRGBA.removeAll(keepingCapacity: false)
        lock.unlock()
        try? FileManager.default.removeItem(at: spoolFileURL)
    }
}

// MARK: - 录屏格式、帧率与清晰度模型

/// MP4 录屏清晰度预设（按最长边像素上限等比缩放，源图更小时不放大）
public enum MP4ResolutionPreset: String, CaseIterable, Codable, Sendable {
    case standard // 最长边 ≤ 1280px（适合聊天/文档快速发送）
    case high     // 最长边 ≤ 1920px（默认推荐，清晰且体积均衡）
    case native   // Retina 1:1 原生像素不缩放

    public var maxLongSide: Int? {
        switch self {
        case .standard: return 1280
        case .high:     return 1920
        case .native:   return nil
        }
    }

    public var title: String {
        switch self {
        case .standard: return L("标准")
        case .high:     return L("高清")
        case .native:   return L("原画")
        }
    }

    /// 计算符合 H.264 偶数像素对齐的目标输出尺寸（永不放大超过原尺寸）
    public func scaledEvenSize(width: Int, height: Int) -> (width: Int, height: Int) {
        let w = max(64, width), h = max(64, height)
        let longSide = max(w, h)
        guard let limit = maxLongSide, longSide > limit else {
            return (max(64, w & ~1), max(64, h & ~1))
        }
        let ratio = Double(limit) / Double(longSide)
        let outW = max(64, Int((Double(w) * ratio).rounded()) & ~1)
        let outH = max(64, Int((Double(h) * ratio).rounded()) & ~1)
        return (outW, outH)
    }
}

/// MP4 录屏帧率模式（支持 30/60fps 及跟随显示器原生高刷，如 ProMotion 120Hz）
public enum MP4FrameRateMode: String, CaseIterable, Codable, Sendable {
    case fps30
    case fps60
    case displayNative

    public var title: String {
        switch self {
        case .fps30:         return "30 fps"
        case .fps60:         return "60 fps"
        case .displayNative: return L("原刷")
        }
    }

    /// 结合当前显示器最高刷新率与输出像素尺寸解析安全稳定的实际录制帧率
    public func resolveFPS(displayMaxFPS: Int, outputWidth: Int, outputHeight: Int) -> Int {
        switch self {
        case .fps30: return 30
        case .fps60: return 60
        case .displayNative:
            let capped = max(30, min(120, displayMaxFPS))
            // 超过 2560px 的超高分原画超出 H.264 硬件 120fps Level 上限时自动稳帧 60fps，防止编码拥塞掉帧
            if max(outputWidth, outputHeight) > 2560 {
                return min(60, capped)
            }
            return capped
        }
    }
}

/// 选区录屏可调参数模型（支持持久化、旧配置无损迁移与跨会话生效）
public struct RecordingOptions: Equatable, Codable, Sendable {
    public var gifFPS: Int = 12
    public var gifMaxLongSide: Int = 960
    public var mp4FPS: Int = 30
    public var mp4FPSMode: MP4FrameRateMode = .fps30
    public var mp4Resolution: MP4ResolutionPreset = .high
    public var showsCursor: Bool = true
    public var captureSystemAudio: Bool = false

    public init(
        gifFPS: Int = 12,
        gifMaxLongSide: Int = 960,
        mp4FPS: Int = 30,
        mp4FPSMode: MP4FrameRateMode = .fps30,
        mp4Resolution: MP4ResolutionPreset = .high,
        showsCursor: Bool = true,
        captureSystemAudio: Bool = false
    ) {
        self.gifFPS = gifFPS
        self.gifMaxLongSide = gifMaxLongSide
        self.mp4FPS = mp4FPS
        self.mp4FPSMode = mp4FPSMode
        self.mp4Resolution = mp4Resolution
        self.showsCursor = showsCursor
        self.captureSystemAudio = captureSystemAudio
    }

    private enum CodingKeys: String, CodingKey {
        case gifFPS, gifMaxLongSide, mp4FPS, mp4FPSMode, mp4Resolution, showsCursor, captureSystemAudio
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gifFPS = try c.decodeIfPresent(Int.self, forKey: .gifFPS) ?? 12
        gifMaxLongSide = try c.decodeIfPresent(Int.self, forKey: .gifMaxLongSide) ?? 960
        let legacyFPS = try c.decodeIfPresent(Int.self, forKey: .mp4FPS) ?? 30
        mp4FPS = legacyFPS
        mp4FPSMode = try c.decodeIfPresent(MP4FrameRateMode.self, forKey: .mp4FPSMode)
            ?? (legacyFPS >= 50 ? .fps60 : .fps30)
        mp4Resolution = try c.decodeIfPresent(MP4ResolutionPreset.self, forKey: .mp4Resolution) ?? .high
        showsCursor = try c.decodeIfPresent(Bool.self, forKey: .showsCursor) ?? true
        captureSystemAudio = try c.decodeIfPresent(Bool.self, forKey: .captureSystemAudio) ?? false
    }

    public var clampedGifFPS: Int { min(20, max(6, gifFPS)) }
    public var clampedGifMaxLongSide: Int { min(1600, max(480, gifMaxLongSide)) }
    public var clampedMp4FPS: Int { min(120, max(15, mp4FPS)) }

    /// 按 GIF 帧率动态计算 30 秒完整时长对应的最大帧数（避免 15fps 在第 24 秒静默截断）
    public var maxGIFFrames: Int {
        max(180, clampedGifFPS * Int(RecordingFormat.gif.maxDurationSeconds))
    }

    /// 结合像素面积与目标帧率计算自适应 H.264 码率（30/60/120fps 逐级平滑拉升，兼顾锐利度与体积上限）
    public static func recommendedMP4Bitrate(width: Int, height: Int, fps: Int) -> Int {
        let areaBits = Double(max(64, width) * max(64, height)) * 4.0
        let fpsFactor = pow(Double(max(24, min(120, fps))) / 30.0, 0.72)
        let raw = Int((areaBits * fpsFactor).rounded())
        return min(32_000_000, max(1_400_000, raw))
    }
}

/// 录屏实时演示画笔笔迹（归一化选区坐标 `0..1`，支持 2.6s 自动渐隐激光模式与常驻标注模式）
public struct RecordingLiveStroke: Sendable {
    public var points: [CGPoint]
    public let isLaser: Bool
    public var updatedAt: TimeInterval

    public init(points: [CGPoint], isLaser: Bool, updatedAt: TimeInterval) {
        self.points = points
        self.isLaser = isLaser
        self.updatedAt = updatedAt
    }
}
