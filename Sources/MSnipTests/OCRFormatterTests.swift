import CoreGraphics
import Foundation
import MSnipCore

func testOCRTextFormatterModes() {
    // 1. 测试中文折行自动无空格合并，以及分段保留
    let items: [OCRLineObservation] = [
        // 第一段第 1 行（铺满右侧 0.92）
        OCRLineObservation(box: CGRect(x: 0.08, y: 0.80, width: 0.84, height: 0.06), text: "MSnip 是一款纯原生超轻量级"),
        // 第一段第 2 行（短尾句 + 句号结尾）
        OCRLineObservation(box: CGRect(x: 0.08, y: 0.72, width: 0.42, height: 0.06), text: "截图与贴图工具。"),
        // 第二段英文连字符跨行 + 正常词跨行（与上段有明显垂直间距）
        OCRLineObservation(box: CGRect(x: 0.08, y: 0.54, width: 0.83, height: 0.06), text: "Pure native frame-"),
        OCRLineObservation(box: CGRect(x: 0.08, y: 0.46, width: 0.82, height: 0.06), text: "work with zero external"),
        OCRLineObservation(box: CGRect(x: 0.08, y: 0.38, width: 0.38, height: 0.06), text: "dependencies."),
        // 列表项保持独立行段
        OCRLineObservation(box: CGRect(x: 0.08, y: 0.28, width: 0.50, height: 0.06), text: "• 支持左图实况划词"),
        OCRLineObservation(box: CGRect(x: 0.08, y: 0.20, width: 0.52, height: 0.06), text: "• 支持桌面贴图直接取字")
    ]

    let preserved = OCRTextFormatter.format(items, mode: .preserveLines)
    let preservedLines = preserved.components(separatedBy: "\n")
    check(preservedLines.count == 7, "保持换行模式应完整保留 7 行视觉行，实际: \(preservedLines.count)")

    let merged = OCRTextFormatter.format(items, mode: .mergeParagraphs)
    check(
        merged.contains("MSnip 是一款纯原生超轻量级截图与贴图工具。"),
        "中文跨行合并应无多余空格: got \(merged)"
    )
    check(
        merged.contains("Pure native framework with zero external dependencies."),
        "英文跨行应自动消去连字符并在普通单词间补空格: got \(merged)"
    )
    check(
        merged.contains("\n\n• 支持左图实况划词\n\n• 支持桌面贴图直接取字"),
        "列表项应保持独立分段不被吞并: got \(merged)"
    )

    // 2. 测试同行左右分栏按 X 排序与制表间隔拼接
    let rowSegments: [OCRLineObservation] = [
        OCRLineObservation(box: CGRect(x: 0.62, y: 0.50, width: 0.25, height: 0.05), text: "⌘3 识字"),
        OCRLineObservation(box: CGRect(x: 0.10, y: 0.51, width: 0.25, height: 0.05), text: "⌘1 截图")
    ]
    let rowOut = OCRTextFormatter.format(rowSegments, mode: .preserveLines)
    check(rowOut == "⌘1 截图    ⌘3 识字", "同行多列应按从左到右排序并保留列间距，实际: \(rowOut)")

    // 3. 测试 VisionKit transcript 纯文本跨行合段与连字符消去
    let rawTranscript = """
    第一行铺满整段宽度的中文内容测试文本在这里继续延伸
    接着第二行句尾结束。
    - 列表项一独立保留
    Build ultra-lightweight na-
    tive macOS apps.
    """
    let mergedTrans = OCRTextFormatter.mergeTranscriptLines(rawTranscript)
    check(
        mergedTrans.contains("延伸接着第二行句尾结束。"),
        "transcript 中文折行合段不应插入空格: got \(mergedTrans)"
    )
    check(
        mergedTrans.contains("native macOS apps."),
        "transcript 英文跨行连字符应自动消去: got \(mergedTrans)"
    )
}
