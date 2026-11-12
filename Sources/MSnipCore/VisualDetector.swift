import CoreGraphics
import Foundation

/// 纯视觉 UI 边界射线检测器（零辅助功能权限依赖）：
/// 在冻结画面上从光标位置向四方投射像素射线，通过「法向色差跳变 + 切向连续性校验」
/// 自动识别按钮、输入框、卡片、代码块、内嵌图片等不同层级的闭合矩形。
public enum VisualDetector {
    /// 在给定窗口边界 `limitRect`（逻辑点，左上角原点）内探测包含 `point` 的多级视觉矩形（从小到大排序）
    public static func detectVisualRects(
        at point: CGPoint,
        within limitRect: CGRect,
        sampler: PixelSampler,
        scale: CGFloat
    ) -> [CGRect] {
        guard limitRect.contains(point), scale > 0 else { return [] }

        let px = Int((point.x * scale).rounded())
        let py = Int((point.y * scale).rounded())
        let minX = max(0, Int((limitRect.minX * scale).rounded()))
        let maxX = min(sampler.width - 1, Int((limitRect.maxX * scale).rounded()))
        let minY = max(0, Int((limitRect.minY * scale).rounded()))
        let maxY = min(sampler.height - 1, Int((limitRect.maxY * scale).rounded()))
        guard minX < maxX, minY < maxY, px >= minX, px <= maxX, py >= minY, py <= maxY else {
            return []
        }

        // 在四个方向上分别搜集最多 3 道显著连续边界（内层控件边 -> 中层卡片边 -> 外层分栏边）
        let leftEdges = scanVerticalBorders(fromX: px, toX: minX, step: -1, atY: py, minY: minY, maxY: maxY, sampler: sampler)
        let rightEdges = scanVerticalBorders(fromX: px, toX: maxX, step: 1, atY: py, minY: minY, maxY: maxY, sampler: sampler)
        let topEdges = scanHorizontalBorders(fromY: py, toY: triggeredBound(minY), step: -1, atX: px, minX: minX, maxX: maxX, sampler: sampler)
        let bottomEdges = scanHorizontalBorders(fromY: py, toY: maxY, step: 1, atX: px, minX: minX, maxX: maxX, sampler: sampler)

        var candidates: [CGRect] = []
        let tierCount = max(leftEdges.count, rightEdges.count, topEdges.count, bottomEdges.count)
        for i in 0..<tierCount {
            let lx = leftEdges.isEmpty ? minX : leftEdges[min(i, leftEdges.count - 1)]
            let rx = rightEdges.isEmpty ? maxX : rightEdges[min(i, rightEdges.count - 1)]
            let ty = topEdges.isEmpty ? minY : topEdges[min(i, topEdges.count - 1)]
            let by = bottomEdges.isEmpty ? maxY : bottomEdges[min(i, bottomEdges.count - 1)]

            let wPt = CGFloat(rx - lx) / scale
            let hPt = CGFloat(by - ty) / scale
            guard wPt >= 16, hPt >= 14 else { continue }

            let rect = CGRect(
                x: CGFloat(lx) / scale,
                y: CGFloat(ty) / scale,
                width: wPt,
                height: hPt
            ).intersection(limitRect)
            if rect.contains(point) {
                candidates.append(rect)
            }
        }
        return normalizeHierarchy(candidates)
    }

    /// 将多个来源（AX 控件树 + 视觉边缘 + 整窗 + 全屏）的候选矩形按面积从小到大排序并去重相似框
    public static func normalizeHierarchy(_ rects: [CGRect], minSize: CGFloat = 12) -> [CGRect] {
        let valid = rects.filter { $0.width >= minSize && $0.height >= minSize && $0.width.isFinite && $0.height.isFinite }
        let sorted = valid.sorted { ($0.width * $0.height) < ($1.width * $1.height) }

        var result: [CGRect] = []
        for r in sorted {
            let rounded = CGRect(
                x: r.origin.x.rounded(),
                y: r.origin.y.rounded(),
                width: r.width.rounded(),
                height: r.height.rounded()
            )
            let isDuplicate = result.contains { existing in
                abs(existing.minX - rounded.minX) < 5 &&
                abs(existing.minY - rounded.minY) < 5 &&
                abs(existing.width - rounded.width) < 5 &&
                abs(existing.height - rounded.height) < 5
            }
            if !isDuplicate {
                result.append(rounded)
            }
        }
        return result
    }

    // MARK: - Ray Casting with Transverse Continuity Check

    private static func triggeredBound(_ v: Int) -> Int { v }

    /// 沿水平方向扫描竖直分割线/边框（要求该跳变在上下切向也连续存在，从而自动过滤普通文字笔画）
    private static func scanVerticalBorders(
        fromX: Int, toX: Int, step: Int, atY: Int, minY: Int, maxY: Int, sampler: PixelSampler
    ) -> [Int] {
        var found: [Int] = []
        var x = fromX + step * 2
        var lastEdgeX = fromX

        while (step > 0 ? x < toX : x > toX) && found.count < 3 {
            if abs(x - lastEdgeX) >= 8,
               colorDelta(sampler, x - step, atY, x, atY) >= 26,
               hasVerticalContinuity(atX: x, step: step, centerY: atY, minY: minY, maxY: maxY, sampler: sampler) {
                found.append(x)
                lastEdgeX = x
                x += step * 8
                continue
            }
            x += step
        }
        return found
    }

    /// 沿垂直方向扫描水平分割线/边框
    private static func scanHorizontalBorders(
        fromY: Int, toY: Int, step: Int, atX: Int, minX: Int, maxX: Int, sampler: PixelSampler
    ) -> [Int] {
        var found: [Int] = []
        var y = fromY + step * 2
        var lastEdgeY = fromY

        while (step > 0 ? y < toY : y > toY) && found.count < 3 {
            if abs(y - lastEdgeY) >= 8,
               colorDelta(sampler, atX, y - step, atX, y) >= 26,
               hasHorizontalContinuity(atY: y, step: step, centerX: atX, minX: minX, maxX: maxX, sampler: sampler) {
                found.append(y)
                lastEdgeY = y
                y += step * 8
                continue
            }
            y += step
        }
        return found
    }

    private static func hasVerticalContinuity(
        atX x: Int, step: Int, centerY: Int, minY: Int, maxY: Int, sampler: PixelSampler
    ) -> Bool {
        let offsets = [-14, -9, -5, 5, 9, 14]
        var hits = 0
        var tested = 0
        for dy in offsets {
            let y = centerY + dy
            guard y >= minY && y <= maxY else { continue }
            tested += 1
            if colorDelta(sampler, x - step, y, x, y) >= 20 {
                hits += 1
            }
        }
        return tested >= 2 && hits * 3 >= tested * 2
    }

    private static func hasHorizontalContinuity(
        atY y: Int, step: Int, centerX: Int, minX: Int, maxX: Int, sampler: PixelSampler
    ) -> Bool {
        let offsets = [-16, -10, -5, 5, 10, 16]
        var hits = 0
        var tested = 0
        for dx in offsets {
            let x = centerX + dx
            guard x >= minX && x <= maxX else { continue }
            tested += 1
            if colorDelta(sampler, x, y - step, x, y) >= 20 {
                hits += 1
            }
        }
        return tested >= 2 && hits * 3 >= tested * 2
    }

    /// 两个物理像素之间的 RGB 曼哈顿色差（0...765）
    private static func colorDelta(_ sampler: PixelSampler, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int {
        guard let c0 = sampler.sampleColor(px: x0, py: y0).components,
              let c1 = sampler.sampleColor(px: x1, py: y1).components,
              c0.count >= 3, c1.count >= 3 else { return 0 }
        let dr = abs(Int((c0[0] * 255).rounded()) - Int((c1[0] * 255).rounded()))
        let dg = abs(Int((c0[1] * 255).rounded()) - Int((c1[1] * 255).rounded()))
        let db = abs(Int((c0[2] * 255).rounded()) - Int((c1[2] * 255).rounded()))
        return dr + dg + db
    }
}
