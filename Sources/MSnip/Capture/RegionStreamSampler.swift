import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import VideoToolbox

/// 面向长截图的局部选区实时帧采集器：
/// 基于 `SCStream` 仅抓取选区矩形，并自动在 `SCContentFilter` 中剔除 `MSnip` 自身全部窗口。
@MainActor
final class RegionStreamSampler {
    private var activeStream: AnyObject?
    private var outputProxy: AnyObject?
    private let captureQueue = DispatchQueue(label: "top.xy.msnip.longshot.capture", qos: .userInteractive)
    private var stopped = false

    func start(
        screen: NSScreen,
        localTopLeftRect: CGRect,
        fps: Int = 20,
        showsCursor: Bool = false,
        onFrameBackground: @escaping @Sendable (CGImage) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) {
        stopped = false
        guard #available(macOS 13.0, *) else {
            onError("长截图实时流需要 macOS 13.0 及以上系统")
            return
        }
        guard let displayID = Self.screenDisplayID(screen) else {
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
            guard let self, !self.stopped else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard !self.stopped else { return }
                guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
                    onError("未找到目标屏幕采集源")
                    return
                }

                let selfPID = ProcessInfo.processInfo.processIdentifier
                let ownWindows = content.windows.filter { $0.owningApplication?.processID == selfPID }
                let filter = SCContentFilter(display: scDisplay, excludingWindows: ownWindows)

                let cfg = SCStreamConfiguration()
                cfg.sourceRect = clampedRect
                cfg.width = max(24, Int((clampedRect.width * scale).rounded()) & ~1)
                cfg.height = max(32, Int((clampedRect.height * scale).rounded()) & ~1)
                cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(5, fps)))
                cfg.queueDepth = 4
                cfg.showsCursor = showsCursor
                cfg.capturesAudio = false

                let proxy = StreamOutputProxy(onFrame: onFrameBackground)
                let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
                try stream.addStreamOutput(proxy, type: .screen, sampleHandlerQueue: self.captureQueue)
                try await stream.startCapture()

                if self.stopped {
                    try? await stream.stopCapture()
                    return
                }
                self.outputProxy = proxy
                self.activeStream = stream
            } catch {
                if !self.stopped {
                    onError("启动长截图画面流失败：\(error.localizedDescription)")
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

    private static func screenDisplayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }
}

@available(macOS 13.0, *)
private final class StreamOutputProxy: NSObject, SCStreamOutput, @unchecked Sendable {
    private let onFrame: @Sendable (CGImage) -> Void

    init(onFrame: @escaping @Sendable (CGImage) -> Void) {
        self.onFrame = onFrame
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let statusRaw = attachments.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            return
        }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var cgImage: CGImage?
        let err = VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        if err == noErr, let img = cgImage {
            onFrame(img)
        }
    }
}
