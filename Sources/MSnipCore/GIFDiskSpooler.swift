import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

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
            if !ok { try? FileManager.default.removeItem(at: outputURL); return nil }
        }
        let finalized = CGImageDestinationFinalize(dest)
        let cancelledEnd: Bool = { lock.lock(); defer { lock.unlock() }; return isCancelled }()
        if !finalized || cancelledEnd {
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
