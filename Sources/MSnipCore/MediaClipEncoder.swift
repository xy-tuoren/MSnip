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

/// 纯原生局部录屏编码器：支持流式硬件 H.264 `.mp4` 直写磁盘，或轻量降采样合成无限循环 `.gif`
public final class MediaClipEncoder: @unchecked Sendable {
    public let format: RecordingFormat
    public let outputURL: URL
    private let lock = NSLock()
    private var isCancelled = false
    private var isFinished = false

    // GIF 帧缓冲（自动限幅 ≤ 880px 长边，控制内存与体积）
    private var gifFrames: [(image: CGImage, time: TimeInterval)] = []
    private let maxGIFFrames = 300
    private let gifMinInterval: TimeInterval = 0.095

    // MP4 实时流式写入器状态
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
        try? FileManager.default.removeItem(at: outputURL)
    }

    /// 追加一帧实时采集画面（`timestamp` 为单调秒数，如 `CACurrentMediaTime()`）
    public func appendFrame(_ cgImage: CGImage, at timestamp: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled, !isFinished else { return }

        if startTime == nil {
            startTime = timestamp
        }
        let elapsed = max(0.0, timestamp - (startTime ?? timestamp))

        switch format {
        case .gif:
            guard gifFrames.count < maxGIFFrames else { return }
            if let prev = gifFrames.last, (elapsed - prev.time) < gifMinInterval {
                return
            }
            if let scaled = Self.downscaleForGIF(cgImage, maxLongSide: 880) {
                gifFrames.append((scaled, elapsed))
                capturedFrameCount = gifFrames.count
            }

        case .mp4:
            if assetWriter == nil {
                guard setupMP4Writer(firstFrame: cgImage) else { return }
            }
            var ptsMs = Int64((elapsed * 1000.0).rounded())
            if ptsMs <= lastPTSMillis {
                ptsMs = lastPTSMillis + 33
            }
            if writeMP4Frame(cgImage, ptsMillis: ptsMs) {
                lastPTSMillis = ptsMs
                lastCGFrame = cgImage
                capturedFrameCount += 1
            }
        }
    }

    /// 结束录制并封装输出文件（成功返回目标 `outputURL`）
    public func finish(finalTimestamp: TimeInterval) async -> URL? {
        let mode: RecordingFormat = {
            lock.lock()
            defer { lock.unlock() }
            if isCancelled || isFinished { return format }
            isFinished = true
            return format
        }()

        switch mode {
        case .gif:
            return encodeGIFToDisk(finalTimestamp: finalTimestamp)
        case .mp4:
            return await finalizeMP4(finalTimestamp: finalTimestamp)
        }
    }

    public func cancel() {
        lock.lock()
        isCancelled = true
        let writer = assetWriter
        assetWriter = nil
        videoInput = nil
        adaptor = nil
        gifFrames.removeAll()
        lastCGFrame = nil
        lock.unlock()

        writer?.cancelWriting()
        try? FileManager.default.removeItem(at: outputURL)
    }

    // MARK: - Native GIF Encoding (ImageIO)

    private func encodeGIFToDisk(finalTimestamp: TimeInterval) -> URL? {
        lock.lock()
        let frames = gifFrames
        let baseStart = startTime ?? finalTimestamp
        gifFrames.removeAll()
        lock.unlock()

        guard !frames.isEmpty else { return nil }
        guard let dest = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            UTType.gif.identifier as CFString,
            frames.count,
            nil
        ) else { return nil }

        let fileProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)

        let totalElapsed = max(0.12, finalTimestamp - baseStart)
        for i in frames.indices {
            let rawDelay: Double
            if i + 1 < frames.count {
                rawDelay = frames[i + 1].time - frames[i].time
            } else {
                rawDelay = max(0.10, totalElapsed - frames[i].time)
            }
            let clampedDelay = min(1.5, max(0.06, rawDelay))
            let frameProps: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: clampedDelay,
                    kCGImagePropertyGIFUnclampedDelayTime: clampedDelay
                ]
            ]
            CGImageDestinationAddImage(dest, frames[i].image, frameProps as CFDictionary)
        }
        return CGImageDestinationFinalize(dest) ? outputURL : nil
    }

    private static func downscaleForGIF(_ src: CGImage, maxLongSide: Int) -> CGImage? {
        let longSide = max(src.width, src.height)
        if longSide <= maxLongSide { return src }
        let ratio = Double(maxLongSide) / Double(longSide)
        let outW = max(16, Int((Double(src.width) * ratio).rounded()) & ~1)
        let outH = max(16, Int((Double(src.height) * ratio).rounded()) & ~1)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return src }
        ctx.interpolationQuality = .high
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        return ctx.makeImage() ?? src
    }

    // MARK: - Native H.264 MP4 Encoding (AVAssetWriter)

    private func setupMP4Writer(firstFrame: CGImage) -> Bool {
        let outW = max(64, firstFrame.width & ~1)
        let outH = max(64, firstFrame.height & ~1)
        guard let writer = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            return false
        }
        let bitRate = max(1_200_000, outW * outH * 4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
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

        self.mp4Size = (outW, outH)
        self.assetWriter = writer
        self.videoInput = input
        self.adaptor = adp
        return true
    }

    private func writeMP4Frame(_ cgImage: CGImage, ptsMillis: Int64) -> Bool {
        guard let input = videoInput, let adaptor, input.isReadyForMoreMediaData,
              let pool = adaptor.pixelBufferPool else { return false }
        var pbOut: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) == kCVReturnSuccess,
              let pb = pbOut else { return false }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: mp4Size.w,
            height: mp4Size.h,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: cs,
            bitmapInfo: bitmapInfo
        ) else { return false }

        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: mp4Size.w, height: mp4Size.h))
        let pts = CMTime(value: ptsMillis, timescale: 1000)
        return adaptor.append(pb, withPresentationTime: pts)
    }

    private func finalizeMP4(finalTimestamp: TimeInterval) async -> URL? {
        let writerAndInput: (AVAssetWriter, AVAssetWriterInput)? = {
            lock.lock()
            defer { lock.unlock() }
            guard let writer = assetWriter, let input = videoInput else { return nil }
            // 若画面静止期间无新帧推送，补齐一帧尾帧以保留完整录制时长
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
