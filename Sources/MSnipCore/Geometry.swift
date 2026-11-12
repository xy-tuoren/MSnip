import CoreGraphics
import Foundation

/// 八向缩放控制柄（用于选区与矩形/椭圆类标注对象）
public enum ResizeHandle: CaseIterable, Sendable {
    case topLeft, top, topRight
    case right, bottomRight, bottom
    case bottomLeft, left

    /// 计算包围盒上对应控制柄的中心坐标（左上角为原点的坐标系）
    public func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft:     return CGPoint(x: rect.minX, y: rect.minY)
        case .top:         return CGPoint(x: rect.midX, y: rect.minY)
        case .topRight:    return CGPoint(x: rect.maxX, y: rect.minY)
        case .right:       return CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: return CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom:      return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft:  return CGPoint(x: rect.minX, y: rect.maxY)
        case .left:        return CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    /// 根据拖拽增量更新矩形，自动处理反向翻转并支持最小尺寸约束
    public func resizedRect(from initial: CGRect, delta: CGPoint, minSize: CGFloat = 4) -> CGRect {
        var left = initial.minX
        var right = initial.maxX
        var top = initial.minY
        var bottom = initial.maxY

        switch self {
        case .topLeft:
            left += delta.x; top += delta.y
        case .top:
            top += delta.y
        case .topRight:
            right += delta.x; top += delta.y
        case .right:
            right += delta.x
        case .bottomRight:
            right += delta.x; bottom += delta.y
        case .bottom:
            bottom += delta.y
        case .bottomLeft:
            left += delta.x; bottom += delta.y
        case .left:
            left += delta.x
        }

        let x0 = min(left, right)
        let x1 = max(left, right)
        let y0 = min(top, bottom)
        let y1 = max(top, bottom)
        return CGRect(
            x: x0,
            y: y0,
            width: max(minSize, x1 - x0),
            height: max(minSize, y1 - y0)
        )
    }
}

/// 纯几何工具函数集（无平台窗口依赖）
public enum Geometry {
    /// 由任意对角两点构造标准化非负宽高矩形
    public static func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(b.x - a.x),
            height: abs(b.y - a.y)
        )
    }

    /// Shift 键等比正方形/正圆终点约束（以 `start` 为锚点）
    public static func squareConstrainedEnd(from start: CGPoint, to current: CGPoint) -> CGPoint {
        let dx = current.x - start.x
        let dy = current.y - start.y
        let side = max(abs(dx), abs(dy))
        let sx: CGFloat = dx >= 0 ? 1 : -1
        let sy: CGFloat = dy >= 0 ? 1 : -1
        return CGPoint(x: start.x + sx * side, y: start.y + sy * side)
    }

    /// Shift 键 45° 倍数方向吸附（用于直线与箭头）
    public static func angleSnappedEnd(from start: CGPoint, to current: CGPoint) -> CGPoint {
        let dx = current.x - start.x
        let dy = current.y - start.y
        let len = hypot(dx, dy)
        guard len > 0.001 else { return current }
        let angle = atan2(dy, dx)
        let step = CGFloat.pi / 4.0
        let snapped = round(angle / step) * step
        return CGPoint(
            x: start.x + cos(snapped) * len,
            y: start.y + sin(snapped) * len
        )
    }

    /// 将矩形钳制在边界矩形内部（尽量保持宽高不变）
    public static func clampRect(_ rect: CGRect, within bounds: CGRect) -> CGRect {
        var r = rect
        r.size.width = min(r.width, bounds.width)
        r.size.height = min(r.height, bounds.height)
        r.origin.x = min(max(r.origin.x, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.origin.y, bounds.minY), bounds.maxY - r.height)
        return r
    }

    /// 命中检测：判断点 `p` 是否落在给定矩形的八向控制柄上
    public static func hitHandle(at p: CGPoint, in rect: CGRect, tolerance: CGFloat = 7) -> ResizeHandle? {
        for handle in ResizeHandle.allCases {
            let c = handle.point(in: rect)
            if hypot(p.x - c.x, p.y - c.y) <= tolerance {
                return handle
            }
        }
        return nil
    }

    /// 点 `p` 到线段 `a -> b` 的最短欧氏距离
    public static func distanceToSegment(point p: CGPoint, a: CGPoint, b: CGPoint) -> CGFloat {
        let vx = b.x - a.x
        let vy = b.y - a.y
        let lenSq = vx * vx + vy * vy
        guard lenSq > 1e-6 else {
            return hypot(p.x - a.x, p.y - a.y)
        }
        let t = max(0, min(1, ((p.x - a.x) * vx + (p.y - a.y) * vy) / lenSq))
        let projX = a.x + t * vx
        let projY = a.y + t * vy
        return hypot(p.x - projX, p.y - projY)
    }

    /// 点到折线点列的最短距离
    public static func distanceToPolyline(point p: CGPoint, points: [CGPoint]) -> CGFloat {
        guard let first = points.first else { return .infinity }
        if points.count == 1 {
            return hypot(p.x - first.x, p.y - first.y)
        }
        var best = CGFloat.infinity
        for i in 0..<(points.count - 1) {
            best = min(best, distanceToSegment(point: p, a: points[i], b: points[i + 1]))
        }
        return best
    }

    /// 椭圆轮廓或内部命中检测
    public static func hitEllipse(point p: CGPoint, in rect: CGRect, filled: Bool, tolerance: CGFloat) -> Bool {
        let rx = rect.width * 0.5
        let ry = rect.height * 0.5
        guard rx > 1, ry > 1 else { return false }
        let dx = p.x - rect.midX
        let dy = p.y - rect.midY
        if filled {
            let norm = (dx * dx) / ((rx + tolerance) * (rx + tolerance))
                + (dy * dy) / ((ry + tolerance) * (ry + tolerance))
            return norm <= 1.0
        }
        let outerRx = rx + tolerance
        let outerRy = ry + tolerance
        let innerRx = max(0.1, rx - tolerance)
        let innerRy = max(0.1, ry - tolerance)
        let outerVal = (dx * dx) / (outerRx * outerRx) + (dy * dy) / (outerRy * outerRy)
        let innerVal = (dx * dx) / (innerRx * innerRx) + (dy * dy) / (innerRy * innerRy)
        return outerVal <= 1.0 && innerVal >= 1.0
    }

    /// 计算箭头头部三角形顶点与缩短后的箭杆终点（防止粗线穿出箭尖）
    public static func arrowGeometry(
        from: CGPoint,
        to: CGPoint,
        lineWidth: CGFloat
    ) -> (shaftEnd: CGPoint, headPoints: [CGPoint])? {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let totalLen = hypot(dx, dy)
        guard totalLen >= 1.0 else { return nil }

        let ux = dx / totalLen
        let uy = dy / totalLen
        let headLen = min(totalLen, max(12.0, lineWidth * 4.2))
        let halfWing = headLen * 0.46

        let base = CGPoint(x: to.x - ux * headLen, y: to.y - uy * headLen)
        let px = -uy
        let py = ux
        let leftWing = CGPoint(x: base.x + px * halfWing, y: base.y + py * halfWing)
        let rightWing = CGPoint(x: base.x - px * halfWing, y: base.y - py * halfWing)
        // 箭杆深入箭头底边内部 1.5pt 消除接缝，且绝不穿透箭尖
        let shaftDepth = min(headLen * 0.5, max(1.0, lineWidth * 0.4))
        let shaftEnd = CGPoint(x: base.x + ux * shaftDepth, y: base.y + uy * shaftDepth)
        return (shaftEnd, [to, leftWing, rightWing])
    }
}
