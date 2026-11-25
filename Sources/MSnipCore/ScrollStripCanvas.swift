import CoreGraphics
import Foundation

/// 滚动长截图无损切片画布存储（维护已提交洁净条带 + 动态可替换尾段，全程保留源帧 Display P3 / ICC 色域）
struct ScrollStripCanvas {
    var strips: [CGImage] = []
    var previewStrips: [CGImage] = []
    var bodyHeightPx: Int = 0
    var liveTailStrip: CGImage?
    var previewTailStrip: CGImage?

    var isEmpty: Bool { strips.isEmpty }
    var totalHeightPx: Int { bodyHeightPx + (liveTailStrip?.height ?? 0) }

    mutating func removeAll() {
        strips.removeAll()
        previewStrips.removeAll()
        bodyHeightPx = 0
        liveTailStrip = nil
        previewTailStrip = nil
    }

    mutating func appendBodyStrip(from src: CGImage, y: Int, height: Int, width: Int) {
        guard height > 0, let s = Self.detachCopy(src, rect: CGRect(x: 0, y: y, width: width, height: height)) else { return }
        strips.append(s)
        previewStrips.append(Self.makePreviewSlice(s))
        bodyHeightPx += s.height
    }

    mutating func updateLiveTail(from frame: CGImage, topY: Int, width: Int, frameHeight: Int) {
        let clampedY = min(max(0, topY), frameHeight - 1)
        let tailH = frameHeight - clampedY
        let tail = Self.detachCopy(frame, rect: CGRect(x: 0, y: clampedY, width: width, height: tailH))
        liveTailStrip = tail
        previewTailStrip = tail.map { Self.makePreviewSlice($0) }
    }

    mutating func restore(stripCount: Int, bodyHeight: Int, liveTail: CGImage?, previewTail: CGImage?) {
        if strips.count > stripCount {
            strips.removeLast(strips.count - stripCount)
            previewStrips.removeLast(previewStrips.count - stripCount)
        }
        bodyHeightPx = bodyHeight
        liveTailStrip = liveTail
        previewTailStrip = previewTail
    }

    /// 裁剪正文尾部指定像素（保留底栏不动，优先从动态尾段裁剪，再从已提交条带裁剪）
    mutating func trimTail(pixels: Int, width: Int, frameHeight: Int, lockedBottomFixed: Int) -> Bool {
        guard pixels > 0, !strips.isEmpty else { return false }
        let minKeep = max(32, frameHeight / 2)
        var remaining = min(pixels, max(0, totalHeightPx - lockedBottomFixed - minKeep))
        guard remaining > 0 else { return false }

        if let tail = liveTailStrip {
            let tailBodyH = max(0, tail.height - lockedBottomFixed)
            let cutTail = min(remaining, tailBodyH)
            if cutTail > 0 {
                let keepBody = tailBodyH - cutTail
                if lockedBottomFixed == 0 {
                    if keepBody > 0, let cropped = Self.detachCopy(tail, rect: CGRect(x: 0, y: 0, width: width, height: keepBody)) {
                        liveTailStrip = cropped; previewTailStrip = Self.makePreviewSlice(cropped)
                    } else {
                        liveTailStrip = nil; previewTailStrip = nil
                    }
                } else {
                    let topPart = keepBody > 0 ? Self.detachCopy(tail, rect: CGRect(x: 0, y: 0, width: width, height: keepBody)) : nil
                    let footPart = Self.detachCopy(tail, rect: CGRect(x: 0, y: tailBodyH, width: width, height: lockedBottomFixed))
                    let merged = Self.composeStrips(
                        widthPx: width, totalHeightPx: keepBody + lockedBottomFixed,
                        strips: topPart.map { [$0] } ?? [], previewStrips: [],
                        tail: footPart, previewTail: nil, scaleDownToMaxSide: nil, usePreviewSlices: false
                    )
                    liveTailStrip = merged; previewTailStrip = merged.map { Self.makePreviewSlice($0) }
                }
                remaining -= cutTail
            }
        }
        while remaining > 0, let last = strips.last {
            if last.height <= remaining, strips.count > 1 {
                strips.removeLast(); previewStrips.removeLast()
                bodyHeightPx -= last.height; remaining -= last.height
            } else {
                let keepH = max(16, last.height - remaining)
                if let cropped = Self.detachCopy(last, rect: CGRect(x: 0, y: 0, width: last.width, height: keepH)) {
                    strips[strips.count - 1] = cropped
                    previewStrips[previewStrips.count - 1] = Self.makePreviewSlice(cropped)
                    bodyHeightPx -= (last.height - keepH)
                }
                break
            }
        }
        return true
    }

    func compose(widthPx: Int, scaleDownToMaxSide: Int?, usePreviewSlices: Bool) -> CGImage? {
        Self.composeStrips(
            widthPx: widthPx, totalHeightPx: totalHeightPx,
            strips: strips, previewStrips: previewStrips,
            tail: liveTailStrip, previewTail: previewTailStrip,
            scaleDownToMaxSide: scaleDownToMaxSide, usePreviewSlices: usePreviewSlices
        )
    }

    // MARK: - Lossless Pixel Helpers

    private static func resolvedColorSpace(for image: CGImage?) -> CGColorSpace {
        if let cs = image?.colorSpace, cs.model == .rgb { return cs }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    static func detachCopy(_ src: CGImage, rect: CGRect) -> CGImage? {
        guard let cropped = src.cropping(to: rect), cropped.width > 0, cropped.height > 0 else { return nil }
        let w = cropped.width, h = cropped.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: resolvedColorSpace(for: src), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func makePreviewSlice(_ src: CGImage, maxWidthPx: Int = 340) -> CGImage {
        guard src.width > maxWidthPx else { return src }
        let ratio = CGFloat(maxWidthPx) / CGFloat(src.width)
        let ph = max(1, Int((CGFloat(src.height) * ratio).rounded()))
        guard let ctx = CGContext(
            data: nil, width: maxWidthPx, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
            space: resolvedColorSpace(for: src), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return src }
        ctx.interpolationQuality = .medium
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: maxWidthPx, height: ph))
        return ctx.makeImage() ?? src
    }

    static func composeStrips(
        widthPx fullW: Int,
        totalHeightPx fullH: Int,
        strips: [CGImage],
        previewStrips: [CGImage],
        tail: CGImage?,
        previewTail: CGImage?,
        scaleDownToMaxSide: Int?,
        usePreviewSlices: Bool
    ) -> CGImage? {
        guard fullW > 0, fullH > 0 else { return nil }
        var scale: CGFloat = 1.0
        if let maxSide = scaleDownToMaxSide, max(fullW, fullH) > maxSide {
            scale = CGFloat(maxSide) / CGFloat(max(fullW, fullH))
        }
        let outW = max(1, Int((CGFloat(fullW) * scale).rounded()))
        let outH = max(1, Int((CGFloat(fullH) * scale).rounded()))
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
            space: resolvedColorSpace(for: strips.first ?? tail), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = scale < 1.0 ? .medium : .none
        var cursorTopPx = 0
        for i in strips.indices {
            let ph = strips[i].height
            let tex = (usePreviewSlices && previewStrips.indices.contains(i)) ? previewStrips[i] : strips[i]
            let dstY = CGFloat(fullH - cursorTopPx - ph) * scale
            ctx.draw(tex, in: CGRect(x: 0, y: dstY, width: CGFloat(outW), height: CGFloat(ph) * scale))
            cursorTopPx += ph
        }
        if let tail {
            let ph = tail.height
            let tex = (usePreviewSlices ? previewTail : nil) ?? tail
            let dstY = CGFloat(fullH - cursorTopPx - ph) * scale
            ctx.draw(tex, in: CGRect(x: 0, y: dstY, width: CGFloat(outW), height: CGFloat(ph) * scale))
        }
        return ctx.makeImage()
    }
}
