import CoreGraphics
import Foundation

/// 12 种高频圈记、荧光高亮、步骤序号、隐私打码、聚光灯与橡皮擦工具
public enum ToolKind: Int, CaseIterable, Codable, Sendable {
    case rect = 1
    case ellipse = 2
    case arrow = 3
    case line = 4
    case pen = 5
    case highlighter = 6
    case step = 7
    case mosaic = 8
    case gaussianBlur = 9
    case text = 0
    case eraser = 10
    case spotlight = 11

    public var title: String {
        switch self {
        case .rect:         return "矩形 (1)"
        case .ellipse:      return "椭圆 (2)"
        case .arrow:        return "箭头 (3)"
        case .line:         return "直线 (4)"
        case .pen:          return "画笔 (5)"
        case .highlighter:  return "荧光笔 (6)"
        case .step:         return "步骤序号 ①②③ (7)"
        case .mosaic:       return "像素马赛克 (8)"
        case .gaussianBlur: return "毛玻璃模糊 (9)"
        case .text:         return "文字标注 (0)"
        case .eraser:       return "橡皮擦 (E)"
        case .spotlight:    return "聚光灯高亮"
        }
    }

    public var sfSymbolName: String {
        switch self {
        case .rect:         return "rectangle"
        case .ellipse:      return "circle"
        case .arrow:        return "arrow.up.right"
        case .line:         return "line.diagonal"
        case .pen:          return "scribble"
        case .highlighter:  return "highlighter"
        case .step:         return "1.circle.fill"
        case .mosaic:       return "checkerboard.rectangle"
        case .gaussianBlur: return "drop.circle"
        case .text:         return "textformat"
        case .eraser:       return "eraser"
        case .spotlight:    return "light.max"
        }
    }
}

/// 跨平台轻量 RGBA 颜色表示（0...255）
public struct RGBAColor: Equatable, Codable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public var cgColor: CGColor {
        CGColor(
            srgbRed: CGFloat(r) / 255.0,
            green: CGFloat(g) / 255.0,
            blue: CGFloat(b) / 255.0,
            alpha: CGFloat(a) / 255.0
        )
    }

    /// 6 种高对比度常用标注预设色（红、橙、黄、绿、蓝、白）
    public static let presets: [RGBAColor] = [
        RGBAColor(255, 59, 48),   // 系统红
        RGBAColor(255, 149, 0),   // 活力橙
        RGBAColor(255, 204, 0),   // 明亮黄
        RGBAColor(52, 199, 89),   // 翡翠绿
        RGBAColor(0, 122, 255),   // 科技蓝
        RGBAColor(255, 255, 255)  // 纯净白
    ]
}

/// 标注样式（颜色、线宽、字号、马赛克/毛玻璃强度、胶囊底色文字开关）
public struct AnnotationStyle: Equatable, Codable, Sendable {
    public var color: RGBAColor
    public var lineWidth: CGFloat
    public var fontSize: CGFloat
    public var mosaicBlockSize: CGFloat
    public var textCapsule: Bool

    public init(
        color: RGBAColor = RGBAColor.presets[0],
        lineWidth: CGFloat = 3.0,
        fontSize: CGFloat = 18.0,
        mosaicBlockSize: CGFloat = 10.0,
        textCapsule: Bool = false
    ) {
        self.color = color
        self.lineWidth = lineWidth
        self.fontSize = fontSize
        self.mosaicBlockSize = mosaicBlockSize
        self.textCapsule = textCapsule
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        color = try c.decode(RGBAColor.self, forKey: .color)
        lineWidth = try c.decode(CGFloat.self, forKey: .lineWidth)
        fontSize = try c.decode(CGFloat.self, forKey: .fontSize)
        mosaicBlockSize = try c.decode(CGFloat.self, forKey: .mosaicBlockSize)
        textCapsule = try c.decodeIfPresent(Bool.self, forKey: .textCapsule) ?? false
    }

    public var highlighterWidth: CGFloat { max(14.0, lineWidth * 4.2) }
    public var stepBadgeRadius: CGFloat { max(12.0, 9.0 + lineWidth * 1.4) }
    public var eraserRadius: CGFloat { max(6.0, 4.0 + lineWidth * 1.8) }

    public static let strokePresets: [CGFloat] = [2.0, 4.0, 7.0]
}

/// 标注几何载荷
public enum AnnotationPayload: Equatable, Sendable {
    case rect(CGRect)
    case ellipse(CGRect)
    case arrow(from: CGPoint, to: CGPoint)
    case line(from: CGPoint, to: CGPoint)
    case pen(points: [CGPoint])
    case highlighter(points: [CGPoint])
    case step(center: CGPoint, tail: CGPoint?, number: Int)
    case mosaic(CGRect)
    case gaussianBlur(CGRect)
    case spotlight(CGRect)
    case text(origin: CGPoint, content: String, measuredSize: CGSize)
}

/// 单个圈记/标注对象（纯值类型，自动享受 Swift Copy-on-Write）
public struct Annotation: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var payload: AnnotationPayload
    public var style: AnnotationStyle

    public init(id: UUID = UUID(), payload: AnnotationPayload, style: AnnotationStyle) {
        self.id = id
        self.payload = payload
        self.style = style
    }

    /// 包含线宽或箭头余量的外接包围盒（供选中框与脏区刷新使用）
    public var bounds: CGRect {
        let pad = style.lineWidth * 0.5 + 2.0
        switch payload {
        case .rect(let r), .ellipse(let r):
            return r.insetBy(dx: -pad, dy: -pad)
        case .mosaic(let r), .gaussianBlur(let r), .spotlight(let r):
            return r
        case .line(let a, let b):
            return Geometry.normalizedRect(from: a, to: b).insetBy(dx: -pad, dy: -pad)
        case .arrow(let a, let b):
            let extra = max(pad, max(12.0, style.lineWidth * 4.2) * 0.5)
            return Geometry.normalizedRect(from: a, to: b).insetBy(dx: -extra, dy: -extra)
        case .pen(let pts):
            return Self.polylineBounds(pts, pad: pad)
        case .highlighter(let pts):
            return Self.polylineBounds(pts, pad: style.highlighterWidth * 0.5 + 2.0)
        case .step(let center, let tail, _):
            let r = style.stepBadgeRadius + 4.0
            var box = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            if let tail {
                let tailBox = CGRect(x: tail.x - 10, y: tail.y - 10, width: 20, height: 20)
                box = box.union(tailBox)
            }
            return box
        case .text(let origin, _, let size):
            return CGRect(origin: origin, size: CGSize(width: max(20, size.width), height: max(20, size.height)))
                .insetBy(dx: -4, dy: -2)
        }
    }

    private static func polylineBounds(_ pts: [CGPoint], pad: CGFloat) -> CGRect {
        guard let first = pts.first else { return .zero }
        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .insetBy(dx: -pad, dy: -pad)
    }

    /// 判断是否过小（防单击误触产生看不见的幽灵图形；步骤序号支持单击即落点故永不退化）
    public var isTrivial: Bool {
        switch payload {
        case .rect(let r), .ellipse(let r), .mosaic(let r), .gaussianBlur(let r), .spotlight(let r):
            return r.width < 3 || r.height < 3
        case .arrow(let a, let b), .line(let a, let b):
            return hypot(b.x - a.x, b.y - a.y) < 4
        case .pen(let pts), .highlighter(let pts):
            return pts.count < 2
        case .step:
            return false
        case .text(_, let s, _):
            return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 命中检测（`tolerance` 为点击容差）
    public func hitTest(_ p: CGPoint, tolerance: CGFloat = 6.0) -> Bool {
        let halfW = style.lineWidth * 0.5 + tolerance
        switch payload {
        case .rect(let r):
            let outer = r.insetBy(dx: -halfW, dy: -halfW)
            let inner = r.insetBy(dx: halfW, dy: halfW)
            if inner.width <= 0 || inner.height <= 0 {
                return outer.contains(p)
            }
            return outer.contains(p) && !inner.contains(p)
        case .ellipse(let r):
            return Geometry.hitEllipse(point: p, in: r, filled: false, tolerance: halfW)
        case .mosaic(let r), .gaussianBlur(let r), .spotlight(let r):
            return r.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        case .line(let a, let b), .arrow(let a, let b):
            return Geometry.distanceToSegment(point: p, a: a, b: b) <= halfW
        case .pen(let pts):
            return Geometry.distanceToPolyline(point: p, points: pts) <= halfW
        case .highlighter(let pts):
            return Geometry.distanceToPolyline(point: p, points: pts) <= style.highlighterWidth * 0.5 + tolerance
        case .step(let center, let tail, _):
            if hypot(p.x - center.x, p.y - center.y) <= style.stepBadgeRadius + tolerance {
                return true
            }
            if let tail, Geometry.distanceToSegment(point: p, a: center, b: tail) <= halfW {
                return true
            }
            return false
        case .text:
            return bounds.contains(p)
        }
    }

    /// 整体平移标注对象
    public mutating func translate(dx: CGFloat, dy: CGFloat) {
        switch payload {
        case .rect(let r):
            payload = .rect(r.offsetBy(dx: dx, dy: dy))
        case .ellipse(let r):
            payload = .ellipse(r.offsetBy(dx: dx, dy: dy))
        case .mosaic(let r):
            payload = .mosaic(r.offsetBy(dx: dx, dy: dy))
        case .gaussianBlur(let r):
            payload = .gaussianBlur(r.offsetBy(dx: dx, dy: dy))
        case .spotlight(let r):
            payload = .spotlight(r.offsetBy(dx: dx, dy: dy))
        case .arrow(let a, let b):
            payload = .arrow(from: CGPoint(x: a.x + dx, y: a.y + dy), to: CGPoint(x: b.x + dx, y: b.y + dy))
        case .line(let a, let b):
            payload = .line(from: CGPoint(x: a.x + dx, y: a.y + dy), to: CGPoint(x: b.x + dx, y: b.y + dy))
        case .pen(let pts):
            payload = .pen(points: pts.map { CGPoint(x: $0.x + dx, y: $0.y + dy) })
        case .highlighter(let pts):
            payload = .highlighter(points: pts.map { CGPoint(x: $0.x + dx, y: $0.y + dy) })
        case .step(let center, let tail, let num):
            let newCenter = CGPoint(x: center.x + dx, y: center.y + dy)
            let newTail = tail.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            payload = .step(center: newCenter, tail: newTail, number: num)
        case .text(let o, let s, let sz):
            payload = .text(origin: CGPoint(x: o.x + dx, y: o.y + dy), content: s, measuredSize: sz)
        }
    }
}

// MARK: - 标注八向控制柄与命中测试

/// 选中标注对象的可拖拽控制柄类型
public enum AnnotationHandle: Equatable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight
    case startPoint, endPoint
    case stepTail
}

/// 控制柄类型与其在画布坐标系中的锚点位置
public struct AnnotationHandlePoint: Equatable, Sendable {
    public let handle: AnnotationHandle
    public let point: CGPoint

    public init(handle: AnnotationHandle, point: CGPoint) {
        self.handle = handle
        self.point = point
    }
}

public extension Annotation {
    /// 返回当前标注支持的二次编辑控制柄列表（供画布绘制与鼠标命中）
    func editableHandles() -> [AnnotationHandlePoint] {
        switch payload {
        case .rect(let r), .ellipse(let r), .mosaic(let r), .gaussianBlur(let r), .spotlight(let r):
            return [
                AnnotationHandlePoint(handle: .topLeft, point: CGPoint(x: r.minX, y: r.minY)),
                AnnotationHandlePoint(handle: .topRight, point: CGPoint(x: r.maxX, y: r.minY)),
                AnnotationHandlePoint(handle: .bottomLeft, point: CGPoint(x: r.minX, y: r.maxY)),
                AnnotationHandlePoint(handle: .bottomRight, point: CGPoint(x: r.maxX, y: r.maxY))
            ]
        case .arrow(let a, let b), .line(let a, let b):
            return [
                AnnotationHandlePoint(handle: .startPoint, point: a),
                AnnotationHandlePoint(handle: .endPoint, point: b)
            ]
        case .step(_, let tail, _):
            if let tail {
                return [AnnotationHandlePoint(handle: .stepTail, point: tail)]
            }
            return []
        case .pen, .highlighter, .text:
            return []
        }
    }

    /// 检测鼠标点是否命中某个二次编辑控制柄
    func hitEditableHandle(at point: CGPoint, radius: CGFloat = 9.0) -> AnnotationHandle? {
        for item in editableHandles() {
            if hypot(point.x - item.point.x, point.y - item.point.y) <= radius {
                return item.handle
            }
        }
        return nil
    }

    /// 根据控制柄拖拽目标点计算新的标注载荷（纯函数，支持 `⇧` 等比/15° 角度约束）
    static func resizedPayload(
        from initial: AnnotationPayload,
        handle: AnnotationHandle,
        to target: CGPoint,
        shift: Bool = false,
        minBoxSize: CGFloat = 6.0
    ) -> AnnotationPayload {
        switch initial {
        case .rect(let r):
            return .rect(resizeBox(r, handle: handle, to: target, shift: shift, minSize: minBoxSize))
        case .ellipse(let r):
            return .ellipse(resizeBox(r, handle: handle, to: target, shift: shift, minSize: minBoxSize))
        case .mosaic(let r):
            return .mosaic(resizeBox(r, handle: handle, to: target, shift: shift, minSize: minBoxSize))
        case .gaussianBlur(let r):
            return .gaussianBlur(resizeBox(r, handle: handle, to: target, shift: shift, minSize: minBoxSize))
        case .spotlight(let r):
            return .spotlight(resizeBox(r, handle: handle, to: target, shift: shift, minSize: minBoxSize))
        case .arrow(let a, let b):
            if handle == .startPoint {
                let p = shift ? Geometry.angleSnappedEnd(from: b, to: target) : target
                return .arrow(from: p, to: b)
            } else {
                let p = shift ? Geometry.angleSnappedEnd(from: a, to: target) : target
                return .arrow(from: a, to: p)
            }
        case .line(let a, let b):
            if handle == .startPoint {
                let p = shift ? Geometry.angleSnappedEnd(from: b, to: target) : target
                return .line(from: p, to: b)
            } else {
                let p = shift ? Geometry.angleSnappedEnd(from: a, to: target) : target
                return .line(from: a, to: p)
            }
        case .step(let center, let tail, let num):
            guard handle == .stepTail, tail != nil else { return initial }
            let p = shift ? Geometry.angleSnappedEnd(from: center, to: target) : target
            return .step(center: center, tail: p, number: num)
        case .pen, .highlighter, .text:
            return initial
        }
    }

    private static func resizeBox(
        _ rect: CGRect,
        handle: AnnotationHandle,
        to target: CGPoint,
        shift: Bool,
        minSize: CGFloat
    ) -> CGRect {
        let anchor: CGPoint
        switch handle {
        case .topLeft:     anchor = CGPoint(x: rect.maxX, y: rect.maxY)
        case .topRight:    anchor = CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomLeft:  anchor = CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomRight: anchor = CGPoint(x: rect.minX, y: rect.minY)
        default:           return rect
        }
        let end = shift ? Geometry.squareConstrainedEnd(from: anchor, to: target) : target
        var out = Geometry.normalizedRect(from: anchor, to: end)
        if out.width < minSize {
            out.size.width = minSize
            if target.x < anchor.x { out.origin.x = anchor.x - minSize }
        }
        if out.height < minSize {
            out.size.height = minSize
            if target.y < anchor.y { out.origin.y = anchor.y - minSize }
        }
        return out
    }
}

// MARK: - 标注分段橡皮擦几何裁剪

/// 标注橡皮擦核心几何引擎：
/// - 针对自由画笔与荧光笔（`.pen` / `.highlighter`）：精确按橡皮擦半径分段擦断，支持只擦除局部笔迹；
/// - 针对结构化图形（矩形/椭圆/箭头/直线/序号/打码/文字）：触碰即整件擦除；
/// - 需配合 `beginTransaction()` / `commitTransaction(changed:)` 实现「一次拖拽涂抹 = 一步 ⌘Z 撤销」。
public extension AnnotationDocument {
    /// 沿橡皮擦拖拽线段 `from -> to`（含单击 `from == to`）执行擦除，返回是否有标注被修改或移除
    @discardableResult
    mutating func eraseAlongSegment(from a: CGPoint, to b: CGPoint, radius: CGFloat) -> Bool {
        guard !objects.isEmpty else { return false }
        let r = max(4.0, radius)
        let probeStep = max(3.0, r * 0.5)
        let segLen = hypot(b.x - a.x, b.y - a.y)
        let steps = max(1, Int(ceil(segLen / probeStep)))
        var probes: [CGPoint] = []
        probes.reserveCapacity(steps + 1)
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            probes.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }

        let beforeCount = objects.count
        var changed = false
        var rebuilt: [Annotation] = []
        rebuilt.reserveCapacity(objects.count)

        for obj in objects {
            switch obj.payload {
            case .pen(let pts):
                let hitR = r + obj.style.lineWidth * 0.5
                let chunks = Self.splitPolyline(pts, erasingFrom: a, to: b, radius: hitR)
                if chunks.count == 1 && chunks[0] == pts {
                    rebuilt.append(obj)
                } else {
                    changed = true
                    for (idx, chunk) in chunks.enumerated() where chunk.count >= 2 {
                        let id = (idx == 0) ? obj.id : UUID()
                        rebuilt.append(Annotation(id: id, payload: .pen(points: chunk), style: obj.style))
                    }
                }

            case .highlighter(let pts):
                let hitR = r + obj.style.highlighterWidth * 0.5
                let chunks = Self.splitPolyline(pts, erasingFrom: a, to: b, radius: hitR)
                if chunks.count == 1 && chunks[0] == pts {
                    rebuilt.append(obj)
                } else {
                    changed = true
                    for (idx, chunk) in chunks.enumerated() where chunk.count >= 2 {
                        let id = (idx == 0) ? obj.id : UUID()
                        rebuilt.append(Annotation(id: id, payload: .highlighter(points: chunk), style: obj.style))
                    }
                }

            default:
                let quickBox = obj.bounds.insetBy(dx: -(r + 2), dy: -(r + 2))
                let segBox = Geometry.normalizedRect(from: a, to: b)
                if quickBox.intersects(segBox), probes.contains(where: { obj.hitTest($0, tolerance: r) }) {
                    changed = true
                } else {
                    rebuilt.append(obj)
                }
            }
        }

        if changed || rebuilt.count != beforeCount {
            replaceObjectsWithoutHistory(rebuilt)
            return true
        }
        return false
    }

    private static func splitPolyline(
        _ pts: [CGPoint],
        erasingFrom a: CGPoint,
        to b: CGPoint,
        radius: CGFloat
    ) -> [[CGPoint]] {
        guard pts.count >= 2 else { return [] }
        // 先快速包围盒剔除，避免未触碰笔迹产生任何细分开销
        var minX = pts[0].x, maxX = pts[0].x, minY = pts[0].y, maxY = pts[0].y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let strokeBox = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -radius, dy: -radius)
        if !strokeBox.intersects(Geometry.normalizedRect(from: a, to: b)) {
            return [pts]
        }

        // 将过长直线段密化到 <= 4pt，确保快速画出的折线中间也能精准擦断
        var dense: [CGPoint] = [pts[0]]
        var anyErased = false
        for i in 0..<(pts.count - 1) {
            let p0 = pts[i], p1 = pts[i + 1]
            let d = hypot(p1.x - p0.x, p1.y - p0.y)
            let sub = max(1, Int(ceil(d / 4.0)))
            for s in 1...sub {
                let t = CGFloat(s) / CGFloat(sub)
                dense.append(CGPoint(x: p0.x + (p1.x - p0.x) * t, y: p0.y + (p1.y - p0.y) * t))
            }
        }

        var chunks: [[CGPoint]] = []
        var current: [CGPoint] = []
        for pt in dense {
            if Geometry.distanceToSegment(point: pt, a: a, b: b) <= radius {
                anyErased = true
                if current.count >= 2 { chunks.append(current) }
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(pt)
            }
        }
        if current.count >= 2 { chunks.append(current) }
        return anyErased ? chunks : [pts]
    }
}
