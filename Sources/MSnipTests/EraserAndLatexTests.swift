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
}
