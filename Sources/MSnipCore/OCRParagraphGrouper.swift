import CoreGraphics
import Foundation

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
