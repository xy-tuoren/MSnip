import Foundation

/// 界面文案本地化：源码以简体中文原文作键，`Resources/en.lproj/Localizable.strings` 提供英文译文，
/// 当前语言没有译文时直接回落中文原文。插值文案写成 `L("已复制 %@ 项", count)`，译文可用 `%1$@` 调整参数顺序。
public enum MSnipL10n {
    private static let lock = NSLock()
    private static var overrideTable: [String: String]?

    /// 注入一张固定译文表（单测与调试截图用）；传 nil 恢复为读取主 Bundle 的 `Localizable.strings`
    public static func setOverrideTable(_ table: [String: String]?) {
        lock.lock()
        overrideTable = table
        lock.unlock()
    }

    /// 界面文案当前是否解析为英文：注入了译文表时按注入表判断，否则看主 Bundle 选中的本地化（进程内固定，切换语言需重启）
    public static var usesEnglish: Bool {
        lock.lock()
        let table = overrideTable
        lock.unlock()
        if let table { return !table.isEmpty }
        return bundleUsesEnglish
    }

    private static let bundleUsesEnglish: Bool = {
        guard Bundle.main.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "en") != nil else {
            return false
        }
        return Bundle.main.preferredLocalizations.first?.hasPrefix("en") ?? false
    }()

    public static func lookup(_ key: String) -> String {
        lock.lock()
        let table = overrideTable
        lock.unlock()
        if let table { return table[key] ?? key }
        return Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    /// 只识别 `%@`、`%1$@`…`%9$@` 与 `%%`：参数一律先转成字符串，个数不足时留空，
    /// 不会像 `String(format:)` 那样因译文占位符与参数类型或个数不符而崩溃；其余 `%` 原样保留。
    public static func format(_ template: String, _ args: [String]) -> String {
        guard template.contains("%") else { return template }
        var out = ""
        var sequential = 0
        for token in tokenize(template) {
            switch token {
            case .text(let s):
                out += s
            case .next:
                if sequential < args.count { out += args[sequential] }
                sequential += 1
            case .position(let n):
                if n <= args.count { out += args[n - 1] }
            }
        }
        return out
    }

    /// 模板用到的参数序号（`%@ %@` 与 `%2$@ %1$@` 都是 [1, 2]），用于校验译文与原文的占位符一致
    public static func placeholderSignature(_ template: String) -> [Int] {
        var used = Set<Int>()
        var sequential = 0
        for token in tokenize(template) {
            switch token {
            case .text: break
            case .next: sequential += 1; used.insert(sequential)
            case .position(let n): used.insert(n)
            }
        }
        return used.sorted()
    }

    private enum Token { case text(Substring), next, position(Int) }

    private static func tokenize(_ template: String) -> [Token] {
        var tokens: [Token] = []
        var literalStart = template.startIndex
        var i = template.startIndex
        func flush(upTo end: String.Index) {
            if literalStart < end { tokens.append(.text(template[literalStart..<end])) }
        }
        while i < template.endIndex {
            guard template[i] == "%" else { i = template.index(after: i); continue }
            let rest = template[template.index(after: i)...]
            if rest.hasPrefix("@") {
                flush(upTo: i); tokens.append(.next)
                i = template.index(i, offsetBy: 2)
            } else if rest.hasPrefix("%") {
                flush(upTo: i); tokens.append(.text("%"))
                i = template.index(i, offsetBy: 2)
            } else if let d = rest.first?.wholeNumberValue, d >= 1, rest.dropFirst().hasPrefix("$@") {
                flush(upTo: i); tokens.append(.position(d))
                i = template.index(i, offsetBy: 4)
            } else {
                i = template.index(after: i)
                continue
            }
            literalStart = i
        }
        flush(upTo: template.endIndex)
        return tokens
    }
}

/// 界面语言偏好：写入本应用域的 `AppleLanguages`（与「系统设置 › 语言与地区 › App」同一机制），重启后生效
public enum MSnipInterfaceLanguage: String, CaseIterable, Sendable {
    case system, simplifiedChinese = "zh-Hans", english = "en"

    /// 语言名称始终用该语言自身书写，任何界面语言下都认得出来
    public var nativeName: String {
        switch self {
        case .system:            return L("跟随系统")
        case .simplifiedChinese: return "简体中文"
        case .english:           return "English"
        }
    }

    public static func current(defaults: UserDefaults = .standard, bundleID: String? = Bundle.main.bundleIdentifier) -> MSnipInterfaceLanguage {
        guard let bundleID,
              let langs = defaults.persistentDomain(forName: bundleID)?["AppleLanguages"] as? [String],
              let first = langs.first else { return .system }
        if first.hasPrefix("zh") { return .simplifiedChinese }
        if first.hasPrefix("en") { return .english }
        return .system
    }

    public static func apply(_ language: MSnipInterfaceLanguage, defaults: UserDefaults = .standard, bundleID: String? = Bundle.main.bundleIdentifier) {
        guard let bundleID else { return }
        var domain = defaults.persistentDomain(forName: bundleID) ?? [:]
        if language == .system {
            domain.removeValue(forKey: "AppleLanguages")
        } else {
            domain["AppleLanguages"] = [language.rawValue]
        }
        defaults.setPersistentDomain(domain, forName: bundleID)
    }
}

/// 提示文案的语气（决定 Toast 图标与配色）：同时识别中文与英文措辞，界面语言切换后仍一致
public enum MessageTone: Sendable, Equatable {
    case warning, success, neutral

    private static let zhWarnPrefixes = ["⚠", "未识别", "未检测", "未能", "未找到", "暂无", "请先"]
    /// 英文译文的对应措辞：失败类词、「… first」（请先…）、「No …」（未检测到 / 暂无…）
    private static let enWarnWords = ["failed", "couldn't", "could not", "cannot", "can't", "unable", "error", "denied",
                                      "timed out", "not found", "unavailable", "too short", " first", " has no "]

    public static func classify(_ message: String) -> MessageTone {
        let lower = message.lowercased()
        if zhWarnPrefixes.contains(where: { message.hasPrefix($0) }) || message.contains("失败") || message.contains("冲突")
            || message.hasPrefix("No ") || message.hasPrefix("Nothing ") || enWarnWords.contains(where: { lower.contains($0) }) {
            return .warning
        }
        // 成功：✓ 开头、中文含「已」，或英文以过去分词开头（Copied / Saved / Pinned …）
        let firstWord = message.split(separator: " ").first.map(String.init) ?? ""
        if message.hasPrefix("✓") || message.contains("已")
            || (firstWord.count > 3 && firstWord.hasSuffix("ed") && firstWord.first?.isUppercase == true) {
            return .success
        }
        return .neutral
    }
}

@inline(never)
public func L(_ key: String) -> String {
    MSnipL10n.lookup(key)
}

@inline(never)
public func L(_ key: String, _ args: CustomStringConvertible...) -> String {
    MSnipL10n.format(MSnipL10n.lookup(key), args.map { $0.description })
}
