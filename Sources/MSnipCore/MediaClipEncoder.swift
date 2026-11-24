import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

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
/// - MP4：基于 `AVAssetWriter` 实时流式硬件 H.264 + 可选 AAC 48kHz 系统音频直写磁盘，无特效帧零拷贝 `CVPixelBuffer` 直通；
/// - GIF：委托 `GIFDiskSpooler` 执行 LZ4 磁盘流式暂存，录制全程零 `CGImage` 数组驻留内存。
public final class MediaClipEncoder: @unchecked Sendable {
    private static let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    public let format: RecordingFormat
    public let outputURL: URL
    public let options: RecordingOptions
    public var spoolFileURL: URL { gifSpooler.spoolFileURL }

    private let lock = NSLock()
    private var isCancelled = false
    private var isFinished = false

    private let gifSpooler: GIFDiskSpooler
    private let maxGIFFrames = 360
    private let gifMinInterval: TimeInterval

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var mp4Size: (w: Int, h: Int) = (0, 0)
    private var startTime: TimeInterval?
    private var lastPTSMillis: Int64 = -1
    private var lastAudioPTS: CMTime = .invalid
    private var lastCGFrame: CGImage?
    private var lastPixelBuffer: CVPixelBuffer?
    private(set) public var capturedFrameCount: Int = 0

    public init(format: RecordingFormat, outputURL: URL, options: RecordingOptions = RecordingOptions()) {
        self.format = format
        self.outputURL = outputURL
        self.options = options
        self.gifMinInterval = max(0.05, 1.0 / Double(options.clampedGifFPS) * 0.92)
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
        var ptsMs = Int64((elapsed * 1000.0).rounded())
        if ptsMs <= lastPTSMillis { ptsMs = lastPTSMillis + 16 }
        if adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: ptsMs, timescale: 1000)) {
            lastPTSMillis = ptsMs
            lastCGFrame = nil
            lastPixelBuffer = pixelBuffer
            capturedFrameCount += 1
        }
        return true
    }

    /// 追加实时系统音频采样缓冲（与视频共享虚拟活跃时钟，天然支持暂停/恢复无音画漂移）
    public func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer, at timestamp: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard format == .mp4, options.captureSystemAudio, !isCancelled, !isFinished,
              let start = startTime, let aInput = audioInput, aInput.isReadyForMoreMediaData else { return }
        let elapsed = max(0.0, timestamp - start)
        let targetPTS = CMTime(seconds: elapsed, preferredTimescale: 48_000)
        if lastAudioPTS.isValid, targetPTS <= lastAudioPTS { return }
        let dur = CMSampleBufferGetDuration(sampleBuffer)
        var timing = CMSampleTimingInfo(duration: dur, presentationTimeStamp: targetPTS, decodeTimeStamp: .invalid)
        var retimed: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &retimed
        )
        if status == noErr, let buf = retimed, aInput.append(buf) {
            lastAudioPTS = targetPTS
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
            if gifSpooler.append(cgImage, elapsed: elapsed) { capturedFrameCount = gifSpooler.frameCount }

        case .mp4:
            if assetWriter == nil {
                guard setupMP4Writer(width: cgImage.width, height: cgImage.height) else { return }
            }
            var ptsMs = Int64((elapsed * 1000.0).rounded())
            if ptsMs <= lastPTSMillis { ptsMs = lastPTSMillis + 16 }
            if writeMP4Frame(cgImage, ptsMillis: ptsMs) {
                lastPTSMillis = ptsMs
                lastCGFrame = cgImage
                lastPixelBuffer = nil
                capturedFrameCount += 1
            }
        }
    }

    /// 结束录制并封装输出文件（成功返回目标 `outputURL`）
    public func finish(finalTimestamp: TimeInterval) async -> URL? {
        guard let baseStart = markFinishedAndSnapshotStart(fallback: finalTimestamp) else { return nil }
        switch format {
        case .gif:
            return gifSpooler.finalizeGIF(to: outputURL, totalElapsed: max(0.12, finalTimestamp - baseStart))
        case .mp4:
            return await finalizeMP4(finalTimestamp: finalTimestamp)
        }
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
        assetWriter = nil; videoInput = nil; audioInput = nil; adaptor = nil
        lastCGFrame = nil; lastPixelBuffer = nil
        gifSpooler.cleanup()
        lock.unlock()

        writer?.cancelWriting()
        try? FileManager.default.removeItem(at: outputURL)
    }

    // MARK: - Native H.264 + Optional AAC MP4 Encoding

    private func setupMP4Writer(width: Int, height: Int) -> Bool {
        let outW = max(64, width & ~1)
        let outH = max(64, height & ~1)
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else { return false }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(1_400_000, outW * outH * 4),
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
        guard writer.canAdd(input) else { return false }
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
                writer.add(ai)
                aInput = ai
            }
        }

        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        self.mp4Size = (outW, outH); self.assetWriter = writer
        self.videoInput = input; self.audioInput = aInput; self.adaptor = adp
        return true
    }

    private func writeMP4Frame(_ cgImage: CGImage, ptsMillis: Int64) -> Bool {
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
        return adaptor.append(pb, withPresentationTime: CMTime(value: ptsMillis, timescale: 1000))
    }

    private func finalizeMP4(finalTimestamp: TimeInterval) async -> URL? {
        let pack: (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInput?)? = {
            lock.lock()
            defer { lock.unlock() }
            guard let writer = assetWriter, let input = videoInput else { return nil }
            if let s = startTime {
                let endMs = max(lastPTSMillis + 33, Int64(((finalTimestamp - s) * 1000.0).rounded()))
                if let tail = lastCGFrame {
                    _ = writeMP4Frame(tail, ptsMillis: endMs)
                } else if let tailPB = lastPixelBuffer, let adaptor, input.isReadyForMoreMediaData, endMs > lastPTSMillis + 60 {
                    _ = adaptor.append(tailPB, withPresentationTime: CMTime(value: endMs, timescale: 1000))
                }
            }
            lastCGFrame = nil; lastPixelBuffer = nil
            return (writer, input, audioInput)
        }()
        guard let (writer, input, aInput) = pack else { return nil }
        input.markAsFinished()
        aInput?.markAsFinished()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        return writer.status == .completed ? outputURL : nil
    }
}
