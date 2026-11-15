import CoreGraphics
import Foundation

/// 高精度闭合矩形视觉探测器（零辅助功能权限依赖）：
/// 1. 采用跨像素步长检测，同时兼容实心色块卡片与 1pt 细线描边容器；
/// 2. 强制执行「四边闭合周长连续性校验（自动避开圆角）」，彻底根除单点十字射线误拼出的幽灵框；
/// 3. 通过 IoU 重叠度合并冗余包裹层，输出干净、稳定的多级矩阵栈。
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
        let minW = Int((32.0 * scale).rounded())
        let minH = Int((22.0 * scale).rounded())
        guard maxX - minX >= minW, maxY - minY >= minH,
              px > minX, px < maxX, py > minY, py < maxY else { return [] }

        let spanStep = max(2, Int((1.5 * scale).rounded()))
        let minEdgeGap = max(8, Int((10.0 * scale).rounded()))

        // 搜集四向候选边界（最多各取 4 道显著连续边 + 窗口外框兜底）
        var lefts = scanVerticalCandidates(fromX: px, toX: minX, dir: -1, atY: py, minY: minY, maxY: maxY, gap: minEdgeGap, span: spanStep, sampler: sampler)
        var rights = scanVerticalCandidates(fromX: px, toX: maxX, dir: 1, atY: py, minY: minY, maxY: maxY, gap: minEdgeGap, span: spanStep, sampler: sampler)
        var tops = scanHorizontalCandidates(fromY: py, toY: minY, dir: -1, atX: px, minX: minX, maxX: maxX, gap: minEdgeGap, span: spanStep, sampler: sampler)
        var bottoms = scanHorizontalCandidates(fromY: py, toY: maxY, dir: 1, atX: px, minX: minX, maxX: maxX, gap: minEdgeGap, span: spanStep, sampler: sampler)

        if lefts.last != minX { lefts.append(minX) }
        if rights.last != maxX { rights.append(maxX) }
        if tops.last != minY { tops.append(minY) }
        if bottoms.last != maxY { bottoms.append(maxY) }

        // 对四边组合执行「周长闭合度验证」：外提顶/底水平边预筛，仅对有效边组合检查左右竖边（零冗余采样）
        var verified: [CGRect] = []
        let cornerCap = Int((10.0 * scale).rounded())
        for lx in lefts {
            for rx in rights where rx - lx >= minW {
                let w = rx - lx
                let cornerX = min(cornerCap, w / 6)

                let validTops = tops.filter { ty in
                    (ty <= minY + 2) || checkHorizontalEdgeSpan(y: ty, x0: lx + cornerX, x1: rx - cornerX, span: spanStep, sampler: sampler)
                }
                if validTops.isEmpty { continue }

                let validBottoms = bottoms.filter { by in
                    (by >= maxY - 2) || checkHorizontalEdgeSpan(y: by, x0: lx + cornerX, x1: rx - cornerX, span: spanStep, sampler: sampler)
                }
                if validBottoms.isEmpty { continue }

                for ty in validTops {
                    for by in validBottoms where by - ty >= minH {
                        let h = by - ty
                        if w > h * 26 || h > w * 18 { continue }
                        if lx == minX && rx == maxX && ty == minY && by == maxY { continue }

                        let cornerY = min(cornerCap, h / 6)
                        guard (lx <= minX + 2) || checkVerticalEdgeSpan(x: lx, y0: ty + cornerY, y1: by - cornerY, span: spanStep, sampler: sampler),
                              (rx >= maxX - 2) || checkVerticalEdgeSpan(x: rx, y0: ty + cornerY, y1: by - cornerY, span: spanStep, sampler: sampler) else {
                            continue
                        }
                        let rect = CGRect(
                            x: CGFloat(lx) / scale,
                            y: CGFloat(ty) / scale,
                            width: CGFloat(w) / scale,
                            height: CGFloat(h) / scale
                        ).intersection(limitRect)
                        if rect.contains(point) {
                            verified.append(rect)
                        }
                    }
                }
            }
        }
        return normalizeHierarchy(verified)
    }

    /// 将多源候选矩形（AX + 视觉闭合框 + 整窗 + 全屏）从小到大排序，并通过边距与 IoU 合并相似包裹层
    public static func normalizeHierarchy(_ rects: [CGRect], minSize: CGFloat = 20) -> [CGRect] {
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
                let closeEdges = abs(existing.minX - rounded.minX) < 10 &&
                    abs(existing.minY - rounded.minY) < 10 &&
                    abs(existing.maxX - rounded.maxX) < 10 &&
                    abs(existing.maxY - rounded.maxY) < 10
                if closeEdges { return true }
                return iou(existing, rounded) > 0.80
            }
            if !isRedundant {
                result.append(rounded)
            }
        }
        return result
    }

    // MARK: - Candidate Edge Ray Scan

    private static func scanVerticalCandidates(
        fromX: Int, toX: Int, dir: Int, atY: Int, minY: Int, maxY: Int,
        gap: Int, span: Int, sampler: PixelSampler
    ) -> [Int] {
        var found: [Int] = []
        var x = fromX + dir * max(3, span)
        var lastX = fromX
        let probeOffsets = [-18, -9, 9, 18]

        while (dir > 0 ? x < toX - span : x > toX + span) && found.count < 4 {
            if abs(x - lastX) >= gap && edgeStrengthV(sampler, x: x, y: atY, span: span) >= 24 {
                var hits = 0, tested = 0
                for dy in probeOffsets {
                    let py = atY + dy
                    guard py > minY && py < maxY else { continue }
                    tested += 1
                    if edgeStrengthV(sampler, x: x, y: py, span: span) >= 20 { hits += 1 }
                }
                if tested >= 2 && hits * 4 >= tested * 3 {
                    let exactX = refineVerticalPeak(around: x, atY: atY, span: span, sampler: sampler)
                    found.append(exactX)
                    lastX = exactX
                    x = exactX + dir * gap
                    continue
                }
            }
            x += dir
        }
        return found
    }

    private static func scanHorizontalCandidates(
        fromY: Int, toY: Int, dir: Int, atX: Int, minX: Int, maxX: Int,
        gap: Int, span: Int, sampler: PixelSampler
    ) -> [Int] {
        var found: [Int] = []
        var y = fromY + dir * max(3, span)
        var lastY = fromY
        let probeOffsets = [-20, -10, 10, 20]

        while (dir > 0 ? y < toY - span : y > toY + span) && found.count < 4 {
            if abs(y - lastY) >= gap && edgeStrengthH(sampler, x: atX, y: y, span: span) >= 24 {
                var hits = 0, tested = 0
                for dx in probeOffsets {
                    let px = atX + dx
                    guard px > minX && px < maxX else { continue }
                    tested += 1
                    if edgeStrengthH(sampler, x: px, y: y, span: span) >= 20 { hits += 1 }
                }
                if tested >= 2 && hits * 4 >= tested * 3 {
                    let exactY = refineHorizontalPeak(around: y, atX: atX, span: span, sampler: sampler)
                    found.append(exactY)
                    lastY = exactY
                    y = exactY + dir * gap
                    continue
                }
            }
            y += dir
        }
        return found
    }

    // MARK: - 4-Side Closed Perimeter Verification

    @inline(__always)
    private static func strongHorizontalAt(x: Int, y: Int, span: Int, sampler: PixelSampler) -> Bool {
        if edgeStrengthH(sampler, x: x, y: y, span: span) >= 20 { return true }
        if edgeStrengthH(sampler, x: x, y: y - 1, span: span) >= 20 { return true }
        return edgeStrengthH(sampler, x: x, y: y + 1, span: span) >= 20
    }

    @inline(__always)
    private static func strongVerticalAt(x: Int, y: Int, span: Int, sampler: PixelSampler) -> Bool {
        if edgeStrengthV(sampler, x: x, y: y, span: span) >= 20 { return true }
        if edgeStrengthV(sampler, x: x - 1, y: y, span: span) >= 20 { return true }
        return edgeStrengthV(sampler, x: x + 1, y: y, span: span) >= 20
    }

    private static func checkHorizontalEdgeSpan(y: Int, x0: Int, x1: Int, span: Int, sampler: PixelSampler) -> Bool {
        guard x1 > x0 else { return false }
        // 优先校验左右双肩端点闭合性，不闭合立即 O(1) 剪枝退出
        guard strongHorizontalAt(x: x0, y: y, span: span, sampler: sampler),
              strongHorizontalAt(x: x1, y: y, span: span, sampler: sampler) else {
            return false
        }
        let samples = 12
        var misses = 0
        for i in 1..<(samples - 1) {
            let x = x0 + ((x1 - x0) * i) / (samples - 1)
            if !strongHorizontalAt(x: x, y: y, span: span, sampler: sampler) {
                misses += 1
                if misses > 2 { return false }
            }
        }
        return true
    }

    private static func checkVerticalEdgeSpan(x: Int, y0: Int, y1: Int, span: Int, sampler: PixelSampler) -> Bool {
        guard y1 > y0 else { return false }
        guard strongVerticalAt(x: x, y: y0, span: span, sampler: sampler),
              strongVerticalAt(x: x, y: y1, span: span, sampler: sampler) else {
            return false
        }
        let samples = 12
        var misses = 0
        for i in 1..<(samples - 1) {
            let y = y0 + ((y1 - y0) * i) / (samples - 1)
            if !strongVerticalAt(x: x, y: y, span: span, sampler: sampler) {
                misses += 1
                if misses > 2 { return false }
            }
        }
        return true
    }

    private static func refineVerticalPeak(around cx: Int, atY y: Int, span: Int, sampler: PixelSampler) -> Int {
        var bestX = cx, bestScore = -1
        for x in (cx - span)...(cx + span) {
            let score = rgbDiff(sampler.sampleRGB(px: x - 1, py: y), sampler.sampleRGB(px: x + 1, py: y))
                + rgbDiff(sampler.sampleRGB(px: x - 1, py: y), sampler.sampleRGB(px: x, py: y))
            if score > bestScore { bestScore = score; bestX = x }
        }
        return bestX
    }

    private static func refineHorizontalPeak(around cy: Int, atX x: Int, span: Int, sampler: PixelSampler) -> Int {
        var bestY = cy, bestScore = -1
        for y in (cy - span)...(cy + span) {
            let score = rgbDiff(sampler.sampleRGB(px: x, py: y - 1), sampler.sampleRGB(px: x, py: y + 1))
                + rgbDiff(sampler.sampleRGB(px: x, py: y - 1), sampler.sampleRGB(px: x, py: y))
            if score > bestScore { bestScore = score; bestY = y }
        }
        return bestY
    }

    // MARK: - Low-Level Contrast & IoU

    @inline(__always)
    private static func edgeStrengthV(_ sampler: PixelSampler, x: Int, y: Int, span: Int) -> Int {
        let a = sampler.sampleRGB(px: x - span, py: y)
        let m = sampler.sampleRGB(px: x, py: y)
        let b = sampler.sampleRGB(px: x + span, py: y)
        return max(rgbDiff(a, b), max(rgbDiff(a, m), rgbDiff(m, b)))
    }

    @inline(__always)
    private static func edgeStrengthH(_ sampler: PixelSampler, x: Int, y: Int, span: Int) -> Int {
        let a = sampler.sampleRGB(px: x, py: y - span)
        let m = sampler.sampleRGB(px: x, py: y)
        let b = sampler.sampleRGB(px: x, py: y + span)
        return max(rgbDiff(a, b), max(rgbDiff(a, m), rgbDiff(m, b)))
    }

    @inline(__always)
    private static func rgbDiff(_ c0: (Int, Int, Int), _ c1: (Int, Int, Int)) -> Int {
        abs(c0.0 - c1.0) + abs(c0.1 - c1.1) + abs(c0.2 - c1.2)
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull && inter.width > 0 && inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        return unionArea > 0 ? (interArea / unionArea) : 0
    }
}
