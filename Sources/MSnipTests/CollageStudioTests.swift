import CoreGraphics
import Foundation
import MSnipCore

func testCollageAlignmentAndAspectRatios() {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    func boxImg(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    // 1) 原寸居中对齐：小图 (100x60) + 大图 (300x200) 横拼不应强拉小图宽度，总宽应严格等于 20*2 + 100 + 16 + 300 = 456，总高 = 20*2 + 200 = 240
    let small = boxImg(100, 60)
    let large = boxImg(300, 200)
    let origCenterOpts = CollageOptions(
        layout: .horizontal, gapPx: 16, padPx: 20, cornerRadiusPx: 8,
        scaleAlignment: .originalCenter, aspectPreset: .auto
    )
    if let res = ImageCollageStitcher.stitch(images: [small, large], options: origCenterOpts) {
        check(res.width == 456 && res.height == 240, "原寸居中横拼应保留各自原始宽高不强拉小图，实际: \(res.width)x\(res.height)")
    } else { check(false, "原寸居中横拼不应失败") }

    // 2) 画幅比例预设：细长横条启用 16:9 与 1:1 应自动上下留白居中扩展为目标比例
    let wide169Opts = CollageOptions(
        layout: .horizontal, gapPx: 16, padPx: 20,
        background: .gradient, gradientPreset: .sunset,
        scaleAlignment: .originalStart, aspectPreset: .widescreen
    )
    if let w169 = ImageCollageStitcher.stitch(images: [small, large], options: wide169Opts) {
        let ratio = Double(w169.width) / Double(w169.height)
        check(abs(ratio - 16.0 / 9.0) < 0.02, "16:9 画幅预设应输出精确 16:9 比例画布，实际: \(w169.width)x\(w169.height)")
    } else { check(false, "16:9 画幅拼图不应失败") }

    let sqOpts = CollageOptions(layout: .horizontal, gapPx: 16, padPx: 20, aspectPreset: .square)
    if let sq = ImageCollageStitcher.stitch(images: [small, large], options: sqOpts) {
        check(abs(sq.width - sq.height) <= 1, "1:1 画幅预设应输出正方形画布，实际: \(sq.width)x\(sq.height)")
    } else { check(false, "1:1 画幅拼图不应失败") }

    // 3) 拼图参数 JSON Codable 往返持久化与剪贴板 PNG 直写落盘盒验证
    let persisted = CollageOptions(
        layout: .grid, gridColumns: 3, gapPx: 18, padPx: 40, cornerRadiusPx: 12,
        background: .gradient, customBackgroundColor: RGBAColor(18, 34, 56),
        gradientPreset: .mint, scaleAlignment: .originalCenter, aspectPreset: .standard,
        cardShadow: false, badge: .beforeAfter, watermark: .tiled, watermarkText: "@MSnipStudio",
        pdfPageNumber: .fraction
    )
    if let encoded = try? JSONEncoder().encode(persisted),
       let decoded = try? JSONDecoder().decode(CollageOptions.self, from: encoded) {
        check(decoded == persisted, "CollageOptions 序列化往返后应与原参数完全一致")
    } else {
        check(false, "CollageOptions JSON 编解码不应失败")
    }

    if let pngData = ClipboardImagePromise.encodePNG(cgImage: small, scaleFactor: 2.0) {
        let box = ClipboardFileBox()
        let url = box.materializeURL(pngData: pngData)
        check(url != nil && FileManager.default.fileExists(atPath: url!.path), "ClipboardFileBox 应支持由已压缩 PNG Data 直接落盘复用")
        if let url { try? FileManager.default.removeItem(at: url) }
    } else {
        check(false, "encodePNG 不应失败")
    }

    // 4) 顶部暂存架严格贴顶触发校验：离顶边差 4pt 不触发，真正抵住顶边 (maxY / maxY - 1) 才触发
    let testScr = CGRect(x: 0, y: 0, width: 1512, height: 982)
    check(!ShelfTriggerGeometry.hitsTopCenterTrigger(point: CGPoint(x: 756, y: 978), screenFrame: testScr, isDragging: false),
          "离屏幕顶边还有 4pt 时不应提前误触暂存架")
    check(ShelfTriggerGeometry.hitsTopCenterTrigger(point: CGPoint(x: 756, y: 981), screenFrame: testScr, isDragging: false),
          "光标真正抵住屏幕最顶边 1px 边界时应正常命中暂存架")

    // 5) 窗口内两张内缩圆角卡片之间的空白缝隙防幽灵框校验（模拟设置窗灰底上的两张白卡片）
    let winW = 400, winH = 340
    if let wCtx = CGContext(data: nil, width: winW, height: winH, bitsPerComponent: 8, bytesPerRow: winW * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        wCtx.setFillColor(CGColor(srgbRed: 0.12, green: 0.14, blue: 0.18, alpha: 1.0)) // 暗色背景终端
        wCtx.fill(CGRect(x: 0, y: 0, width: winW, height: winH))
        let winBox = CGRect(x: 40, y: 20, width: 320, height: 300)
        wCtx.setFillColor(CGColor(srgbRed: 0.95, green: 0.96, blue: 0.98, alpha: 1.0)) // 浅灰设置窗
        wCtx.addPath(CGPath(roundedRect: winBox, cornerWidth: 14, cornerHeight: 14, transform: nil)); wCtx.fillPath()
        wCtx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        wCtx.addPath(CGPath(roundedRect: CGRect(x: 60, y: 60, width: 280, height: 80), cornerWidth: 10, cornerHeight: 10, transform: nil)); wCtx.fillPath()
        wCtx.addPath(CGPath(roundedRect: CGRect(x: 60, y: 180, width: 280, height: 80), cornerWidth: 10, cornerHeight: 10, transform: nil)); wCtx.fillPath()
        if let simImg = wCtx.makeImage() {
            let sampler = PixelSampler(cgImage: simImg)
            // 光标停在两张卡片中间的 40px 灰色缝隙（y = 180 flipped -> CG y = 160 -> flipped top-down y = 180）：不应拼出宽 320 高 40 的幽灵缝隙条！
            let gapRects = VisualDetector.detectVisualRects(at: CGPoint(x: 200, y: 180), within: CGRect(x: 0, y: 0, width: 400, height: 340), sampler: sampler, scale: 1.0)
            let hasFakeGap = gapRects.contains { abs($0.width - 320) <= 6 && $0.height < 60 }
            check(!hasFakeGap, "两张内缩卡片之间的窗口背景缝隙绝不应误拼成横跨窗口的假矩形: \(gapRects)")
            let hasWholeWin = gapRects.contains { abs($0.minX - 40) <= 3 && abs($0.width - 320) <= 6 && abs($0.height - 300) <= 6 }
            check(hasWholeWin, "在设置窗两卡片空白处应精准探测出整个设置窗口外框: \(gapRects)")
        }
    }
}
