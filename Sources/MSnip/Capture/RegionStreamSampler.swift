import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import VideoToolbox

/// 面向长截图与区域录屏的局部选区实时帧采集器：
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
        losslessBGRA: Bool = false,
        capturesAudio: Bool = false,
        onFrameBackground: @escaping @Sendable (CGImage) -> Void,
        onPixelBufferBackground: (@Sendable (CVPixelBuffer) -> Void)? = nil,
        onAudioSampleBackground: (@Sendable (CMSampleBuffer) -> Void)? = nil,
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
                    cfg.queueDepth = 8
                } else {
                    // 视频编码模式：保持偶数像素尺寸以满足 H.264 4:2:0 要求
                    let evenW = max(24, Int((clampedRect.width * scale).rounded()) & ~1)
                    let evenH = max(32, Int((clampedRect.height * scale).rounded()) & ~1)
                    cfg.sourceRect = CGRect(
                        x: clampedRect.minX,
                        y: clampedRect.minY,
                        width: CGFloat(evenW) / scale,
                        height: CGFloat(evenH) / scale
                    )
                    cfg.width = evenW
                    cfg.height = evenH
                    cfg.pixelFormat = kCVPixelFormatType_32BGRA
                    cfg.colorSpaceName = CGColorSpace.sRGB
                    cfg.queueDepth = 5
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
                let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
                try stream.addStreamOutput(proxy, type: .screen, sampleHandlerQueue: self.captureQueue)
                if wantAudio {
                    try? stream.addStreamOutput(proxy, type: .audio, sampleHandlerQueue: self.captureQueue)
                }
                try await stream.startCapture()

                if self.stopped {
                    try? await stream.stopCapture()
                    return
                }
                self.outputProxy = proxy
                self.activeStream = stream
            } catch {
                if !self.stopped {
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

    private static func screenDisplayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }
}

@available(macOS 13.0, *)
private final class StreamOutputProxy: NSObject, SCStreamOutput, @unchecked Sendable {
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
