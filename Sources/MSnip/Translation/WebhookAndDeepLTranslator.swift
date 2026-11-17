import Foundation
import MSnipCore

/// DeepL 官方 API / DeepLX 自建免 Key 接口与自定义通用 JSON 模版请求适配器
enum WebhookAndDeepLTranslator {
    static func callDeepLOrDeepLX(
        lines: [String],
        target: TranslationTargetLang,
        profile: TranslationProviderProfile
    ) async throws -> [String] {
        let key = profile.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var ep = profile.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if ep.isEmpty {
            ep = key.hasSuffix(":fx") ? "https://api-free.deepl.com/v2/translate" : "https://api.deepl.com/v2/translate"
        }
        guard let url = URL(string: ep) else { throw CloudAPITranslator.CloudError.badConfig(ep) }

        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if ep.lowercased().contains("deepl.com") {
            req.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["text": lines, "target_lang": target.deeplCode])
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw CloudAPITranslator.CloudError.apiError("HTTP \(http.statusCode)")
            }
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let arr = obj["translations"] as? [[String: Any]] {
                return arr.compactMap { $0["text"] as? String }
            }
            throw CloudAPITranslator.CloudError.apiError("DeepL 响应无 translations 字段")
        } else {
            if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            let joined = lines.joined(separator: "\n")
            let dlxTarget = target.deeplCode.hasPrefix("ZH") ? "ZH" : target.deeplCode
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "text": joined, "source_lang": "auto", "target_lang": dlxTarget
            ])
            let (data, _) = try await URLSession.shared.data(for: req)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let txt = obj["data"] as? String, !txt.isEmpty {
                return CloudAPITranslator.splitPreservingCount(txt, expected: lines)
            }
            throw CloudAPITranslator.CloudError.apiError("DeepLX 响应未包含 data 译文")
        }
    }

    static func callCustomWebhook(
        text: String,
        target: TranslationTargetLang,
        profile: TranslationProviderProfile
    ) async throws -> String {
        guard let url = URL(string: profile.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CloudAPITranslator.CloudError.badConfig(profile.endpoint)
        }
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !profile.apiKey.isEmpty {
            req.setValue("Bearer \(profile.apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let hdData = profile.customHeadersJSON.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: hdData) as? [String: String] {
            for (k, v) in dict { req.setValue(v, forHTTPHeaderField: k) }
        }
        let escaped = jsonEscape(text)
        let bodyStr = profile.customBodyTemplate
            .replacingOccurrences(of: "{{text}}", with: escaped)
            .replacingOccurrences(of: "{{to}}", with: target.tencentCode)
            .replacingOccurrences(of: "{{from}}", with: "auto")
        req.httpBody = Data(bodyStr.utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CloudAPITranslator.CloudError.apiError("HTTP \(http.statusCode)")
        }
        if let json = try? JSONSerialization.jsonObject(with: data),
           let extracted = TranslationSettingsConfig.extractJSONPath(json, path: profile.customResponsePath),
           !extracted.isEmpty {
            return extracted
        }
        if let rawStr = String(data: data, encoding: .utf8), !rawStr.isEmpty { return rawStr }
        throw CloudAPITranslator.CloudError.apiError("未能按路径 \(profile.customResponsePath) 提取译文")
    }

    private static func jsonEscape(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let raw = String(data: data, encoding: .utf8), raw.count >= 4 else { return s }
        return String(raw.dropFirst(2).dropLast(2))
    }
}
