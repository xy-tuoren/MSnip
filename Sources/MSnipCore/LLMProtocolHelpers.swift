import Foundation

/// 大模型兼容协议 URL 补全、局域网免鉴权判定、思考标签清洗与模型列表解析工具
public enum LLMProtocolHelpers {
    /// 智能补全 OpenAI 兼容聊天端点（支持裸域名、`/v1`、`/v2`、`/v3`、`/v4` 及完整 `/chat/completions`）
    public static func resolveOpenAIChatURL(_ raw: String) -> URL? {
        let base = stripTrailingSlashes(raw)
        guard !base.isEmpty else { return nil }
        if base.hasSuffix("/chat/completions") { return URL(string: base) }
        if hasVersionSuffix(base) { return URL(string: base + "/chat/completions") }
        return URL(string: base + "/v1/chat/completions")
    }

    /// 推导 OpenAI 兼容协议的 `/models` 枚举接口地址
    public static func resolveOpenAIModelsURL(_ raw: String) -> URL? {
        var base = stripTrailingSlashes(raw)
        guard !base.isEmpty else { return nil }
        if base.hasSuffix("/models") { return URL(string: base) }
        if base.hasSuffix("/chat/completions") {
            base = String(base.dropLast("/chat/completions".count))
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

    /// 推导 Gemini 原生协议的 `/models` 列表地址
    public static func resolveGeminiModelsURL(endpoint: String, apiKey: String) -> URL? {
        let base = stripTrailingSlashes(endpoint).isEmpty
            ? "https://generativelanguage.googleapis.com/v1beta"
            : stripTrailingSlashes(endpoint)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: "\(base)/models?key=\(key)")
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

    /// 清洗思考类模型（如 deepseek-reasoner / Qwen3）可能内联输出的 `<think>...</think>` 推理块（兼容流式未闭合前缀）
    public static func stripThinkingTags(_ raw: String) -> String {
        guard raw.range(of: "<think>", options: .caseInsensitive) != nil else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var text = raw
        while let start = text.range(of: "<think>", options: .caseInsensitive) {
            if let end = text.range(of: "</think>", options: .caseInsensitive, range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                // 流式输出尚未收到闭合 `</think>` 时暂不暴露思考草稿
                text.removeSubrange(start.lowerBound..<text.endIndex)
                break
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

    /// 解析 OpenAI 兼容 SSE `data:` 负载中的增量文本
    public static func parseOpenAISSEChunk(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String, !content.isEmpty else { return nil }
        return content
    }

    /// 解析 Anthropic `/v1/messages` SSE `data:` 负载中的增量文本 (`content_block_delta` / `text_delta`)
    public static func parseAnthropicSSEChunk(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "content_block_delta",
              let delta = obj["delta"] as? [String: Any],
              (delta["type"] as? String) == "text_delta",
              let text = delta["text"] as? String, !text.isEmpty else { return nil }
        return text
    }

    /// 解析 Google Gemini `:streamGenerateContent?alt=sse` `data:` 负载中的增量文本
    public static func parseGeminiSSEChunk(_ payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cands = obj["candidates"] as? [[String: Any]],
              let content = cands.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }
        let joined = parts.compactMap { $0["text"] as? String }.joined()
        return joined.isEmpty ? nil : joined
    }

    /// 解包批量多行翻译的 `⟦1⟧ ...` 编号行（保证返回数组长度与原文逐行严格对齐）
    public static func unpackNumberedLines(_ raw: String, original: [String]) -> [String] {
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

    private static func stripTrailingSlashes(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private static func hasVersionSuffix(_ path: String) -> Bool {
        guard let slash = path.lastIndex(of: "/") else { return false }
        let last = path[path.index(after: slash)...]
        guard last.count >= 2, last.first == "v" || last.first == "V" else { return false }
        return last.dropFirst().allSatisfy(\.isNumber)
    }
}
