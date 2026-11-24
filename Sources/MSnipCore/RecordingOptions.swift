import CoreGraphics
import Foundation

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
        case .standard: return "标准"
        case .high:     return "高清"
        case .native:   return "原画"
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
        case .displayNative: return "原刷"
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
