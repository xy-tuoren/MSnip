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
/// - MP4：基于 `AVAssetWriter` 实时流式硬件 H.264 直写磁盘；
/// - GIF：委托 `GIFDiskSpooler` 执行 LZ4 磁盘流式暂存，录制全程零 `CGImage` 数组驻留内存。
public final class MediaClipEncoder: @unchecked Sendable {
    public let format: RecordingFormat
    public let outputURL: URL
    public var spoolFileURL: URL { gifSpooler.spoolFileURL }

    private let lock = NSLock()
    private var isCancelled = false
    private var isFinished = false

    private let gifSpooler: GIFDiskSpooler
    private let maxGIFFrames = 300
    private let gifMinInterval: TimeInterval = 0.095

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var mp4Size: (w: Int, h: Int) = (0, 0)
    private var startTime: TimeInterval?
    private var lastPTSMillis: Int64 = -1
    private var lastCGFrame: CGImage?
    private(set) public var capturedFrameCount: Int = 0

    public init(format: RecordingFormat, outputURL: URL) {
        self.format = format
        self.outputURL = outputURL
        let spoolURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".msnip-gifspool-\(UUID().uuidString).bin")
        self.gifSpooler = GIFDiskSpooler(spoolFileURL: spoolURL)
        try? FileManager.default.removeItem(at: outputURL)
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
            if gifSpooler.append(cgImage, elapsed: elapsed) {
                capturedFrameCount = gifSpooler.frameCount
            }

        case .mp4:
            if assetWriter == nil {
                guard setupMP4Writer(firstFrame: cgImage) else { return }
            }
            var ptsMs = Int64((elapsed * 1000.0).rounded())
            if ptsMs <= lastPTSMillis { ptsMs = lastPTSMillis + 33 }
            if writeMP4Frame(cgImage, ptsMillis: ptsMs) {
                lastPTSMillis = ptsMs
                lastCGFrame = cgImage
                capturedFrameCount += 1
            }
        }
    }

    /// 结束录制并封装输出文件（成功返回目标 `outputURL`）
    public func finish(finalTimestamp: TimeInterval) async -> URL? {
        guard let baseStart = markFinishedAndSnapshotStart(fallback: finalTimestamp) else {
            return nil
        }
        switch format {
        case .gif:
            let totalElapsed = max(0.12, finalTimestamp - baseStart)
            return gifSpooler.finalizeGIF(to: outputURL, totalElapsed: totalElapsed)
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
        assetWriter = nil; videoInput = nil; adaptor = nil
        lastCGFrame = nil
        gifSpooler.cleanup()
        lock.unlock()

        writer?.cancelWriting()
        try? FileManager.default.removeItem(at: outputURL)
    }

    // MARK: - Native H.264 MP4 Encoding (AVAssetWriter)

    private func setupMP4Writer(firstFrame: CGImage) -> Bool {
        let outW = max(64, firstFrame.width & ~1)
        let outH = max(64, firstFrame.height & ~1)
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else { return false }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(1_200_000, outW * outH * 4),
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
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        self.mp4Size = (outW, outH); self.assetWriter = writer; self.videoInput = input; self.adaptor = adp
        return true
    }

    private func writeMP4Frame(_ cgImage: CGImage, ptsMillis: Int64) -> Bool {
        guard let input = videoInput, let adaptor, input.isReadyForMoreMediaData,
              let pool = adaptor.pixelBufferPool else { return false }
        var pbOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) == kCVReturnSuccess, let pb = pbOut else { return false }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb), width: mp4Size.w, height: mp4Size.h,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: cs, bitmapInfo: bitmapInfo
        ) else { return false }
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: mp4Size.w, height: mp4Size.h))
        return adaptor.append(pb, withPresentationTime: CMTime(value: ptsMillis, timescale: 1000))
    }

    private func finalizeMP4(finalTimestamp: TimeInterval) async -> URL? {
        let writerAndInput: (AVAssetWriter, AVAssetWriterInput)? = {
            lock.lock()
            defer { lock.unlock() }
            guard let writer = assetWriter, let input = videoInput else { return nil }
            if let tail = lastCGFrame, let s = startTime {
                let endMs = max(lastPTSMillis + 33, Int64(((finalTimestamp - s) * 1000.0).rounded()))
                _ = writeMP4Frame(tail, ptsMillis: endMs)
            }
            lastCGFrame = nil
            return (writer, input)
        }()
        guard let (writer, input) = writerAndInput else { return nil }
        input.markAsFinished()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        return writer.status == .completed ? outputURL : nil
    }
}
