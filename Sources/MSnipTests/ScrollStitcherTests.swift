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

    testScrollStitcherDarkModeFloatingDownButtonAndMicroScroll()
}

/// 复现真实 ChatGPT 暗色模式长截图场景：
/// - 深灰 `#212121` 背景 + 稀疏白色文字/表格线（易诱发旧算法暗色背景误匹配）
/// - 底部固定输入框 + 输入框内每帧闪烁光标
/// - 底部输入框上方居中悬浮 `↓` 置底圆钮（旧算法逐帧底边切片会将其反复盖章 10+ 次）
/// - 35 帧微小步长平滑滚轮（+14..+20px/帧）+ 触底后 `↓` 按钮淡出静默刷新
private func renderDarkChatViewport(
    w: Int,
    h: Int,
    stickyBottomH: Int,
    scrollY: Int,
    showFloatingButton: Bool,
    cursorOn: Bool
) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)

    // 深灰底色 #212121
    ctx.setFillColor(CGColor(srgbRed: 33.0 / 255.0, green: 33.0 / 255.0, blue: 33.0 / 255.0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

    // 稀疏唯一正文文字块与表格分割线（每个 docY 段落都有独特位置与宽度分布）
    let bodyH = h - stickyBottomH
    for vy in 0..<bodyH {
        let docY = scrollY + vy
        let rowInBlock = docY % 38
        let blockIdx = docY / 38
        if rowInBlock == 0 {
            ctx.setFillColor(CGColor(srgbRed: 0.25, green: 0.25, blue: 0.27, alpha: 1))
            ctx.fill(CGRect(x: 16, y: vy, width: w - 32, height: 1))
        } else if rowInBlock >= 10 && rowInBlock <= 20 {
            ctx.setFillColor(CGColor(srgbRed: 0.90, green: 0.90, blue: 0.92, alpha: 1))
            let segCount = 3 + (blockIdx % 4)
            for s in 0..<segCount {
                let hash = (blockIdx * 37 + s * 53 + (rowInBlock / 3) * 19)
                let sx = 20 + (hash * 17) % max(40, w - 90)
                let sw = 24 + (hash % 36)
                ctx.fill(CGRect(x: sx, y: vy, width: sw, height: 2))
            }
        }
    }

    // 底部上方居中悬浮 `↓` 置底圆钮（使用鲜艳青蓝色标记，便于单测逐像素校验零残留）
    if showFloatingButton {
        let btnSize = 42
        let bx = (w - btnSize) / 2
        let by = bodyH - btnSize - 16
        ctx.setFillColor(CGColor(srgbRed: 0.10, green: 0.72, blue: 0.98, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: bx, y: by, width: btnSize, height: btnSize))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: w / 2 - 2, y: by + 11, width: 4, height: 20))
    }

    // 底部固定输入栏 + 闪烁光标
    if stickyBottomH > 0 {
        let fy = h - stickyBottomH
        ctx.setFillColor(CGColor(srgbRed: 0.16, green: 0.16, blue: 0.18, alpha: 1))
        ctx.fill(CGRect(x: 0, y: fy, width: w, height: stickyBottomH))
        ctx.setFillColor(CGColor(srgbRed: 0.24, green: 0.24, blue: 0.27, alpha: 1))
        ctx.fill(CGRect(x: 18, y: fy + 16, width: w - 36, height: stickyBottomH - 28))
        ctx.setFillColor(CGColor(srgbRed: 0.20, green: 0.56, blue: 0.96, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: w - 54, y: fy + 24, width: 26, height: 26))
        if cursorOn {
            ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.98, alpha: 1))
            ctx.fill(CGRect(x: 44, y: fy + 28, width: 3, height: 18))
        }
    }
    return ctx.makeImage()!
}

private func testScrollStitcherDarkModeFloatingDownButtonAndMicroScroll() {
    let w = 420, h = 520, botH = 84
    let stitcher = ScrollStitcher()
    var scrollY = 0
    _ = stitcher.ingest(frame: renderDarkChatViewport(w: w, h: h, stickyBottomH: botH, scrollY: 0, showFloatingButton: true, cursorOn: true))

    // 模拟高帧率平滑滚轮：35 帧微小位移 (+14..+20px)，每帧光标闪烁，底部一直悬浮 `↓` 按钮
    let steps = [16, 18, 14, 20, 16, 18, 16, 20, 14, 18, 16, 20, 18, 16, 14, 20, 18, 16, 18, 16, 20, 14, 18, 16, 20, 18, 16, 14, 20, 18, 16, 20, 18, 16, 14]
    for (idx, step) in steps.enumerated() {
        scrollY += step
        let frame = renderDarkChatViewport(w: w, h: h, stickyBottomH: botH, scrollY: scrollY, showFloatingButton: true, cursorOn: idx % 2 == 0)
        let res = stitcher.ingest(frame: frame)
        if case .appended = res {
            // OK
        } else {
            check(false, "暗色模式平滑微滚动第 \(idx) 帧 (scrollY=\(scrollY)) 应成功拼接，实际: \(res)")
            break
        }
    }

    // 模拟滚到底部后 150ms：位移不变 (dy=0)，但悬浮 `↓` 按钮自然淡出
    let settled = renderDarkChatViewport(w: w, h: h, stickyBottomH: botH, scrollY: scrollY, showFloatingButton: false, cursorOn: false)
    _ = stitcher.ingest(frame: settled)

    let expectedH = h + scrollY
    guard let finalImg = stitcher.renderFinalImage() else {
        check(false, "暗色模式悬浮按钮长截图应成功导出图像")
        return
    }
    check(finalImg.width == w && finalImg.height == expectedH,
          "35 帧微滚动拼接总高度应零漂移精确等于 \(expectedH)px，实际: \(finalImg.height)px")

    // 逐行扫描整张正文中心列：断言全图正文区 0 颗悬浮 `↓` 按钮青蓝色像素残留
    let sampler = PixelSampler(cgImage: finalImg)
    var leakedCyanPixels = 0
    for y in 0..<(finalImg.height - botH) {
        for x in (w / 2 - 24)...(w / 2 + 24) {
            let (r, g, b) = sampler.sampleRGB(px: x, py: y)
            if b > 180 && g > 130 && r < 80 { leakedCyanPixels += 1 }
        }
    }
    check(leakedCyanPixels == 0, "暗色模式长截图正文与触底淡出尾段不应残留任何悬浮 ↓ 按钮重影像素，实际残留: \(leakedCyanPixels)")

    // 校验暗色模式跨整屏无关内容绝不会被 88% 黑底稀释误匹配
    let unrelated = renderDarkChatViewport(w: w, h: h, stickyBottomH: botH, scrollY: scrollY + 2400, showFloatingButton: true, cursorOn: true)
    check(stitcher.ingest(frame: unrelated) == .mismatchLostOverlap, "暗色模式无重叠跳跃帧应严格拦截为 mismatchLostOverlap")

    // 校验长图实时尾随预览：超长图 (8× 高宽比) 仍保持清晰可读宽度，不压扁成细线
    let tallPreview = stitcher.renderPreviewImage(maxSidePx: 680)
    check(tallPreview != nil && tallPreview!.width >= 200, "长图实时预览应保持清晰可读宽度，实际: \(tallPreview?.width ?? 0)")

    testScrollStitcherSparseMicroScrollAndRubberBand()
}

/// 校验极稀疏暗色页微小步进不被尾段静默刷新误吞 + macOS 触控板触底橡皮筋空白回弹自动撤消
private func testScrollStitcherSparseMicroScrollAndRubberBand() {
    let w = 320, h = 360
    func renderSparseFrame(scrollY: Int, maxDocH: Int) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(CGColor(srgbRed: 33.0 / 255.0, green: 33.0 / 255.0, blue: 33.0 / 255.0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // 仅在稀疏位置绘制少量高对比度文字条（超过 95% 区域为纯深灰背景）
        let lines = [52, 134, 240, 345, 420]
        ctx.setFillColor(CGColor(srgbRed: 0.92, green: 0.92, blue: 0.94, alpha: 1))
        for (idx, docY) in lines.enumerated() where docY < maxDocH {
            let vy = docY - scrollY
            if vy >= 0 && vy + 6 <= h {
                ctx.fill(CGRect(x: 24 + idx * 14, y: vy, width: 120 + (idx % 3) * 24, height: 5))
            }
        }
        return ctx.makeImage()!
    }

    // 1) 极稀疏页面微滚动（每帧仅 +5px / +6px）绝不能被 isSettledTailRefresh 误吞
    let s1 = ScrollStitcher()
    _ = s1.ingest(frame: renderSparseFrame(scrollY: 0, maxDocH: 900))
    var sy = 0
    for step in [5, 6, 5, 6, 6, 5, 6, 5] {
        sy += step
        let res = s1.ingest(frame: renderSparseFrame(scrollY: sy, maxDocH: 900))
        if case .appended = res {} else {
            check(false, "极稀疏页面微小步进 +\(step)px 不应被误吞为 \(res)")
            break
        }
    }
    check(s1.totalHeightPx == h + sy, "极稀疏页面连续微滚总高度应精确等于 \(h + sy)px，实际: \(s1.totalHeightPx)px")

    // 2) macOS 触控板触底橡皮筋回弹：滚到真实底部后多拉出 +54px 纯空白，紧接着弹回真实底部，空白应自动撤消
    let s2 = ScrollStitcher()
    let trueDocH = 480
    let trueMaxScroll = trueDocH - h // 120px
    _ = s2.ingest(frame: renderSparseFrame(scrollY: 0, maxDocH: trueDocH))
    _ = s2.ingest(frame: renderSparseFrame(scrollY: 80, maxDocH: trueDocH))
    _ = s2.ingest(frame: renderSparseFrame(scrollY: trueMaxScroll, maxDocH: trueDocH))
    check(s2.totalHeightPx == trueDocH, "滚至真实底部时高度应为 \(trueDocH)px，实际: \(s2.totalHeightPx)px")
    // 触控板惯性超滚 +54px（底部拉出 54px 纯空白橡皮筋区）
    _ = s2.ingest(frame: renderSparseFrame(scrollY: trueMaxScroll + 54, maxDocH: trueDocH))
    // 100ms 后系统自动弹回真实底部 trueMaxScroll
    let bounce = s2.ingest(frame: renderSparseFrame(scrollY: trueMaxScroll, maxDocH: trueDocH))
    check(bounce == .scrolledBackward && s2.totalHeightPx == trueDocH,
          "触底橡皮筋纯空白回弹后应自动撤消多余空白并回归真实高度 \(trueDocH)px，实际: \(s2.totalHeightPx)px (\(bounce))")
}
