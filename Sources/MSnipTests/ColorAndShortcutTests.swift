import CoreGraphics
import Foundation
import MSnipCore

func testColorSamplingAndRoundedBake() {
    // 1) 验证 PixPin 四种取色格式转换与循环顺序
    let c = RGBAColor(51, 136, 255)
    check(c.formatted(as: .hex) == "#3388FF", "HEX 格式应为 #3388FF，实际: \(c.formatted(as: .hex))")
    check(c.formatted(as: .rgb) == "rgb(51, 136, 255)", "RGB 格式应为 rgb(51, 136, 255)")
    check(c.formatted(as: .hsl) == "hsl(215, 100%, 60%)", "HSL 格式应为 hsl(215, 100%, 60%)，实际: \(c.formatted(as: .hsl))")
    check(c.formatted(as: .hsv) == "hsv(215, 80%, 100%)", "HSV 格式应为 hsv(215, 80%, 100%)，实际: \(c.formatted(as: .hsv))")
    check(ColorCopyFormat.hex.next == .rgb && ColorCopyFormat.hsv.next == .hex, "Shift 色值格式循环顺序应闭环")

    // 2) 验证剪贴板色值文本解析与色彩贴图卡渲染
    check(RGBAColor.parseColorString(" #3388ff ") == c, "应支持大小写 #RRGGBB 解析")
    check(RGBAColor.parseColorString("#38F") == c, "应支持简写 #RGB 解析")
    check(RGBAColor.parseColorString("rgb(51, 136, 255)") == c, "应支持 rgb(r, g, b) 解析")
    check(RGBAColor.parseColorString("not-a-color") == nil, "非法文本应返回 nil")

    let card = RGBAColor.renderColorPinCard(c, scale: 2.0)
    check(card != nil && card!.width == 448 && card!.height == 184, "2x 色彩贴图卡尺寸应为 448×184")

    // 3) 验证圆角截图烘焙（四角像素透明、中心像素不透明）
    let w = 100, h = 80
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1.0))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let sampler = PixelSampler(cgImage: ctx.makeImage()!)

    let rounded = AnnotationRenderer.bakeExportImage(
        sampler: sampler,
        selection: CGRect(x: 0, y: 0, width: 50, height: 40),
        imageScale: 2.0,
        annotations: [],
        cornerRadiusPt: 12
    )
    check(rounded != nil, "圆角截图应成功烘焙导出")
    if let img = rounded, let data = img.dataProvider?.data, let ptr = CFDataGetBytePtr(data) {
        let bpr = img.bytesPerRow
        let cornerAlpha = ptr[0 * bpr + 0 * 4 + 3]
        let centerAlpha = ptr[40 * bpr + 50 * 4 + 3]
        check(cornerAlpha == 0, "圆角裁切后的极角像素 (0,0) 必须完全透明 (alpha=0)，实际: \(cornerAlpha)")
        check(centerAlpha == 255, "圆角截图中心像素必须保持完全不透明 (alpha=255)，实际: \(centerAlpha)")
    }
}
