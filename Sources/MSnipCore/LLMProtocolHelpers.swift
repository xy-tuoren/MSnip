import Foundation

/// 大模型兼容协议 URL 补全、局域网免鉴权判定、思考标签清洗与模型列表解析工具
public enum LLMProtocolHelpers {
    /// 智能补全 OpenAI 兼容聊天端点（支持裸域名、`/v1`、`/v2`、`/v3`、`/v4` 及完整 `/chat/completions`）
    public static func resolveOpenAIChatURL(_ raw: String) -> URL? {
        var base = stripTrailingSlashes(raw)
        guard !base.isEmpty else { return nil }
        if base.hasSuffix("/chat/completions") { return URL(string: base) }
        if base.hasSuffix("/responses") { base = String(base.dropLast("/responses".count)) }
        if hasVersionSuffix(base) { return URL(string: base + "/chat/completions") }
        return URL(string: base + "/v1/chat/completions")
    }

    /// 智能补全 OpenAI Responses API (`/v1/responses`) 端点（兼容裸域名、`/v1`、完整 `/responses` 或从 `/chat/completions` 切换）
    public static func resolveOpenAIResponsesURL(_ raw: String) -> URL? {
        var base = stripTrailingSlashes(raw)
        guard !base.isEmpty else { return nil }
        if base.hasSuffix("/responses") { return URL(string: base) }
        if base.hasSuffix("/chat/completions") { base = String(base.dropLast("/chat/completions".count)) }
        if hasVersionSuffix(base) { return URL(string: base + "/responses") }
        return URL(string: base + "/v1/responses")
    }

    /// 推导 OpenAI 兼容协议（Chat / Responses）的 `/models` 枚举接口地址
    public static func resolveOpenAIModelsURL(_ raw: String) -> URL? {
        var base = stripTrailingSlashes(raw)
        guard !base.isEmpty else { return nil }
        if base.hasSuffix("/models") { return URL(string: base) }
        if base.hasSuffix("/chat/completions") {
            base = String(base.dropLast("/chat/completions".count))
            return URL(string: base + "/models")
        }
        if base.hasSuffix("/responses") {
            base = String(base.dropLast("/responses".count))
            return URL(string: base + "/models")
        }
        if hasVersionSuffix(base) { return URL(string: base + "/models") }
        return URL(string: base + "/v1/models")
    }

    /// 智能补全 Anthropic `/v1/messages` 端点（避免 `/v1` 结尾重复拼接 `/v1/v1/messages`）
    public static func resolveAnthropicMessagesURL(_ raw: String) -> URL? {
        let base = stripTrailingSlashes(raw)
        if base.isEmpty { return URL(string: "https://api.anthropic.com/v1/messages") }
        if base.hasSuffix("/messages") { return URL(string: base) }
        if hasVersionSuffix(base) { return URL(string: base + "/messages") }
        return URL(string: base + "/v1/messages")
    }

    /// 推导 Anthropic 兼容协议的 `/v1/models` 地址
    public static func resolveAnthropicModelsURL(_ raw: String) -> URL? {
        var base = stripTrailingSlashes(raw)
        if base.isEmpty { return URL(string: "https://api.anthropic.com/v1/models") }
        if base.hasSuffix("/models") { return URL(string: base) }
        if base.hasSuffix("/messages") {
            base = String(base.dropLast("/messages".count))
            return URL(string: base + "/models")
        }
        if hasVersionSuffix(base) { return URL(string: base + "/models") }
        return URL(string: base + "/v1/models")
    }

    /// 推导 Gemini 原生协议的 `/models` 列表地址（裸域名自动补全 `/v1beta`，已有 `/v1`/`/v1beta`/`/v1alpha` 不重复拼接）。
    /// 密钥仅经 `x-goog-api-key` 请求头传递，绝不拼进 URL，避免落入中转代理与服务端访问日志。
    public static func resolveGeminiModelsURL(endpoint: String) -> URL? {
        URL(string: "\(normalizedGeminiBase(endpoint))/models")
    }

    /// 推导 Gemini 原生协议的 `:generateContent` / `:streamGenerateContent` 端点（兼容官方与裸域名中转站）
    public static func resolveGeminiGenerateURL(endpoint: String, model: String, stream: Bool) -> URL? {
        let raw = stripTrailingSlashes(endpoint)
        if raw.contains(":generateContent") || raw.contains(":streamGenerateContent") {
            return URL(string: raw)
        }
        let base = normalizedGeminiBase(raw)
        var cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanModel.hasPrefix("models/") { cleanModel = String(cleanModel.dropFirst("models/".count)) }
        let encodedModel = cleanModel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cleanModel
        let action = stream ? "streamGenerateContent?alt=sse" : "generateContent"
        return URL(string: "\(base)/models/\(encodedModel):\(action)")
    }

    private static func normalizedGeminiBase(_ raw: String) -> String {
        var base = stripTrailingSlashes(raw)
        if base.isEmpty { return "https://generativelanguage.googleapis.com/v1beta" }
        if base.hasSuffix("/models") { base = String(base.dropLast("/models".count)) }
        return hasVersionSuffix(base) ? base : (base + "/v1beta")
    }

    /// 判定模型是否禁止传入自定义 `temperature`（如 OpenAI o1/o3/o4/gpt-5 及 Kimi K2.5）
    public static func modelRequiresDefaultTemperature(_ model: String) -> Bool {
        let leaf = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(separator: "/").last.map(String.init) ?? ""
        return leaf == "o1" || leaf.hasPrefix("o1-") || leaf == "o3" || leaf.hasPrefix("o3-")
            || leaf == "o4" || leaf.hasPrefix("o4-") || leaf == "gpt-5" || leaf.hasPrefix("gpt-5-")
            || leaf.hasPrefix("gpt-5.") || leaf.hasPrefix("kimi-k2.5") || leaf.hasPrefix("qwen-mt")
    }

    /// 判定模型是否不支持 `role: "system"`（如早期 o1-mini/o1-preview、qwen-mt 系列）
    public static func modelDisallowsSystemRole(_ model: String) -> Bool {
        let leaf = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(separator: "/").last.map(String.init) ?? ""
        return leaf.hasPrefix("o1-mini") || leaf.hasPrefix("o1-preview") || leaf.hasPrefix("qwen-mt")
    }

    /// 判定是否为本机或私有局域网自建地址（支持无 API Key 直接就绪）
    public static func isLocalOrPrivateEndpoint(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        if lower.contains(":11434") { return true }
        guard let host = URL(string: trimmed)?.host?.lowercased() else { return false }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "0.0.0.0" {
            return true
        }
        if host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".internal") {
            return true
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            if parts[0] == 10 { return true }
            if parts[0] == 192 && parts[1] == 168 { return true }
            if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        }
        return false
    }

    /// 清洗思考类模型（DeepSeek-R1 / Qwen3 / vLLM 等）内联输出的 `<think>...</think>`、孤立 `</think>` 及 `<thought>...</thought>` 推理块
    public static func stripThinkingTags(_ raw: String) -> String {
        var text = raw
        for (openTag, closeTag) in [("<think>", "</think>"), ("<thought>", "</thought>")] {
            while let start = text.range(of: openTag, options: .caseInsensitive) {
                if let end = text.range(of: closeTag, options: .caseInsensitive, range: start.upperBound..<text.endIndex) {
                    text.removeSubrange(start.lowerBound..<end.upperBound)
                } else {
                    text.removeSubrange(start.lowerBound..<text.endIndex)
                    break
                }
            }
            if let orphanClose = text.range(of: closeTag, options: .caseInsensitive) {
                text.removeSubrange(text.startIndex..<orphanClose.upperBound)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 解析 OpenAI / Anthropic / Ollama / Gemini 的模型列表 JSON
    public static func parseModelIDs(from data: Data, kind: TranslationProviderKind) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var ids: [String] = []
        if let arr = obj["data"] as? [[String: Any]] {
            for item in arr {
                if let id = item["id"] as? String, !id.isEmpty { ids.append(id) }
            }
        }
        if ids.isEmpty, let arr = obj["models"] as? [[String: Any]] {
            for item in arr {
                if let id = item["id"] as? String, !id.isEmpty {
                    ids.append(id)
                } else if var name = item["name"] as? String, !name.isEmpty {
                    if kind == .geminiNative && name.hasPrefix("models/") {
                        name = String(name.dropFirst("models/".count))
                    }
                    ids.append(name)
                }
            }
        }
        return Array(Set(ids)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private static func stripTrailingSlashes(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private static func hasVersionSuffix(_ path: String) -> Bool {
        guard let slash = path.lastIndex(of: "/") else { return false }
        let last = path[path.index(after: slash)...].lowercased()
        guard last.count >= 2, last.first == "v" else { return false }
        let rest = last.dropFirst()
        if rest.allSatisfy(\.isNumber) { return true }
        for suffix in ["beta", "alpha"] where rest.hasSuffix(suffix) {
            let num = rest.dropLast(suffix.count)
            if !num.isEmpty && num.allSatisfy(\.isNumber) { return true }
        }
        return false
    }
}

// MARK: - 多协议响应体与流式片段解析

/// 四大兼容协议（OpenAI Chat / OpenAI Responses / Anthropic Messages / Gemini Native）的 SSE 增量与非流式 JSON 响应解析器
public extension LLMProtocolHelpers {
    /// 解析 OpenAI Chat Completions SSE `data:` 负载中的增量文本
    static func parseOpenAISSEChunk(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String, !content.isEmpty else { return nil }
        return content
    }

    /// 解析 OpenAI Responses API (`/v1/responses`) SSE `data:` 负载中的增量文本（自动忽略 reasoning delta）
    static func parseOpenAIResponsesSSEChunk(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "response.output_text.delta",
              let delta = obj["delta"] as? String, !delta.isEmpty else { return nil }
        return delta
    }

    /// 解析 Anthropic `/v1/messages` SSE `data:` 负载中的增量文本 (`content_block_delta` / `text_delta`)
    static func parseAnthropicSSEChunk(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "content_block_delta",
              let delta = obj["delta"] as? [String: Any],
              (delta["type"] as? String) == "text_delta",
              let text = delta["text"] as? String, !text.isEmpty else { return nil }
        return text
    }

    /// 解析 Google Gemini `:streamGenerateContent?alt=sse` `data:` 负载中的增量文本（自动跳过思考模型 `thought: true` 分片）
    static func parseGeminiSSEChunk(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cands = obj["candidates"] as? [[String: Any]],
              let content = cands.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }
        let joined = parts.compactMap { ($0["thought"] as? Bool) == true ? nil : ($0["text"] as? String) }.joined()
        return joined.isEmpty ? nil : joined
    }

    /// 提取 OpenAI Chat Completions 非流式 JSON 响应文本（兼容纯字符串与分段内容数组，自动剥离 `<think>` 标签）
    static func extractOpenAIResponseText(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any] else { return nil }
        let raw: String
        if let str = msg["content"] as? String {
            raw = str
        } else if let parts = msg["content"] as? [[String: Any]] {
            raw = parts.compactMap { part in
                let kind = (part["type"] as? String)?.lowercased() ?? ""
                if kind == "thinking" || kind == "reasoning" || kind == "redacted_thinking" { return nil }
                return part["text"] as? String
            }.joined()
        } else {
            return nil
        }
        let cleaned = stripThinkingTags(raw)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// 提取 OpenAI Responses (`/v1/responses`) JSON 或 `response.completed` / `response.output_text.done` 正文（跳过 reasoning 项）
    static func extractOpenAIResponsesText(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if (obj["type"] as? String) == "response.output_text.done", let txt = obj["text"] as? String {
            let cleaned = stripThinkingTags(txt)
            return cleaned.isEmpty ? nil : cleaned
        }
        let root = (obj["response"] as? [String: Any]) ?? obj
        if let outputs = root["output"] as? [[String: Any]] {
            var chunks: [String] = []
            for item in outputs {
                let itemType = (item["type"] as? String)?.lowercased() ?? ""
                if itemType == "reasoning" || itemType == "thinking" { continue }
                if let content = item["content"] as? [[String: Any]] {
                    for part in content {
                        let pType = (part["type"] as? String)?.lowercased() ?? ""
                        if pType == "reasoning" || pType == "thinking" || pType == "refusal" { continue }
                        if let t = part["text"] as? String, !t.isEmpty { chunks.append(t) }
                    }
                } else if let t = item["text"] as? String, !t.isEmpty {
                    chunks.append(t)
                }
            }
            let cleaned = stripThinkingTags(chunks.joined())
            if !cleaned.isEmpty { return cleaned }
        }
        if let flat = root["output_text"] as? String {
            let cleaned = stripThinkingTags(flat)
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }

    /// 提取 Anthropic `/v1/messages` 非流式 JSON 响应文本（自动跳过前置 `thinking` / `redacted_thinking` 推理块）
    static func extractAnthropicResponseText(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = obj["content"] as? [[String: Any]] else { return nil }
        let joined = blocks.compactMap { block -> String? in
            let kind = (block["type"] as? String)?.lowercased() ?? ""
            if kind == "thinking" || kind == "redacted_thinking" { return nil }
            return block["text"] as? String
        }.joined()
        let cleaned = stripThinkingTags(joined)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// 提取 Gemini `:generateContent` 非流式 JSON 响应文本（自动跳过 `thought: true` 思考块）
    static func extractGeminiResponseText(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cands = obj["candidates"] as? [[String: Any]],
              let content = cands.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }
        let joined = parts.compactMap { ($0["thought"] as? Bool) == true ? nil : ($0["text"] as? String) }.joined()
        let cleaned = stripThinkingTags(joined)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// 解包批量多行翻译的 `⟦1⟧ ...` 编号行（保证返回数组长度与原文逐行严格对齐）
    static func unpackNumberedLines(_ raw: String, original: [String]) -> [String] {
        var result = original
        var matched = 0
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("⟦"), let closeIdx = trimmed.firstIndex(of: "⟧") else { continue }
            let numStr = trimmed[trimmed.index(after: trimmed.startIndex)..<closeIdx]
            if let n = Int(numStr), n >= 1, n <= result.count {
                let content = trimmed[trimmed.index(after: closeIdx)...].trimmingCharacters(in: .whitespaces)
                if !content.isEmpty {
                    result[n - 1] = content
                    matched += 1
                }
            }
        }
        if matched == 0 {
            let fallback = raw.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            for i in 0..<min(result.count, fallback.count) { result[i] = fallback[i] }
        }
        return result
    }

    /// 按字节上限截取响应体为可读文本片段：截断点落在多字节 UTF-8 字符中间时丢弃残缺尾字节，
    /// 避免 `String(data:encoding:)` 整体返回 nil 而吞掉中文服务商的错误信息（及依赖错误文案的自动降级重试）
    static func utf8Snippet(_ data: Data, maxBytes: Int) -> String {
        let slice = data.prefix(max(0, maxBytes))
        var text = String(decoding: slice, as: UTF8.self)
        if slice.count < data.count {
            while text.unicodeScalars.last == "\u{FFFD}" { text.unicodeScalars.removeLast() }
        }
        return text
    }

    /// 提取四协议 JSON 响应中的服务端错误文案（兼容顶层 `error` 及 Responses API `response.error`）
    static func extractErrorMessage(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let root = (obj["response"] as? [String: Any]) ?? obj
        if let err = root["error"] as? [String: Any], let msg = err["message"] as? String, !msg.isEmpty { return msg }
        if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String, !msg.isEmpty { return msg }
        if let errStr = root["error"] as? String, !errStr.isEmpty { return errStr }
        if let msg = obj["message"] as? String, !msg.isEmpty { return msg }
        return nil
    }
}

// MARK: - 主流大模型一键预设模板

/// 预设大模型服务商分组（用于设置页快捷模版与添加菜单清晰分区）
public enum LLMQuickPresetGroup: Int, CaseIterable, Sendable {
    case custom = 0
    case domestic = 1
    case international = 2
    case local = 3

    public var title: String {
        switch self {
        case .custom:        return L("自定义 / 中转")
        case .domestic:      return L("国内主流大模型官网")
        case .international: return L("国际主流厂商与聚合网关")
        case .local:         return L("本机离线推理引擎（免 Key）")
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
        case .customOpenAI:  return L("自定义 / 中转站")
        case .deepseek:      return L("DeepSeek 官方")
        case .zhipuFree:     return L("智谱 BigModel · GLM")
        case .qwen:          return L("阿里云百炼 · 通义千问")
        case .doubao:        return L("火山方舟 · 豆包")
        case .kimi:          return L("Kimi · 月之暗面")
        case .hunyuan:       return L("腾讯混元大模型")
        case .qianfan:       return L("百度千帆 · 文心")
        case .minimax:       return L("MiniMax · 海螺 AI")
        case .spark:         return L("讯飞星火大模型")
        case .stepfun:       return L("阶跃星辰 StepFun")
        case .siliconflow:   return L("硅基流动 SiliconFlow")
        case .openai:        return L("OpenAI 官方")
        case .claude:        return "Anthropic Claude"
        case .gemini:        return "Google Gemini"
        case .xai:           return "xAI Grok"
        case .groq:          return "Groq"
        case .mistral:       return "Mistral AI"
        case .openrouter:    return "OpenRouter"
        case .ollamaLocal:   return L("本地 Ollama")
        case .lmStudioLocal: return L("本地 LM Studio")
        }
    }

    public var shortName: String {
        switch self {
        case .customOpenAI:  return L("自定义中转")
        case .deepseek:      return "DeepSeek"
        case .zhipuFree:     return L("智谱 GLM")
        case .qwen:          return L("通义千问")
        case .doubao:        return L("豆包 · 火山方舟")
        case .kimi:          return "Kimi · Moonshot"
        case .hunyuan:       return L("腾讯混元")
        case .qianfan:       return L("百度千帆")
        case .minimax:       return "MiniMax"
        case .spark:         return L("讯飞星火")
        case .stepfun:       return L("阶跃星辰")
        case .siliconflow:   return L("硅基流动")
        case .openai:        return "OpenAI"
        case .claude:        return "Claude"
        case .gemini:        return "Google Gemini"
        case .xai:           return "xAI Grok"
        case .groq:          return "Groq"
        case .mistral:       return "Mistral AI"
        case .openrouter:    return "OpenRouter"
        case .ollamaLocal:   return L("本地 Ollama")
        case .lmStudioLocal: return L("本地 LM Studio")
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
