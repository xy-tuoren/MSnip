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
    case preserveLines   // 保持原行与代码缩进（适合代码、表格、终端日志、短标签）
    case mergeParagraphs // 智能合并换行与多栏重排（适合中英文长段落、PDF/网页正文）
}

/// 纯算法 OCR 阅读顺序重排、双栏识别、代码缩进保留与中英文智能段落合并器（零外部依赖）
public enum OCRTextFormatter {
    private static let invisibleScalars: Set<UInt32> = [0x200B, 0x200C, 0x200D, 0xFEFF]

    /// 清理零宽不可见脏字符与多余首尾空白
    public static func sanitizeLine(_ raw: String) -> String {
        let filtered = String(raw.unicodeScalars.filter { !invisibleScalars.contains($0.value) })
        return filtered.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 将乱序识别块按垂直重叠度聚类为视觉行，并按从上到下、同行从左到右排列
    public static func groupIntoVisualRows(_ items: [OCRLineObservation]) -> [[OCRLineObservation]] {
        let cleaned = items.compactMap { item -> OCRLineObservation? in
            let s = sanitizeLine(item.text)
            return s.isEmpty ? nil : OCRLineObservation(box: item.box, text: s)
        }
        guard !cleaned.isEmpty else { return [] }

        let byTop = cleaned.sorted { a, b in
            if abs(a.box.midY - b.box.midY) > 0.005 {
                return a.box.midY > b.box.midY
            }
            return a.box.minX < b.box.minX
        }

        struct RowBucket {
            var items: [OCRLineObservation]
            var minY: CGFloat
            var maxY: CGFloat
            var midY: CGFloat { (minY + maxY) * 0.5 }
            var height: CGFloat { max(0.004, maxY - minY) }
        }

        var buckets: [RowBucket] = []
        for item in byTop {
            var bestIdx: Int?
            var bestScore: CGFloat = 0
            // 向后回看最近 3 行，防止多栏或轻微倾斜导致同行被拆散
            let startIdx = max(0, buckets.count - 3)
            for idx in startIdx..<buckets.count {
                let b = buckets[idx]
                let overlap = min(b.maxY, item.box.maxY) - max(b.minY, item.box.minY)
                let minH = max(0.004, min(b.height, item.box.height))
                let overlapRatio = overlap / minH
                let centerDelta = abs(b.midY - item.box.midY)
                if overlapRatio >= 0.42 || centerDelta <= minH * 0.40 {
                    let score = overlapRatio - centerDelta
                    if bestIdx == nil || score > bestScore {
                        bestIdx = idx
                        bestScore = score
                    }
                }
            }

            if let idx = bestIdx {
                buckets[idx].items.append(item)
                buckets[idx].minY = min(buckets[idx].minY, item.box.minY)
                buckets[idx].maxY = max(buckets[idx].maxY, item.box.maxY)
            } else {
                buckets.append(RowBucket(items: [item], minY: item.box.minY, maxY: item.box.maxY))
            }
        }

        buckets.sort { $0.midY > $1.midY }
        return buckets.map { b in b.items.sorted { $0.box.minX < $1.box.minX } }
    }

    public static func format(_ items: [OCRLineObservation], mode: OCRLayoutMode) -> String {
        let cleaned = items.compactMap { item -> OCRLineObservation? in
            let s = sanitizeLine(item.text)
            return s.isEmpty ? nil : OCRLineObservation(box: item.box, text: s)
        }
        guard !cleaned.isEmpty else { return "" }

        // 双栏版式检测：在智能合段模式下先左栏再右栏，彻底解决双栏论文/文档混行串读
        if mode == .mergeParagraphs, let split = detectTwoColumnSplit(cleaned) {
            let leftStr = formatSingleRegion(split.left, mode: mode)
            let rightStr = formatSingleRegion(split.right, mode: mode)
            return [leftStr, rightStr].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        return formatSingleRegion(cleaned, mode: mode)
    }

    private static func formatSingleRegion(_ items: [OCRLineObservation], mode: OCRLayoutMode) -> String {
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
                    let sep = gapX > seg.box.height * 1.45 ? "    " : smartInlineJoiner(left: lineText, right: seg.text)
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
            return formatPreservedLinesWithIndentation(visualRows.map { ($0.minX, $0.height, $0.text) })
        }

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
                appendJoinedLine(curr.text, to: &paragraphs)
            }
        }
        return paragraphs.joined(separator: "\n\n")
    }

    /// 保持原行时按左边界偏移量还原代码/列表层级缩进（小偏差归零，明显阶梯缩进补齐空格）
    private static func formatPreservedLinesWithIndentation(_ rows: [(minX: CGFloat, height: CGFloat, text: String)]) -> String {
        guard rows.count >= 2 else { return rows.first?.text ?? "" }
        let sortedH = rows.map(\.height).sorted()
        let medH = max(0.008, sortedH[sortedH.count / 2])
        let baseLeft = rows.map(\.minX).min() ?? 0
        let charUnit = medH * 0.52

        // 仅当存在明显阶梯缩进且不是普通居中排版时才补空格
        let indentedCount = rows.filter { ($0.minX - baseLeft) > charUnit * 1.6 }.count
        guard indentedCount > 0, indentedCount < rows.count else {
            return rows.map(\.text).joined(separator: "\n")
        }

        return rows.map { r in
            let delta = r.minX - baseLeft
            guard delta > charUnit * 1.35 else { return r.text }
            let spaces = min(24, max(2, Int((delta / charUnit).rounded())))
            return String(repeating: " ", count: spaces) + r.text
        }.joined(separator: "\n")
    }

    /// 检测是否存在清晰双栏中缝（左右各至少 3 个文本块，且几乎无横跨中缝的宽行）
    private static func detectTwoColumnSplit(_ items: [OCRLineObservation]) -> (left: [OCRLineObservation], right: [OCRLineObservation])? {
        guard items.count >= 6 else { return nil }
        for probe in stride(from: CGFloat(0.38), through: 0.62, by: 0.04) {
            let gutterMin = probe - 0.018
            let gutterMax = probe + 0.018
            let spanning = items.filter { $0.box.minX < gutterMin && $0.box.maxX > gutterMax }
            guard spanning.isEmpty else { continue }
            let left = items.filter { $0.box.maxX <= gutterMax }
            let right = items.filter { $0.box.minX >= gutterMin }
            guard left.count >= 3, right.count >= 3 else { continue }
            let leftTop = left.map(\.box.maxY).max() ?? 0
            let leftBot = left.map(\.box.minY).min() ?? 1
            let rightTop = right.map(\.box.maxY).max() ?? 0
            let rightBot = right.map(\.box.minY).min() ?? 1
            let vertOverlap = min(leftTop, rightTop) - max(leftBot, rightBot)
            if vertOverlap > 0.18 {
                return (left, right)
            }
        }
        return nil
    }

    /// 对纯文本多行识别结果（如 VisionKit transcript）执行中英文智能合段
    public static func mergeTranscriptLines(_ transcript: String) -> String {
        let rawLines = transcript.components(separatedBy: .newlines)
        var paragraphs: [String] = []
        let nonEmpty = rawLines.map(sanitizeLine).filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return "" }

        let maxVisLen = max(12, nonEmpty.map(visualWidth).max() ?? 12)
        var prevWasBlank = true
        var prevVisLen = 0

        for raw in rawLines {
            let line = sanitizeLine(raw)
            if line.isEmpty {
                prevWasBlank = true
                continue
            }
            let curVisLen = visualWidth(line)
            let lastPara = paragraphs.last ?? ""
            let prevStoppedShort = endsWithSentenceStop(lastPara) && prevVisLen * 100 < maxVisLen * 80

            if prevWasBlank || paragraphs.isEmpty || isListOrHeadingPrefix(line) || prevStoppedShort {
                paragraphs.append(line)
            } else {
                appendJoinedLine(line, to: &paragraphs)
            }
            prevWasBlank = false
            prevVisLen = curVisLen
        }
        return paragraphs.joined(separator: "\n\n")
    }

    private static func appendJoinedLine(_ line: String, to paragraphs: inout [String]) {
        guard !paragraphs.isEmpty else { paragraphs.append(line); return }
        let last = paragraphs[paragraphs.count - 1]
        if last.hasSuffix("-") && !last.hasSuffix("--"),
           let firstChar = line.unicodeScalars.first,
           CharacterSet.lowercaseLetters.contains(firstChar) {
            paragraphs[paragraphs.count - 1] = String(last.dropLast()) + line
        } else {
            paragraphs[paragraphs.count - 1] = last + smartInlineJoiner(left: last, right: line) + line
        }
    }

    private static func visualWidth(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { $0 + (isCJKOrFullwidth($1) ? 2 : 1) }
    }

    /// 中日韩字符及括号/斜杠/尾标点处无缝拼接，拉丁词与数字之间自动补单个空格
    public static func smartInlineJoiner(left: String, right: String) -> String {
        guard let lScalar = left.unicodeScalars.last,
              let rScalar = right.unicodeScalars.first else { return "" }
        if isCJKOrFullwidth(lScalar) || isCJKOrFullwidth(rScalar) { return "" }
        let noSpaceAfter = "([{/\\@#“‘"
        let noSpaceBefore = ")]},.;:!?%”’"
        if let lc = left.last, noSpaceAfter.contains(lc) { return "" }
        if let rc = right.first, noSpaceBefore.contains(rc) { return "" }
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
