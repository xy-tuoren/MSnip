import Foundation

/// 单条内置翻译语种元数据（由 macOS 系统 `Locale` 动态提供中/英/原生多语种名称，零包体积膨胀）
public struct TranslationLanguageEntry: Identifiable, Equatable, Sendable {
    public let code: String
    public let zhName: String
    public let enName: String
    public let nativeName: String
    public let isCommon: Bool

    public var id: String { code }

    public var displayTitle: String {
        if code.hasPrefix("zh") || code == "yue" || code == "wyw" || nativeName.isEmpty || nativeName == zhName {
            return zhName
        }
        return "\(zhName) (\(nativeName))"
    }

    public func matches(_ rawQuery: String) -> Bool {
        let q = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        return zhName.lowercased().contains(q)
            || enName.lowercased().contains(q)
            || nativeName.lowercased().contains(q)
            || code.lowercased().contains(q)
    }
}

/// 覆盖 Google 翻译全量 112 种世界语种目录与多云平台（Apple / 百度 / 腾讯 / 有道 / DeepL）语种码映射中心
public enum TranslationLanguageCatalog {
    /// 置顶高频常用 16 语种（按国内开发者与学术阅读使用频率排序）
    private static let commonCodes: [String] = [
        "zh-Hans", "zh-Hant", "yue", "wyw", "en", "ja", "ko", "fr",
        "de", "es", "ru", "pt", "it", "vi", "th", "ar"
    ]

    /// Google 翻译全系其他 96 种国际与地区语种 ISO / BCP-47 代码
    private static let extendedCodes: [String] = [
        "af", "sq", "am", "hy", "as", "ay", "az", "bm", "eu", "be", "bn", "bho", "bs", "bg", "ca", "ceb",
        "ny", "co", "hr", "cs", "da", "dv", "doi", "nl", "eo", "et", "ee", "tl", "fi", "fy", "gl", "ka",
        "el", "gn", "gu", "ht", "ha", "haw", "he", "hi", "hmn", "hu", "is", "ig", "ilo", "id", "ga", "jw",
        "kn", "kk", "km", "rw", "gom", "kri", "ku", "ckb", "ky", "lo", "la", "lv", "ln", "lt", "lg", "lb",
        "mk", "mai", "mg", "ms", "ml", "mt", "mi", "mr", "lus", "mn", "my", "ne", "no", "or", "om", "ps",
        "fa", "pl", "pa", "qu", "ro", "sm", "sa", "gd", "sr", "st", "sn", "sd", "si", "sk", "sl", "so",
        "su", "sw", "sv", "tg", "ta", "tt", "te", "ti", "ts", "tr", "tk", "ak", "uk", "ur", "ug", "uz",
        "cy", "xh", "yi", "yo", "zu"
    ]

    private static let zhOverrides: [String: String] = [
        "zh-Hans": "简体中文", "zh-Hant": "繁体中文", "yue": "粤语（广东话）", "wyw": "文言文",
        "tl": "菲律宾语", "jw": "爪哇语", "ceb": "宿务语", "haw": "夏威夷语", "hmn": "苗语",
        "la": "拉丁语", "eo": "世界语", "he": "希伯来语", "id": "印尼语", "ms": "马来语"
    ]

    private static let enOverrides: [String: String] = [
        "zh-Hans": "Simplified Chinese", "zh-Hant": "Traditional Chinese",
        "yue": "Cantonese", "wyw": "Classical Literary Chinese"
    ]

    public static let allEntries: [TranslationLanguageEntry] = {
        let zhLocale = Locale(identifier: "zh-Hans")
        let enLocale = Locale(identifier: "en")
        let commonSet = Set(commonCodes)
        var built: [TranslationLanguageEntry] = []
        var seen = Set<String>()

        func buildEntry(_ code: String, common: Bool) -> TranslationLanguageEntry? {
            guard !seen.contains(code) else { return nil }
            seen.insert(code)
            let zh = zhOverrides[code] ?? zhLocale.localizedString(forIdentifier: code) ?? code
            let en = enOverrides[code] ?? enLocale.localizedString(forIdentifier: code) ?? code
            let selfLoc = Locale(identifier: code)
            let native = selfLoc.localizedString(forIdentifier: code) ?? ""
            return TranslationLanguageEntry(code: code, zhName: zh, enName: en, nativeName: native, isCommon: common)
        }

        for c in commonCodes {
            if let e = buildEntry(c, common: true) { built.append(e) }
        }
        var rest: [TranslationLanguageEntry] = []
        for c in extendedCodes {
            if let e = buildEntry(c, common: false) { rest.append(e) }
        }
        rest.sort { $0.zhName.localizedStandardCompare($1.zhName) == .orderedAscending }
        built.append(contentsOf: rest)
        return built
    }()

    private static let entryMap: [String: TranslationLanguageEntry] = {
        Dictionary(uniqueKeysWithValues: allEntries.map { ($0.code, $0) })
    }()

    public static func entry(for code: String) -> TranslationLanguageEntry? {
        entryMap[code]
    }

    // MARK: - Multi-Provider Language Code Mapping

    private static let baiduIrregularMap: [String: String] = [
        "zh-Hans": "zh", "zh-Hant": "cht", "yue": "yue", "wyw": "wyw",
        "ja": "jp", "ko": "kor", "fr": "fra", "es": "spa", "ar": "ara",
        "bg": "bul", "et": "est", "da": "dan", "fi": "fin", "ro": "rom",
        "sl": "slo", "sv": "swe", "vi": "vie"
    ]

    public static func baiduCode(for code: String) -> String {
        if let mapped = baiduIrregularMap[code] { return mapped }
        return code.components(separatedBy: "-").first?.lowercased() ?? "zh"
    }

    public static func tencentCode(for code: String) -> String {
        switch code {
        case "zh-Hans", "yue", "wyw": return "zh"
        case "zh-Hant": return "zh-TW"
        case "he": return "iw"
        case "jw": return "jv"
        default: return code.components(separatedBy: "-").first?.lowercased() ?? "zh"
        }
    }

    public static func youdaoCode(for code: String) -> String {
        switch code {
        case "zh-Hans", "wyw": return "zh-CHS"
        case "zh-Hant": return "zh-CHT"
        default: return code
        }
    }

    public static func deeplCode(for code: String) -> String {
        switch code {
        case "zh-Hans", "yue", "wyw": return "ZH-HANS"
        case "zh-Hant": return "ZH-HANT"
        case "en": return "EN"
        case "pt": return "PT-PT"
        default: return (code.components(separatedBy: "-").first ?? "ZH").uppercased()
        }
    }

    public static func appleCode(for code: String) -> String {
        switch code {
        case "yue", "wyw": return "zh-Hant"
        default: return code
        }
    }

    /// 当用户输入自由自定义目标（如“粤语口语”、“地道美式英语”）但底层选了传统云 API 时，智能推断最接近的基础语种码
    public static func inferFallbackCode(fromCustom spec: String) -> String {
        let s = spec.lowercased()
        if s.contains("粤") || s.contains("广东") || s.contains("cantonese") { return "yue" }
        if s.contains("文言") || s.contains("古文") { return "wyw" }
        if s.contains("繁") || s.contains("台灣") || s.contains("台湾") || s.contains("traditional") { return "zh-Hant" }
        if s.contains("英") || s.contains("english") { return "en" }
        if s.contains("日") || s.contains("japanese") { return "ja" }
        if s.contains("韩") || s.contains("朝鲜") || s.contains("korean") { return "ko" }
        if s.contains("法") || s.contains("french") { return "fr" }
        if s.contains("德") || s.contains("german") { return "de" }
        if s.contains("西") || s.contains("spanish") { return "es" }
        if s.contains("俄") || s.contains("russian") { return "ru" }
        for item in allEntries where s.contains(item.zhName.lowercased()) || s.contains(item.enName.lowercased()) {
            return item.code
        }
        return "zh-Hans"
    }
}
