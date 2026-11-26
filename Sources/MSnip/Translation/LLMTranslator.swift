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
        case .openAIResponses:
            return try await callOpenAIResponses(
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
        case .openAIResponses:
            raw = try await callOpenAIResponses(system: sys, user: packed, profile: profile, stream: false, onChunk: nil)
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
        let omitTemp = LLMProtocolHelpers.modelRequiresDefaultTemperature(modelName)
        let noSystem = LLMProtocolHelpers.modelDisallowsSystemRole(modelName)

        func makeOpenAIRequest(includeTemp: Bool, includeSystem: Bool) throws -> URLRequest {
            var r = req
            let msgs: [[String: String]] = includeSystem
                ? [["role": "system", "content": system], ["role": "user", "content": user]]
                : [["role": "user", "content": "\(system)\n\n\(user)"]]
            var body: [String: Any] = ["model": modelName, "stream": stream, "messages": msgs]
            if includeTemp { body["temperature"] = 0.2 }
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            return r
        }

        func executeOpenAI(_ request: URLRequest) async throws -> String {
            if stream {
                return try await consumeSSEStream(
                    request: request,
                    extractDelta: LLMProtocolHelpers.parseOpenAISSEChunk,
                    fallbackExtract: LLMProtocolHelpers.extractOpenAIResponseText,
                    onChunk: onChunk
                )
            }
            let (data, resp) = try await URLSession.shared.data(for: request)
            try validateHTTP(resp, data: data)
            if let cleaned = LLMProtocolHelpers.extractOpenAIResponseText(from: data) { return cleaned }
            if let err = LLMProtocolHelpers.extractErrorMessage(from: data) { throw LLMError.httpError(200, err) }
            throw LLMError.emptyResponse
        }

        do {
            return try await executeOpenAI(try makeOpenAIRequest(includeTemp: !omitTemp, includeSystem: !noSystem))
        } catch let LLMError.httpError(code, msg) where code == 400 {
            let lower = msg.lowercased()
            let dropTemp = !omitTemp && lower.contains("temperature")
            let dropSys = !noSystem && lower.contains("system")
            guard dropTemp || dropSys else { throw LLMError.httpError(code, msg) }
            return try await executeOpenAI(try makeOpenAIRequest(includeTemp: !omitTemp && !dropTemp, includeSystem: !noSystem && !dropSys))
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
            "max_tokens": 4096,
            "stream": stream,
            "system": system,
            "messages": [["role": "user", "content": user]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        if stream {
            return try await consumeSSEStream(
                request: req,
                extractDelta: LLMProtocolHelpers.parseAnthropicSSEChunk,
                fallbackExtract: LLMProtocolHelpers.extractAnthropicResponseText,
                onChunk: onChunk
            )
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        try validateHTTP(resp, data: data)
        if let cleaned = LLMProtocolHelpers.extractAnthropicResponseText(from: data) { return cleaned }
        if let err = LLMProtocolHelpers.extractErrorMessage(from: data) { throw LLMError.httpError(200, err) }
        throw LLMError.emptyResponse
    }

    private static func callGemini(
        system: String,
        user: String,
        profile: TranslationProviderProfile,
        stream: Bool,
        onChunk: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "gemini-2.5-flash"
            : profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = profile.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = LLMProtocolHelpers.resolveGeminiGenerateURL(endpoint: profile.endpoint, model: model, stream: stream) else {
            throw LLMError.invalidEndpoint(profile.endpoint)
        }

        var req = URLRequest(url: url, timeoutInterval: 35)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { req.setValue(key, forHTTPHeaderField: "x-goog-api-key") }
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
                fallbackExtract: LLMProtocolHelpers.extractGeminiResponseText,
                onChunk: onChunk
            )
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        try validateHTTP(resp, data: data)
        if let cleaned = LLMProtocolHelpers.extractGeminiResponseText(from: data) { return cleaned }
        if let err = LLMProtocolHelpers.extractErrorMessage(from: data) { throw LLMError.httpError(200, err) }
        throw LLMError.emptyResponse
    }

    static func applyCustomHeaders(_ rawJSON: String, to req: inout URLRequest) {
        let s = rawJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let d = s.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return }
        for (k, v) in dict { req.setValue(v, forHTTPHeaderField: k) }
    }

    static func validateHTTP(_ resp: URLResponse, data: Data) throws {
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let snippet = String(data: data.prefix(360), encoding: .utf8) ?? ""
            throw LLMError.httpError(http.statusCode, snippet)
        }
    }
}
