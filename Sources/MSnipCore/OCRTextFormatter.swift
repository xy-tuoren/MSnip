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

// MARK: - OCR 段落智能重组与合并

/// 聚合后的原位翻译段落块（`box` 为 Vision 归一化左下角坐标系 `0..1`）
public struct OCRParagraphBlock: Equatable, Sendable {
    public let box: CGRect
    public let text: String
    public let lineCount: Int
    public let avgLineHeight: CGFloat

    public init(box: CGRect, text: String, lineCount: Int, avgLineHeight: CGFloat) {
        self.box = box
        self.text = text
        self.lineCount = lineCount
        self.avgLineHeight = avgLineHeight
    }
}

/// 纯算法段落聚类器：将垂直紧邻、同栏左对齐且字号相近的视觉行合并为自然段落，
/// 同时把同行大间距（按钮/表格多列）切分为独立单元，大幅提升原位翻译上下文连贯性与排版美观度。
public enum OCRParagraphGrouper {
    public static func group(_ observations: [OCRLineObservation]) -> [OCRParagraphBlock] {
        let visualRows = OCRTextFormatter.groupIntoVisualRows(observations)
        guard !visualRows.isEmpty else { return [] }

        // 1) 同行大间距（如表格列、左右导航按钮）拆分为独立行段，同行普通词距正常合并
        struct SegLine {
            let box: CGRect
            let text: String
        }
        var lines: [SegLine] = []
        for row in visualRows {
            var curBox: CGRect?
            var curText = ""
            for obs in row {
                let t = OCRTextFormatter.sanitizeLine(obs.text)
                guard !t.isEmpty else { continue }
                if let prev = curBox {
                    let gapX = obs.box.minX - prev.maxX
                    let refH = max(0.008, min(prev.height, obs.box.height))
                    if gapX > max(0.06, refH * 2.4) {
                        lines.append(SegLine(box: prev, text: curText))
                        curBox = obs.box
                        curText = t
                    } else {
                        curBox = prev.union(obs.box)
                        curText += OCRTextFormatter.smartInlineJoiner(left: curText, right: t) + t
                    }
                } else {
                    curBox = obs.box
                    curText = t
                }
            }
            if let b = curBox, !curText.isEmpty {
                lines.append(SegLine(box: b, text: curText))
            }
        }
        guard !lines.isEmpty else { return [] }

        // 2) 自顶向下合并属于同一自然段的连续行（支持多栏独立成段）
        struct Builder {
            var box: CGRect
            var text: String
            var lineCount: Int
            var heightSum: CGFloat
            var lastBox: CGRect
            var avgH: CGFloat { heightSum / CGFloat(max(1, lineCount)) }
        }
        var blocks: [Builder] = []
        for line in lines {
            var matchIdx: Int?
            for idx in stride(from: blocks.count - 1, through: max(0, blocks.count - 6), by: -1) {
                let b = blocks[idx]
                let avgH = (b.avgH + line.box.height) * 0.5
                let vGap = b.lastBox.minY - line.box.maxY
                guard vGap >= -avgH * 0.25 && vGap <= avgH * 0.85 else { continue }

                let hRatio = max(b.avgH, line.box.height) / max(0.002, min(b.avgH, line.box.height))
                guard hRatio <= 1.38 else { continue }

                // 水平区间重叠且左边界基本对齐（防止跨栏合并或居中按钮误合）
                let hOverlap = min(b.box.maxX, line.box.maxX) - max(b.box.minX, line.box.minX)
                guard hOverlap > min(b.box.width, line.box.width) * 0.32 else { continue }
                let leftDiff = abs(b.box.minX - line.box.minX)
                guard leftDiff <= max(0.045, avgH * 2.2) else { continue }

                // 列表/标题前缀或上行短尾句号换段
                if isListPrefix(line.text) { continue }
                if b.lastBox.width < b.box.width * 0.72 && endsWithStop(b.text) { continue }

                matchIdx = idx
                break
            }

            if let idx = matchIdx {
                let prevText = blocks[idx].text
                let joined: String
                if prevText.hasSuffix("-") && !prevText.hasSuffix("--"),
                   let first = line.text.unicodeScalars.first,
                   CharacterSet.lowercaseLetters.contains(first) {
                    joined = String(prevText.dropLast()) + line.text
                } else {
                    joined = prevText + OCRTextFormatter.smartInlineJoiner(left: prevText, right: line.text) + line.text
                }
                blocks[idx].text = joined
                blocks[idx].box = blocks[idx].box.union(line.box)
                blocks[idx].lastBox = line.box
                blocks[idx].lineCount += 1
                blocks[idx].heightSum += line.box.height
            } else {
                blocks.append(Builder(
                    box: line.box, text: line.text, lineCount: 1,
                    heightSum: line.box.height, lastBox: line.box
                ))
            }
        }

        return blocks.map {
            OCRParagraphBlock(box: $0.box, text: $0.text, lineCount: $0.lineCount, avgLineHeight: $0.avgH)
        }
    }

    private static func endsWithStop(_ s: String) -> Bool {
        guard let last = s.last else { return false }
        return "。！？.!?;；".contains(last)
    }

    private static func isListPrefix(_ s: String) -> Bool {
        ["- ", "* ", "• ", "· ", "# ", "## ", "1.", "2.", "3.", "①", "②", "③"].contains(where: { s.hasPrefix($0) })
    }
}

// MARK: - OCR 表格重建与 Markdown/TSV 导出

/// OCR 表格结构还原结果（支持 Markdown 表格与 Excel/Numbers 通用 TSV）
public struct OCRTableResult: Equatable, Sendable {
    public let rows: [[String]]
    public let columnCount: Int
    public let markdown: String
    public let tsv: String

    public init(rows: [[String]], columnCount: Int, markdown: String, tsv: String) {
        self.rows = rows
        self.columnCount = columnCount
        self.markdown = markdown
        self.tsv = tsv
    }
}

/// 纯算法 OCR 表格探测器：基于边界框列槽聚类将多列文本块还原为 Markdown / TSV 表格
public enum OCRTableFormatter {
    public static func extractTable(from observations: [OCRLineObservation]) -> OCRTableResult? {
        let visualRows = OCRTextFormatter.groupIntoVisualRows(observations)
        guard visualRows.count >= 2 else { return nil }

        let allHeights = observations.map(\.box.height).filter { $0 > 0.002 }.sorted()
        let medH = allHeights.isEmpty ? 0.025 : allHeights[allHeights.count / 2]
        let cellSplitGap = max(0.025, medH * 1.15)

        // 1) 将每视觉行按水平明显空隙切分为独立单元格
        struct Cell { let minX: CGFloat; let maxX: CGFloat; let text: String }
        var rowCells: [[Cell]] = []
        for row in visualRows {
            var cells: [Cell] = []
            for obs in row {
                let text = OCRTextFormatter.sanitizeLine(obs.text)
                guard !text.isEmpty else { continue }
                if let last = cells.last, (obs.box.minX - last.maxX) < cellSplitGap {
                    let sep = OCRTextFormatter.smartInlineJoiner(left: last.text, right: text)
                    cells[cells.count - 1] = Cell(
                        minX: last.minX,
                        maxX: max(last.maxX, obs.box.maxX),
                        text: last.text + sep + text
                    )
                } else {
                    cells.append(Cell(minX: obs.box.minX, maxX: obs.box.maxX, text: text))
                }
            }
            if !cells.isEmpty { rowCells.append(cells) }
        }

        let multiCellRows = rowCells.filter { $0.count >= 2 }.count
        guard rowCells.count >= 2, multiCellRows >= 2, multiCellRows * 100 >= rowCells.count * 50 else {
            return nil
        }

        // 2) 对全部单元格的左边界进行一维聚类，构建列槽中心
        let allStarts = rowCells.flatMap { $0.map(\.minX) }.sorted()
        let colTol = max(0.045, medH * 1.55)
        var colAnchors: [CGFloat] = []
        var colCounts: [Int] = []
        for x in allStarts {
            if let last = colAnchors.last, abs(x - last) <= colTol {
                let n = colCounts[colCounts.count - 1]
                colAnchors[colAnchors.count - 1] = (last * CGFloat(n) + x) / CGFloat(n + 1)
                colCounts[colCounts.count - 1] = n + 1
            } else {
                colAnchors.append(x)
                colCounts.append(1)
            }
        }
        guard colAnchors.count >= 2, colAnchors.count <= 12 else { return nil }

        // 3) 将每行单元格分配至最近列槽
        let colCount = colAnchors.count
        var grid: [[String]] = []
        var populatedMultiColRows = 0
        for cells in rowCells {
            var line = Array(repeating: "", count: colCount)
            var usedCols = Set<Int>()
            for cell in cells {
                var bestCol = 0
                var bestDist = CGFloat.greatestFiniteMagnitude
                for (ci, anchor) in colAnchors.enumerated() {
                    let d = abs(cell.minX - anchor)
                    if d < bestDist { bestDist = d; bestCol = ci }
                }
                if line[bestCol].isEmpty {
                    line[bestCol] = cell.text
                } else {
                    line[bestCol] += OCRTextFormatter.smartInlineJoiner(left: line[bestCol], right: cell.text) + cell.text
                }
                usedCols.insert(bestCol)
            }
            if usedCols.count >= 2 { populatedMultiColRows += 1 }
            grid.append(line)
        }
        guard populatedMultiColRows >= 2 else { return nil }

        // 4) 剔除完全空白列
        let activeCols = (0..<colCount).filter { ci in grid.contains { !$0[ci].isEmpty } }
        guard activeCols.count >= 2 else { return nil }
        let normalizedGrid = grid.map { row in activeCols.map { row[$0] } }

        let md = buildMarkdown(rows: normalizedGrid)
        let tsv = buildTSV(rows: normalizedGrid)
        return OCRTableResult(rows: normalizedGrid, columnCount: activeCols.count, markdown: md, tsv: tsv)
    }

    private static func buildMarkdown(rows: [[String]]) -> String {
        guard let header = rows.first else { return "" }
        func escapeCell(_ s: String) -> String {
            s.replacingOccurrences(of: "|", with: "\\|")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        var lines: [String] = []
        lines.append("| " + header.map(escapeCell).joined(separator: " | ") + " |")
        lines.append("| " + header.map { _ in "---" }.joined(separator: " | ") + " |")
        for row in rows.dropFirst() {
            lines.append("| " + row.map(escapeCell).joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    private static func buildTSV(rows: [[String]]) -> String {
        rows.map { row in
            row.map {
                $0.replacingOccurrences(of: "\t", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }
}

// MARK: - 敏感隐私字段离线探测

/// 离线敏感隐私文本类型（供一键智能打码精确识别子串范围）
public enum SensitiveMatchKind: String, Equatable, Sendable {
    case apiKey
    case email
    case phone
    case idCard
    case ipv4
    case bankCard
}

public struct SensitiveTextMatch: Equatable, Sendable {
    public let kind: SensitiveMatchKind
    public let range: Range<String.Index>
    public let matchedText: String

    public init(kind: SensitiveMatchKind, range: Range<String.Index>, matchedText: String) {
        self.kind = kind
        self.range = range
        self.matchedText = matchedText
    }
}

/// 纯 Swift 离线隐私敏感字段规则探测器（零外部依赖，兼容 macOS 12+）：
/// 识别 API Key / JWT / 邮箱 / 手机号 / 18 位身份证 / IPv4 / 银行卡号，并合并重叠子串范围供 Vision 精确定位局部选框。
public enum SensitiveTextDetector {
    private struct Rule {
        let kind: SensitiveMatchKind
        let regex: NSRegularExpression
    }

    private static let rules: [Rule] = {
        let specs: [(SensitiveMatchKind, String)] = [
            // API Key / Secret Token / JWT
            (.apiKey, #"(?i)\b(?:sk-(?:proj-|ant-|live-|test-)?[A-Za-z0-9_-]{14,}|gh[pousr]_[A-Za-z0-9]{18,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{28,}|xox[baprs]-[0-9A-Za-z-]{10,}|Bearer\s+[A-Za-z0-9._-]{16,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})"#),
            // 电子邮箱
            (.email, #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#),
            // 18 位中国大陆居民身份证号
            (.idCard, #"(?<!\d)[1-9]\d{5}(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[\dXx](?!\d)"#),
            // 16~19 位银行卡号（支持 4 位空格/连字符分隔）
            (.bankCard, #"(?<!\d)(?:\d{4}[\s-]?){3}\d{4,7}(?!\d)"#),
            // 11 位中国大陆手机号（支持 3-4-4 空格或连字符分隔）
            (.phone, #"(?<!\d)(?:\+?86[\s-]?)?1[3-9]\d[\s-]?\d{4}[\s-]?\d{4}(?!\d)"#),
            // IPv4 地址（排除本地环回 127.0.0.1 与 0.0.0.0）
            (.ipv4, #"(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?![\d.])"#)
        ]
        return specs.compactMap { kind, pattern in
            (try? NSRegularExpression(pattern: pattern)).map { Rule(kind: kind, regex: $0) }
        }
    }()

    /// 在单行文本中扫描全部敏感子串（自动去重与合并重叠区间，按从左到右排序）
    public static func detect(in text: String) -> [SensitiveTextMatch] {
        guard text.count >= 6 else { return [] }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var rawMatches: [SensitiveTextMatch] = []

        for rule in rules {
            for hit in rule.regex.matches(in: text, options: [], range: nsRange) {
                guard let swiftRange = Range(hit.range, in: text) else { continue }
                let sub = String(text[swiftRange])
                if rule.kind == .ipv4, (sub == "127.0.0.1" || sub == "0.0.0.0") { continue }
                if rule.kind == .bankCard {
                    let digits = sub.filter(\.isNumber)
                    if digits.count < 16 || digits.count > 19 { continue }
                }
                rawMatches.append(SensitiveTextMatch(kind: rule.kind, range: swiftRange, matchedText: sub))
            }
        }
        guard !rawMatches.isEmpty else { return [] }
        rawMatches.sort { a, b in
            if a.range.lowerBound != b.range.lowerBound { return a.range.lowerBound < b.range.lowerBound }
            return a.range.upperBound > b.range.upperBound
        }

        // 合并重叠区间，优先保留先匹配到的高优先级类型（如 18 位身份证不被误拆成手机号）
        var merged: [SensitiveTextMatch] = []
        for m in rawMatches {
            if let last = merged.last, m.range.lowerBound < last.range.upperBound {
                if m.range.upperBound > last.range.upperBound {
                    let combined = last.range.lowerBound..<m.range.upperBound
                    merged[merged.count - 1] = SensitiveTextMatch(
                        kind: last.kind, range: combined, matchedText: String(text[combined])
                    )
                }
            } else {
                merged.append(m)
            }
        }
        return merged
    }
}
