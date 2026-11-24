import CoreGraphics
import Foundation
import ImageIO
import MSnipCore

func testV030Features() {
    // 1) AnnotationHandles：矩形缩放柄、箭头双端点柄、步骤序号尾针柄与 Shift 约束
    let rectAnn = Annotation(payload: .rect(CGRect(x: 20, y: 30, width: 100, height: 60)), style: AnnotationStyle())
    check(rectAnn.editableHandles().count == 4, "矩形标注应暴露 4 个角点控制柄")
    check(rectAnn.hitEditableHandle(at: CGPoint(x: 121, y: 89)) == .bottomRight, "应精准命中右下角控制柄")
    check(rectAnn.hitEditableHandle(at: CGPoint(x: 70, y: 60)) == nil, "中心非控制柄区域不应误命中")
    let resizedRect = Annotation.resizedPayload(from: rectAnn.payload, handle: .bottomRight, to: CGPoint(x: 160, y: 120), shift: true)
    if case .rect(let rr) = resizedRect {
        check(abs(rr.width - rr.height) < 0.01 && rr.origin == CGPoint(x: 20, y: 30), "按住 Shift 拖拽右下柄应锁定正方形缩放")
    } else {
        check(false, "矩形缩放后应仍为矩形载荷")
    }
    let tinyRect = Annotation.resizedPayload(from: rectAnn.payload, handle: .bottomRight, to: CGPoint(x: 21, y: 31), shift: false, minBoxSize: 8)
    if case .rect(let tr) = tinyRect {
        check(tr.width >= 8 && tr.height >= 8, "缩放矩形不应小于最小边长约束")
    }

    let arrowAnn = Annotation(payload: .arrow(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 10)), style: AnnotationStyle())
    check(arrowAnn.editableHandles().count == 2 && arrowAnn.hitEditableHandle(at: CGPoint(x: 10, y: 10)) == .startPoint, "箭头应支持首尾双端点控制柄")
    let movedArrow = Annotation.resizedPayload(from: arrowAnn.payload, handle: .endPoint, to: CGPoint(x: 110, y: 112), shift: true)
    if case .arrow(let a, let b) = movedArrow {
        check(a == CGPoint(x: 10, y: 10) && abs((b.x - a.x) - (b.y - a.y)) < 1.5, "按住 Shift 拖拽箭头端点应吸附至 45°")
    }

    let stepAnn = Annotation(payload: .step(center: CGPoint(x: 50, y: 50), tail: CGPoint(x: 90, y: 50), number: 1), style: AnnotationStyle())
    check(stepAnn.hitEditableHandle(at: CGPoint(x: 90, y: 50)) == .stepTail, "带尾针步骤序号应支持尾针端点控制柄")

    // 2) ImageTransform：90° 顺/逆时针无损互逆旋转、水平翻转与多贴图边缘磁吸
    let quadImg = makeFourQuadrantImage(w: 80, h: 40)
    if let cw = ImageTransform.rotateClockwise90(quadImg),
       let back = ImageTransform.rotateCounterClockwise90(cw),
       let flipped = ImageTransform.flipHorizontal(quadImg) {
        check(cw.width == 40 && cw.height == 80, "顺时针 90° 旋转应交换宽高 (80×40 -> 40×80)")
        check(back.width == 80 && back.height == 40, "顺逆 90° 连续旋转应还原原始尺寸")
        let sOrig = PixelSampler(cgImage: quadImg)
        let sCW = PixelSampler(cgImage: cw)
        let sBack = PixelSampler(cgImage: back)
        let sFlip = PixelSampler(cgImage: flipped)
        // 原图左上角为红色 (240, 20, 20) -> 顺时针 90° 后应在右上角 (x=35, y=5)
        let cwTopRight = sCW.sampleRGB(px: 35, py: 5)
        check(cwTopRight.0 > 200 && cwTopRight.1 < 50 && cwTopRight.2 < 50, "顺时针 90° 后原左上红块应落至右上角: \(cwTopRight)")
        // 逆时针转回后左上角恢复红、右上角恢复绿
        let backTL = sBack.sampleRGB(px: 5, py: 5), origTL = sOrig.sampleRGB(px: 5, py: 5)
        let backTR = sBack.sampleRGB(px: 75, py: 5), origTR = sOrig.sampleRGB(px: 75, py: 5)
        check(abs(backTL.0 - origTL.0) <= 2 && abs(backTR.1 - origTR.1) <= 2, "CW + CCW 旋转必须像素级互逆")
        // 水平翻转后原左上红块应移至右上角 (x=75, y=5)
        let flipTR = sFlip.sampleRGB(px: 75, py: 5)
        check(flipTR.0 > 200 && flipTR.1 < 50, "水平翻转后原左上红块应移至右上角: \(flipTR)")
    } else {
        check(false, "ImageTransform 像素变换不应返回 nil")
    }

    let snapped = ImageTransform.snapPinOrigin(
        CGPoint(x: 205, y: 103),
        size: CGSize(width: 120, height: 80),
        siblingFrames: [CGRect(x: 100, y: 100, width: 100, height: 80)],
        visibleBounds: CGRect(x: 0, y: 0, width: 1440, height: 900),
        threshold: 8.0
    )
    check(abs(snapped.x - 200) < 0.01 && abs(snapped.y - 100) < 0.01, "多贴图边缘磁吸应在 8pt 内精准对齐兄弟贴图右边与底边")

    // 3) OCRTableFormatter：3×3 多列表格还原为 Markdown 与 TSV，非表格正文不误判
    let tableObs: [OCRLineObservation] = [
        OCRLineObservation(box: CGRect(x: 0.05, y: 0.80, width: 0.18, height: 0.04), text: "Name"),
        OCRLineObservation(box: CGRect(x: 0.40, y: 0.80, width: 0.16, height: 0.04), text: "Role"),
        OCRLineObservation(box: CGRect(x: 0.72, y: 0.80, width: 0.15, height: 0.04), text: "Score"),
        OCRLineObservation(box: CGRect(x: 0.05, y: 0.65, width: 0.18, height: 0.04), text: "Alice"),
        OCRLineObservation(box: CGRect(x: 0.40, y: 0.65, width: 0.18, height: 0.04), text: "Eng|Core"),
        OCRLineObservation(box: CGRect(x: 0.72, y: 0.65, width: 0.12, height: 0.04), text: "98"),
        OCRLineObservation(box: CGRect(x: 0.05, y: 0.50, width: 0.16, height: 0.04), text: "Bob"),
        OCRLineObservation(box: CGRect(x: 0.40, y: 0.50, width: 0.15, height: 0.04), text: "Design"),
        OCRLineObservation(box: CGRect(x: 0.72, y: 0.50, width: 0.12, height: 0.04), text: "95")
    ]
    if let tbl = OCRTableFormatter.extractTable(from: tableObs) {
        check(tbl.rows.count == 3 && tbl.columnCount == 3, "应识别出 3×3 表格，实际: \(tbl.rows.count)×\(tbl.columnCount)")
        check(tbl.markdown.contains("| Name | Role | Score |") && tbl.markdown.contains("Eng\\|Core"), "Markdown 表格应正确转义竖线并生成表头分隔行")
        check(tbl.tsv.contains("Alice\tEng|Core\t98"), "TSV 应使用制表符分列")
    } else {
        check(false, "规则 3×3 表格文本块应被正确还原为表格")
    }
    let proseObs = [
        OCRLineObservation(box: CGRect(x: 0.10, y: 0.80, width: 0.75, height: 0.04), text: "This is the first line of a normal paragraph"),
        OCRLineObservation(box: CGRect(x: 0.10, y: 0.74, width: 0.72, height: 0.04), text: "and it continues smoothly onto a second line.")
    ]
    check(OCRTableFormatter.extractTable(from: proseObs) == nil, "普通单栏正文不应被误判为表格")

    // 4) OCRParagraphGrouper：同段合并与分栏/列表拆分
    let grouped = OCRParagraphGrouper.group(proseObs)
    check(grouped.count == 1 && grouped[0].lineCount == 2 && grouped[0].text.contains("paragraph and it"), "同段两行英文应聚合为单个翻译段落")
    let splitCols = OCRParagraphGrouper.group([
        OCRLineObservation(box: CGRect(x: 0.05, y: 0.80, width: 0.15, height: 0.04), text: "Save"),
        OCRLineObservation(box: CGRect(x: 0.65, y: 0.80, width: 0.15, height: 0.04), text: "Cancel")
    ])
    check(splitCols.count == 2, "同行大间距独立按钮应拆分为 2 个独立翻译块")

    // 5) ScrollStitcher：撤回上一段、尾部裁剪与横向向右长截图
    let tallCanvas = makeTexturedStripCanvas(width: 240, height: 500)
    let vStitcher = ScrollStitcher(axis: .vertical)
    let vf0 = tallCanvas.cropping(to: CGRect(x: 0, y: 0, width: 240, height: 220))!
    let vf1 = tallCanvas.cropping(to: CGRect(x: 0, y: 90, width: 240, height: 220))!
    let vf2 = tallCanvas.cropping(to: CGRect(x: 0, y: 180, width: 240, height: 220))!
    _ = vStitcher.ingest(frame: vf0)
    _ = vStitcher.ingest(frame: vf1)
    let hAfter1 = vStitcher.outputSizePx.height
    _ = vStitcher.ingest(frame: vf2)
    check(vStitcher.canUndoAppend && vStitcher.outputSizePx.height > hAfter1, "追加第二段后总高度应增长且支持撤回")
    check(vStitcher.undoLastAppend() && vStitcher.outputSizePx.height == hAfter1, "undoLastAppend 应精确回退至上一段高度")
    let beforeTrim = vStitcher.outputSizePx.height
    check(vStitcher.trimTail(pixels: 40) && vStitcher.outputSizePx.height == beforeTrim - 40, "trimTail 应精确裁去指定尾部像素")

    let wideCanvas = makeHorizontalTexturedCanvas(width: 520, height: 200)
    let hStitcher = ScrollStitcher(axis: .horizontal)
    _ = hStitcher.ingest(frame: wideCanvas.cropping(to: CGRect(x: 0, y: 0, width: 240, height: 200))!)
    _ = hStitcher.ingest(frame: wideCanvas.cropping(to: CGRect(x: 110, y: 0, width: 240, height: 200))!)
    _ = hStitcher.ingest(frame: wideCanvas.cropping(to: CGRect(x: 220, y: 0, width: 240, height: 200))!)
    if let hFinal = hStitcher.renderFinalImage() {
        check(hFinal.height == 200 && abs(hFinal.width - 460) <= 4, "横向长截图应正确拼接宽度 ~460×200，实际: \(hFinal.width)×\(hFinal.height)")
    } else {
        check(false, "横向长截图应成功导出合成图")
    }

    // 6) RecordingOverlayCompositor 实时画笔合成与激光自动过期 + RecordingOptions 自定义 GIF 宽度
    let comp = RecordingOverlayCompositor(isEnabled: false)
    comp.beginLiveStroke(normalizedPoint: CGPoint(x: 0.2, y: 0.5), isLaser: true, at: 1.0)
    comp.appendLiveStrokePoint(CGPoint(x: 0.8, y: 0.5), at: 1.05)
    check(comp.hasActiveVisuals(at: 1.5), "即便关闭点击回显，存在活跃实时画笔时 hasActiveVisuals 仍应为 true")
    check(!comp.hasActiveVisuals(at: 5.0), "激光笔迹超时后 hasActiveVisuals 应恢复为 false")
    comp.clearLiveStrokes()
    let opts = RecordingOptions(gifFPS: 15, gifMaxLongSide: 720, mp4FPS: 60, showsCursor: false, captureSystemAudio: true)
    check(opts.clampedGifFPS == 15 && opts.clampedGifMaxLongSide == 720 && opts.clampedMp4FPS == 60, "RecordingOptions 参数范围校验应准确")
}

private func makeFourQuadrantImage(w: Int, h: Int) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // CoreGraphics 原点左下，上方 y=h/2..h 对应视觉顶部
    ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.08, blue: 0.08, alpha: 1)); ctx.fill(CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2))       // 视觉左上：红
    ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.90, blue: 0.12, alpha: 1)); ctx.fill(CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2))   // 视觉右上：绿
    ctx.setFillColor(CGColor(srgbRed: 0.10, green: 0.25, blue: 0.95, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h / 2))           // 视觉左下：蓝
    ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.85, blue: 0.10, alpha: 1)); ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2))       // 视觉右下：黄
    return ctx.makeImage()!
}

private func makeTexturedStripCanvas(width: Int, height: Int) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.97, blue: 0.99, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for row in stride(from: 8, to: height - 10, by: 18) {
        let r = CGFloat((row * 37) % 200) / 255.0
        let g = CGFloat((row * 73) % 200) / 255.0
        let b = CGFloat((row * 113) % 200) / 255.0
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        let barW = 40 + ((row * 29) % (width - 60))
        ctx.fill(CGRect(x: 16, y: row, width: barW, height: 9))
    }
    return ctx.makeImage()!
}

private func makeHorizontalTexturedCanvas(width: Int, height: Int) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.97, blue: 0.99, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for col in stride(from: 8, to: width - 10, by: 18) {
        let r = CGFloat((col * 41) % 200) / 255.0
        let g = CGFloat((col * 83) % 200) / 255.0
        let b = CGFloat((col * 127) % 200) / 255.0
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        let barH = 36 + ((col * 31) % (height - 56))
        ctx.fill(CGRect(x: col, y: 14, width: 9, height: barH))
    }
    return ctx.makeImage()!
}
