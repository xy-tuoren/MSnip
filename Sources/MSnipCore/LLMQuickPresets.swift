import Foundation

/// 预设大模型服务商分组（用于设置页快捷模版与添加菜单清晰分区）
public enum LLMQuickPresetGroup: Int, CaseIterable, Sendable {
    case custom = 0
    case domestic = 1
    case international = 2
    case local = 3

    public var title: String {
        switch self {
        case .custom:        return "自定义 / 中转"
        case .domestic:      return "国内主流大模型官网"
        case .international: return "国际主流厂商与聚合网关"
        case .local:         return "本机离线推理引擎（免 Key）"
        }
    }
}

/// 覆盖 21 家国内外主流大模型与本机推理引擎的官方兼容协议预设
public enum LLMQuickPreset: String, CaseIterable, Sendable {
    case customOpenAI
    // 国内主流厂商
    case deepseek, zhipuFree, qwen, doubao, kimi, hunyuan, qianfan, minimax, spark, stepfun, siliconflow
    // 国际主流与极速/聚合网关
    case openai, claude, gemini, xai, groq, mistral, openrouter
    // 本机离线
    case ollamaLocal, lmStudioLocal

    public var group: LLMQuickPresetGroup {
        switch self {
        case .customOpenAI:
            return .custom
        case .deepseek, .zhipuFree, .qwen, .doubao, .kimi, .hunyuan, .qianfan, .minimax, .spark, .stepfun, .siliconflow:
            return .domestic
        case .openai, .claude, .gemini, .xai, .groq, .mistral, .openrouter:
            return .international
        case .ollamaLocal, .lmStudioLocal:
            return .local
        }
    }

    public var providerKind: TranslationProviderKind {
        switch self {
        case .claude: return .anthropicCompatible
        case .gemini: return .geminiNative
        default:      return .openAICompatible
        }
    }

    public var title: String {
        switch self {
        case .customOpenAI:  return "自定义 / 中转站"
        case .deepseek:      return "DeepSeek 官方"
        case .zhipuFree:     return "智谱 BigModel · GLM"
        case .qwen:          return "阿里云百炼 · 通义千问"
        case .doubao:        return "火山方舟 · 豆包"
        case .kimi:          return "Kimi · 月之暗面"
        case .hunyuan:       return "腾讯混元大模型"
        case .qianfan:       return "百度千帆 · 文心"
        case .minimax:       return "MiniMax · 海螺 AI"
        case .spark:         return "讯飞星火大模型"
        case .stepfun:       return "阶跃星辰 StepFun"
        case .siliconflow:   return "硅基流动 SiliconFlow"
        case .openai:        return "OpenAI 官方"
        case .claude:        return "Anthropic Claude"
        case .gemini:        return "Google Gemini"
        case .xai:           return "xAI Grok"
        case .groq:          return "Groq"
        case .mistral:       return "Mistral AI"
        case .openrouter:    return "OpenRouter"
        case .ollamaLocal:   return "本地 Ollama"
        case .lmStudioLocal: return "本地 LM Studio"
        }
    }

    public var shortName: String {
        switch self {
        case .customOpenAI:  return "自定义中转"
        case .deepseek:      return "DeepSeek"
        case .zhipuFree:     return "智谱 GLM"
        case .qwen:          return "通义千问"
        case .doubao:        return "豆包 · 火山方舟"
        case .kimi:          return "Kimi · Moonshot"
        case .hunyuan:       return "腾讯混元"
        case .qianfan:       return "百度千帆"
        case .minimax:       return "MiniMax"
        case .spark:         return "讯飞星火"
        case .stepfun:       return "阶跃星辰"
        case .siliconflow:   return "硅基流动"
        case .openai:        return "OpenAI"
        case .claude:        return "Claude"
        case .gemini:        return "Google Gemini"
        case .xai:           return "xAI Grok"
        case .groq:          return "Groq"
        case .mistral:       return "Mistral AI"
        case .openrouter:    return "OpenRouter"
        case .ollamaLocal:   return "本地 Ollama"
        case .lmStudioLocal: return "本地 LM Studio"
        }
    }

    public var baseURL: String {
        switch self {
        case .customOpenAI:  return ""
        case .deepseek:      return "https://api.deepseek.com/v1"
        case .zhipuFree:     return "https://open.bigmodel.cn/api/paas/v4"
        case .qwen:          return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .doubao:        return "https://ark.cn-beijing.volces.com/api/v3"
        case .kimi:          return "https://api.moonshot.cn/v1"
        case .hunyuan:       return "https://api.hunyuan.cloud.tencent.com/v1"
        case .qianfan:       return "https://qianfan.baidubce.com/v2"
        case .minimax:       return "https://api.minimaxi.com/v1"
        case .spark:         return "https://spark-api-open.xf-yun.com/v1"
        case .stepfun:       return "https://api.stepfun.com/v1"
        case .siliconflow:   return "https://api.siliconflow.cn/v1"
        case .openai:        return "https://api.openai.com/v1"
        case .claude:        return "https://api.anthropic.com/v1"
        case .gemini:        return "https://generativelanguage.googleapis.com/v1beta"
        case .xai:           return "https://api.x.ai/v1"
        case .groq:          return "https://api.groq.com/openai/v1"
        case .mistral:       return "https://api.mistral.ai/v1"
        case .openrouter:    return "https://openrouter.ai/api/v1"
        case .ollamaLocal:   return "http://127.0.0.1:11434/v1"
        case .lmStudioLocal: return "http://127.0.0.1:1234/v1"
        }
    }

    public var defaultModel: String {
        switch self {
        case .customOpenAI:  return ""
        case .deepseek:      return "deepseek-chat"
        case .zhipuFree:     return "glm-4-flash"
        case .qwen:          return "qwen-turbo"
        case .doubao:        return "doubao-1-5-lite-32k-250115"
        case .kimi:          return "moonshot-v1-8k"
        case .hunyuan:       return "hunyuan-lite"
        case .qianfan:       return "ernie-speed-128k"
        case .minimax:       return "MiniMax-Text-01"
        case .spark:         return "lite"
        case .stepfun:       return "step-2-mini"
        case .siliconflow:   return "Qwen/Qwen3-8B"
        case .openai:        return "gpt-4o-mini"
        case .claude:        return "claude-3-5-haiku-latest"
        case .gemini:        return "gemini-2.5-flash"
        case .xai:           return "grok-3-mini"
        case .groq:          return "llama-3.3-70b-versatile"
        case .mistral:       return "mistral-small-latest"
        case .openrouter:    return "google/gemini-2.5-flash"
        case .ollamaLocal:   return "qwen2.5:7b"
        case .lmStudioLocal: return "local-model"
        }
    }

    /// 官网 API Key 控制台直达链接
    public var consoleURL: String? {
        switch self {
        case .customOpenAI, .ollamaLocal, .lmStudioLocal: return nil
        case .deepseek:    return "https://platform.deepseek.com/api_keys"
        case .zhipuFree:   return "https://open.bigmodel.cn/usercenter/apikeys"
        case .qwen:        return "https://bailian.console.aliyun.com/?apiKey=1"
        case .doubao:      return "https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey"
        case .kimi:        return "https://platform.moonshot.cn/console/api-keys"
        case .hunyuan:     return "https://console.cloud.tencent.com/hunyuan/api-key"
        case .qianfan:     return "https://console.bce.baidu.com/iam/#/iam/apikey/list"
        case .minimax:     return "https://platform.minimaxi.com/user-center/basic-information/interface-key"
        case .spark:       return "https://console.xfyun.cn/services/bm35"
        case .stepfun:     return "https://platform.stepfun.com/interface-key"
        case .siliconflow: return "https://cloud.siliconflow.cn/account/ak"
        case .openai:      return "https://platform.openai.com/api-keys"
        case .claude:      return "https://console.anthropic.com/settings/keys"
        case .gemini:      return "https://aistudio.google.com/app/apikey"
        case .xai:         return "https://console.x.ai/"
        case .groq:        return "https://console.groq.com/keys"
        case .mistral:     return "https://console.mistral.ai/api-keys"
        case .openrouter:  return "https://openrouter.ai/settings/keys"
        }
    }

    /// 根据接口地址域名自动反查对应的官方预设（供「获取 Key ↗」与快捷模版自动回显）
    public static func match(endpoint raw: String) -> LLMQuickPreset? {
        let ep = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !ep.isEmpty else { return nil }
        let rules: [(String, LLMQuickPreset)] = [
            ("deepseek.com", .deepseek),
            ("bigmodel.cn", .zhipuFree), ("api.z.ai", .zhipuFree),
            ("dashscope", .qwen), ("aliyuncs.com", .qwen),
            ("volces.com", .doubao),
            ("moonshot.cn", .kimi), ("moonshot.ai", .kimi),
            ("hunyuan", .hunyuan),
            ("qianfan.baidubce", .qianfan),
            ("minimax", .minimax),
            ("xf-yun.com", .spark),
            ("stepfun", .stepfun),
            ("siliconflow", .siliconflow),
            ("api.openai.com", .openai),
            ("anthropic.com", .claude),
            ("generativelanguage.googleapis.com", .gemini),
            ("api.x.ai", .xai),
            ("api.groq.com", .groq),
            ("api.mistral.ai", .mistral),
            ("openrouter.ai", .openrouter),
            (":11434", .ollamaLocal),
            (":1234", .lmStudioLocal)
        ]
        return rules.first(where: { ep.contains($0.0) })?.1
    }
}
