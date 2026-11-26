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

    /// 推导 Gemini 原生协议的 `/models` 列表地址（裸域名自动补全 `/v1beta`，已有 `/v1`/`/v1beta`/`/v1alpha` 不重复拼接）
    public static func resolveGeminiModelsURL(endpoint: String, apiKey: String) -> URL? {
        let base = normalizedGeminiBase(endpoint)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return URL(string: "\(base)/models") }
        let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
        return URL(string: "\(base)/models?key=\(encoded)")
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
