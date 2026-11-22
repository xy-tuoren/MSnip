import CoreGraphics
import Foundation
import MSnipCore

func testAnnotationEraserAndLatexModels() {
    // 1) 橡皮擦对自由画笔执行局部擦断（中间擦除后自动拆分为两段独立笔迹，一步 ⌘Z 完整恢复）
    var doc = AnnotationDocument()
    let pen = Annotation(
        payload: .pen(points: [CGPoint(x: 0, y: 50), CGPoint(x: 100, y: 50)]),
        style: AnnotationStyle(lineWidth: 3.0)
    )
    let rect = Annotation(
        payload: .rect(CGRect(x: 150, y: 20, width: 60, height: 40)),
        style: AnnotationStyle(lineWidth: 3.0)
    )
    doc.append(pen)
    doc.append(rect)
    check(doc.objects.count == 2, "初始应包含画笔与矩形两个标注")

    doc.beginTransaction()
    let splitHit = doc.eraseAlongSegment(from: CGPoint(x: 50, y: 40), to: CGPoint(x: 50, y: 60), radius: 8.0)
    doc.commitTransaction(changed: splitHit)
    check(splitHit, "橡皮擦横穿画笔中段应返回命中")
    check(doc.objects.count == 3, "画笔中段被擦断后应拆分为两段笔迹 + 原矩形，实际: \(doc.objects.count)")

    // 2) 橡皮擦扫过矩形边框应整件移除，且一步撤销恢复
    doc.beginTransaction()
    let rectHit = doc.eraseAlongSegment(from: CGPoint(x: 150, y: 20), to: CGPoint(x: 155, y: 25), radius: 8.0)
    doc.commitTransaction(changed: rectHit)
    check(rectHit && doc.objects.count == 2, "橡皮擦触碰矩形边框应整件擦除")

    check(doc.undo(), "应可一步撤销矩形擦除")
    check(doc.objects.count == 3, "撤销后矩形应恢复")
    check(doc.undo(), "应可一步撤销画笔分段擦除")
    check(doc.objects.count == 2, "再撤销一步应还原为原始未擦断的两件标注")

    // 3) LaTeX 围栏与定界符清洗 + 4 档包裹格式校验
    let messy = "```latex\n$$\\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}$$\n```"
    let clean = LatexPostProcessor.stripFencesAndDelimiters(messy)
    check(clean == "\\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}", "应剥离 Markdown 围栏与外层 $$ 定界符，实际: \(clean)")
    check(LatexWrapFormat.inlineDollar.wrap(messy) == "$\\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}$", "行内格式不应重复包裹 $$")
    check(LatexWrapFormat.blockDollar.wrap(clean) == "$$\n\\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}\n$$", "行间 $$ 包裹应规范换行")
    check(LatexWrapFormat.displayBrackets.wrap(clean) == "\\[\n\\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}\n\\]", "\\[...\\] 包裹应规范换行")

    // 4) 离线基础 Unicode 数学符号转 LaTeX 兜底校验
    let uni = "∑ x² + α ≤ ∞"
    let converted = LatexPostProcessor.heuristicUnicodeToLatex(uni)
    check(
        converted.contains("\\sum") && converted.contains("x^2") && converted.contains("\\alpha") && converted.contains("\\leq") && converted.contains("\\infty"),
        "离线转换应正确映射希腊字母、上下标与关系符，实际: \(converted)"
    )

    // 5) OCRImagePreprocessor 小图超分放大 + 留白坐标精确反算
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    if let ctx = CGContext(data: nil, width: 120, height: 40, bitsPerComponent: 8, bytesPerRow: 480, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.14, blue: 0.18, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 40))
        if let smallImg = ctx.makeImage() {
            let prep = OCRImagePreprocessor.prepare(smallImg)
            check(prep.upscaleFactor >= 2.0, "小选区应自动触发 >=2× 超分放大")
            check(prep.cgImage.width > smallImg.width * 2, "增强图应包含放大像素与四周留白")
            let mapped = prep.mapBoxBack(prep.contentNormalizedRect)
            check(abs(mapped.minX) < 0.002 && abs(mapped.minY) < 0.002 && abs(mapped.width - 1.0) < 0.002 && abs(mapped.height - 1.0) < 0.002,
                  "留白归一化框应 1:1 精确映射回原始 [0,1] 坐标，实际: \(mapped)")
        }
    }

    // 6) OCRTextFormatter 双栏先左后右重排、代码缩进还原与智能标点拼接
    let twoCol: [OCRLineObservation] = [
        OCRLineObservation(box: CGRect(x: 0.04, y: 0.80, width: 0.36, height: 0.05), text: "Left line one"),
        OCRLineObservation(box: CGRect(x: 0.56, y: 0.80, width: 0.36, height: 0.05), text: "Right line one"),
        OCRLineObservation(box: CGRect(x: 0.04, y: 0.73, width: 0.36, height: 0.05), text: "Left line two"),
        OCRLineObservation(box: CGRect(x: 0.56, y: 0.73, width: 0.36, height: 0.05), text: "Right line two"),
        OCRLineObservation(box: CGRect(x: 0.04, y: 0.66, width: 0.36, height: 0.05), text: "Left line three."),
        OCRLineObservation(box: CGRect(x: 0.56, y: 0.66, width: 0.36, height: 0.05), text: "Right line three.")
    ]
    let mergedCols = OCRTextFormatter.format(twoCol, mode: .mergeParagraphs)
    check(mergedCols.hasPrefix("Left line one Left line two Left line three.") && mergedCols.contains("Right line one Right line two Right line three."),
          "双栏文档应先读完整左栏再读右栏，实际: \(mergedCols)")

    let codeLines: [OCRLineObservation] = [
        OCRLineObservation(box: CGRect(x: 0.05, y: 0.80, width: 0.40, height: 0.06), text: "func demo() {"),
        OCRLineObservation(box: CGRect(x: 0.18, y: 0.70, width: 0.35, height: 0.06), text: "return 42"),
        OCRLineObservation(box: CGRect(x: 0.05, y: 0.60, width: 0.05, height: 0.06), text: "}")
    ]
    let preservedCode = OCRTextFormatter.format(codeLines, mode: .preserveLines)
    check(preservedCode.contains("\n  return 42\n") || preservedCode.contains("\n    return 42\n"),
          "保持原行模式应还原代码层级缩进，实际: \(preservedCode)")
    check(OCRTextFormatter.smartInlineJoiner(left: "foo(", right: "bar") == "" && OCRTextFormatter.smartInlineJoiner(left: "bar", right: ");") == "",
          "括号与尾标点处不应插入多余空格")
    check(OCRTextFormatter.sanitizeLine("\u{200B}Hello\u{FEFF} ") == "Hello", "应清理零宽不可见字符")

    // 7) 翻译极简预设与控制台直达链接校验
    let ds = TranslationProviderProfile.makePreset(.openAICompatible, llmPreset: .deepseek)
    let ol = TranslationProviderProfile.makePreset(.openAICompatible, llmPreset: .ollamaLocal)
    check(ds.consoleURL?.contains("deepseek") == true, "DeepSeek 应内置官方 API Key 直达地址")
    check(ol.isLocalNoKeyEndpoint && ol.consoleURL == nil, "本地 Ollama 应识别为免密钥模式")
}
