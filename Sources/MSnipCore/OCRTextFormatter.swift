import CoreGraphics
import Foundation

/// 单条离线 OCR 识别文本块（`box` 为 Vision 归一化左下角坐标系 `0..1`）
public struct OCRLineObservation: Equatable, Sendable {
    public let box: CGRect
    public let text: String

    public init(box: CGRect, text: String) {
        self.box = box
        self.text = text
    }
}

/// OCR 文本排版输出模式
public enum OCRLayoutMode: String, CaseIterable, Codable, Sendable {
    case preserveLines   // 保持原行（适合代码、表格、终端日志、短标签）
    case mergeParagraphs // 智能合并换行（适合中英文长段落、PDF/网页正文）
}

/// 纯算法 OCR 阅读顺序重排与中英文智能段落合并器（零外部依赖）
public enum OCRTextFormatter {
    /// 将乱序识别块聚类为视觉行，并按从上到下、同行从左到右排列
    public static func groupIntoVisualRows(_ items: [OCRLineObservation]) -> [[OCRLineObservation]] {
        let cleaned = items.compactMap { item -> OCRLineObservation? in
            let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : OCRLineObservation(box: item.box, text: trimmed)
        }
        guard !cleaned.isEmpty else { return [] }

        let byTop = cleaned.sorted { a, b in
            if abs(a.box.midY - b.box.midY) > 0.008 {
                return a.box.midY > b.box.midY
            }
            return a.box.minX < b.box.minX
        }

        var rows: [[OCRLineObservation]] = []
        for item in byTop {
            if let lastIdx = rows.indices.last {
                let ref = rows[lastIdx][0]
                let tol = max(0.012, min(ref.box.height, item.box.height) * 0.55)
                if abs(ref.box.midY - item.box.midY) <= tol {
                    rows[lastIdx].append(item)
                    continue
                }
            }
            rows.append([item])
        }

        for i in rows.indices {
            rows[i].sort { $0.box.minX < $1.box.minX }
        }
        return rows
    }

    public static func format(_ items: [OCRLineObservation], mode: OCRLayoutMode) -> String {
        let rows = groupIntoVisualRows(items)
        guard !rows.isEmpty else { return "" }

        struct MergedRow {
            let minX: CGFloat
            let maxX: CGFloat
            let minY: CGFloat
            let maxY: CGFloat
            let text: String
            var height: CGFloat { max(0.005, maxY - minY) }
        }

        let visualRows: [MergedRow] = rows.map { segs in
            var lineText = ""
            for (idx, seg) in segs.enumerated() {
                if idx == 0 {
                    lineText = seg.text
                } else {
                    let gapX = seg.box.minX - segs[idx - 1].box.maxX
                    let sep = gapX > seg.box.height * 1.4 ? "    " : smartInlineJoiner(left: lineText, right: seg.text)
                    lineText += sep + seg.text
                }
            }
            let minX = segs.map(\.box.minX).min() ?? 0
            let maxX = segs.map(\.box.maxX).max() ?? 1
            let minY = segs.map(\.box.minY).min() ?? 0
            let maxY = segs.map(\.box.maxY).max() ?? 0
            return MergedRow(minX: minX, maxX: maxX, minY: minY, maxY: maxY, text: lineText)
        }

        if mode == .preserveLines {
            return visualRows.map(\.text).joined(separator: "\n")
        }

        // 智能合并段落：识别明显垂直空行、短尾句、列表前缀
        let rightEdgeRef = visualRows.map(\.maxX).max() ?? 1.0
        let leftEdgeRef = visualRows.map(\.minX).min() ?? 0.0
        let spanW = max(0.1, rightEdgeRef - leftEdgeRef)

        var paragraphs: [String] = [visualRows[0].text]
        for i in 1..<visualRows.count {
            let prev = visualRows[i - 1]
            let curr = visualRows[i]
            let verticalGap = prev.minY - curr.maxY
            let avgH = (prev.height + curr.height) * 0.5

            let largeVerticalGap = verticalGap > avgH * 0.85
            let prevShortTail = (rightEdgeRef - prev.maxX) > spanW * 0.22
            let currIndentedOrList = (curr.minX - leftEdgeRef) > spanW * 0.06 || isListOrHeadingPrefix(curr.text)
            let prevTerminalPunct = endsWithSentenceStop(prev.text)

            if largeVerticalGap || isListOrHeadingPrefix(curr.text) || (prevShortTail && (prevTerminalPunct || currIndentedOrList)) {
                paragraphs.append(curr.text)
            } else {
                let last = paragraphs[paragraphs.count - 1]
                if last.hasSuffix("-") && !last.hasSuffix("--"),
                   let firstChar = curr.text.unicodeScalars.first,
                   CharacterSet.lowercaseLetters.contains(firstChar) {
                    paragraphs[paragraphs.count - 1] = String(last.dropLast()) + curr.text
                } else {
                    let join = smartInlineJoiner(left: last, right: curr.text)
                    paragraphs[paragraphs.count - 1] = last + join + curr.text
                }
            }
        }
        return paragraphs.joined(separator: "\n\n")
    }

    /// 对纯文本多行识别结果（如 VisionKit transcript）执行中英文智能合段
    public static func mergeTranscriptLines(_ transcript: String) -> String {
        let rawLines = transcript.components(separatedBy: .newlines)
        var paragraphs: [String] = []
        let nonEmpty = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return "" }

        let maxVisLen = max(12, nonEmpty.map(visualWidth).max() ?? 12)
        var prevWasBlank = true
        var prevVisLen = 0

        for raw in rawLines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                prevWasBlank = true
                continue
            }
            let curVisLen = visualWidth(line)
            let lastPara = paragraphs.last ?? ""
            let prevStoppedShort = endsWithSentenceStop(lastPara) && prevVisLen * 100 < maxVisLen * 80

            if prevWasBlank || paragraphs.isEmpty || isListOrHeadingPrefix(line) || prevStoppedShort {
                paragraphs.append(line)
            } else if lastPara.hasSuffix("-") && !lastPara.hasSuffix("--"),
                      let firstChar = line.unicodeScalars.first,
                      CharacterSet.lowercaseLetters.contains(firstChar) {
                paragraphs[paragraphs.count - 1] = String(lastPara.dropLast()) + line
            } else {
                let join = smartInlineJoiner(left: lastPara, right: line)
                paragraphs[paragraphs.count - 1] = lastPara + join + line
            }
            prevWasBlank = false
            prevVisLen = curVisLen
        }
        return paragraphs.joined(separator: "\n\n")
    }

    private static func visualWidth(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { $0 + (isCJKOrFullwidth($1) ? 2 : 1) }
    }

    /// 中日韩字符之间无缝拼接，拉丁词/数字之间自动补单个空格
    static func smartInlineJoiner(left: String, right: String) -> String {
        guard let lScalar = left.unicodeScalars.last,
              let rScalar = right.unicodeScalars.first else { return "" }
        if isCJKOrFullwidth(lScalar) || isCJKOrFullwidth(rScalar) {
            return ""
        }
        return " "
    }

    private static func isCJKOrFullwidth(_ s: UnicodeScalar) -> Bool {
        let v = s.value
        return (0x2E80...0x9FFF).contains(v)
            || (0xF900...0xFAFF).contains(v)
            || (0x3000...0x303F).contains(v)
            || (0xFF00...0xFFEF).contains(v)
    }

    private static func endsWithSentenceStop(_ s: String) -> Bool {
        guard let last = s.last else { return false }
        return "。！？；：.!?;:".contains(last)
    }

    private static func isListOrHeadingPrefix(_ s: String) -> Bool {
        let prefixes = ["- ", "* ", "• ", "· ", "# ", "## ", "1.", "2.", "3.", "4.", "①", "②", "③"]
        return prefixes.contains(where: { s.hasPrefix($0) })
    }
}
