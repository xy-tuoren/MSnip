import Foundation
import MSnipCore

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
        case .openAICompatible:
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
        case .openAICompatible:
            if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        case .anthropicCompatible:
            if !key.isEmpty { req.setValue(key, forHTTPHeaderField: "x-api-key") }
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
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
