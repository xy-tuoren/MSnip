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

        // 2D 纹理像素精校：用 ±1px 亚像素容差做准入核验，再用无模糊精确误差 exactErr（辅以全行 1D 分数破平）锁定 0px 峰值
        var verifiedDy: Int?
        var verifiedExact = Double.greatestFiniteMagnitude
        var verified1D = Double.greatestFiniteMagnitude
        for cand in fineCands.prefix(3) {
            let lo = max(minBackwardDy, cand.dy - 1)
            let hi = min(maxForwardDy, cand.dy + 1)
            for dy in lo...hi {
                if let exactErr = verify2DTextured(
                    anchor: anchor, curr: curr, width: w, height: h,
                    workTop: workTop, workBottom: workBottom, dy: dy, activeMask: activeBands.mask
                ) {
                    let s1d = score1D(at: dy, rowStep: 1)
                    let isBetter = exactErr + 0.05 < verifiedExact
                        || (abs(exactErr - verifiedExact) <= 0.05 && s1d < verified1D)
                    if isBetter {
                        verifiedExact = exactErr
                        verified1D = s1d
                        verifiedDy = dy
                    }
                }
            }
        }
        guard let bestDy = verifiedDy else { return nil }
        return MatchResult(dy: bestDy, margins: margins)
    }

    /// 严格逐行校验上洁净区 `[workTop ..< seamY]` 是否纹丝不动、且仅下尾段发生局部渐隐变化：
    /// - 只要上区存在任何纹理行移动（即便是极稀疏页面上仅 2 行文字微滚 4px），立即返回 false，绝不误吞滚动；
    /// - 仅当上区静止且下区有局部变化（如 ChatGPT `↓` 按钮或系统滚动条淡出）时返回 true。
    static func isSettledTailRefresh(
        a: ScrollFrameDigest,
        b: ScrollFrameDigest,
        workTop: Int,
        seamY: Int,
        height: Int
    ) -> Bool {
        guard seamY - workTop >= 16, height > seamY else { return false }
        var upperChanged = 0
        for y in workTop..<seamY {
            let d = a.rows[y].fullDiff(to: b.rows[y])
            if d > 3 {
                upperChanged += 1
                if a.rows[y].grad >= 3 || b.rows[y].grad >= 3 || upperChanged > 1 { return false }
            }
        }
        let tailSpan = height - seamY
        var lowerChanged = 0
        for y in seamY..<height where a.rows[y].fullDiff(to: b.rows[y]) > 3 {
            lowerChanged += 1
        }
        return lowerChanged > 0 && lowerChanged * 100 <= tailSpan * 48
    }

    /// 二维纹理像素鲁棒验证（零堆分配直方图 85% 截断均值）：
    /// - 重点考核具备局部边缘/对比度的纹理像素，杜绝暗色模式 88% 纯黑底稀释误差导致的错行误配；
    /// - 截断最差 15% 离群点，天然吸收 ChatGPT 悬浮 `↓` 按钮、闪烁光标或动图引起的局部差异。
    private static func verify2DTextured(
        anchor: ScrollFrameDigest,
        curr: ScrollFrameDigest,
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

        // 优先采样真实包含文字/边缘的纹理行（绝不被固定步长跳过 5px 细字行），不足时再用均匀网格补足
        var sampleYs: [Int] = []
        sampleYs.reserveCapacity(52)
        var texRows: [Int] = []
        for y in startY..<endY where curr.rows[y].grad >= 2 || anchor.rows[y + dy].grad >= 2 {
            texRows.append(y)
        }
        if !texRows.isEmpty {
            let tStep = max(1, texRows.count / 44)
            var idx = 0
            while idx < texRows.count { sampleYs.append(texRows[idx]); idx += tStep }
        }
        if sampleYs.count < 24 {
            let stepY = max(1, (endY - startY) / 32)
            var y = startY
            while y < endY { sampleYs.append(y); y += stepY }
        }

        var texHist = [Int](repeating: 0, count: 256)
        var exactTexHist = [Int](repeating: 0, count: 256)
        var allHist = [Int](repeating: 0, count: 256)
        var exactAllSum = 0
        var texTotal = 0, texAgreed = 0, allTotal = 0

        let dxProbe = max(1, min(3, span / 64))
        for cy in sampleYs {
            let ay = cy + dy
            let ayPrev = max(0, ay - 1)
            let ayNext = min(height - 1, ay + 1)
            for x in xs {
                let pc = curr.sampler.sampleRGB(px: x, py: cy)
                let p0 = anchor.sampler.sampleRGB(px: x, py: ay)
                let e0 = abs(p0.0 - pc.0) + abs(p0.1 - pc.1) + abs(p0.2 - pc.2)

                let err3: Int
                if e0 <= 9 {
                    err3 = e0
                } else {
                    let pPrev = anchor.sampler.sampleRGB(px: x, py: ayPrev)
                    let pNext = anchor.sampler.sampleRGB(px: x, py: ayNext)
                    let ePrev = abs(pPrev.0 - pc.0) + abs(pPrev.1 - pc.1) + abs(pPrev.2 - pc.2) + 3
                    let eNext = abs(pNext.0 - pc.0) + abs(pNext.1 - pc.1) + abs(pNext.2 - pc.2) + 3
                    let eMid = abs(((p0.0 + pNext.0) >> 1) - pc.0)
                        + abs(((p0.1 + pNext.1) >> 1) - pc.1)
                        + abs(((p0.2 + pNext.2) >> 1) - pc.2) + 2
                    err3 = min(min(e0, eMid), min(ePrev, eNext))
                }
                let perCh = min(255, err3 / 3)
                let exactCh = min(255, e0 / 3)
                allHist[perCh] += 1
                exactAllSum += exactCh
                allTotal += 1

                let pcR = curr.sampler.sampleRGB(px: min(width - 1, x + dxProbe), py: cy)
                let p0R = anchor.sampler.sampleRGB(px: min(width - 1, x + dxProbe), py: ay)
                let cGrad = abs(pc.0 - pcR.0) + abs(pc.1 - pcR.1) + abs(pc.2 - pcR.2)
                let aGrad = abs(p0.0 - p0R.0) + abs(p0.1 - p0R.1) + abs(p0.2 - p0R.2)
                let p0D = anchor.sampler.sampleRGB(px: x, py: ayNext)
                let vGrad = abs(p0.0 - p0D.0) + abs(p0.1 - p0D.1) + abs(p0.2 - p0D.2)
                if cGrad >= 24 || aGrad >= 24 || vGrad >= 24 {
                    texHist[perCh] += 1
                    exactTexHist[exactCh] += 1
                    texTotal += 1
                    if perCh <= 22 { texAgreed += 1 }
                }
            }
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
            return trimmedMean(exactTexHist, total: texTotal, keepPercent: 95)
        }
        guard allTrim <= 12.0 else { return nil }
        return Double(exactAllSum) / Double(allTotal)
    }
}
