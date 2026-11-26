import Foundation
import MSnipCore

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
