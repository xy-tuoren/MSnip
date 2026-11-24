import Foundation

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
