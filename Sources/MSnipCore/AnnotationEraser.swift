import CoreGraphics
import Foundation

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
