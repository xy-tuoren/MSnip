import CoreGraphics
import Foundation

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
