import Foundation

/// 截图翻译目标语种（默认自动中英互译）
public enum TranslationTargetLang: String, CaseIterable, Codable, Sendable {
    case autoZhEn = "auto_zh_en"
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en = "en"
    case ja = "ja"
    case ko = "ko"
    case fr = "fr"
    case de = "de"

    public var displayName: String {
        switch self {
        case .autoZhEn: return "自动互译（外→中 / 中→英）"
        case .zhHans:   return "简体中文"
        case .zhHant:   return "繁体中文"
        case .en:       return "英语 (English)"
        case .ja:       return "日语 (日本語)"
        case .ko:       return "韩语 (한국어)"
        case .fr:       return "法语 (Français)"
        case .de:       return "德语 (Deutsch)"
        }
    }

    public var promptLanguageName: String {
        switch self {
        case .autoZhEn: return "Simplified Chinese"
        case .zhHans:   return "Simplified Chinese (简体中文)"
        case .zhHant:   return "Traditional Chinese (繁體中文)"
        case .en:       return "English"
        case .ja:       return "Japanese (日本語)"
        case .ko:       return "Korean (한국어)"
        case .fr:       return "French"
        case .de:       return "German"
        }
    }

    public var appleIdentifier: String {
        switch self {
        case .autoZhEn, .zhHans: return "zh-Hans"
        case .zhHant: return "zh-Hant"
        case .en: return "en"
        case .ja: return "ja"
        case .ko: return "ko"
        case .fr: return "fr"
        case .de: return "de"
        }
    }

    public var baiduCode: String {
        switch self {
        case .autoZhEn, .zhHans: return "zh"
        case .zhHant: return "cht"
        case .en: return "en"
        case .ja: return "jp"
        case .ko: return "kor"
        case .fr: return "fra"
        case .de: return "de"
        }
    }

    public var tencentCode: String {
        switch self {
        case .autoZhEn, .zhHans: return "zh"
        case .zhHant: return "zh-TW"
        case .en: return "en"
        case .ja: return "ja"
        case .ko: return "ko"
        case .fr: return "fr"
        case .de: return "de"
        }
    }

    public var youdaoCode: String {
        switch self {
        case .autoZhEn, .zhHans: return "zh-CHS"
        case .zhHant: return "zh-CHT"
        case .en: return "en"
        case .ja: return "ja"
        case .ko: return "ko"
        case .fr: return "fr"
        case .de: return "de"
        }
    }

    public var deeplCode: String {
        switch self {
        case .autoZhEn, .zhHans: return "ZH-HANS"
        case .zhHant: return "ZH-HANT"
        case .en: return "EN"
        case .ja: return "JA"
        case .ko: return "KO"
        case .fr: return "FR"
        case .de: return "DE"
        }
    }

    /// 根据输入文本自动推断源语种与实际目标语种（处理 `.autoZhEn` 双向智能互译）
    public static func resolve(target: TranslationTargetLang, sampleText: String) -> (sourceApple: String, concreteTarget: TranslationTargetLang) {
        var hanCount = 0
        var kanaCount = 0
        var hangulCount = 0
        var alphaCount = 0
        for scalar in sampleText.unicodeScalars {
            let v = scalar.value
            if (0x3040...0x30FF).contains(v) { kanaCount += 1 }
            else if (0xAC00...0xD7AF).contains(v) { hangulCount += 1 }
            else if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) { hanCount += 1 }
            else if CharacterSet.letters.contains(scalar) { alphaCount += 1 }
        }
        let totalLetters = max(1, hanCount + kanaCount + hangulCount + alphaCount)
        let sourceGuess: String
        if kanaCount > 0 && kanaCount * 8 >= totalLetters {
            sourceGuess = "ja"
        } else if hangulCount > 0 && hangulCount * 6 >= totalLetters {
            sourceGuess = "ko"
        } else if hanCount * 100 >= totalLetters * 22 {
            sourceGuess = "zh-Hans"
        } else {
            sourceGuess = "en"
        }

        if target == .autoZhEn {
            let resolvedTarget: TranslationTargetLang = (sourceGuess == "zh-Hans") ? .en : .zhHans
            return (sourceGuess, resolvedTarget)
        }
        if sourceGuess == target.appleIdentifier {
            let altSource = (target == .en) ? "zh-Hans" : "en"
            return (altSource, target)
        }
        return (sourceGuess, target)
    }
}

/// 常见通用大模型服务商一键预设模版
public enum LLMQuickPreset: String, CaseIterable, Sendable {
    case deepseek
    case zhipuFree
    case qwen
    case doubao
    case siliconflow
    case kimi
    case openai
    case openrouter
    case ollamaLocal

    public var title: String {
        switch self {
        case .deepseek:    return "DeepSeek 官方 (deepseek-chat)"
        case .zhipuFree:   return "智谱 GLM (含免费 glm-4-flash)"
        case .qwen:        return "通义千问 · 阿里云百炼 (qwen-mt-turbo)"
        case .doubao:      return "火山方舟 · 豆包 (doubao-1.5-lite)"
        case .siliconflow: return "硅基流动 SiliconFlow (含免费模型)"
        case .kimi:        return "Kimi · Moonshot (moonshot-v1-8k)"
        case .openai:      return "OpenAI 官方 (gpt-4o-mini)"
        case .openrouter:  return "OpenRouter 聚合网关"
        case .ollamaLocal: return "本地 Ollama（免费离线 · 免 API Key）"
        }
    }

    public var baseURL: String {
        switch self {
        case .deepseek:    return "https://api.deepseek.com/v1"
        case .zhipuFree:   return "https://open.bigmodel.cn/api/paas/v4"
        case .qwen:        return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .doubao:      return "https://ark.cn-beijing.volces.com/api/v3"
        case .siliconflow: return "https://api.siliconflow.cn/v1"
        case .kimi:        return "https://api.moonshot.cn/v1"
        case .openai:      return "https://api.openai.com/v1"
        case .openrouter:  return "https://openrouter.ai/api/v1"
        case .ollamaLocal: return "http://127.0.0.1:11434/v1"
        }
    }

    public var defaultModel: String {
        switch self {
        case .deepseek:    return "deepseek-chat"
        case .zhipuFree:   return "glm-4-flash"
        case .qwen:        return "qwen-mt-turbo"
        case .doubao:      return "doubao-1-5-lite-32k-250115"
        case .siliconflow: return "Qwen/Qwen2.5-7B-Instruct"
        case .kimi:        return "moonshot-v1-8k"
        case .openai:      return "gpt-4o-mini"
        case .openrouter:  return "google/gemini-2.0-flash-001"
        case .ollamaLocal: return "qwen2.5:7b"
        }
    }
}

/// 支持的 9 大类翻译协议族
public enum TranslationProviderKind: String, CaseIterable, Codable, Sendable {
    case appleNative = "apple_native"
    case openAICompatible = "openai_compatible"
    case anthropicCompatible = "anthropic_compatible"
    case geminiNative = "gemini_native"
    case tencent = "tencent_tmt"
    case baidu = "baidu_fanyi"
    case youdao = "youdao_v3"
    case deepl = "deepl"
    case customWebhook = "custom_webhook"

    public var displayName: String {
        switch self {
        case .appleNative:         return "macOS 原生离线翻译（免费 · 无需 Key）"
        case .openAICompatible:    return "通用大模型 · OpenAI 兼容协议 (/v1/chat/completions)"
        case .anthropicCompatible: return "通用大模型 · Anthropic Claude 协议 (/v1/messages)"
        case .geminiNative:        return "通用大模型 · Google Gemini 原生协议"
        case .tencent:             return "国内云接口 · 腾讯云机器翻译 TMT"
        case .baidu:               return "国内云接口 · 百度翻译开放平台"
        case .youdao:              return "国内云接口 · 有道智云文本翻译"
        case .deepl:               return "国际翻译 · DeepL 官方 / DeepLX 免 Key"
        case .customWebhook:       return "自定义通用 HTTP JSON 模版接口"
        }
    }

    public var supportsStreaming: Bool {
        self == .openAICompatible
    }
}
