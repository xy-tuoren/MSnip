import CoreGraphics
import Foundation

/// 选区录屏可调参数模型（支持持久化与跨会话生效）
public struct RecordingOptions: Equatable, Codable, Sendable {
    public var gifFPS: Int = 12
    public var gifMaxLongSide: Int = 880
    public var mp4FPS: Int = 30
    public var showsCursor: Bool = true
    public var captureSystemAudio: Bool = false

    public init(
        gifFPS: Int = 12,
        gifMaxLongSide: Int = 880,
        mp4FPS: Int = 30,
        showsCursor: Bool = true,
        captureSystemAudio: Bool = false
    ) {
        self.gifFPS = gifFPS
        self.gifMaxLongSide = gifMaxLongSide
        self.mp4FPS = mp4FPS
        self.showsCursor = showsCursor
        self.captureSystemAudio = captureSystemAudio
    }

    public var clampedGifFPS: Int { min(20, max(6, gifFPS)) }
    public var clampedGifMaxLongSide: Int { min(1600, max(480, gifMaxLongSide)) }
    public var clampedMp4FPS: Int { min(60, max(15, mp4FPS)) }
}

/// 录屏实时演示画笔笔迹（归一化选区坐标 `0..1`，支持 2.5s 自动渐隐激光模式与常驻标注模式）
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
