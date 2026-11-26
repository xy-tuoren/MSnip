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

    /// 根据拖拽增量更新矩形，自动处理反向翻转并支持最小尺寸与 Shift 等比缩放约束
    public func resizedRect(
        from initial: CGRect,
        delta: CGPoint,
        minSize: CGFloat = 4,
        preserveAspect: Bool = false
    ) -> CGRect {
        if preserveAspect, initial.width >= 1, initial.height >= 1 {
            let ratio = initial.width / initial.height
            switch self {
            case .topLeft, .topRight, .bottomRight, .bottomLeft:
                let anchorX = (self == .topLeft || self == .bottomLeft) ? initial.maxX : initial.minX
                let anchorY = (self == .topLeft || self == .topRight) ? initial.maxY : initial.minY
                let dirX: CGFloat = (self == .topLeft || self == .bottomLeft) ? -1 : 1
                let dirY: CGFloat = (self == .topLeft || self == .topRight) ? -1 : 1
                let rawW = max(minSize, initial.width + delta.x * dirX)
                let rawH = max(minSize, initial.height + delta.y * dirY)
                let scale = max(rawW / initial.width, rawH / initial.height)
                let w = max(minSize, initial.width * scale)
                let h = max(minSize, w / ratio)
                let x = (dirX < 0) ? (anchorX - w) : anchorX
                let y = (dirY < 0) ? (anchorY - h) : anchorY
                return CGRect(x: x, y: y, width: w, height: h)
            default: break
            }
        }
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

// MARK: - 像素级智能卡尺测量

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

// MARK: - 高 DPI 像素安全采样器

/// 安全高性能底图像素采样器：
/// - 标准 8-bit 32bpp RGB 位图走零拷贝 `CFData` 指针直读（带严格长度边界保护）；
/// - 8-bit 灰度、24-bit 无透明通道、16-bit/浮点 HDR 或索引色位图自动一次性栅格化为紧凑 8-bit RGBA 缓冲，彻底杜绝越界崩溃与通道错位。
public final class PixelSampler: @unchecked Sendable {
    public let cgImage: CGImage
    public let samplingColorSpace: CGColorSpace
    public let width: Int
    public let height: Int
    private let bytesPerRow: Int
    private let bytesPerPixel: Int
    private let rIdx: Int
    private let gIdx: Int
    private let bIdx: Int
    private let data: CFData?
    private let ownedPtr: UnsafeMutablePointer<UInt8>?
    private let ptr: UnsafePointer<UInt8>?
    private let byteLength: Int

    deinit { ownedPtr?.deallocate() }

    public init(cgImage: CGImage) {
        self.cgImage = cgImage
        let w = cgImage.width, h = cgImage.height
        self.width = w
        self.height = h

        let info = cgImage.bitmapInfo
        let byteOrder = info.rawValue & CGBitmapInfo.byteOrderMask.rawValue
        let isFloat = info.contains(.floatComponents)
        let canDirectRead = w > 0 && h > 0
            && cgImage.bitsPerComponent == 8
            && cgImage.bitsPerPixel == 32
            && !isFloat
            && cgImage.colorSpace?.model == .rgb
            && cgImage.bytesPerRow >= w * 4

        if canDirectRead,
           let cfData = cgImage.dataProvider?.data,
           CFDataGetLength(cfData) >= (h - 1) * cgImage.bytesPerRow + w * 4 {
            let directCS = (cgImage.colorSpace?.model == .rgb && cgImage.colorSpace?.supportsOutput == true)
                ? cgImage.colorSpace! : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
            self.samplingColorSpace = directCS
            self.bytesPerRow = cgImage.bytesPerRow
            self.bytesPerPixel = 4
            let isLittle32 = (byteOrder == CGBitmapInfo.byteOrder32Little.rawValue)
            let alpha = CGImageAlphaInfo(rawValue: info.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
            let alphaFirst = (alpha == .premultipliedFirst || alpha == .first || alpha == .noneSkipFirst)
            if isLittle32 {
                if alphaFirst { self.bIdx = 0; self.gIdx = 1; self.rIdx = 2 }
                else          { self.bIdx = 1; self.gIdx = 2; self.rIdx = 3 }
            } else {
                if alphaFirst { self.rIdx = 1; self.gIdx = 2; self.bIdx = 3 }
                else          { self.rIdx = 0; self.gIdx = 1; self.bIdx = 2 }
            }
            self.data = cfData
            self.ownedPtr = nil
            self.ptr = CFDataGetBytePtr(cfData)
            self.byteLength = CFDataGetLength(cfData)
            return
        }

        // 非 32bpp 8-bit RGB（如扫描灰度图、24-bit JPEG、16-bit/HDR PNG）：安全转栅格为标准 8-bit sRGB RGBA
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        self.samplingColorSpace = cs
        self.data = nil
        self.bytesPerPixel = 4
        self.rIdx = 0; self.gIdx = 1; self.bIdx = 2
        guard w > 0, h > 0 else {
            self.bytesPerRow = 0; self.ownedPtr = nil; self.ptr = nil; self.byteLength = 0
            return
        }
        let bpr = w * 4
        let totalBytes = h * bpr
        let rawPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: totalBytes)
        rawPtr.initialize(repeating: 128, count: totalBytes)
        if let ctx = CGContext(
            data: rawPtr, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) {
            ctx.interpolationQuality = .none
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        self.bytesPerRow = bpr
        self.byteLength = totalBytes
        self.ownedPtr = rawPtr
        self.ptr = UnsafePointer(rawPtr)
    }

    /// 零分配安全读取物理像素 `(px, py)`（左上角为原点）的 RGB 分量 (0...255)
    @inline(__always)
    public func sampleRGB(px: Int, py: Int) -> (Int, Int, Int) {
        guard let ptr, width > 0, height > 0 else { return (128, 128, 128) }
        let cx = min(max(0, px), width - 1)
        let cy = min(max(0, py), height - 1)
        let offset = cy * bytesPerRow + cx * bytesPerPixel
        guard offset >= 0, offset + 3 < byteLength else { return (128, 128, 128) }
        return (Int(ptr[offset + rIdx]), Int(ptr[offset + gIdx]), Int(ptr[offset + bIdx]))
    }

    /// 按物理像素坐标 `(px, py)`（左上角为原点）读取与缓冲字节完全匹配色域的 `CGColor`
    public func sampleColor(px: Int, py: Int) -> CGColor {
        let (r, g, b) = sampleRGB(px: px, py: py)
        if let c = CGColor(colorSpace: samplingColorSpace, components: [CGFloat(r) / 255.0, CGFloat(g) / 255.0, CGFloat(b) / 255.0, 1.0]) {
            return c
        }
        return CGColor(srgbRed: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0, blue: CGFloat(b) / 255.0, alpha: 1.0)
    }
}
