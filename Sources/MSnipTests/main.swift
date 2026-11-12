import AppKit
import CoreGraphics
import Foundation
import MSnipCore

var passedCount = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #fileID, line: Int = #line) {
    if !condition() {
        fputs("❌ Test failed (\(file):\(line)): \(message)\n", stderr)
        exit(1)
    }
    passedCount += 1
}

private func testGeometry() {
    let r = Geometry.normalizedRect(from: CGPoint(x: 120, y: 90), to: CGPoint(x: 20, y: 30))
    check(r == CGRect(x: 20, y: 30, width: 100, height: 60), "反向拖拽应生成标准化正宽高矩形")

    let sq = Geometry.squareConstrainedEnd(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: -10))
    check(sq == CGPoint(x: 50, y: -30), "Shift 正方形约束应取较长边并保留象限符号")

    let snapped = Geometry.angleSnappedEnd(from: .zero, to: CGPoint(x: 100, y: 8))
    check(abs(snapped.y) < 0.01 && snapped.x > 99, "接近水平的线段按 Shift 应吸附到 0°")

    let d = Geometry.distanceToSegment(point: CGPoint(x: 50, y: 12), a: CGPoint(x: 0, y: 0), b: CGPoint(x: 100, y: 0))
    check(abs(d - 12.0) < 0.001, "点到线段距离应等于垂距")

    let arrow = Geometry.arrowGeometry(from: .zero, to: CGPoint(x: 100, y: 0), lineWidth: 4.0)
    check(arrow != nil && arrow!.shaftEnd.x < 100.0 && arrow!.headPoints[0] == CGPoint(x: 100, y: 0), "箭杆终点应缩入箭头内部防穿模")
}

private func testAnnotationsAndHitTesting() {
    let style = AnnotationStyle(color: RGBAColor.presets[0], lineWidth: 4.0)
    var rectObj = Annotation(payload: .rect(CGRect(x: 20, y: 20, width: 100, height: 80)), style: style)
    check(!rectObj.isTrivial, "正常尺寸矩形不应判定为退化图形")
    check(rectObj.hitTest(CGPoint(x: 20, y: 50)), "矩形左边框应命中")
    check(!rectObj.hitTest(CGPoint(x: 70, y: 60)), "空心矩形中心空白处不应命中")

    rectObj.translate(dx: 15, dy: -5)
    check(rectObj.hitTest(CGPoint(x: 35, y: 45)), "平移后新边框应命中")

    let ellipseObj = Annotation(payload: .ellipse(CGRect(x: 0, y: 0, width: 200, height: 100)), style: style)
    check(ellipseObj.hitTest(CGPoint(x: 200, y: 50)), "椭圆右极点应命中轮廓")
    check(!ellipseObj.hitTest(CGPoint(x: 100, y: 50)), "椭圆圆心不应命中描边轮廓")

    let tiny = Annotation(payload: .rect(CGRect(x: 0, y: 0, width: 1, height: 1)), style: style)
    check(tiny.isTrivial, "1x1 误触图形应判定为退化丢弃")
}

private func testDocumentUndoRedoAndDelete() {
    var doc = AnnotationDocument()
    let style = AnnotationStyle()
    let a1 = Annotation(payload: .rect(CGRect(x: 10, y: 10, width: 40, height: 40)), style: style)
    let a2 = Annotation(payload: .arrow(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 80, y: 80)), style: style)

    doc.append(a1)
    doc.append(a2)
    check(doc.objects.count == 2 && doc.canUndo && !doc.canRedo, "追加两个对象后应可撤销")

    // 单独删除第一个对象，且一步撤销可恢复
    doc.remove(at: 0)
    check(doc.objects.count == 1 && doc.objects[0].id == a2.id, "Delete 应仅删除目标对象")
    check(doc.undo(), "删除后应支持一步撤销恢复")
    check(doc.objects.count == 2 && doc.objects[0].id == a1.id, "撤销后被删对象应原位恢复")
    check(doc.redo() && doc.objects.count == 1, "重做后应再次移除")

    // 连续拖拽事务合并为一步撤销
    doc.beginTransaction()
    doc.updateWithoutHistory(at: 0) { $0.translate(dx: 5, dy: 5) }
    doc.updateWithoutHistory(at: 0) { $0.translate(dx: 10, dy: 10) }
    doc.commitTransaction(changed: true)
    check(doc.undo(), "整段拖拽应合并为一步撤销")
    if case .arrow(let from, _) = doc.objects[0].payload {
        check(from == .zero, "撤销拖拽后应回到拖拽前初始位置")
    } else {
        check(false, "对象类型不应改变")
    }
}

private func testRetinaExportOrientationAndAnnotationBaking() {
    // 构造一张 100x80 物理像素（对应 50x40 @ 2x Retina）测试图：上半部纯蓝、下半部纯绿
    let w = 100, h = 80
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // 标准 CGContext 原点在左下：y in 0..<40 是图像下半部（绿），y in 40..<80 是上半部（蓝）
    ctx.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: 40))
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 40, width: w, height: 40))

    let srcImage = ctx.makeImage()!
    let sampler = PixelSampler(cgImage: srcImage)

    // 在逻辑选区 (0, 0, 50, 40) 的左上角 (5, 5) 画一条纯红粗线到 (45, 5)
    let redLine = Annotation(
        payload: .line(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 45, y: 5)),
        style: AnnotationStyle(color: RGBAColor(255, 0, 0), lineWidth: 4.0)
    )
    let exported = AnnotationRenderer.bakeExportImage(
        sampler: sampler,
        selection: CGRect(x: 0, y: 0, width: 50, height: 40),
        imageScale: 2.0,
        annotations: [redLine]
    )
    check(exported != nil && exported!.width == 100 && exported!.height == 80, "2x Retina 导出必须保留完整物理像素尺寸")

    let outSampler = PixelSampler(cgImage: exported!)
    // 校验顶部红线像素 (px: 50, py: 10) 为红色
    let topRed = outSampler.sampleColor(px: 50, py: 10).components ?? []
    check(topRed.count >= 3 && topRed[0] > 0.8 && topRed[2] < 0.2, "左上角逻辑 y=5 处应渲染出红色直线")

    // 校验上半部未画线处 (px: 50, py: 25) 仍为蓝色（证明底图未上下颠倒）
    let upperBlue = outSampler.sampleColor(px: 50, py: 25).components ?? []
    check(upperBlue.count >= 3 && upperBlue[2] > 0.8 && upperBlue[1] < 0.2, "图像上半部应保持蓝色不颠倒")

    // 校验下半部 (px: 50, py: 65) 仍为绿色
    let lowerGreen = outSampler.sampleColor(px: 50, py: 65).components ?? []
    check(lowerGreen.count >= 3 && lowerGreen[1] > 0.8 && lowerGreen[2] < 0.2, "图像下半部应保持绿色不颠倒")
}

private func testFlippedNSViewDrawsCGImageUpright() {
    // 回归测试：验证在 isFlipped=true 的 NSView 中使用 respectFlipped=true 绘制截屏图像不会上下倒置或镜像
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 80,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // 左上角 (x: 0..<10, CG y: 10..<20) 涂纯红，其余涂纯黑
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
    ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 10, width: 10, height: 10))
    let cg = ctx.makeImage()!

    final class ProbeFlippedView: NSView {
        let nsImage: NSImage
        init(cg: CGImage) {
            self.nsImage = NSImage(cgImage: cg, size: NSSize(width: 20, height: 20))
            super.init(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        }
        @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            nsImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0, respectFlipped: true, hints: nil)
        }
    }

    let view = ProbeFlippedView(cg: cg)
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)

    let topLeft = rep.colorAt(x: 3, y: 3)!
    let bottomLeft = rep.colorAt(x: 3, y: 17)!
    let topRight = rep.colorAt(x: 17, y: 3)!
    check(topLeft.redComponent > 0.8 && topLeft.blueComponent < 0.2, "左上角像素应保持红色（不上下倒置）")
    check(bottomLeft.redComponent < 0.2, "左下角像素应保持黑色")
    check(topRight.redComponent < 0.2, "右上角像素应保持黑色（不左右镜像）")
}

private func testVisualDetectorFindsNestedCardAndButton() {
    // 构造 400x300 @ 1x 模拟界面（左上角逻辑原点）：
    // - 深灰窗口底色 (30, 30, 35)
    // - 居中白色卡片: (60, 50, 280, 200)
    // - 卡片内蓝色按钮: (140, 120, 120, 44)
    let w = 400, h = 300
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // 翻转 CGContext 使绘图坐标与左上角原点一致
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)

    ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

    let cardRect = CGRect(x: 60, y: 50, width: 280, height: 200)
    ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1))
    ctx.fill(cardRect)

    let buttonRect = CGRect(x: 140, y: 120, width: 120, height: 44)
    ctx.setFillColor(CGColor(srgbRed: 0.10, green: 0.48, blue: 0.96, alpha: 1))
    ctx.fill(buttonRect)

    let sampler = PixelSampler(cgImage: ctx.makeImage()!)
    let winBounds = CGRect(x: 0, y: 0, width: w, height: h)

    // 光标停在蓝色按钮中心 (200, 142)：应按从小到大顺序识别出 [按钮框, 白色卡片框]
    let hierarchyAtBtn = VisualDetector.detectVisualRects(
        at: CGPoint(x: 200, y: 142),
        within: winBounds,
        sampler: sampler,
        scale: 1.0
    )
    check(hierarchyAtBtn.count >= 2, "停在嵌套按钮内部应至少识别出『内层按钮 + 外层卡片』两级矩阵")
    let first = hierarchyAtBtn[0]
    let second = hierarchyAtBtn[1]
    check(
        abs(first.minX - buttonRect.minX) <= 2 &&
        abs(first.minY - buttonRect.minY) <= 2 &&
        abs(first.width - buttonRect.width) <= 4 &&
        abs(first.height - buttonRect.height) <= 4,
        "第 1 层（最小矩阵）应精准吸附内层蓝色按钮: got \(first)"
    )
    check(
        abs(second.minX - cardRect.minX) <= 2 &&
        abs(second.minY - cardRect.minY) <= 2 &&
        abs(second.width - cardRect.width) <= 4 &&
        abs(second.height - cardRect.height) <= 4,
        "第 2 层（父容器矩阵）应精准吸附外层白色卡片: got \(second)"
    )

    // 验证相似矩形去重与从小到大归一化
    let merged = VisualDetector.normalizeHierarchy([
        winBounds,
        CGRect(x: 141, y: 121, width: 119, height: 43),
        buttonRect,
        cardRect
    ])
    check(merged.count == 3, "误差 <5pt 的重复框应自动合并为单一矩阵层级")
    check(merged[0].width < merged[1].width && merged[1].width < merged[2].width, "层级栈必须严格按从小到大排列")
}

private func testVisualDetectorRejectsPhantomCrosshairsAndFindsOutlinedBox() {
    let w = 420, h = 300
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)

    // 深色背景 + 同底色 1pt 细线描边大卡片 (50, 30, 320, 230)
    ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let card = CGRect(x: 50, y: 30, width: 320, height: 230)
    ctx.setStrokeColor(CGColor(srgbRed: 0.42, green: 0.42, blue: 0.46, alpha: 1))
    ctx.setLineWidth(1.0)
    ctx.stroke(card.insetBy(dx: 0.5, dy: 0.5))

    // 在卡片内放入互不闭合的干扰色块（左侧头像块 + 上方短标签），测试十字射线不会误拼幽灵框
    ctx.setFillColor(CGColor(srgbRed: 0.90, green: 0.35, blue: 0.30, alpha: 1))
    ctx.fill(CGRect(x: 74, y: 95, width: 36, height: 42))
    ctx.setFillColor(CGColor(srgbRed: 0.30, green: 0.75, blue: 0.45, alpha: 1))
    ctx.fill(CGRect(x: 185, y: 52, width: 64, height: 22))

    let sampler = PixelSampler(cgImage: ctx.makeImage()!)
    let winBounds = CGRect(x: 0, y: 0, width: w, height: h)
    // 光标位于 (210, 116)：水平正对左侧红块，垂直正对上方绿条，但不处于任何小闭合框内
    let hits = VisualDetector.detectVisualRects(
        at: CGPoint(x: 210, y: 116),
        within: winBounds,
        sampler: sampler,
        scale: 1.0
    )
    check(hits.count == 1, "十字干扰块不应拼出幽灵矩形，应唯一识别出外层 1pt 描边卡片，实际得到: \(hits)")
    if let only = hits.first {
        check(
            abs(only.minX - card.minX) <= 3 && abs(only.width - card.width) <= 6,
            "1pt 细线描边同底色卡片应被精准识别: got \(only)"
        )
    }
}

testGeometry()
testAnnotationsAndHitTesting()
testDocumentUndoRedoAndDelete()
testRetinaExportOrientationAndAnnotationBaking()
testFlippedNSViewDrawsCGImageUpright()
testVisualDetectorFindsNestedCardAndButton()
testVisualDetectorRejectsPhantomCrosshairsAndFindsOutlinedBox()
testColorSamplingAndRoundedBake()
print("✅ All \(passedCount) assertions in MSnipTests passed!")
