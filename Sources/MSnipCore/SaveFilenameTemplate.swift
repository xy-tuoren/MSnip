import Foundation

/// 自定义保存文件名模板渲染器（纯值类型公历分量计算，100% 线程安全且不受非公历/12h 系统区域干扰）
public enum SaveFilenameTemplate {
    public static let defaultTemplate = "MSnip-{date}-{time}"

    public static func render(
        template rawTemplate: String,
        date: Date = Date(),
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        fileExtension: String,
        appendMillisIfNoMillis: Bool = false
    ) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        let yyyy = String(format: "%04d", comps.year ?? 2026)
        let MM   = String(format: "%02d", comps.month ?? 1)
        let dd   = String(format: "%02d", comps.day ?? 1)
        let HH   = String(format: "%02d", comps.hour ?? 0)
        let mm   = String(format: "%02d", comps.minute ?? 0)
        let ss   = String(format: "%02d", comps.second ?? 0)
        let SSS  = String(format: "%03d", max(0, min(999, (comps.nanosecond ?? 0) / 1_000_000)))
        let dateStr = "\(yyyy)\(MM)\(dd)"
        let timeStr = "\(HH)\(mm)\(ss)"

        let trimmed = rawTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        var stem = trimmed.isEmpty ? defaultTemplate : trimmed
        let hadMillis = stem.contains("{SSS}")

        let replacements: [(String, String)] = [
            ("{date}", dateStr), ("{time}", timeStr),
            ("{yyyy}", yyyy),    ("{MM}", MM), ("{dd}", dd),
            ("{HH}", HH),        ("{mm}", mm), ("{ss}", ss), ("{SSS}", SSS),
            ("{w}", pixelWidth.map { "\($0)" } ?? "0"),
            ("{h}", pixelHeight.map { "\($0)" } ?? "0")
        ]
        for (token, val) in replacements {
            stem = stem.replacingOccurrences(of: token, with: val)
        }
        stem = sanitizeStem(stem)
        if stem.isEmpty { stem = "MSnip-\(dateStr)-\(timeStr)" }
        if appendMillisIfNoMillis && !hadMillis { stem += "-\(SSS)" }
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
