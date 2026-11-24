import CoreGraphics
import Foundation

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
