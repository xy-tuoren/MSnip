import CoreGraphics
import Foundation
import MSnipCore

func testMilestone1AnnotationUpgrades() {
    let style = AnnotationStyle(color: RGBAColor(255, 204, 0), lineWidth: 4.0, mosaicBlockSize: 10.0)

    // 1) 步骤序号自增、撤销复用、单击非退化与尾部命中测试
    var doc = AnnotationDocument()
    check(doc.nextStepNumber() == 1, "空白画布首个步骤序号应为 1")

    let s1 = Annotation(payload: .step(center: CGPoint(x: 30, y: 30), tail: nil, number: doc.nextStepNumber()), style: style)
    check(!s1.isTrivial, "单击生成的无尾步骤序号绝不应被视作退化图形丢弃")
    doc.append(s1)
    check(doc.nextStepNumber() == 2, "落标 ① 后下一个序号应递增为 2")

    var s2 = Annotation(
        payload: .step(center: CGPoint(x: 80, y: 40), tail: CGPoint(x: 150, y: 40), number: doc.nextStepNumber()),
        style: style
    )
    doc.append(s2)
    check(doc.nextStepNumber() == 3, "落标 ② 后下一个序号应递增为 3")
    check(s2.hitTest(CGPoint(x: 80, y: 40)), "步骤徽章圆心应命中")
    check(s2.hitTest(CGPoint(x: 120, y: 40)), "拖拽拉出的指示箭杆应命中")
    check(!s2.hitTest(CGPoint(x: 20, y: 120)), "远离徽章与箭头的空白处不应命中")

    s2.translate(dx: 10, dy: 15)
    check(s2.hitTest(CGPoint(x: 90, y: 55)) && s2.hitTest(CGPoint(x: 155, y: 55)), "平移步骤序号应同步移动圆心与指示箭头")

    check(doc.undo(), "应可撤销末个步骤序号")
    check(doc.nextStepNumber() == 2, "撤销 ② 后再次点击应自然复用序号 2")

    // 2) 荧光笔独立透明层：折返重涂单笔不叠加发黑，且底层亮底保持高可读性
    let w = 120, h = 100
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let bgCtx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // 构造上半纯红 (CG y: 50..<100)、下半纯蓝 (CG y: 0..<50) 底图，右侧留纯白条 (x: 80..<120)
    bgCtx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    bgCtx.fill(CGRect(x: 0, y: 0, width: 80, height: 50))
    bgCtx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    bgCtx.fill(CGRect(x: 0, y: 50, width: 80, height: 50))
    bgCtx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    bgCtx.fill(CGRect(x: 80, y: 0, width: 40, height: 100))

    let sampler = PixelSampler(cgImage: bgCtx.makeImage()!)

    // 在右侧纯白区域 (x=100) 来回重涂两次荧光笔，测试单笔自交处与未自交处色值一致
    let hl = Annotation(
        payload: .highlighter(points: [
            CGPoint(x: 100, y: 15),
            CGPoint(x: 100, y: 80),
            CGPoint(x: 100, y: 40)
        ]),
        style: AnnotationStyle(color: RGBAColor(255, 204, 0), lineWidth: 4.0)
    )
    // 在左侧红蓝交界处 (x: 10..<70, y: 25..<75) 施加毛玻璃高斯模糊
    let blur = Annotation(
        payload: .gaussianBlur(CGRect(x: 10, y: 25, width: 60, height: 50)),
        style: AnnotationStyle(color: RGBAColor.presets[0], lineWidth: 4.0, mosaicBlockSize: 8.0)
    )

    let baked = AnnotationRenderer.bakeExportImage(
        sampler: sampler,
        selection: CGRect(x: 0, y: 0, width: 120, height: 100),
        imageScale: 1.0,
        annotations: [hl, blur, s1]
    )
    check(baked != nil, "含荧光笔、毛玻璃与步骤序号的图像应成功烘焙")

    let out = PixelSampler(cgImage: baked!)
    let singlePass = out.sampleRGB(px: 100, py: 22)
    let doublePass = out.sampleRGB(px: 100, py: 55)
    check(
        abs(singlePass.2 - doublePass.2) <= 3 && singlePass.0 > 240 && singlePass.2 > 130 && singlePass.2 < 200,
        "荧光笔透明层应呈均匀半透明亮黄且单笔来回重涂不加深: single=\(singlePass), double=\(doublePass)"
    )

    // 3) 毛玻璃方向与柔化混合校验：交界中心 (40, 50) 红蓝混合，模糊区上沿偏红、下沿偏蓝（绝不上下颠倒）
    let blurCenter = out.sampleRGB(px: 40, py: 50)
    let blurUpper = out.sampleRGB(px: 40, py: 30)
    let blurLower = out.sampleRGB(px: 40, py: 70)
    check(blurCenter.0 > 60 && blurCenter.2 > 60, "毛玻璃中心交界处应平滑混合红蓝像素: \(blurCenter)")
    check(blurUpper.0 > blurUpper.2, "毛玻璃上半部应保持红占优（正立不倒置）: \(blurUpper)")
    check(blurLower.2 > blurLower.0, "毛玻璃下半部应保持蓝占优（正立不倒置）: \(blurLower)")
}
