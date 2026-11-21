import CoreGraphics
import Foundation

/// 像素卡尺四向自动测距结果（物理像素坐标，左上角原点）
public struct PixelCaliperResult: Equatable, Sendable {
    public let originX: Int
    public let originY: Int
    /// 左/右/上/下四个方向上距离最近色差边界的内侧终点像素坐标（含自身）
    public let leftPx: Int
    public let rightPx: Int
    public let topPx: Int
    public let bottomPx: Int
    public let hitLeft: Bool
    public let hitRight: Bool
    public let hitTop: Bool
    public let hitBottom: Bool

    /// 水平内侧净宽（像素）
    public var widthPx: Int { max(1, rightPx - leftPx + 1) }
    /// 垂直内侧净高（像素）
    public var heightPx: Int { max(1, bottomPx - topPx + 1) }

    /// 当前卡尺测得的完整物理像素矩形
    public var pixelRect: CGRect {
        CGRect(x: leftPx, y: topPx, width: widthPx, height: heightPx)
    }
}

/// 零依赖纯原生四向像素卡尺测距算法（类似 Shottr：从光标中心向四向发射射线，遇色差边界即停）
public enum PixelCaliper {
    /// 从物理像素 `(px, py)` 向左、右、上、下扫描，返回精确到 1px 的净间距测量结果
    public static func measure(
        atX px: Int,
        y py: Int,
        in sampler: PixelSampler,
        originThreshold: Int = 26,
        stepThreshold: Int = 22
    ) -> PixelCaliperResult? {
        let w = sampler.width
        let h = sampler.height
        guard w >= 2, h >= 2 else { return nil }
        let cx = min(max(0, px), w - 1)
        let cy = min(max(0, py), h - 1)
        let (r0, g0, b0) = sampler.sampleRGB(px: cx, py: cy)

        func cast(dx: Int, dy: Int) -> (endCoord: Int, hitEdge: Bool) {
            var x = cx
            var y = cy
            var prevR = r0
            var prevG = g0
            var prevB = b0

            while true {
                let nx = x + dx
                let ny = y + dy
                if nx < 0 || nx >= w || ny < 0 || ny >= h {
                    return (dx != 0 ? x : y, false)
                }
                let (r, g, b) = sampler.sampleRGB(px: nx, py: ny)
                let diffOrigin = abs(r - r0) + abs(g - g0) + abs(b - b0)
                let diffStep = abs(r - prevR) + abs(g - prevG) + abs(b - prevB)
                if diffOrigin >= originThreshold || diffStep >= stepThreshold {
                    return (dx != 0 ? x : y, true)
                }
                x = nx
                y = ny
                prevR = r
                prevG = g
                prevB = b
            }
        }

        let left = cast(dx: -1, dy: 0)
        let right = cast(dx: 1, dy: 0)
        let top = cast(dx: 0, dy: -1)
        let bottom = cast(dx: 0, dy: 1)

        return PixelCaliperResult(
            originX: cx,
            originY: cy,
            leftPx: left.endCoord,
            rightPx: right.endCoord,
            topPx: top.endCoord,
            bottomPx: bottom.endCoord,
            hitLeft: left.hitEdge,
            hitRight: right.hitEdge,
            hitTop: top.hitEdge,
            hitBottom: bottom.hitEdge
        )
    }
}
