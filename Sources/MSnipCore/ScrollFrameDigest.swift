import CoreGraphics
import Foundation

/// 单行 16 分区抗亚像素抖动特征签名：
/// - 每行横跨有效正文区采样 64 像素聚合成 16 个 SIMD 分区，大幅提升暗色模式细字体与表格分辨力；
/// - 纵向经 `[1, 2, 1]/4` 平滑抑制 `@1x` 屏幕亚像素闪烁，配合截断 Huber 差值天然免疫局部悬浮按钮（如 `↓` 置底键）。
struct ScrollRowSig {
    var luma: Int32
    var grad: Int32
    var bands: SIMD16<Int16>   // 16 个水平分区的平滑亮度 (0..1020)
    var chroma: SIMD16<Int16>  // 16 个水平分区的平滑色度差
    var energy: SIMD16<Int16>  // 16 个水平分区内部水平边缘能量

    @inline(__always)
    func fullDiff(to other: ScrollRowSig) -> Int32 {
        maskedDiff(to: other, activeMask: 0xFFFF, activeCount: 16, huberClamp: false)
    }

    @inline(__always)
    func maskedDiff(to other: ScrollRowSig, activeMask: UInt16, activeCount: Int32, huberClamp: Bool = true) -> Int32 {
        var sum: Int32 = 0
        for i in 0..<16 where (activeMask & (1 << i)) != 0 {
            let db = Int32(abs(bands[i] - other.bands[i]))
            let dc = Int32(abs(chroma[i] - other.chroma[i]))
            let bandErr = (db + dc) / 3
            sum += huberClamp ? min(bandErr, 48) : bandErr
        }
        let denom = max(1, activeCount)
        let dg = min(abs(grad - other.grad) >> 1, huberClamp ? 24 : 255)
        return (sum / denom) + dg
    }

    @inline(__always)
    func changedBandCount(to other: ScrollRowSig, threshold: Int32 = 10) -> Int {
        var changed = 0
        for i in 0..<16 {
            let db = abs(Int32(bands[i] - other.bands[i]))
            let dc = abs(Int32(chroma[i] - other.chroma[i]))
            if db > threshold || dc > threshold { changed += 1 }
        }
        return changed
    }
}

struct ScrollFrameDigest {
    let image: CGImage
    let sampler: PixelSampler
    let rows: [ScrollRowSig]

    /// 将当前未分离的帧拷贝为独立拥有的位图摘要（复用已算好的行特征，零重复计算）
    func detachedCopy() -> ScrollFrameDigest? {
        guard let det = ScrollStripCanvas.detachCopy(
            image, rect: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ) else { return nil }
        return ScrollFrameDigest(image: det, sampler: PixelSampler(cgImage: det), rows: rows)
    }

    static func build(for image: CGImage, detach: Bool = false) -> ScrollFrameDigest {
        let owned = detach
            ? (ScrollStripCanvas.detachCopy(image, rect: CGRect(x: 0, y: 0, width: image.width, height: image.height)) ?? image)
            : image
        let sampler = PixelSampler(cgImage: owned)
        let w = sampler.width, h = sampler.height
        let rightMargin = min(max(10, w / 18), 42)
        let x0 = min(4, w / 16)
        let x1 = max(x0 + 16, w - rightMargin)
        let span = max(16, x1 - x0)

        var sampleX = [Int](repeating: 0, count: 64)
        for idx in 0..<64 {
            sampleX[idx] = min(w - 1, x0 + (span * (idx * 2 + 1)) / 128)
        }

        var rawBands = [SIMD16<Int16>](repeating: .zero, count: h)
        var rawChroma = [SIMD16<Int16>](repeating: .zero, count: h)
        var rawEnergy = [SIMD16<Int16>](repeating: .zero, count: h)
        var rawGrad = [Int32](repeating: 0, count: h)
        var rawLuma = [Int32](repeating: 0, count: h)

        for y in 0..<h {
            var bVec = SIMD16<Int16>()
            var cVec = SIMD16<Int16>()
            var eVec = SIMD16<Int16>()
            var gradSum: Int32 = 0
            var lumaSum: Int32 = 0
            var prevL: Int32 = -1

            for b in 0..<16 {
                var bSum: Int32 = 0
                var cSum: Int32 = 0
                var bMin: Int32 = 1024
                var bMax: Int32 = 0
                let base = b << 2
                for s in 0..<4 {
                    let (r, g, bl) = sampler.sampleRGB(px: sampleX[base + s], py: y)
                    let l = Int32(r + (g << 1) + bl)
                    bSum += l
                    cSum += Int32(r - bl) + Int32(g - bl)
                    lumaSum += l
                    if l < bMin { bMin = l }
                    if l > bMax { bMax = l }
                    if prevL >= 0 { gradSum += abs(l - prevL) }
                    prevL = l
                }
                bVec[b] = Int16(clamping: bSum >> 2)
                cVec[b] = Int16(clamping: cSum >> 2)
                eVec[b] = Int16(clamping: (bMax - bMin) >> 2)
            }
            rawBands[y] = bVec
            rawChroma[y] = cVec
            rawEnergy[y] = eVec
            rawLuma[y] = lumaSum >> 6
            rawGrad[y] = gradSum / 63
        }

        var sigs: [ScrollRowSig] = []
        sigs.reserveCapacity(h)
        for y in 0..<h {
            let ym = max(0, y - 1), yp = min(h - 1, y + 1)
            var sb = SIMD16<Int16>()
            var sc = SIMD16<Int16>()
            var se = SIMD16<Int16>()
            for k in 0..<16 {
                let bm = Int32(rawBands[ym][k]), bc = Int32(rawBands[y][k]), bp = Int32(rawBands[yp][k])
                sb[k] = Int16(clamping: (bm + (bc << 1) + bp) >> 2)
                let cm = Int32(rawChroma[ym][k]), cc = Int32(rawChroma[y][k]), cp = Int32(rawChroma[yp][k])
                sc[k] = Int16(clamping: (cm + (cc << 1) + cp) >> 2)
                se[k] = max(rawEnergy[y][k], max(rawEnergy[ym][k], rawEnergy[yp][k]))
            }
            let sl = (rawLuma[ym] + (rawLuma[y] << 1) + rawLuma[yp]) >> 2
            let sg = (rawGrad[ym] + (rawGrad[y] << 1) + rawGrad[yp]) >> 2
            sigs.append(ScrollRowSig(luma: sl, grad: sg, bands: sb, chroma: sc, energy: se))
        }
        return ScrollFrameDigest(image: owned, sampler: sampler, rows: sigs)
    }

    /// 识别在两帧之间发生实际滚动变化的 16 水平分区掩码（自动排除左/右固定侧边栏、Minimap 与纯空白边栏）
    static func detectActiveBands(
        a: [ScrollRowSig],
        b: [ScrollRowSig],
        workTop: Int,
        workBottom: Int
    ) -> (mask: UInt16, count: Int32) {
        let spanH = max(1, workBottom - workTop)
        let minChanged = max(4, spanH * 4 / 100)
        var mask: UInt16 = 0
        var count: Int32 = 0
        for i in 0..<16 {
            var changedRows = 0
            for y in workTop..<workBottom {
                let db = abs(Int32(a[y].bands[i] - b[y].bands[i]))
                let dc = abs(Int32(a[y].chroma[i] - b[y].chroma[i]))
                if db > 9 || dc > 9 { changedRows += 1 }
            }
            if changedRows >= minChanged {
                mask |= (1 << i)
                count += 1
            }
        }
        if count == 0 { return (0xFFFF, 16) }
        return (mask, count)
    }

    /// 识别顶/底连续未变化区（允许输入框内闪烁光标等单分区微抖动，同时严防纯色段落留白被误锁为 Sticky 栏）
    static func detectStaticMargins(
        a: [ScrollRowSig],
        b: [ScrollRowSig],
        height: Int
    ) -> (matchTop: Int, matchBottom: Int, stickyTop: Int, stickyBottom: Int) {
        let limit = height * 30 / 100

        func scanEdge(fromBottom: Bool) -> (span: Int, isSticky: Bool) {
            var strictSpan = 0
            var strictTextured = 0
            var totalTextured = 0
            var flickerRun = 0
            for offset in 0..<limit {
                let y = fromBottom ? (height - 1 - offset) : offset
                let changed = a[y].changedBandCount(to: b[y], threshold: 10)
                let isTex = a[y].grad >= 3
                if changed == 0 && a[y].fullDiff(to: b[y]) <= 6 {
                    flickerRun = 0
                    if isTex { totalTextured += 1 }
                    strictSpan = offset + 1
                    strictTextured = totalTextured
                } else if changed <= 1 && flickerRun < 36 {
                    flickerRun += 1
                    if isTex { totalTextured += 1 }
                } else {
                    break
                }
            }
            let isSticky = strictSpan >= 10 && strictTextured >= max(3, strictSpan / 14)
            return (strictSpan, isSticky)
        }

        let top = scanEdge(fromBottom: false)
        let bot = scanEdge(fromBottom: true)
        return (
            matchTop: top.span,
            matchBottom: bot.span,
            stickyTop: top.isSticky ? top.span : 0,
            stickyBottom: bot.isSticky ? bot.span : 0
        )
    }

    /// 根据已知位移 `dy > 0` 探测视口内的局部悬浮静态障碍行（如 ChatGPT 的悬浮 `↓` 置底键、角落 FAB），
    /// 并优先在视口中上部无悬浮障碍的洁净带内选定内部切割缝 `seamY`。
    static func pickCleanSeamY(
        anchor: [ScrollRowSig],
        curr: [ScrollRowSig],
        dy: Int,
        workTop: Int,
        workBottom: Int
    ) -> Int {
        let workH = workBottom - workTop
        let preferred = workTop + (workH * 43 / 100)
        guard workH >= 96, dy > 0 else { return preferred }

        var blocked = [Bool](repeating: false, count: workH)
        for relY in 0..<workH {
            let y = workTop + relY
            let ay = y + dy
            guard ay < workBottom else { continue }
            for b in 0..<16 {
                let staticDiff = abs(Int32(anchor[y].bands[b] - curr[y].bands[b]))
                    + abs(Int32(anchor[y].chroma[b] - curr[y].chroma[b]))
                guard staticDiff <= 10 else { continue }
                let hasDetail = curr[y].energy[b] >= 8 || anchor[y].energy[b] >= 8
                guard hasDetail else { continue }
                let scrollDiff = abs(Int32(anchor[ay].bands[b] - curr[y].bands[b]))
                    + abs(Int32(anchor[ay].chroma[b] - curr[y].chroma[b]))
                if scrollDiff >= 36 {
                    blocked[relY] = true
                    break
                }
            }
        }

        // 上下各膨胀 10px 安全缓冲
        var padded = blocked
        for i in 0..<workH where blocked[i] {
            let lo = max(0, i - 10), hi = min(workH - 1, i + 10)
            for j in lo...hi { padded[j] = true }
        }

        let minRel = max(20, workH * 24 / 100)
        let maxRel = min(workH - 24, workH * 58 / 100)
        guard minRel <= maxRel else { return preferred }
        let prefRel = min(max(preferred - workTop, minRel), maxRel)

        func isBandClean(at rel: Int) -> Bool {
            let lo = max(0, rel - 20), hi = min(workH - 1, rel + 8)
            for j in lo...hi where padded[j] { return false }
            return true
        }

        for delta in 0...(maxRel - minRel) {
            if prefRel - delta >= minRel && isBandClean(at: prefRel - delta) { return workTop + prefRel - delta }
            if delta > 0 && prefRel + delta <= maxRel && isBandClean(at: prefRel + delta) { return workTop + prefRel + delta }
        }
        return workTop + prefRel
    }

    /// 检测可滚区最底端 `depth` 像素是否为几乎无纹理的纯色空白带（用于精准识别 macOS 触控板触底橡皮筋回弹空白）
    static func isBlankRubberBand(rows: [ScrollRowSig], workBottom: Int, depth: Int) -> Bool {
        guard depth >= 4, workBottom > depth, workBottom <= rows.count else { return false }
        let startY = workBottom - depth
        var uniformRows = 0
        for y in startY..<workBottom {
            let r = rows[y]
            var maxEnergy: Int16 = 0
            for b in 0..<16 { if r.energy[b] > maxEnergy { maxEnergy = r.energy[b] } }
            let flatRow = r.grad <= 2 && maxEnergy <= 4
            let smoothNext = (y + 1 >= workBottom) || (r.fullDiff(to: rows[y + 1]) <= 3)
            if flatRow && smoothNext { uniformRows += 1 }
        }
        return uniformRows * 100 >= depth * 90
    }
}
