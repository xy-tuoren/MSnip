import CoreGraphics
import Foundation

/// 高精度闭合矩形视觉探测器（零辅助功能权限依赖）：
/// 1. 采用像素级精确步距（1pt 锐边 + 2pt 柔边 + 全跨度峰值精修），确保检测边界 0px 偏移；
/// 2. 强制执行「四边闭合周长连续性校验（自适应兼容大圆角 10–22pt）」，根除单点十字射线误拼出的幽灵框；
/// 3. 按紧凑边距（5pt）与 IoU（0.86）去重归一化，保留按钮/卡片/分栏完整层级而不吞并内层控件。
public enum VisualDetector {
    /// 在给定窗口边界 `limitRect`（逻辑点，左上角原点）内探测包含 `point` 的真实闭合 UI 矩形（从小到大排序）
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
        let minW = Int((24.0 * scale).rounded())
        let minH = Int((18.0 * scale).rounded())
        guard maxX - minX >= minW, maxY - minY >= minH,
              px > minX, px < maxX, py > minY, py < maxY else { return [] }

        let sharp = max(1, Int(scale.rounded()))
        let wide = max(2, Int((2.0 * scale).rounded()))
        let gap = max(6, Int((7.0 * scale).rounded()))

        var lefts = scanVerticalCandidates(fromX: px, toX: minX, dir: -1, atY: py, minY: minY, maxY: maxY, gap: gap, sharp: sharp, wide: wide, scale: scale, sampler: sampler)
        var rights = scanVerticalCandidates(fromX: px, toX: maxX, dir: 1, atY: py, minY: minY, maxY: maxY, gap: gap, sharp: sharp, wide: wide, scale: scale, sampler: sampler)
        var tops = scanHorizontalCandidates(fromY: py, toY: minY, dir: -1, atX: px, minX: minX, maxX: maxX, gap: gap, sharp: sharp, wide: wide, scale: scale, sampler: sampler)
        var bottoms = scanHorizontalCandidates(fromY: py, toY: maxY, dir: 1, atX: px, minX: minX, maxX: maxX, gap: gap, sharp: sharp, wide: wide, scale: scale, sampler: sampler)

        if lefts.last != minX { lefts.append(minX) }
        if rights.last != maxX { rights.append(maxX) }
        if tops.last != minY { tops.append(minY) }
        if bottoms.last != maxY { bottoms.append(maxY) }

        var verified: [CGRect] = []
        for lx in lefts {
            for rx in rights where rx - lx >= minW {
                let w = rx - lx
                let validTops = tops.filter { ty in
                    (ty <= minY + 2) || checkHorizontalEdgeAdaptive(y: ty, lx: lx, rx: rx, sharp: sharp, wide: wide, scale: scale, sampler: sampler)
                }
                if validTops.isEmpty { continue }

                let validBottoms = bottoms.filter { by in
                    (by >= maxY - 2) || checkHorizontalEdgeAdaptive(y: by, lx: lx, rx: rx, sharp: sharp, wide: wide, scale: scale, sampler: sampler)
                }
                if validBottoms.isEmpty { continue }

                for ty in validTops {
                    for by in validBottoms where by - ty >= minH {
                        let h = by - ty
                        if w > h * 26 || h > w * 18 { continue }
                        if lx == minX && rx == maxX && ty == minY && by == maxY { continue }

                        guard (lx <= minX + 2) || checkVerticalEdgeAdaptive(x: lx, ty: ty, by: by, sharp: sharp, wide: wide, scale: scale, sampler: sampler),
                              (rx >= maxX - 2) || checkVerticalEdgeAdaptive(x: rx, ty: ty, by: by, sharp: sharp, wide: wide, scale: scale, sampler: sampler) else {
                            continue
                        }
                        let rect = CGRect(
                            x: CGFloat(lx) / scale,
                            y: CGFloat(ty) / scale,
                            width: CGFloat(w) / scale,
                            height: CGFloat(h) / scale
                        ).intersection(limitRect)
                        if rect.contains(point) { verified.append(rect) }
                    }
                }
            }
        }
        return normalizeHierarchy(verified)
    }

    /// 校验指定矩形在冻结像素中是否至少有 3 条真实可见边
    public static func hasVisualBoundary(
        _ rect: CGRect,
        within limitRect: CGRect,
        sampler: PixelSampler,
        scale: CGFloat
    ) -> Bool {
        guard scale > 0, rect.width >= 20, rect.height >= 18 else { return false }
        let lx = max(0, Int((rect.minX * scale).rounded()))
        let rx = min(sampler.width - 1, Int((rect.maxX * scale).rounded()))
        let ty = max(0, Int((rect.minY * scale).rounded()))
        let by = min(sampler.height - 1, Int((rect.maxY * scale).rounded()))
        guard rx - lx >= 14, by - ty >= 12 else { return false }

        let sharp = max(1, Int(scale.rounded()))
        let wide = max(2, Int((2.0 * scale).rounded()))
        let tol: CGFloat = 3.5

        var validSides = 0
        if abs(rect.minY - limitRect.minY) <= tol || checkHorizontalEdgeAdaptive(y: ty, lx: lx, rx: rx, sharp: sharp, wide: wide, scale: scale, sampler: sampler) {
            validSides += 1
        }
        if abs(rect.maxY - limitRect.maxY) <= tol || checkHorizontalEdgeAdaptive(y: by, lx: lx, rx: rx, sharp: sharp, wide: wide, scale: scale, sampler: sampler) {
            validSides += 1
        }
        if abs(rect.minX - limitRect.minX) <= tol || checkVerticalEdgeAdaptive(x: lx, ty: ty, by: by, sharp: sharp, wide: wide, scale: scale, sampler: sampler) {
            validSides += 1
        }
        if validSides < 3 && (abs(rect.maxX - limitRect.maxX) <= tol || checkVerticalEdgeAdaptive(x: rx, ty: ty, by: by, sharp: sharp, wide: wide, scale: scale, sampler: sampler)) {
            validSides += 1
        }
        return validSides >= 3
    }

    /// 将多源候选矩形从小到大排序，通过紧凑边距（5pt）与 IoU（0.86）去重合并重复包裹层
    public static func normalizeHierarchy(_ rects: [CGRect], minSize: CGFloat = 16) -> [CGRect] {
        let valid = rects.filter {
            $0.width >= minSize && $0.height >= minSize && $0.width.isFinite && $0.height.isFinite
        }
        let sorted = valid.sorted { ($0.width * $0.height) < ($1.width * $1.height) }

        var result: [CGRect] = []
        for r in sorted {
            let rounded = CGRect(
                x: r.origin.x.rounded(),
                y: r.origin.y.rounded(),
                width: r.width.rounded(),
                height: r.height.rounded()
            )
            let isRedundant = result.contains { existing in
                let closeEdges = abs(existing.minX - rounded.minX) <= 5 &&
                    abs(existing.minY - rounded.minY) <= 5 &&
                    abs(existing.maxX - rounded.maxX) <= 5 &&
                    abs(existing.maxY - rounded.maxY) <= 5
                if closeEdges { return true }
                return iou(existing, rounded) > 0.86
            }
            if !isRedundant { result.append(rounded) }
        }
        return result
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull && inter.width > 0 && inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        return unionArea > 0 ? (interArea / unionArea) : 0
    }
}
