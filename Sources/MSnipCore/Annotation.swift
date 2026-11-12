import CoreGraphics
import Foundation

/// 7 种高频圈记与标注工具
public enum ToolKind: Int, CaseIterable, Codable, Sendable {
    case rect = 1
    case ellipse = 2
    case arrow = 3
    case line = 4
    case pen = 5
    case mosaic = 6
    case text = 7

    public var title: String {
        switch self {
        case .rect:    return "矩形 (1)"
        case .ellipse: return "椭圆 (2)"
        case .arrow:   return "箭头 (3)"
        case .line:    return "直线 (4)"
        case .pen:     return "画笔 (5)"
        case .mosaic:  return "打码 (6)"
        case .text:    return "文字 (7)"
        }
    }

    public var sfSymbolName: String {
        switch self {
        case .rect:    return "rectangle"
        case .ellipse: return "circle"
        case .arrow:   return "arrow.up.right"
        case .line:    return "line.diagonal"
        case .pen:     return "scribble"
        case .mosaic:  return "checkerboard.rectangle"
        case .text:    return "textformat"
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

/// 标注样式（颜色、线宽、字号、马赛克块尺寸）
public struct AnnotationStyle: Equatable, Codable, Sendable {
    public var color: RGBAColor
    public var lineWidth: CGFloat
    public var fontSize: CGFloat
    public var mosaicBlockSize: CGFloat

    public init(
        color: RGBAColor = RGBAColor.presets[0],
        lineWidth: CGFloat = 3.0,
        fontSize: CGFloat = 18.0,
        mosaicBlockSize: CGFloat = 10.0
    ) {
        self.color = color
        self.lineWidth = lineWidth
        self.fontSize = fontSize
        self.mosaicBlockSize = mosaicBlockSize
    }

    public static let strokePresets: [CGFloat] = [2.0, 4.0, 7.0]
}

/// 标注几何载荷
public enum AnnotationPayload: Equatable, Sendable {
    case rect(CGRect)
    case ellipse(CGRect)
    case arrow(from: CGPoint, to: CGPoint)
    case line(from: CGPoint, to: CGPoint)
    case pen(points: [CGPoint])
    case mosaic(CGRect)
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
        case .mosaic(let r):
            return r
        case .line(let a, let b):
            return Geometry.normalizedRect(from: a, to: b).insetBy(dx: -pad, dy: -pad)
        case .arrow(let a, let b):
            let extra = max(pad, max(12.0, style.lineWidth * 4.2) * 0.5)
            return Geometry.normalizedRect(from: a, to: b).insetBy(dx: -extra, dy: -extra)
        case .pen(let pts):
            guard let first = pts.first else { return .zero }
            var minX = first.x, maxX = first.x
            var minY = first.y, maxY = first.y
            for p in pts {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                .insetBy(dx: -pad, dy: -pad)
        case .text(let origin, _, let size):
            return CGRect(origin: origin, size: CGSize(width: max(20, size.width), height: max(20, size.height)))
                .insetBy(dx: -4, dy: -2)
        }
    }

    /// 判断是否过小（防单击误触产生看不见的幽灵图形）
    public var isTrivial: Bool {
        switch payload {
        case .rect(let r), .ellipse(let r), .mosaic(let r):
            return r.width < 3 || r.height < 3
        case .arrow(let a, let b), .line(let a, let b):
            return hypot(b.x - a.x, b.y - a.y) < 4
        case .pen(let pts):
            return pts.count < 2
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
        case .mosaic(let r):
            return r.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        case .line(let a, let b), .arrow(let a, let b):
            return Geometry.distanceToSegment(point: p, a: a, b: b) <= halfW
        case .pen(let pts):
            return Geometry.distanceToPolyline(point: p, points: pts) <= halfW
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
        case .arrow(let a, let b):
            payload = .arrow(from: CGPoint(x: a.x + dx, y: a.y + dy), to: CGPoint(x: b.x + dx, y: b.y + dy))
        case .line(let a, let b):
            payload = .line(from: CGPoint(x: a.x + dx, y: a.y + dy), to: CGPoint(x: b.x + dx, y: b.y + dy))
        case .pen(let pts):
            payload = .pen(points: pts.map { CGPoint(x: $0.x + dx, y: $0.y + dy) })
        case .text(let o, let s, let sz):
            payload = .text(origin: CGPoint(x: o.x + dx, y: o.y + dy), content: s, measuredSize: sz)
        }
    }
}
