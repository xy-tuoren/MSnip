import CoreGraphics
import Foundation

/// 滚动长截图位移搜索与 2D 纹理像素精确验证引擎（抗暗色模式纯背景误配、重复表格干扰及局部悬浮按钮干扰）
enum ScrollOverlapVerifier {
    struct MatchResult {
        let dy: Int
        let margins: (matchTop: Int, matchBottom: Int, stickyTop: Int, stickyBottom: Int)
    }

    static func matchDisplacement(
        anchor: ScrollFrameDigest,
        curr: ScrollFrameDigest,
        width w: Int,
        height h: Int,
        lockedTop: Int,
        lockedBottom: Int
    ) -> MatchResult? {
        let margins = ScrollFrameDigest.detectStaticMargins(a: anchor.rows, b: curr.rows, height: h)
        let workTop = min(h * 32 / 100, max(lockedTop, margins.matchTop))
        let workBottom = h - min(h * 32 / 100, max(lockedBottom, margins.matchBottom))
        let workH = workBottom - workTop
        guard workH >= 32 else { return nil }

        let minOverlap = max(20, workH * 12 / 100)
        let maxForwardDy = workH - minOverlap
        let minBackwardDy = -min(workH / 2, 260)
        guard maxForwardDy >= 2 else { return nil }

        let activeBands = ScrollFrameDigest.detectActiveBands(
            a: anchor.rows, b: curr.rows, workTop: workTop, workBottom: workBottom
        )

        func score1D(at dy: Int, rowStep: Int) -> Double {
            let ovS = max(workTop, workTop - dy), ovE = min(workBottom, workBottom - dy)
            if ovE - ovS < minOverlap { return .greatestFiniteMagnitude }
            var wDiff = 0.0, wSum = 0.0, textured = 0, cy = ovS
            while cy < ovE {
                let ra = anchor.rows[cy + dy], rc = curr.rows[cy]
                let d = Double(ra.maskedDiff(to: rc, activeMask: activeBands.mask, activeCount: activeBands.count))
                let isTex = ra.grad >= 3 || rc.grad >= 3
                let wgt = isTex ? 4.0 : 0.18
                if isTex { textured += 1 }
                wDiff += d * wgt
                wSum += wgt
                cy += rowStep
            }
            guard wSum > 0 else { return .greatestFiniteMagnitude }
            var m = (wDiff / wSum) * (1.0 + Double(abs(dy)) / Double(workH * 10))
            if textured < 3 { m += 4.5 }
            return m
        }

        // 粗扫保留前 5 个候选波谷，避免重复表格分隔线干扰主峰
        var topCands: [(dy: Int, sc: Double)] = []
        var cDy = minBackwardDy
        while cDy <= maxForwardDy {
            let sc = score1D(at: cDy, rowStep: 2)
            if sc < .greatestFiniteMagnitude {
                if topCands.count < 5 {
                    topCands.append((cDy, sc)); topCands.sort { $0.sc < $1.sc }
                } else if sc < topCands[4].sc {
                    topCands[4] = (cDy, sc); topCands.sort { $0.sc < $1.sc }
                }
            }
            cDy += 2
        }

        // 围绕候选峰进行逐像素 1D 精扫，保留前 2 个独立峰交由 2D 纹理验证最终裁决
        var fineCands: [(dy: Int, sc: Double)] = []
        for cand in topCands {
            var localBestDy = cand.dy, localBestSc = Double.greatestFiniteMagnitude
            for dy in max(minBackwardDy, cand.dy - 3)...min(maxForwardDy, cand.dy + 3) {
                let sc = score1D(at: dy, rowStep: 1)
                if sc < localBestSc { localBestSc = sc; localBestDy = dy }
            }
            if localBestSc <= 20.0 && !fineCands.contains(where: { abs($0.dy - localBestDy) <= 2 }) {
                fineCands.append((localBestDy, localBestSc))
            }
        }
        fineCands.sort { $0.sc < $1.sc }
        guard !fineCands.isEmpty else { return nil }

        // 2D 纹理像素精校（在 ±1px 范围内比较前 3 个独立峰，锁定 0px 零误差全局最优，彻底拦截暗色模式纯背景误匹配）
        var verifiedDy: Int?
        var verifiedErr = Double.greatestFiniteMagnitude
        for cand in fineCands.prefix(3) {
            let lo = max(minBackwardDy, cand.dy - 1)
            let hi = min(maxForwardDy, cand.dy + 1)
            for dy in lo...hi {
                if let err = verify2DTextured(
                    anchor: anchor.sampler, curr: curr.sampler, width: w, height: h,
                    workTop: workTop, workBottom: workBottom, dy: dy, activeMask: activeBands.mask
                ) {
                    let isBetter = err + 0.6 < verifiedErr
                        || (abs(err - verifiedErr) <= 0.6 && verifiedDy.map { abs(dy) < abs($0) } ?? true)
                    if isBetter {
                        verifiedErr = err
                        verifiedDy = dy
                    }
                }
            }
        }
        guard let bestDy = verifiedDy else { return nil }
        return MatchResult(dy: bestDy, margins: margins)
    }

    /// 快速校验上洁净区 `[workTop ..< seamY]` 是否仍静止对齐（用于停滚后静默刷新渐隐悬浮按钮/滚动条的尾段）
    static func isUpperRegionAligned(
        a: ScrollFrameDigest,
        b: ScrollFrameDigest,
        workTop: Int,
        seamY: Int
    ) -> Bool {
        let span = seamY - workTop
        guard span >= 16 else { return false }
        var diffSum: Int32 = 0
        var count: Int32 = 0
        let step = max(1, span / 48)
        var y = workTop
        while y < seamY {
            diffSum += a.rows[y].fullDiff(to: b.rows[y])
            count += 1
            y += step
        }
        return count > 0 && (diffSum / count) <= 3
    }

    /// 二维纹理像素鲁棒验证（零堆分配直方图 85% 截断均值）：
    /// - 重点考核具备局部边缘/对比度的纹理像素，杜绝暗色模式 88% 纯黑底稀释误差导致的错行误配；
    /// - 截断最差 15% 离群点，天然吸收 ChatGPT 悬浮 `↓` 按钮、闪烁光标或动图引起的局部差异。
    private static func verify2DTextured(
        anchor: PixelSampler,
        curr: PixelSampler,
        width: Int,
        height: Int,
        workTop: Int,
        workBottom: Int,
        dy: Int,
        activeMask: UInt16
    ) -> Double? {
        let startY = max(workTop, workTop - dy)
        let endY = min(workBottom, workBottom - dy)
        guard endY - startY >= 16 else { return nil }

        let rightMargin = min(max(10, width / 18), 42)
        let x0 = min(4, width / 16)
        let span = max(16, max(x0 + 16, width - rightMargin) - x0)

        var xs: [Int] = []
        xs.reserveCapacity(32)
        for b in 0..<16 where (activeMask & (1 << b)) != 0 {
            let cx = min(width - 2, x0 + (span * (b * 2 + 1)) / 32)
            xs.append(cx)
            if activeMask.nonzeroBitCount <= 8 {
                xs.append(min(width - 2, cx + max(2, span / 48)))
            }
        }
        if xs.isEmpty { xs = [width * 30 / 100, width * 50 / 100, width * 70 / 100] }

        var texHist = [Int](repeating: 0, count: 256)
        var allHist = [Int](repeating: 0, count: 256)
        var texTotal = 0, texAgreed = 0, allTotal = 0

        let stepY = max(1, (endY - startY) / 44)
        let dxProbe = max(1, min(3, span / 64))
        var cy = startY
        while cy < endY {
            let ay = cy + dy
            let ayPrev = max(0, ay - 1)
            let ayNext = min(height - 1, ay + 1)
            for x in xs {
                let pc = curr.sampleRGB(px: x, py: cy)
                let p0 = anchor.sampleRGB(px: x, py: ay)
                let e0 = abs(p0.0 - pc.0) + abs(p0.1 - pc.1) + abs(p0.2 - pc.2)

                let err3: Int
                if e0 <= 9 {
                    err3 = e0
                } else {
                    let pPrev = anchor.sampleRGB(px: x, py: ayPrev)
                    let pNext = anchor.sampleRGB(px: x, py: ayNext)
                    let ePrev = abs(pPrev.0 - pc.0) + abs(pPrev.1 - pc.1) + abs(pPrev.2 - pc.2) + 3
                    let eNext = abs(pNext.0 - pc.0) + abs(pNext.1 - pc.1) + abs(pNext.2 - pc.2) + 3
                    let eMid = abs(((p0.0 + pNext.0) >> 1) - pc.0)
                        + abs(((p0.1 + pNext.1) >> 1) - pc.1)
                        + abs(((p0.2 + pNext.2) >> 1) - pc.2) + 2
                    err3 = min(min(e0, eMid), min(ePrev, eNext))
                }
                let perCh = min(255, err3 / 3)
                allHist[perCh] += 1
                allTotal += 1

                let pcR = curr.sampleRGB(px: min(width - 1, x + dxProbe), py: cy)
                let p0R = anchor.sampleRGB(px: min(width - 1, x + dxProbe), py: ay)
                let cGrad = abs(pc.0 - pcR.0) + abs(pc.1 - pcR.1) + abs(pc.2 - pcR.2)
                let aGrad = abs(p0.0 - p0R.0) + abs(p0.1 - p0R.1) + abs(p0.2 - p0R.2)
                let p0D = anchor.sampleRGB(px: x, py: ayNext)
                let vGrad = abs(p0.0 - p0D.0) + abs(p0.1 - p0D.1) + abs(p0.2 - p0D.2)
                if cGrad >= 24 || aGrad >= 24 || vGrad >= 24 {
                    texHist[perCh] += 1
                    texTotal += 1
                    if perCh <= 22 { texAgreed += 1 }
                }
            }
            cy += stepY
        }
        guard allTotal > 0 else { return nil }

        func trimmedMean(_ hist: [Int], total: Int, keepPercent: Int) -> Double {
            let keep = max(1, total * keepPercent / 100)
            var rem = keep, acc = 0
            for v in 0..<256 where hist[v] > 0 {
                let take = min(rem, hist[v])
                acc += take * v
                rem -= take
                if rem == 0 { break }
            }
            return Double(acc) / Double(keep)
        }

        let allTrim = trimmedMean(allHist, total: allTotal, keepPercent: 85)
        if texTotal >= 20 {
            let texTrim = trimmedMean(texHist, total: texTotal, keepPercent: 85)
            let agreeRatio = Double(texAgreed) / Double(texTotal)
            guard texTrim <= 18.0 && agreeRatio >= 0.66 && allTrim <= 16.0 else { return nil }
            return texTrim
        }
        guard allTrim <= 12.0 else { return nil }
        return allTrim
    }
}
