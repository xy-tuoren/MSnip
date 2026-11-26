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

// MARK: - Responses 协议与 SSE 流式解析

/// OpenAI Responses API (`/v1/responses`) 适配器与四协议通用 SSE 消费器（兼容 Codex 仅流式网关与非流式 JSON 兜底）
extension LLMTranslator {
    static func callOpenAIResponses(
        system: String,
        user: String,
        profile: TranslationProviderProfile,
        stream: Bool,
        onChunk: (@Sendable (String) -> Void)?
    ) async throws -> String {
        guard let url = LLMProtocolHelpers.resolveOpenAIResponsesURL(profile.endpoint) else {
            throw LLMError.invalidEndpoint(profile.endpoint)
        }
        var req = URLRequest(url: url, timeoutInterval: 40)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = profile.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        applyCustomHeaders(profile.customHeadersJSON, to: &req)

        let modelName = profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "gpt-5-mini"
            : profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let omitTemp = LLMProtocolHelpers.modelRequiresDefaultTemperature(modelName)

        func makeRequest(useStream: Bool, includeTemp: Bool, includeStore: Bool) throws -> URLRequest {
            var r = req
            var body: [String: Any] = [
                "model": modelName,
                "instructions": system,
                "input": [
                    ["type": "message", "role": "user", "content": [["type": "input_text", "text": user]]]
                ],
                "stream": useStream
            ]
            if includeStore { body["store"] = false }
            if includeTemp { body["temperature"] = 0.2 }
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            return r
        }

        func execute(useStream: Bool, includeTemp: Bool, includeStore: Bool) async throws -> String {
            let request = try makeRequest(useStream: useStream, includeTemp: includeTemp, includeStore: includeStore)
            if useStream {
                return try await consumeSSEStream(
                    request: request,
                    extractDelta: LLMProtocolHelpers.parseOpenAIResponsesSSEChunk,
                    fallbackExtract: LLMProtocolHelpers.extractOpenAIResponsesText,
                    onChunk: onChunk
                )
            }
            let (data, resp) = try await URLSession.shared.data(for: request)
            try validateHTTP(resp, data: data)
            if let cleaned = LLMProtocolHelpers.extractOpenAIResponsesText(from: data) { return cleaned }
            if let err = LLMProtocolHelpers.extractErrorMessage(from: data) { throw LLMError.httpError(200, err) }
            throw LLMError.emptyResponse
        }

        do {
            return try await execute(useStream: stream, includeTemp: !omitTemp, includeStore: true)
        } catch let LLMError.httpError(code, msg) where code == 400 {
            let lower = msg.lowercased()
            let forceStream = !stream && lower.contains("stream")
            let dropTemp = !omitTemp && lower.contains("temperature")
            let dropStore = lower.contains("store")
            guard forceStream || dropTemp || dropStore else { throw LLMError.httpError(code, msg) }
            return try await execute(
                useStream: stream || forceStream,
                includeTemp: !omitTemp && !dropTemp,
                includeStore: !dropStore
            )
        }
    }

    /// 通用 SSE 流式消费器（40ms 合并节流；兼容只发 completed 事件或忽略 stream 直接返回 JSON 的网关）
    static func consumeSSEStream(
        request: URLRequest,
        extractDelta: (String) -> String?,
        fallbackExtract: (Data) -> String?,
        onChunk: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let (bytes, resp) = try await URLSession.shared.bytes(for: request)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            var errTxt = ""
            for try await line in bytes.lines { errTxt += line; if errTxt.count > 400 { break } }
            throw LLMError.httpError(http.statusCode, errTxt)
        }
        var full = "", rawFallback = "", doneFallback = "", streamErr: String?
        var lastEmitAt: TimeInterval = 0
        for try await line in bytes.lines {
            try Task.checkCancellation()
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("data:") {
                let payload = t.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                if let delta = extractDelta(payload), !delta.isEmpty {
                    full += delta
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastEmitAt >= 0.04 {
                        lastEmitAt = now
                        let visible = LLMProtocolHelpers.stripThinkingTags(full)
                        if !visible.isEmpty { onChunk?(visible) }
                    }
                } else if let d = payload.data(using: .utf8) {
                    if full.isEmpty, let fb = fallbackExtract(d), !fb.isEmpty { doneFallback = fb }
                    if streamErr == nil { streamErr = LLMProtocolHelpers.extractErrorMessage(from: d) }
                }
            } else if full.isEmpty && rawFallback.count < 65536 {
                rawFallback += line
            }
        }
        var cleaned = LLMProtocolHelpers.stripThinkingTags(full)
        if cleaned.isEmpty && !doneFallback.isEmpty { cleaned = doneFallback }
        if cleaned.isEmpty, let rawData = rawFallback.data(using: .utf8), !rawData.isEmpty {
            if let fallback = fallbackExtract(rawData) { cleaned = fallback }
            else if streamErr == nil { streamErr = LLMProtocolHelpers.extractErrorMessage(from: rawData) }
        }
        if cleaned.isEmpty {
            if let err = streamErr { throw LLMError.httpError(200, err) }
            throw LLMError.emptyResponse
        }
        onChunk?(cleaned)
        return cleaned
    }
}

// MARK: - 模型列表自动拉取服务

/// 大模型服务端可用模型列表自动拉取客户端（支持 OpenAI / Anthropic 兼容 `/v1/models` 及 Gemini 原生接口）
enum LLMModelFetcher {
    enum FetchError: LocalizedError {
        case invalidEndpoint
        case httpError(Int, String)
        case emptyList

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint: return "请先填写有效的接口地址（Base URL）"
            case .httpError(let code, let msg): return "拉取模型失败 (HTTP \(code))：\(msg)"
            case .emptyList: return "服务端未返回可用模型列表，可手动填写模型名"
            }
        }
    }

    static func fetchModels(profile: TranslationProviderProfile) async throws -> [String] {
        let key = profile.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL?
        switch profile.kind {
        case .openAICompatible, .openAIResponses:
            url = LLMProtocolHelpers.resolveOpenAIModelsURL(profile.endpoint)
        case .anthropicCompatible:
            url = LLMProtocolHelpers.resolveAnthropicModelsURL(profile.endpoint)
        case .geminiNative:
            url = LLMProtocolHelpers.resolveGeminiModelsURL(endpoint: profile.endpoint, apiKey: key)
        default:
            url = nil
        }
        guard let targetURL = url else { throw FetchError.invalidEndpoint }

        var req = URLRequest(url: targetURL, timeoutInterval: 12)
        req.httpMethod = "GET"
        switch profile.kind {
        case .openAICompatible, .openAIResponses:
            if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        case .anthropicCompatible:
            if !key.isEmpty { req.setValue(key, forHTTPHeaderField: "x-api-key") }
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .geminiNative:
            if !key.isEmpty { req.setValue(key, forHTTPHeaderField: "x-goog-api-key") }
        default:
            break
        }
        let headersRaw = profile.customHeadersJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if !headersRaw.isEmpty, let d = headersRaw.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: d) as? [String: String] {
            for (k, v) in dict { req.setValue(v, forHTTPHeaderField: k) }
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let snippet = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw FetchError.httpError(http.statusCode, snippet)
        }
        let models = LLMProtocolHelpers.parseModelIDs(from: data, kind: profile.kind)
        if models.isEmpty { throw FetchError.emptyList }
        return models
    }
}
