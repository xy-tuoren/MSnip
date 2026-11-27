import CryptoKit
import Foundation
import MSnipCore

/// 国内主流云翻译 API（腾讯云 TMT / 百度翻译 / 有道智云）纯原生 `CryptoKit` 签名适配器
enum CloudAPITranslator {
    enum CloudError: LocalizedError {
        case badConfig(String)
        case apiError(String)

        var errorDescription: String? {
            switch self {
            case .badConfig(let m): return "翻译接口配置有误：\(m)"
            case .apiError(let m):  return "翻译接口返回错误：\(m)"
            }
        }
    }

    static func translateLines(
        lines: [String],
        target: TranslationTargetLang,
        profile: TranslationProviderProfile
    ) async throws -> [String] {
        guard !lines.isEmpty else { return [] }
        let resolved = TranslationTargetLang.resolve(target: target, sampleText: lines.joined(separator: "\n")).concreteTarget
        switch profile.kind {
        case .tencent:
            return try await callTencentBatch(lines: lines, target: resolved, profile: profile)
        case .baidu:
            return try await callBaidu(lines: lines, target: resolved, profile: profile)
        case .youdao:
            let res = try await callYoudao(text: lines.joined(separator: "\n"), target: resolved, profile: profile)
            return splitPreservingCount(res, expected: lines)
        case .deepl:
            return try await WebhookAndDeepLTranslator.callDeepLOrDeepLX(lines: lines, target: resolved, profile: profile)
        case .customWebhook:
            let res = try await WebhookAndDeepLTranslator.callCustomWebhook(text: lines.joined(separator: "\n"), target: resolved, profile: profile)
            return splitPreservingCount(res, expected: lines)
        default:
            throw CloudError.badConfig(profile.kind.displayName)
        }
    }

    // MARK: - 腾讯云机器翻译 TMT (TC3-HMAC-SHA256 V3 原生签名，支持批量列表)

    private static func callTencentBatch(
        lines: [String],
        target: TranslationTargetLang,
        profile: TranslationProviderProfile
    ) async throws -> [String] {
        let secretId = profile.appIdOrSecretId.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretKey = profile.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secretId.isEmpty, !secretKey.isEmpty else { throw CloudError.badConfig("请填写腾讯云 SecretId 与 SecretKey") }

        let customHost = URL(string: profile.endpoint.trimmingCharacters(in: .whitespacesAndNewlines))?.host
            ?? profile.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = (!customHost.isEmpty && !customHost.contains("/")) ? customHost : "tmt.tencentcloudapi.com"
        let service = "tmt"
        let region = profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "ap-guangzhou"
            : profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let timestamp = Int(Date().timeIntervalSince1970)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        let dateStr = fmt.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))

        let payloadObj: [String: Any] = [
            "Source": "auto", "Target": target.tencentCode, "ProjectId": 0, "SourceTextList": lines
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payloadObj)
        let canonicalHeaders = "content-type:application/json; charset=utf-8\nhost:\(host)\n"
        let signedHeaders = "content-type;host"
        let canonicalReq = "POST\n/\n\n\(canonicalHeaders)\n\(signedHeaders)\n\(sha256Hex(payloadData))"
        let credScope = "\(dateStr)/\(service)/tc3_request"
        let stringToSign = "TC3-HMAC-SHA256\n\(timestamp)\n\(credScope)\n\(sha256Hex(Data(canonicalReq.utf8)))"

        let kDate = hmacSHA256(key: Data(("TC3" + secretKey).utf8), msg: Data(dateStr.utf8))
        let kService = hmacSHA256(key: kDate, msg: Data(service.utf8))
        let kSigning = hmacSHA256(key: kService, msg: Data("tc3_request".utf8))
        let signature = hexString(hmacSHA256(key: kSigning, msg: Data(stringToSign.utf8)))
        let auth = "TC3-HMAC-SHA256 Credential=\(secretId)/\(credScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        var req = URLRequest(url: URL(string: "https://\(host)")!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.httpBody = payloadData
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue(host, forHTTPHeaderField: "Host")
        req.setValue("TextTranslateBatch", forHTTPHeaderField: "X-TC-Action")
        req.setValue("2018-03-21", forHTTPHeaderField: "X-TC-Version")
        req.setValue("\(timestamp)", forHTTPHeaderField: "X-TC-Timestamp")
        req.setValue(region, forHTTPHeaderField: "X-TC-Region")
        req.setValue(auth, forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CloudError.apiError("HTTP \(http.statusCode)")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resp = root["Response"] as? [String: Any] else {
            throw CloudError.apiError("响应解析失败")
        }
        if let err = resp["Error"] as? [String: Any], let msg = err["Message"] as? String {
            throw CloudError.apiError(msg)
        }
        if let list = resp["TargetTextList"] as? [String], !list.isEmpty { return list }
        throw CloudError.apiError("未返回译文列表")
    }

    // MARK: - 百度翻译开放平台 (MD5 签名，原生支持 `\n` 多行对应返回)

    private static func callBaidu(
        lines: [String],
        target: TranslationTargetLang,
        profile: TranslationProviderProfile
    ) async throws -> [String] {
        let appid = profile.appIdOrSecretId.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = profile.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appid.isEmpty, !secret.isEmpty else { throw CloudError.badConfig("请填写百度翻译 AppID 与密钥") }

        let q = lines.joined(separator: "\n")
        let salt = "\(Int.random(in: 100_000...999_999))"
        let sign = md5Hex(appid + q + salt + secret)
        let ep = profile.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "https://fanyi-api.baidu.com/api/trans/vip/translate"
            : profile.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: ep) else { throw CloudError.badConfig(ep) }

        let bodyStr = formBody([
            ("q", q), ("from", "auto"), ("to", target.baiduCode),
            ("appid", appid), ("salt", salt), ("sign", sign)
        ])
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(bodyStr.utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CloudError.apiError("HTTP \(http.statusCode)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.apiError("百度响应格式异常")
        }
        if let errCode = obj["error_code"] as? String {
            throw CloudError.apiError("\(errCode): \((obj["error_msg"] as? String) ?? errCode)")
        }
        if let arr = obj["trans_result"] as? [[String: Any]] {
            let dsts = arr.compactMap { $0["dst"] as? String }
            if dsts.count == lines.count { return dsts }
            if !dsts.isEmpty { return splitPreservingCount(dsts.joined(separator: "\n"), expected: lines) }
        }
        throw CloudError.apiError("未获取到百度翻译结果")
    }

    // MARK: - 有道智云文本翻译 V3 (SHA256 截断签名)

    private static func callYoudao(
        text: String,
        target: TranslationTargetLang,
        profile: TranslationProviderProfile
    ) async throws -> String {
        let appKey = profile.appIdOrSecretId.trimmingCharacters(in: .whitespacesAndNewlines)
        let appSecret = profile.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !appKey.isEmpty, !appSecret.isEmpty else { throw CloudError.badConfig("请填写有道智云应用 ID 与应用密钥") }

        let salt = UUID().uuidString
        let curtime = "\(Int(Date().timeIntervalSince1970))"
        // 签名 input 按 Unicode 码点截取与计数（与有道官方示例 `len(q)` / `q[0:10]` 一致）；
        // Swift `Character` 会把泰文/印地文组合音标、组合 emoji 合并为单个字素簇，导致长文本签名不一致
        let scalars = Array(text.unicodeScalars)
        func scalarText(_ part: ArraySlice<Unicode.Scalar>) -> String { String(String.UnicodeScalarView(part)) }
        let input = scalars.count <= 20 ? text : (scalarText(scalars.prefix(10)) + "\(scalars.count)" + scalarText(scalars.suffix(10)))
        let sign = sha256Hex(Data((appKey + input + salt + curtime + appSecret).utf8))

        let ep = profile.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "https://openapi.youdao.com/api"
            : profile.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: ep) else { throw CloudError.badConfig(ep) }

        let bodyStr = formBody([
            ("q", text), ("from", "auto"), ("to", target.youdaoCode),
            ("appKey", appKey), ("salt", salt), ("sign", sign),
            ("signType", "v3"), ("curtime", curtime)
        ])
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(bodyStr.utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CloudError.apiError("HTTP \(http.statusCode)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.apiError("有道响应解析失败")
        }
        if let code = obj["errorCode"] as? String, code != "0" {
            throw CloudError.apiError("errorCode \(code)")
        }
        if let trans = obj["translation"] as? [String], !trans.isEmpty { return trans.joined(separator: "\n") }
        throw CloudError.apiError("有道未返回译文")
    }

    static func splitPreservingCount(_ text: String, expected: [String]) -> [String] {
        if expected.count <= 1 { return [text.trimmingCharacters(in: .whitespacesAndNewlines)] }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let parts = normalized.components(separatedBy: "\n")
        if parts.count == expected.count { return parts }
        var out = expected
        for i in 0..<min(out.count, parts.count) { out[i] = parts[i] }
        return out
    }

    private static let formAllowed: CharacterSet = {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        return cs
    }()
    private static func formEncode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? s }
    private static func formBody(_ pairs: [(String, String)]) -> String {
        pairs.map { "\($0.0)=\(formEncode($0.1))" }.joined(separator: "&")
    }
    private static func md5Hex(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func hmacSHA256(key: Data, msg: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key)))
    }
    private static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Webhook 与 DeepL 翻译适配器

/// DeepL 官方 API / DeepLX 自建免 Key 接口与自定义通用 JSON 模版请求适配器
private enum WebhookAndDeepLTranslator {
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
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw CloudAPITranslator.CloudError.apiError("HTTP \(http.statusCode)")
            }
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
        let cleanKey = profile.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanKey.isEmpty {
            req.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
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
        let path = profile.customResponsePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if let json = try? JSONSerialization.jsonObject(with: data) {
            if let extracted = TranslationSettingsConfig.extractJSONPath(json, path: path), !extracted.isEmpty {
                return extracted
            }
            throw CloudAPITranslator.CloudError.apiError("未能按路径「\(path)」提取译文")
        }
        if path.isEmpty, let rawStr = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !rawStr.isEmpty {
            return rawStr
        }
        throw CloudAPITranslator.CloudError.apiError("响应非有效 JSON 或未能按路径「\(path)」提取译文")
    }

    private static func jsonEscape(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let raw = String(data: data, encoding: .utf8), raw.count >= 4 else { return s }
        return String(raw.dropFirst(2).dropLast(2))
    }
}
