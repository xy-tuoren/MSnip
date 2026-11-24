import Foundation
import MSnipCore

/// 通用大模型翻译协议适配器：
/// 支持 OpenAI 兼容协议（含 SSE 实时流式输出）、Anthropic Claude `/v1/messages` 及 Google Gemini 原生协议。
enum LLMTranslator {
    enum LLMError: LocalizedError {
        case invalidEndpoint(String)
        case httpError(Int, String)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint(let ep): return "无效的大模型接口地址：\(ep)"
            case .httpError(let code, let msg): return "大模型请求失败 (HTTP \(code))：\(msg)"
            case .emptyResponse: return "大模型未返回有效译文"
            }
        }
    }

    private static let defaultSystemInstruction = """
    You are a professional, accurate UI & document translator. Translate the user's text faithfully and naturally into the requested target language. Output ONLY the translated text itself without explanations, quotes, or markdown code fences. Preserve technical identifiers, code symbols, URLs, and line breaks.
    """

    static func translateStream(
        text: String,
        target: TranslationTargetLang,
        profile: TranslationProviderProfile,
        onChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let resolved = TranslationTargetLang.resolve(target: target, sampleText: text)
        let targetName = resolved.concreteTarget.promptLanguageName
        let sys = profile.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultSystemInstruction
            : profile.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let userPrompt = "Translate the following text into \(targetName):\n\n\(text)"

        switch profile.kind {
        case .openAICompatible:
            return try await callOpenAICompatible(
                system: sys, user: userPrompt, profile: profile, stream: onChunk != nil, onChunk: onChunk
            )
        case .anthropicCompatible:
            return try await callAnthropic(
                system: sys, user: userPrompt, profile: profile, stream: onChunk != nil, onChunk: onChunk
            )
        case .geminiNative:
            return try await callGemini(
                system: sys, user: userPrompt, profile: profile, stream: onChunk != nil, onChunk: onChunk
            )
        default:
            throw LLMError.invalidEndpoint(profile.endpoint)
        }
    }

    /// 单次请求批量翻译多行 OCR 框文本（保持行号严格一一对应，供页内原位覆盖翻译使用）
    static func translateBatchLines(
        lines: [String],
        target: TranslationTargetLang,
        profile: TranslationProviderProfile
    ) async throws -> [String] {
        guard !lines.isEmpty else { return [] }
        if lines.count == 1 {
            let single = try await translateStream(text: lines[0], target: target, profile: profile)
            return [single.trimmingCharacters(in: .whitespacesAndNewlines)]
        }

        let resolved = TranslationTargetLang.resolve(target: target, sampleText: lines.joined(separator: "\n"))
        let targetName = resolved.concreteTarget.promptLanguageName
        let packed = lines.enumerated().map { "⟦\($0.offset + 1)⟧ \($0.element)" }.joined(separator: "\n")
        let sys = """
        You are a precise UI screenshot translator. Translate each numbered line ⟦1⟧, ⟦2⟧, ... into \(targetName). Keep EVERY ⟦N⟧ marker at the start of its corresponding line so the line count matches 1-to-1. Output ONLY the numbered translated lines.
        """
        let raw: String
        switch profile.kind {
        case .openAICompatible:
            raw = try await callOpenAICompatible(system: sys, user: packed, profile: profile, stream: false, onChunk: nil)
        case .anthropicCompatible:
            raw = try await callAnthropic(system: sys, user: packed, profile: profile, stream: false, onChunk: nil)
        case .geminiNative:
            raw = try await callGemini(system: sys, user: packed, profile: profile, stream: false, onChunk: nil)
        default:
            throw LLMError.invalidEndpoint(profile.endpoint)
        }
        return LLMProtocolHelpers.unpackNumberedLines(raw, original: lines)
    }

    private static func callOpenAICompatible(
        system: String,
        user: String,
        profile: TranslationProviderProfile,
        stream: Bool,
        onChunk: (@Sendable (String) -> Void)?
    ) async throws -> String {
        guard let url = TranslationSettingsConfig.resolveChatCompletionsURL(profile.endpoint) else {
            throw LLMError.invalidEndpoint(profile.endpoint)
        }
        var req = URLRequest(url: url, timeoutInterval: 35)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = profile.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        applyCustomHeaders(profile.customHeadersJSON, to: &req)

        let modelName = profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "gpt-4o-mini"
            : profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: Any] = [
            "model": modelName,
            "temperature": 0.2,
            "stream": stream,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        if stream {
            return try await consumeSSEStream(
                request: req,
                extractDelta: LLMProtocolHelpers.parseOpenAISSEChunk,
                onChunk: onChunk
            )
        } else {
            let (data, resp) = try await URLSession.shared.data(for: req)
            try validateHTTP(resp, data: data)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String else {
                throw LLMError.emptyResponse
            }
            let cleaned = LLMProtocolHelpers.stripThinkingTags(content)
            if cleaned.isEmpty { throw LLMError.emptyResponse }
            return cleaned
        }
    }

    private static func callAnthropic(
        system: String,
        user: String,
        profile: TranslationProviderProfile,
        stream: Bool,
        onChunk: (@Sendable (String) -> Void)?
    ) async throws -> String {
        guard let url = LLMProtocolHelpers.resolveAnthropicMessagesURL(profile.endpoint) else {
            throw LLMError.invalidEndpoint(profile.endpoint)
        }

        var req = URLRequest(url: url, timeoutInterval: 35)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = profile.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { req.setValue(key, forHTTPHeaderField: "x-api-key") }
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        applyCustomHeaders(profile.customHeadersJSON, to: &req)

        let modelName = profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "claude-3-5-haiku-latest"
            : profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: Any] = [
            "model": modelName,
            "max_tokens": 2048,
            "stream": stream,
            "system": system,
            "messages": [["role": "user", "content": user]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        if stream {
            return try await consumeSSEStream(
                request: req,
                extractDelta: LLMProtocolHelpers.parseAnthropicSSEChunk,
                onChunk: onChunk
            )
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        try validateHTTP(resp, data: data)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentArr = obj["content"] as? [[String: Any]],
              let text = contentArr.first?["text"] as? String else {
            throw LLMError.emptyResponse
        }
        let cleaned = LLMProtocolHelpers.stripThinkingTags(text)
        if cleaned.isEmpty { throw LLMError.emptyResponse }
        return cleaned
    }

    private static func callGemini(
        system: String,
        user: String,
        profile: TranslationProviderProfile,
        stream: Bool,
        onChunk: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let base = profile.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "https://generativelanguage.googleapis.com/v1beta"
            : profile.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "gemini-2.0-flash"
            : profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = profile.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = stream ? "streamGenerateContent?alt=sse&key=\(key)" : "generateContent?key=\(key)"
        guard let url = URL(string: "\(base)/models/\(model):\(action)") else { throw LLMError.invalidEndpoint(base) }

        var req = URLRequest(url: url, timeoutInterval: 35)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyCustomHeaders(profile.customHeadersJSON, to: &req)

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["parts": [["text": user]]]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        if stream {
            return try await consumeSSEStream(
                request: req,
                extractDelta: LLMProtocolHelpers.parseGeminiSSEChunk,
                onChunk: onChunk
            )
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        try validateHTTP(resp, data: data)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cands = obj["candidates"] as? [[String: Any]],
              let content = cands.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw LLMError.emptyResponse
        }
        let cleaned = LLMProtocolHelpers.stripThinkingTags(text)
        if cleaned.isEmpty { throw LLMError.emptyResponse }
        return cleaned
    }

    /// 通用 SSE 流式消费器（40ms 合并节流，避免高频 token 触发主线程全量 NSTextStorage 重排）
    private static func consumeSSEStream(
        request: URLRequest,
        extractDelta: (String) -> String?,
        onChunk: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let (bytes, resp) = try await URLSession.shared.bytes(for: request)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            var errTxt = ""
            for try await line in bytes.lines { errTxt += line; if errTxt.count > 400 { break } }
            throw LLMError.httpError(http.statusCode, errTxt)
        }
        var full = ""
        var lastEmitAt: TimeInterval = 0
        for try await line in bytes.lines {
            try Task.checkCancellation()
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("data:") else { continue }
            let payload = t.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let delta = extractDelta(payload), !delta.isEmpty else { continue }
            full += delta
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastEmitAt >= 0.04 {
                lastEmitAt = now
                let visible = LLMProtocolHelpers.stripThinkingTags(full)
                if !visible.isEmpty { onChunk?(visible) }
            }
        }
        let cleaned = LLMProtocolHelpers.stripThinkingTags(full)
        if cleaned.isEmpty { throw LLMError.emptyResponse }
        onChunk?(cleaned)
        return cleaned
    }

    private static func applyCustomHeaders(_ rawJSON: String, to req: inout URLRequest) {
        let s = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let d = s.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return }
        for (k, v) in dict { req.setValue(v, forHTTPHeaderField: k) }
    }

    private static func validateHTTP(_ resp: URLResponse, data: Data) throws {
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let snippet = String(data: data.prefix(360), encoding: .utf8) ?? ""
            throw LLMError.httpError(http.statusCode, snippet)
        }
    }
}
