import Foundation

/// 自定义保存文件名模板渲染器（支持日期/时间/尺寸占位符，自动清洗非法路径字符防目录穿越）
public enum SaveFilenameTemplate {
    public static let defaultTemplate = "MSnip-{date}-{time}"

    private static let dateFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; return f }()
    private static let timeFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HHmmss"; return f }()
    private static let yearFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy"; return f }()
    private static let monthFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MM"; return f }()
    private static let dayFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd"; return f }()
    private static let hourFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH"; return f }()
    private static let minFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "mm"; return f }()
    private static let secFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "ss"; return f }()
    private static let msFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "SSS"; return f }()

    /// 根据模板与元数据生成安全文件名（含后缀，如 `MSnip-20261124-123045.png`）
    public static func render(
        template rawTemplate: String,
        date: Date = Date(),
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        fileExtension: String,
        appendMillisIfNoMillis: Bool = false
    ) -> String {
        let trimmed = rawTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        var stem = trimmed.isEmpty ? defaultTemplate : trimmed
        let hadMillis = stem.contains("{SSS}")

        let replacements: [(String, String)] = [
            ("{date}", dateFmt.string(from: date)),
            ("{time}", timeFmt.string(from: date)),
            ("{yyyy}", yearFmt.string(from: date)),
            ("{MM}",   monthFmt.string(from: date)),
            ("{dd}",   dayFmt.string(from: date)),
            ("{HH}",   hourFmt.string(from: date)),
            ("{mm}",   minFmt.string(from: date)),
            ("{ss}",   secFmt.string(from: date)),
            ("{SSS}",  msFmt.string(from: date)),
            ("{w}",    pixelWidth.map { "\($0)" } ?? "0"),
            ("{h}",    pixelHeight.map { "\($0)" } ?? "0")
        ]
        for (token, val) in replacements {
            stem = stem.replacingOccurrences(of: token, with: val)
        }
        stem = sanitizeStem(stem)
        if stem.isEmpty {
            stem = "MSnip-\(dateFmt.string(from: date))-\(timeFmt.string(from: date))"
        }
        if appendMillisIfNoMillis && !hadMillis {
            stem += "-\(msFmt.string(from: date))"
        }
        let ext = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ". \t\n"))
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    private static func sanitizeStem(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|\r\n\t")
        let cleaned = raw.components(separatedBy: forbidden).joined(separator: "-")
            .replacingOccurrences(of: "..", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return String(cleaned.prefix(100))
    }
}
