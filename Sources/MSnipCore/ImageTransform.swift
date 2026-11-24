import CoreGraphics
import Foundation

/// 无损像素几何变换与多贴图边缘磁吸对齐纯算法库（保留原生 Display P3 / RGB ICC 色彩空间）
public enum ImageTransform {
    /// 顺时针无损旋转 90°（精确交换宽高物理像素，零插值模糊）
    public static func rotateClockwise90(_ image: CGImage) -> CGImage? {
        let srcW = image.width, srcH = image.height
        guard srcW > 0, srcH > 0 else { return nil }
        let dstW = srcH, dstH = srcW
        let cs = resolvedOutputColorSpace(for: image)
        guard let ctx = CGContext(
            data: nil, width: dstW, height: dstH, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .none
        // CoreGraphics 左下角原点下：旋转 -90° 后平移 (0, dstH) 使原图左上角落至新图右上角
        ctx.translateBy(x: 0, y: CGFloat(dstH))
        ctx.rotate(by: -.pi / 2.0)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: srcW, height: srcH))
        return ctx.makeImage()
    }

    /// 逆时针无损旋转 90°（与 `rotateClockwise90` 互为严格像素逆变换）
    public static func rotateCounterClockwise90(_ image: CGImage) -> CGImage? {
        let srcW = image.width, srcH = image.height
        guard srcW > 0, srcH > 0 else { return nil }
        let dstW = srcH, dstH = srcW
        let cs = resolvedOutputColorSpace(for: image)
        guard let ctx = CGContext(
            data: nil, width: dstW, height: dstH, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .none
        ctx.translateBy(x: CGFloat(dstW), y: 0)
        ctx.rotate(by: .pi / 2.0)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: srcW, height: srcH))
        return ctx.makeImage()
    }

    /// 水平镜像翻转（零插值模糊）
    public static func flipHorizontal(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let cs = resolvedOutputColorSpace(for: image)
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .none
        ctx.translateBy(x: CGFloat(w), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// 计算多贴图窗口拖动时的边缘磁吸位置（独立对齐 X/Y 轴上的兄弟贴图边与屏幕可视区域边）
    public static func snapPinOrigin(
        _ proposed: CGPoint,
        size: CGSize,
        siblingFrames: [CGRect],
        visibleBounds: CGRect,
        threshold: CGFloat = 8.0
    ) -> CGPoint {
        guard threshold > 0 else { return proposed }
        var xTargets: [CGFloat] = [visibleBounds.minX, visibleBounds.maxX]
        var yTargets: [CGFloat] = [visibleBounds.minY, visibleBounds.maxY]
        for sib in siblingFrames {
            xTargets.append(contentsOf: [sib.minX, sib.maxX])
            yTargets.append(contentsOf: [sib.minY, sib.maxY])
        }

        var bestDx: CGFloat = 0
        var minAbsDx = threshold + 0.001
        let curMinX = proposed.x, curMaxX = proposed.x + size.width
        for tx in xTargets {
            let dLeft = tx - curMinX
            if abs(dLeft) < minAbsDx { minAbsDx = abs(dLeft); bestDx = dLeft }
            let dRight = tx - curMaxX
            if abs(dRight) < minAbsDx { minAbsDx = abs(dRight); bestDx = dRight }
        }

        var bestDy: CGFloat = 0
        var minAbsDy = threshold + 0.001
        let curMinY = proposed.y, curMaxY = proposed.y + size.height
        for ty in yTargets {
            let dBottom = ty - curMinY
            if abs(dBottom) < minAbsDy { minAbsDy = abs(dBottom); bestDy = dBottom }
            let dTop = ty - curMaxY
            if abs(dTop) < minAbsDy { minAbsDy = abs(dTop); bestDy = dTop }
        }

        return CGPoint(x: proposed.x + bestDx, y: proposed.y + bestDy)
    }

    private static func resolvedOutputColorSpace(for image: CGImage) -> CGColorSpace {
        if let cs = image.colorSpace, cs.model == .rgb, cs.supportsOutput {
            return cs
        }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }
}
