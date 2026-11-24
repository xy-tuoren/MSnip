import CoreGraphics
import Foundation
import MSnipCore

func testV031Features() {
    // 1) SensitiveTextDetector：精确匹配 API Key / JWT / 邮箱 / 手机号 / 18 位身份证 / IPv4 / 银行卡，忽略环回地址
    let apiHits = SensitiveTextDetector.detect(in: "export OPENAI_API_KEY=sk-proj-AbCdEf1234567890XyZ")
    check(apiHits.count == 1 && apiHits[0].kind == .apiKey && apiHits[0].matchedText.hasPrefix("sk-proj-"), "应精准定位 sk-proj API Key 子串")

    let multiLine = "联系邮箱 dev.user@example.com，手机 138-0013-8000，服务器 192.168.10.24 (本地 127.0.0.1 忽略)"
    let multiHits = SensitiveTextDetector.detect(in: multiLine)
    check(multiHits.map(\.kind) == [.email, .phone, .ipv4], "应按序命中邮箱、手机号与非环回 IP，实际: \(multiHits.map(\.kind))")

    let idHits = SensitiveTextDetector.detect(in: "身份证 11010519900307123X 与 GitHub ghp_1234567890abcdefghij123456")
    check(idHits.count == 2 && idHits[0].kind == .idCard && idHits[1].kind == .apiKey, "18 位身份证不应被误拆成手机号，且应同时命中 ghp_ token")

    let cleanHits = SensitiveTextDetector.detect(in: "Hello MSnip v0.3.1 release notes 2026")
    check(cleanHits.isEmpty, "普通文案不应误报敏感隐私信息")

    // 2) Spotlight 聚光灯标注：控制柄、碰撞检测与压暗框外渲染
    let spot = Annotation(payload: .spotlight(CGRect(x: 40, y: 30, width: 60, height: 40)), style: AnnotationStyle())
    check(spot.editableHandles().count == 4 && spot.hitTest(CGPoint(x: 70, y: 50)), "聚光灯应支持 4 角控制柄与区域命中")
    let whiteBg = makeSolidTestImage(w: 160, h: 120, r: 1, g: 1, b: 1)
    let spotSampler = PixelSampler(cgImage: whiteBg)
    if let bakedSpot = AnnotationRenderer.bakeExportImage(
        sampler: spotSampler,
        selection: CGRect(x: 0, y: 0, width: 160, height: 120),
        imageScale: 1.0,
        annotations: [spot]
    ) {
        let bs = PixelSampler(cgImage: bakedSpot)
        let inside = bs.sampleRGB(px: 70, py: 50)
        let outside = bs.sampleRGB(px: 10, py: 10)
        check(inside.0 > 245 && outside.0 < 160, "聚光灯框内应保持原亮度、框外应明显压暗: in=\(inside) out=\(outside)")
    } else {
        check(false, "聚光灯标注烘焙导出不应失败")
    }

    // 3) ImageCollageStitcher：横向并排与纵向长图拼接
    let redImg = makeSolidTestImage(w: 120, h: 80, r: 0.9, g: 0.15, b: 0.15)
    let blueImg = makeSolidTestImage(w: 160, h: 80, r: 0.12, g: 0.4, b: 0.95)
    if let hCol = ImageCollageStitcher.stitch(images: [redImg, blueImg], direction: .horizontal, gapPx: 20, padPx: 20) {
        check(hCol.width == 20 * 2 + 120 + 160 + 20 && hCol.height == 20 * 2 + 80, "横向拼图尺寸应精确为 340×120，实际: \(hCol.width)×\(hCol.height)")
    } else {
        check(false, "横向对比拼图应合成成功")
    }
    if let vCol = ImageCollageStitcher.stitch(images: [redImg, blueImg], direction: .vertical, gapPx: 20, padPx: 20) {
        check(vCol.height > vCol.width, "纵向拼图总高应大于总宽，实际: \(vCol.width)×\(vCol.height)")
    } else {
        check(false, "纵向对比拼图应合成成功")
    }

    // 4) SaveFilenameTemplate：占位符渲染与路径穿越安全清洗
    let refDate = Date(timeIntervalSince1970: 1_700_000_000)
    let customName = SaveFilenameTemplate.render(template: "截屏_{w}x{h}_{date}", date: refDate, pixelWidth: 800, pixelHeight: 600, fileExtension: "png")
    check(customName.hasPrefix("截屏_800x600_") && customName.hasSuffix(".png"), "自定义文件名模板应正确替换宽高与日期: \(customName)")
    let evilName = SaveFilenameTemplate.render(template: "../../etc:passwd/bad*name", date: refDate, fileExtension: "jpg")
    check(!evilName.contains("/") && !evilName.contains("..") && !evilName.contains(":") && evilName.hasSuffix(".jpg"), "非法路径字符必须彻底清洗: \(evilName)")

    // 5) BackdropBeautifier：16:9 / 1:1 比例扩展与文字水印
    let card = makeSolidTestImage(w: 200, h: 200, r: 1, g: 1, b: 1)
    if let wideCard = BackdropBeautifier.apply(
        to: card, style: .oceanAurora, imageScale: 1.0,
        aspectRatio: .ratio16x9, watermarkText: "@MSnip"
    ) {
        let ratio = CGFloat(wideCard.width) / CGFloat(wideCard.height)
        check(abs(ratio - (16.0 / 9.0)) < 0.03, "16:9 衬底画幅比例应精准对齐 1.778，实际: \(ratio)")
    } else {
        check(false, "带 16:9 比例与水印的美化衬底应烘焙成功")
    }
    if let squareCard = BackdropBeautifier.apply(
        to: makeSolidTestImage(w: 300, h: 120, r: 1, g: 1, b: 1),
        style: .cleanStudio, imageScale: 1.0, aspectRatio: .ratio1x1
    ) {
        check(abs(squareCard.width - squareCard.height) <= 2, "1:1 衬底画幅宽高应相等: \(squareCard.width)×\(squareCard.height)")
    } else {
        check(false, "1:1 比例美化衬底应烘焙成功")
    }
}

private func makeSolidTestImage(w: Int, h: Int, r: CGFloat, g: CGFloat, b: CGFloat) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}
