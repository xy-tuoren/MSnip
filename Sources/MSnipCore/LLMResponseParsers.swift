import Foundation

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
