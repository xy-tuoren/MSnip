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

// MARK: - 四边闭合视觉边缘探测算法

/// `VisualDetector` 像素精确边缘射线扫描、全跨度峰值精修与自适应大圆角闭合校验
extension VisualDetector {
    static func scanVerticalCandidates(
        fromX: Int, toX: Int, dir: Int, atY: Int, minY: Int, maxY: Int,
        gap: Int, sharp: Int, wide: Int, scale: CGFloat, sampler: PixelSampler
    ) -> [Int] {
        var found: [Int] = []
        var x = fromX + dir * max(2, sharp)
        var lastX = fromX
        let longOffsets = [-16, -8, 8, 16].map { Int((CGFloat($0) * scale).rounded()) }
        let shortOffsets = [-7, -3, 3, 7].map { Int((CGFloat($0) * scale).rounded()) }

        while (dir > 0 ? x < toX - sharp : x > toX + sharp) && found.count < 16 {
            if abs(x - lastX) >= gap && edgeStrengthV(sampler, x: x, y: atY, sharp: sharp, wide: wide) >= 20 {
                if passesVerticalLocalProbes(x: x, atY: atY, offsets: longOffsets, minY: minY, maxY: maxY, sharp: sharp, wide: wide, sampler: sampler)
                    || passesVerticalLocalProbes(x: x, atY: atY, offsets: shortOffsets, minY: minY, maxY: maxY, sharp: sharp, wide: wide, sampler: sampler) {
                    // 在完整 wide 跨度内精修真实最陡边界像素，杜绝柔边提前触发造成的 4pt 内缩偏移
                    let exactX = refineVerticalPeak(around: x, atY: atY, minY: minY, maxY: maxY, radius: wide + 1, sampler: sampler)
                    if found.last.map({ abs($0 - exactX) >= gap / 2 }) ?? true {
                        found.append(exactX)
                        lastX = exactX
                        x = exactX + dir * gap
                        continue
                    }
                }
            }
            x += dir
        }
        return found
    }

    static func scanHorizontalCandidates(
        fromY: Int, toY: Int, dir: Int, atX: Int, minX: Int, maxX: Int,
        gap: Int, sharp: Int, wide: Int, scale: CGFloat, sampler: PixelSampler
    ) -> [Int] {
        var found: [Int] = []
        var y = fromY + dir * max(2, sharp)
        var lastY = fromY
        let longOffsets = [-18, -9, 9, 18].map { Int((CGFloat($0) * scale).rounded()) }
        let shortOffsets = [-8, -4, 4, 8].map { Int((CGFloat($0) * scale).rounded()) }

        while (dir > 0 ? y < toY - sharp : y > toY + sharp) && found.count < 16 {
            if abs(y - lastY) >= gap && edgeStrengthH(sampler, x: atX, y: y, sharp: sharp, wide: wide) >= 20 {
                if passesHorizontalLocalProbes(y: y, atX: atX, offsets: longOffsets, minX: minX, maxX: maxX, sharp: sharp, wide: wide, sampler: sampler)
                    || passesHorizontalLocalProbes(y: y, atX: atX, offsets: shortOffsets, minX: minX, maxX: maxX, sharp: sharp, wide: wide, sampler: sampler) {
                    let exactY = refineHorizontalPeak(around: y, atX: atX, minX: minX, maxX: maxX, radius: wide + 1, sampler: sampler)
                    if found.last.map({ abs($0 - exactY) >= gap / 2 }) ?? true {
                        found.append(exactY)
                        lastY = exactY
                        y = exactY + dir * gap
                        continue
                    }
                }
            }
            y += dir
        }
        return found
    }

    private static func passesVerticalLocalProbes(
        x: Int, atY: Int, offsets: [Int], minY: Int, maxY: Int, sharp: Int, wide: Int, sampler: PixelSampler
    ) -> Bool {
        var hits = 0, tested = 0
        for dy in offsets {
            let py = atY + dy
            guard py > minY && py < maxY else { continue }
            tested += 1
            if edgeStrengthV(sampler, x: x, y: py, sharp: sharp, wide: wide) >= 16 { hits += 1 }
        }
        return tested >= 2 && hits * 4 >= tested * 3
    }

    private static func passesHorizontalLocalProbes(
        y: Int, atX: Int, offsets: [Int], minX: Int, maxX: Int, sharp: Int, wide: Int, sampler: PixelSampler
    ) -> Bool {
        var hits = 0, tested = 0
        for dx in offsets {
            let px = atX + dx
            guard px > minX && px < maxX else { continue }
            tested += 1
            if edgeStrengthH(sampler, x: px, y: y, sharp: sharp, wide: wide) >= 16 { hits += 1 }
        }
        return tested >= 2 && hits * 4 >= tested * 3
    }

    // MARK: - 4-Side Closed Perimeter Verification (Adaptive Rounded Corners)

    static func checkHorizontalEdgeAdaptive(
        y: Int, lx: Int, rx: Int, sharp: Int, wide: Int, scale: CGFloat, sampler: PixelSampler
    ) -> Bool {
        let w = rx - lx
        let c1 = min(Int((5.0 * scale).rounded()), w / 8)
        if checkHorizontalEdgeSpan(y: y, x0: lx + c1, x1: rx - c1, sharp: sharp, wide: wide, sampler: sampler) {
            return true
        }
        let c2 = min(Int((22.0 * scale).rounded()), w / 4)
        guard w >= Int((56.0 * scale).rounded()), c2 > c1 else { return false }
        // 真圆角卡片/窗口的左右竖边不会在水平边外侧继续笔直延伸；防止把上下两张内缩卡片之间的空白缝隙误判成独立闭合框
        let probeOut = max(4, Int((8.0 * scale).rounded()))
        let outY1 = y - probeOut, outY2 = y + probeOut
        let leftContinuesThrough = outY1 > 1 && outY2 < sampler.height - 2
            && strongVerticalAt(x: lx, y: outY1, sharp: sharp, wide: wide, sampler: sampler)
            && strongVerticalAt(x: lx, y: outY2, sharp: sharp, wide: wide, sampler: sampler)
        let rightContinuesThrough = outY1 > 1 && outY2 < sampler.height - 2
            && strongVerticalAt(x: rx, y: outY1, sharp: sharp, wide: wide, sampler: sampler)
            && strongVerticalAt(x: rx, y: outY2, sharp: sharp, wide: wide, sampler: sampler)
        if leftContinuesThrough && rightContinuesThrough { return false }
        return checkHorizontalEdgeSpan(y: y, x0: lx + c2, x1: rx - c2, sharp: sharp, wide: wide, sampler: sampler)
    }

    static func checkVerticalEdgeAdaptive(
        x: Int, ty: Int, by: Int, sharp: Int, wide: Int, scale: CGFloat, sampler: PixelSampler
    ) -> Bool {
        let h = by - ty
        let c1 = min(Int((5.0 * scale).rounded()), h / 8)
        if checkVerticalEdgeSpan(x: x, y0: ty + c1, y1: by - c1, sharp: sharp, wide: wide, sampler: sampler) {
            return true
        }
        let c2 = min(Int((22.0 * scale).rounded()), h / 4)
        guard h >= Int((56.0 * scale).rounded()), c2 > c1 else { return false }
        let probeOut = max(4, Int((8.0 * scale).rounded()))
        let outX1 = x - probeOut, outX2 = x + probeOut
        let topContinuesThrough = outX1 > 1 && outX2 < sampler.width - 2
            && strongHorizontalAt(x: outX1, y: ty, sharp: sharp, wide: wide, sampler: sampler)
            && strongHorizontalAt(x: outX2, y: ty, sharp: sharp, wide: wide, sampler: sampler)
        let botContinuesThrough = outX1 > 1 && outX2 < sampler.width - 2
            && strongHorizontalAt(x: outX1, y: by, sharp: sharp, wide: wide, sampler: sampler)
            && strongHorizontalAt(x: outX2, y: by, sharp: sharp, wide: wide, sampler: sampler)
        if topContinuesThrough && botContinuesThrough { return false }
        return checkVerticalEdgeSpan(x: x, y0: ty + c2, y1: by - c2, sharp: sharp, wide: wide, sampler: sampler)
    }

    @inline(__always)
    private static func strongHorizontalAt(x: Int, y: Int, sharp: Int, wide: Int, sampler: PixelSampler) -> Bool {
        if edgeStrengthH(sampler, x: x, y: y, sharp: sharp, wide: wide) >= 16 { return true }
        if edgeStrengthH(sampler, x: x, y: y - 1, sharp: sharp, wide: wide) >= 16 { return true }
        return edgeStrengthH(sampler, x: x, y: y + 1, sharp: sharp, wide: wide) >= 16
    }

    @inline(__always)
    private static func strongVerticalAt(x: Int, y: Int, sharp: Int, wide: Int, sampler: PixelSampler) -> Bool {
        if edgeStrengthV(sampler, x: x, y: y, sharp: sharp, wide: wide) >= 16 { return true }
        if edgeStrengthV(sampler, x: x - 1, y: y, sharp: sharp, wide: wide) >= 16 { return true }
        return edgeStrengthV(sampler, x: x + 1, y: y, sharp: sharp, wide: wide) >= 16
    }

    private static func checkHorizontalEdgeSpan(y: Int, x0: Int, x1: Int, sharp: Int, wide: Int, sampler: PixelSampler) -> Bool {
        guard x1 > x0,
              strongHorizontalAt(x: x0, y: y, sharp: sharp, wide: wide, sampler: sampler),
              strongHorizontalAt(x: x1, y: y, sharp: sharp, wide: wide, sampler: sampler) else { return false }
        let samples = 12
        var misses = 0
        for i in 1..<(samples - 1) {
            let x = x0 + ((x1 - x0) * i) / (samples - 1)
            if !strongHorizontalAt(x: x, y: y, sharp: sharp, wide: wide, sampler: sampler) {
                misses += 1
                if misses > 2 { return false }
            }
        }
        return true
    }

    private static func checkVerticalEdgeSpan(x: Int, y0: Int, y1: Int, sharp: Int, wide: Int, sampler: PixelSampler) -> Bool {
        guard y1 > y0,
              strongVerticalAt(x: x, y: y0, sharp: sharp, wide: wide, sampler: sampler),
              strongVerticalAt(x: x, y: y1, sharp: sharp, wide: wide, sampler: sampler) else { return false }
        let samples = 12
        var misses = 0
        for i in 1..<(samples - 1) {
            let y = y0 + ((y1 - y0) * i) / (samples - 1)
            if !strongVerticalAt(x: x, y: y, sharp: sharp, wide: wide, sampler: sampler) {
                misses += 1
                if misses > 2 { return false }
            }
        }
        return true
    }

    private static func refineVerticalPeak(around cx: Int, atY y: Int, minY: Int, maxY: Int, radius: Int, sampler: PixelSampler) -> Int {
        let ys = [max(minY + 1, y - 3), y, min(maxY - 1, y + 3)]
        var bestX = cx, bestScore = -1
        for x in (cx - radius)...(cx + radius) {
            var score = 0
            for py in ys {
                score += rgbDiff(sampler.sampleRGB(px: x - 1, py: py), sampler.sampleRGB(px: x + 1, py: py)) * 2
                    + rgbDiff(sampler.sampleRGB(px: x - 1, py: py), sampler.sampleRGB(px: x, py: py))
            }
            if score > bestScore { bestScore = score; bestX = x }
        }
        return bestX
    }

    private static func refineHorizontalPeak(around cy: Int, atX x: Int, minX: Int, maxX: Int, radius: Int, sampler: PixelSampler) -> Int {
        let xs = [max(minX + 1, x - 3), x, min(maxX - 1, x + 3)]
        var bestY = cy, bestScore = -1
        for y in (cy - radius)...(cy + radius) {
            var score = 0
            for px in xs {
                score += rgbDiff(sampler.sampleRGB(px: px, py: y - 1), sampler.sampleRGB(px: px, py: y + 1)) * 2
                    + rgbDiff(sampler.sampleRGB(px: px, py: y - 1), sampler.sampleRGB(px: px, py: y))
            }
            if score > bestScore { bestScore = score; bestY = y }
        }
        return bestY
    }

    @inline(__always)
    private static func edgeStrengthV(_ sampler: PixelSampler, x: Int, y: Int, sharp: Int, wide: Int) -> Int {
        let a = sampler.sampleRGB(px: x - sharp, py: y)
        let m = sampler.sampleRGB(px: x, py: y)
        let b = sampler.sampleRGB(px: x + sharp, py: y)
        let sharpDiff = max(rgbDiff(a, b), max(rgbDiff(a, m), rgbDiff(m, b)))
        let wideDiff = rgbDiff(sampler.sampleRGB(px: x - wide, py: y), sampler.sampleRGB(px: x + wide, py: y))
        return max(sharpDiff, wideDiff)
    }

    @inline(__always)
    private static func edgeStrengthH(_ sampler: PixelSampler, x: Int, y: Int, sharp: Int, wide: Int) -> Int {
        let a = sampler.sampleRGB(px: x, py: y - sharp)
        let m = sampler.sampleRGB(px: x, py: y)
        let b = sampler.sampleRGB(px: x, py: y + sharp)
        let sharpDiff = max(rgbDiff(a, b), max(rgbDiff(a, m), rgbDiff(m, b)))
        let wideDiff = rgbDiff(sampler.sampleRGB(px: x, py: y - wide), sampler.sampleRGB(px: x, py: y + wide))
        return max(sharpDiff, wideDiff)
    }

    @inline(__always)
    private static func rgbDiff(_ c0: (Int, Int, Int), _ c1: (Int, Int, Int)) -> Int {
        abs(c0.0 - c1.0) + abs(c0.1 - c1.1) + abs(c0.2 - c1.2)
    }
}
