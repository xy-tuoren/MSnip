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
                system: sys,
                user: userPrompt,
                profile: profile,
                stream: onChunk != nil,
                onChunk: onChunk
            )
        case .anthropicCompatible:
            let res = try await callAnthropic(system: sys, user: userPrompt, profile: profile)
            onChunk?(res)
            return res
        case .geminiNative:
            let res = try await callGemini(system: sys, user: userPrompt, profile: profile)
            onChunk?(res)
            return res
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
            raw = try await callAnthropic(system: sys, user: packed, profile: profile)
        case .geminiNative:
            raw = try await callGemini(system: sys, user: packed, profile: profile)
        default:
            throw LLMError.invalidEndpoint(profile.endpoint)
        }
        return unpackNumberedLines(raw, original: lines)
    }

    private static func unpackNumberedLines(_ raw: String, original: [String]) -> [String] {
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
            let fallbackLines = raw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            for i in 0..<min(result.count, fallbackLines.count) { result[i] = fallbackLines[i] }
        }
        return result
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
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                var errTxt = ""
                for try await line in bytes.lines { errTxt += line; if errTxt.count > 400 { break } }
                throw LLMError.httpError(http.statusCode, errTxt)
            }
            var full = ""
            for try await line in bytes.lines {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("data:") else { continue }
                let payload = t.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = obj["choices"] as? [[String: Any]],
                      let delta = choices.first?["delta"] as? [String: Any],
                      let content = delta["content"] as? String, !content.isEmpty else { continue }
                full += content
                onChunk?(full)
            }
            let cleaned = full.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty { throw LLMError.emptyResponse }
            return cleaned
        } else {
            let (data, resp) = try await URLSession.shared.data(for: req)
            try validateHTTP(resp, data: data)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let msg = choices.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String else {
                throw LLMError.emptyResponse
            }
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func callAnthropic(
        system: String,
        user: String,
        profile: TranslationProviderProfile
    ) async throws -> String {
        var ep = profile.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if ep.isEmpty { ep = "https://api.anthropic.com/v1/messages" }
        else if !ep.hasSuffix("/messages") { ep = ep.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/messages" }
        guard let url = URL(string: ep) else { throw LLMError.invalidEndpoint(ep) }

        var req = URLRequest(url: url, timeoutInterval: 35)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(profile.apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        applyCustomHeaders(profile.customHeadersJSON, to: &req)

        let modelName = profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "claude-3-5-haiku-latest"
            : profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: Any] = [
            "model": modelName,
            "max_tokens": 2048,
            "system": system,
            "messages": [["role": "user", "content": user]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try validateHTTP(resp, data: data)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contentArr = obj["content"] as? [[String: Any]],
              let text = contentArr.first?["text"] as? String else {
            throw LLMError.emptyResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func callGemini(
        system: String,
        user: String,
        profile: TranslationProviderProfile
    ) async throws -> String {
        let base = profile.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "https://generativelanguage.googleapis.com/v1beta"
            : profile.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "gemini-2.0-flash"
            : profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = profile.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlStr = "\(base)/models/\(model):generateContent?key=\(key)"
        guard let url = URL(string: urlStr) else { throw LLMError.invalidEndpoint(base) }

        var req = URLRequest(url: url, timeoutInterval: 35)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyCustomHeaders(profile.customHeadersJSON, to: &req)

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["parts": [["text": user]]]]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try validateHTTP(resp, data: data)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cands = obj["candidates"] as? [[String: Any]],
              let content = cands.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw LLMError.emptyResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
