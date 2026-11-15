import CoreGraphics
import Foundation
import MSnipCore

/// 生成带固定顶栏、固定底栏、动态右侧滚动条的模拟长网页帧，精确检验 ScrollStitcher 拼接精度
private func renderSyntheticScrollViewport(
    viewportW: Int,
    viewportH: Int,
    stickyTopH: Int,
    stickyBottomH: Int,
    scrollOffsetY: Int,
    totalDocBodyH: Int
) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: viewportW, height: viewportH, bitsPerComponent: 8, bytesPerRow: viewportW * 4,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // 切换为左上角原点以便直观绘制文档行
    ctx.translateBy(x: 0, y: CGFloat(viewportH))
    ctx.scaleBy(x: 1, y: -1)

    // 1) 绘制可滚动正文（每行有唯一确定性纹理图案，便于逐像素核对拼接结果是否错位或重影）
    let bodyViewportH = viewportH - stickyTopH - stickyBottomH
    for vy in 0..<bodyViewportH {
        let docY = scrollOffsetY + vy
        let r = CGFloat((docY * 7 + 31) % 220 + 20) / 255.0
        let g = CGFloat((docY * 13 + 67) % 210 + 25) / 255.0
        let b = CGFloat((docY * 19 + 113) % 200 + 30) / 255.0
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: stickyTopH + vy, width: viewportW, height: 1))

        // 模拟正文卡片与文字色块（高水平边缘能量 grad）
        let blockX = 24 + ((docY / 6) * 29) % 90
        ctx.setFillColor(CGColor(srgbRed: 1.0 - r * 0.7, green: 0.95, blue: 0.25 + b * 0.5, alpha: 1))
        ctx.fill(CGRect(x: blockX, y: stickyTopH + vy, width: 84, height: 1))
    }

    // 2) 绘制顶部 Sticky 导航栏（深蓝色 + 亮色图标块）
    if stickyTopH > 0 {
        ctx.setFillColor(CGColor(srgbRed: 0.10, green: 0.16, blue: 0.30, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: viewportW, height: stickyTopH))
        ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.85, blue: 0.25, alpha: 1))
        ctx.fill(CGRect(x: 20, y: 10, width: 60, height: max(4, stickyTopH - 20)))
    }

    // 3) 绘制底部 Sticky 输入栏（深灰色 + 发送按钮色块）
    if stickyBottomH > 0 {
        let fy = viewportH - stickyBottomH
        ctx.setFillColor(CGColor(srgbRed: 0.18, green: 0.19, blue: 0.22, alpha: 1))
        ctx.fill(CGRect(x: 0, y: fy, width: viewportW, height: stickyBottomH))
        ctx.setFillColor(CGColor(srgbRed: 0.20, green: 0.78, blue: 0.42, alpha: 1))
        ctx.fill(CGRect(x: viewportW - 90, y: fy + 8, width: 56, height: max(4, stickyBottomH - 16)))
    }

    // 4) 绘制最右侧随滚动位置移动的动态滚动条（检验右侧干扰屏蔽）
    let maxScroll = max(1, totalDocBodyH - bodyViewportH)
    let thumbY = stickyTopH + (bodyViewportH - 40) * min(scrollOffsetY, maxScroll) / maxScroll
    ctx.setFillColor(CGColor(srgbRed: 0.55, green: 0.55, blue: 0.58, alpha: 1))
    ctx.fill(CGRect(x: viewportW - 10, y: thumbY, width: 6, height: 40))

    return ctx.makeImage()!
}

func testScrollStitcherWithStickyChromeAndBackscroll() {
    let vw = 260, vh = 240
    let topH = 36, botH = 32
    let bodyViewH = vh - topH - botH // 172px
    let docH = 800

    let stitcher = ScrollStitcher()
    let f0 = renderSyntheticScrollViewport(viewportW: vw, viewportH: vh, stickyTopH: topH, stickyBottomH: botH, scrollOffsetY: 0, totalDocBodyH: docH)
    check(stitcher.ingest(frame: f0) == .initialized(widthPx: vw, heightPx: vh), "首帧应正确初始化尺寸")
    check(stitcher.ingest(frame: f0) == .unchanged, "完全静止的重复帧应跳过")

    // 依次向下滚动 +50px, +64px，中途故意往回滚 -25px，再向下滚 +75px（净超出前沿 +50px）
    let f1 = renderSyntheticScrollViewport(viewportW: vw, viewportH: vh, stickyTopH: topH, stickyBottomH: botH, scrollOffsetY: 50, totalDocBodyH: docH)
    let r1 = stitcher.ingest(frame: f1)
    check(r1 == .appended(addedPx: 50, totalHeightPx: vh + 50), "第一次滚动 +50px 应精确追加 50px，实际: \(r1)")

    let f2 = renderSyntheticScrollViewport(viewportW: vw, viewportH: vh, stickyTopH: topH, stickyBottomH: botH, scrollOffsetY: 114, totalDocBodyH: docH)
    let r2 = stitcher.ingest(frame: f2)
    check(r2 == .appended(addedPx: 64, totalHeightPx: vh + 114), "第二次滚动 +64px 应精确追加 64px，实际: \(r2)")

    // 模拟用户误触向上回滚到 89 (-25px)：不应重复追加
    let fBack = renderSyntheticScrollViewport(viewportW: vw, viewportH: vh, stickyTopH: topH, stickyBottomH: botH, scrollOffsetY: 89, totalDocBodyH: docH)
    check(stitcher.ingest(frame: fBack) == .scrolledBackward, "向上回滚应识别为 scrolledBackward 且不污染前沿")

    // 继续向下滚到 164（相对之前最高前沿 114 新增了 +50px！）
    let f3 = renderSyntheticScrollViewport(viewportW: vw, viewportH: vh, stickyTopH: topH, stickyBottomH: botH, scrollOffsetY: 164, totalDocBodyH: docH)
    let r3 = stitcher.ingest(frame: f3)
    check(r3 == .appended(addedPx: 50, totalHeightPx: vh + 164), "回滚后再向下滚应仅追加超出前沿的 +50px，实际: \(r3)")

    // 模拟一次跨整屏过快滚动（无重叠）应触发 mismatchLostOverlap
    let fTooFast = renderSyntheticScrollViewport(viewportW: vw, viewportH: vh, stickyTopH: topH, stickyBottomH: botH, scrollOffsetY: 600, totalDocBodyH: docH)
    check(stitcher.ingest(frame: fTooFast) == .mismatchLostOverlap, "跨整屏无重叠帧应返回 mismatchLostOverlap 告警")

    // 验证最终合成长图尺寸与中间像素无固定导航栏夹层
    let finalImg = stitcher.renderFinalImage()
    let expectedTotalH = topH + (bodyViewH + 164) + botH
    check(finalImg != nil && finalImg!.width == vw && finalImg!.height == expectedTotalH,
          "合成长图总高度应严格等于 顶栏+累积正文+底栏 (\(expectedTotalH)px)，实际: \(finalImg?.height ?? -1)")
}
