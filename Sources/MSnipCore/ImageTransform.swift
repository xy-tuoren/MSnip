import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// 无损像素几何变换与多贴图边缘磁吸对齐纯算法库（保留原生 Display P3 / RGB ICC 色彩空间）
public enum ImageTransform {
    /// 将 `CGImage.cropping(to:)` 子图拷贝为独立紧致内存缓冲，避免小截图强引用整块 5K 全屏 `CGDataProvider`（保留原生色域）
    public static func detachedCopy(_ image: CGImage) -> CGImage {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(
                  data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: resolvedOutputColorSpace(for: image),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return image }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

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

    /// 计算贴图在可视屏幕内的自适应显示框与初始缩放比（原图超宽/超高或居中贴图时自动等比缩小不超出屏幕，保留原始高清像素）
    public static func fittedPinRect(
        baseSize: CGSize,
        visibleBounds: CGRect,
        preferredOrigin: CGPoint? = nil,
        cascadeOffset: CGPoint = .zero,
        marginX: CGFloat = 36,
        marginY: CGFloat = 52
    ) -> (frame: CGRect, zoom: CGFloat) {
        let bw = max(8, baseSize.width)
        let bh = max(8, baseSize.height)
        let availW = max(80, visibleBounds.width - marginX * 2)
        let availH = max(80, visibleBounds.height - marginY * 2)
        let exceedsVisible = bw > (visibleBounds.width - 24) || bh > (visibleBounds.height - 48)
        let shouldFit = (preferredOrigin == nil) || exceedsVisible

        let zoom: CGFloat = shouldFit
            ? min(1.0, min(availW / bw, availH / bh))
            : 1.0
        let w = max(24, (bw * zoom).rounded())
        let h = max(24, (bh * zoom).rounded())

        var ox: CGFloat
        var oy: CGFloat
        if let pref = preferredOrigin, zoom >= 0.999 {
            ox = pref.x
            oy = pref.y
        } else {
            ox = visibleBounds.midX - w * 0.5 + cascadeOffset.x
            oy = visibleBounds.midY - h * 0.5 + cascadeOffset.y
            let padX = min(16, max(0, (visibleBounds.width - w) * 0.5))
            let padY = min(16, max(0, (visibleBounds.height - h) * 0.5))
            let minX = visibleBounds.minX + padX, maxX = visibleBounds.maxX - w - padX
            let minY = visibleBounds.minY + padY, maxY = visibleBounds.maxY - h - padY
            ox = minX <= maxX ? min(max(ox, minX), maxX) : (visibleBounds.midX - w * 0.5)
            oy = minY <= maxY ? min(max(oy, minY), maxY) : (visibleBounds.midY - h * 0.5)
        }
        return (CGRect(x: ox, y: oy, width: w, height: h), zoom)
    }

    /// 拖动贴图任意 4 角或 4 边时的等比缩放矩形计算（macOS 左下角原点坐标系，严格锁定对角/对边锚点防跳动）
    public static func resizedPinFrame(
        edge: PinResizeEdge,
        initialFrame: CGRect,
        baseSize: CGSize,
        delta: CGPoint,
        minZoom: CGFloat = 0.08,
        maxZoom: CGFloat = 4.0
    ) -> (frame: CGRect, zoom: CGFloat) {
        let bw = max(8, baseSize.width)
        let bh = max(8, baseSize.height)
        let initZoom = max(0.01, initialFrame.width / bw)

        let proposedZoom: CGFloat
        switch edge {
        case .right:
            proposedZoom = (initialFrame.width + delta.x) / bw
        case .left:
            proposedZoom = (initialFrame.width - delta.x) / bw
        case .top:
            proposedZoom = (initialFrame.height + delta.y) / bh
        case .bottom:
            proposedZoom = (initialFrame.height - delta.y) / bh
        case .topRight, .topLeft, .bottomRight, .bottomLeft:
            let sx: CGFloat = (edge == .topRight || edge == .bottomRight) ? 1.0 : -1.0
            let sy: CGFloat = (edge == .topRight || edge == .topLeft) ? 1.0 : -1.0
            let vx = sx * bw
            let vy = sy * bh
            let denom = max(1.0, vx * vx + vy * vy)
            proposedZoom = initZoom + (delta.x * vx + delta.y * vy) / denom
        }

        let clampedZoom = min(maxZoom, max(minZoom, proposedZoom))
        let newW = max(24, (bw * clampedZoom).rounded())
        let newH = max(24, (bh * clampedZoom).rounded())

        let originX: CGFloat = (edge == .left || edge == .topLeft || edge == .bottomLeft) ? (initialFrame.maxX - newW)
            : (edge == .right || edge == .topRight || edge == .bottomRight) ? initialFrame.minX : (initialFrame.midX - newW * 0.5)
        let originY: CGFloat = (edge == .bottom || edge == .bottomLeft || edge == .bottomRight) ? (initialFrame.maxY - newH)
            : (edge == .top || edge == .topLeft || edge == .topRight) ? initialFrame.minY : (initialFrame.midY - newH * 0.5)
        return (CGRect(x: originX, y: originY, width: newW, height: newH), clampedZoom)
    }

    private static func resolvedOutputColorSpace(for image: CGImage) -> CGColorSpace {
        if let cs = image.colorSpace, cs.model == .rgb, cs.supportsOutput { return cs }
        return CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }
}

/// 贴图窗口 8 向边角缩放热区枚举（采用 macOS 窗口标准左下角原点坐标系：`+Y` 朝上）
public enum PinResizeEdge: CaseIterable, Equatable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// 在窗口局部坐标系中检测是否命中 4 角或 4 边拖拽热区（四角优先，支持向外延伸 `outerSlop` 覆盖外发光描边）
    public static func hitTest(
        point: CGPoint,
        in bounds: CGRect,
        cornerSize: CGFloat = 14,
        edgeThickness: CGFloat = 7,
        outerSlop: CGFloat = 0
    ) -> PinResizeEdge? {
        let hitBounds = outerSlop > 0 ? bounds.insetBy(dx: -outerSlop, dy: -outerSlop) : bounds
        guard hitBounds.contains(point), bounds.width >= 32, bounds.height >= 32 else { return nil }
        let minDim = min(bounds.width, bounds.height)
        let c = min(cornerSize, max(6, minDim * 0.28)), e = min(edgeThickness, max(4, minDim * 0.18))
        let dL = point.x - bounds.minX, dR = bounds.maxX - point.x
        let dB = point.y - bounds.minY, dT = bounds.maxY - point.y
        if dL <= c && dT <= c { return .topLeft }
        if dR <= c && dT <= c { return .topRight }
        if dL <= c && dB <= c { return .bottomLeft }
        if dR <= c && dB <= c { return .bottomRight }
        if dL <= e { return .left }
        if dR <= e { return .right }
        if dT <= e { return .top }
        if dB <= e { return .bottom }
        return nil
    }
}

/// 贴图外置悬浮操作条定位、桥接热区与窗口遮挡纯几何判定（100% 可单测）
public enum PinHoverGeometry {
    /// 闭区间命中判断，避免光标紧贴 `maxX` / `maxY` 物理边缘时因半开区间漏检
    public static func containsPointInclusive(_ rect: CGRect, _ point: CGPoint) -> Bool {
        guard !rect.isNull, !rect.isEmpty else { return false }
        return point.x >= rect.minX && point.x <= rect.maxX
            && point.y >= rect.minY && point.y <= rect.maxY
    }

    /// 计算外置悬浮条在目标屏幕可见区内的锚定矩形（优先置顶右对齐，触顶自动翻至贴图下方）
    public static func hoverBarFrame(
        anchoringTo pinFrame: CGRect,
        barSize: CGSize,
        visibleBounds vf: CGRect,
        gap: CGFloat = 5
    ) -> CGRect {
        let minX = vf.minX + 4
        let maxX = max(minX, vf.maxX - barSize.width - 4)
        let x = min(max(minX, round(pinFrame.maxX - barSize.width)), maxX)
        let aboveY = round(pinFrame.maxY + gap)
        let belowY = round(pinFrame.minY - barSize.height - gap)
        let y = (aboveY + barSize.height <= vf.maxY - 2) ? aboveY : max(vf.minY + 4, belowY)
        return CGRect(x: x, y: y, width: barSize.width, height: barSize.height)
    }

    /// 贴图与悬浮条之间的窄桥接走廊（仅覆盖悬浮条下方/上方的 5pt 间隙，防止滑向操作条途中误隐藏）
    public static func bridgeCorridor(
        pinFrame: CGRect,
        barFrame: CGRect,
        horizontalSlop: CGFloat = 6
    ) -> CGRect {
        let minX = barFrame.minX - horizontalSlop
        let width = barFrame.width + horizontalSlop * 2
        if barFrame.minY >= pinFrame.maxY {
            return CGRect(x: minX, y: pinFrame.maxY - 2, width: width, height: (barFrame.minY - pinFrame.maxY) + 4)
        }
        if barFrame.maxY <= pinFrame.minY {
            return CGRect(x: minX, y: barFrame.maxY - 2, width: width, height: (pinFrame.minY - barFrame.maxY) + 4)
        }
        return barFrame.insetBy(dx: -2, dy: -2)
    }

    /// 光标是否落在贴图本体、可见悬浮条本体或二者桥接走廊内
    public static func isPointInHoverZone(
        point: CGPoint,
        pinFrame: CGRect,
        barFrame: CGRect?,
        isBarVisible: Bool
    ) -> Bool {
        if containsPointInclusive(pinFrame, point) { return true }
        guard isBarVisible, let bar = barFrame else { return false }
        return containsPointInclusive(bar, point)
            || containsPointInclusive(bridgeCorridor(pinFrame: pinFrame, barFrame: bar), point)
    }

    /// 判断目标窗口在当前光标点是否未被更高层级窗口遮挡（同时兼容独立窗口圆角/透明 PNG 的透明像素穿透）
    public static func isWindowUncovered(
        pinWindowNumber: Int,
        topWindowNumber: Int,
        belowPinWindowNumber: Int
    ) -> Bool {
        topWindowNumber == pinWindowNumber || topWindowNumber == belowPinWindowNumber
    }
}

// MARK: - EXIF 方向校正与安全解码

/// 带 EXIF 方向自动扶正与零全局缓存的图像读取及微缩略图工具（彻底杜绝 iPhone 竖拍 HEIC/JPEG 导入倒置与大图主线程重采样）
public enum ImageOrientationLoader {
    /// 读取文件并自动应用 EXIF 旋转/镜像方向（不写入 ImageIO 全局缓存，零常驻内存）
    public static func loadOrientedCGImage(from url: URL, maxPixelSize: Int? = nil) -> CGImage? {
        let srcOpts: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOpts as CFDictionary) else { return nil }

        // 当指定最大边长或文件存在非默认 EXIF 方向时，统一通过 CoreGraphics Transform 缩略管线一步扶正
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let orient = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        let pixelW = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let pixelH = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let naturalMax = max(1, max(pixelW, pixelH))

        if maxPixelSize != nil || (orient != 1 && naturalMax > 1) {
            let targetMax = maxPixelSize ?? naturalMax
            let thumbOpts: [CFString: Any] = [
                kCGImageSourceShouldCache: false,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(16, targetMax)
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) {
                return ImageTransform.detachedCopy(cg)
            }
        }
        guard let raw = CGImageSourceCreateImageAtIndex(src, 0, srcOpts as CFDictionary) else { return nil }
        return ImageTransform.detachedCopy(raw)
    }

    /// 将高分辨率 `CGImage` 一次性降采样为轻量预览缩略图（避免在胶片条/预览卡上反复重采样 5K 位图）
    public static func makeThumbnailNSImage(from cgImage: CGImage, maxPixelSize: Int = 240) -> NSImage {
        let w = cgImage.width, h = cgImage.height
        let longest = max(1, max(w, h))
        let displayCG: CGImage
        if longest > maxPixelSize {
            let ratio = CGFloat(maxPixelSize) / CGFloat(longest)
            let nw = max(1, Int((CGFloat(w) * ratio).rounded()))
            let nh = max(1, Int((CGFloat(h) * ratio).rounded()))
            let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            if let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .medium
                ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: nw, height: nh))
                displayCG = ctx.makeImage() ?? cgImage
            } else {
                displayCG = cgImage
            }
        } else {
            displayCG = cgImage
        }
        return NSImage(cgImage: displayCG, size: NSSize(width: CGFloat(displayCG.width) * 0.5, height: CGFloat(displayCG.height) * 0.5))
    }
}
