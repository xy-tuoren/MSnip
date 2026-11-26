import Foundation

/// 截图翻译目标语种：
/// - 内置「自动互译」+ Google 翻译级 112 种全球标准语种（`TranslationLanguageCatalog`）；
/// - 支持任意用户自定义目标语种、方言或翻译风格（如 `custom:粤语口语`、`custom:地道学术英文`），单字符串无缝序列化兼容。
public struct TranslationTargetLang: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rawValue = trimmed.isEmpty ? "auto_zh_en" : trimmed
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let str = (try? c.decode(String.self)) ?? "auto_zh_en"
        self.init(rawValue: str)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    // MARK: - Standard Presets & Custom Constructor

    public static let autoZhEn = TranslationTargetLang(rawValue: "auto_zh_en")
    public static let zhHans   = TranslationTargetLang(rawValue: "zh-Hans")
    public static let zhHant   = TranslationTargetLang(rawValue: "zh-Hant")
    public static let en       = TranslationTargetLang(rawValue: "en")
    public static let ja       = TranslationTargetLang(rawValue: "ja")
    public static let ko       = TranslationTargetLang(rawValue: "ko")
    public static let fr       = TranslationTargetLang(rawValue: "fr")
    public static let de       = TranslationTargetLang(rawValue: "de")
    public static let es       = TranslationTargetLang(rawValue: "es")
    public static let ru       = TranslationTargetLang(rawValue: "ru")

    public static func language(_ code: String) -> TranslationTargetLang {
        TranslationTargetLang(rawValue: code)
    }

    public static func custom(_ userInput: String) -> TranslationTargetLang {
        var clean = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.lowercased().hasPrefix("custom:") {
            clean = String(clean.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !clean.isEmpty else { return .autoZhEn }
        if clean == "auto_zh_en" { return .autoZhEn }
        if let exact = TranslationLanguageCatalog.allEntries.first(where: {
            $0.code.caseInsensitiveCompare(clean) == .orderedSame || $0.zhName == clean
        }) {
            return .language(exact.code)
        }
        return TranslationTargetLang(rawValue: "custom:\(clean)")
    }

    public var isCustom: Bool { rawValue.hasPrefix("custom:") }

    public var customText: String? {
        guard isCustom else { return nil }
        let s = String(rawValue.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private var effectiveCode: String {
        if rawValue == "auto_zh_en" { return "zh-Hans" }
        if let custom = customText { return TranslationLanguageCatalog.inferFallbackCode(fromCustom: custom) }
        return rawValue
    }

    public var displayName: String {
        if rawValue == "auto_zh_en" { return "自动互译（外→中 / 中→英）" }
        if let custom = customText { return "自定义：\(custom)" }
        if let entry = TranslationLanguageCatalog.entry(for: rawValue) { return entry.displayTitle }
        return rawValue
    }

    public var promptLanguageName: String {
        if rawValue == "auto_zh_en" { return "Simplified Chinese" }
        if let custom = customText { return custom }
        if let entry = TranslationLanguageCatalog.entry(for: rawValue) {
            return "\(entry.enName) (\(entry.zhName))"
        }
        return rawValue
    }

    public var appleIdentifier: String { TranslationLanguageCatalog.appleCode(for: effectiveCode) }
    public var baiduCode: String       { TranslationLanguageCatalog.baiduCode(for: effectiveCode) }
    public var tencentCode: String     { TranslationLanguageCatalog.tencentCode(for: effectiveCode) }
    public var youdaoCode: String      { TranslationLanguageCatalog.youdaoCode(for: effectiveCode) }
    public var deeplCode: String       { TranslationLanguageCatalog.deeplCode(for: effectiveCode) }

    /// 根据输入文本自动推断源语种与实际目标语种（处理 `.autoZhEn` 双向智能互译）
    public static func resolve(target: TranslationTargetLang, sampleText: String) -> (sourceApple: String, concreteTarget: TranslationTargetLang) {
        var hanCount = 0, kanaCount = 0, hangulCount = 0, alphaCount = 0
        for scalar in sampleText.unicodeScalars {
            let v = scalar.value
            if (0x3040...0x30FF).contains(v) { kanaCount += 1 }
            else if (0xAC00...0xD7AF).contains(v) { hangulCount += 1 }
            else if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) { hanCount += 1 }
            else if CharacterSet.letters.contains(scalar) { alphaCount += 1 }
        }
        let totalLetters = max(1, hanCount + kanaCount + hangulCount + alphaCount)
        let sourceGuess: String
        if kanaCount > 0 && kanaCount * 8 >= totalLetters { sourceGuess = "ja" }
        else if hangulCount > 0 && hangulCount * 6 >= totalLetters { sourceGuess = "ko" }
        else if hanCount * 100 >= totalLetters * 22 { sourceGuess = "zh-Hans" }
        else { sourceGuess = "en" }

        if target == .autoZhEn {
            let resolvedTarget: TranslationTargetLang = (sourceGuess == "zh-Hans") ? .en : .zhHans
            return (sourceGuess, resolvedTarget)
        }
        if !target.isCustom && sourceGuess == target.appleIdentifier {
            let altSource = (target == .en) ? "zh-Hans" : "en"
            return (altSource, target)
        }
        return (sourceGuess, target)
    }
}

/// 支持的 10 大类翻译协议族（完整涵盖 CC Switch 常见 4 大 LLM 接口格式 + 系统离线 + 主流云翻译）
public enum TranslationProviderKind: String, CaseIterable, Codable, Sendable {
    case appleNative = "apple_native"
    case openAICompatible = "openai_compatible"
    case openAIResponses = "openai_responses"
    case anthropicCompatible = "anthropic_compatible"
    case geminiNative = "gemini_native"
    case tencent = "tencent_tmt"
    case baidu = "baidu_fanyi"
    case youdao = "youdao_v3"
    case deepl = "deepl"
    case customWebhook = "custom_webhook"

    public static let llmProtocolCases: [TranslationProviderKind] = [
        .openAICompatible, .openAIResponses, .anthropicCompatible, .geminiNative
    ]

    public var isLLMProtocol: Bool {
        switch self {
        case .openAICompatible, .openAIResponses, .anthropicCompatible, .geminiNative: return true
        default: return false
        }
    }

    public var llmFormatTitle: String {
        switch self {
        case .openAICompatible:    return "OpenAI Chat Completions (/v1/chat/completions)"
        case .openAIResponses:     return "OpenAI Responses (/v1/responses)"
        case .anthropicCompatible: return "Anthropic Messages (/v1/messages)"
        case .geminiNative:        return "Google Gemini 原生 (/v1beta/models)"
        default:                   return displayName
        }
    }

    public var displayName: String {
        switch self {
        case .appleNative:         return "macOS 原生离线翻译（免费 · 无需 Key）"
        case .openAICompatible:    return "通用大模型 · OpenAI Chat Completions (/v1/chat/completions)"
        case .openAIResponses:     return "通用大模型 · OpenAI Responses (/v1/responses)"
        case .anthropicCompatible: return "通用大模型 · Anthropic Messages (/v1/messages)"
        case .geminiNative:        return "通用大模型 · Google Gemini 原生协议"
        case .tencent:             return "国内云接口 · 腾讯云机器翻译 TMT"
        case .baidu:               return "国内云接口 · 百度翻译开放平台"
        case .youdao:              return "国内云接口 · 有道智云文本翻译"
        case .deepl:               return "国际翻译 · DeepL 官方 / DeepLX 免 Key"
        case .customWebhook:       return "自定义通用 HTTP JSON 模版接口"
        }
    }

    public var supportsStreaming: Bool { isLLMProtocol }
}

public extension TranslationProviderProfile {
    var isLocalNoKeyEndpoint: Bool {
        let lower = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if kind == .openAICompatible || kind == .openAIResponses || kind == .anthropicCompatible {
            return LLMProtocolHelpers.isLocalOrPrivateEndpoint(lower)
        }
        if kind == .deepl { return !lower.isEmpty && !lower.contains("deepl.com") }
        return kind == .appleNative
    }

    var consoleURL: String? {
        let ep = endpoint.lowercased()
        switch kind {
        case .appleNative, .customWebhook: return nil
        case .anthropicCompatible: return (ep.isEmpty || ep.contains("anthropic.com")) ? LLMQuickPreset.claude.consoleURL : LLMQuickPreset.match(endpoint: ep)?.consoleURL
        case .geminiNative:        return LLMQuickPreset.gemini.consoleURL
        case .tencent:             return "https://console.cloud.tencent.com/cam/capi"
        case .baidu:               return "https://fanyi-api.baidu.com/manage/developer"
        case .youdao:              return "https://ai.youdao.com/console/"
        case .deepl:               return isLocalNoKeyEndpoint ? nil : "https://www.deepl.com/account/summary"
        case .openAICompatible, .openAIResponses: return LLMQuickPreset.match(endpoint: ep)?.consoleURL
        }
    }

    var quickGuideText: String {
        switch kind {
        case .appleNative: return "系统内置免费离线模型 · 无需配置，开箱即用"
        case .openAICompatible:
            if isLocalNoKeyEndpoint { return "本机/局域网兼容服务 · 可免 Key，点「拉取」自动选模型" }
            if endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "填入任意 OpenAI 兼容 Base URL、Key 与模型名即可直连"
            }
            if endpoint.lowercased().contains("bigmodel") { return "智谱含免费 glm-4-flash · 填 Key 后测通即用" }
            if endpoint.lowercased().contains("siliconflow") { return "硅基流动含免费额度 · 填 Key 后可拉取模型列表" }
            return "兼容 OpenAI Chat 协议 · 填好地址、密钥与模型即可直连"
        case .openAIResponses:
            return isLocalNoKeyEndpoint ? "局域网 OpenAI Responses 服务 · 填地址与模型即用" : "兼容 /v1/responses 协议（Codex / GPT-5 等）· 填入地址、Key 与模型即用"
        case .anthropicCompatible:
            return isLocalNoKeyEndpoint ? "局域网 Anthropic 兼容服务 · 填地址与模型即用" : "兼容 /v1/messages 协议 · 填入地址、Key 与模型即用"
        case .geminiNative:        return "Google AI Studio 含免费额度 · 粘贴 Key 即用"
        case .tencent:             return "每月 500 万字符免费额度 · 填入双密钥即用"
        case .baidu:               return "每月含免费翻译额度 · 填入 AppID 与密钥即用"
        case .youdao:              return "填入有道智云应用 ID 与密钥 · 测通即启用"
        case .deepl:               return isLocalNoKeyEndpoint ? "自建 DeepLX 免密钥 · 确认地址即可使用" : "粘贴 DeepL Auth Key · 测通即可启用"
        case .customWebhook:       return "开发者自定义 HTTP 接口 · 填写 URL 与模板"
        }
    }
}
