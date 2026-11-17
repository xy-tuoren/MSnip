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

        let host = "tmt.tencentcloudapi.com"
        let service = "tmt"
        let region = profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "ap-guangzhou"
            : profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let timestamp = Int(Date().timeIntervalSince1970)
        let fmt = DateFormatter()
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

        let (data, _) = try await URLSession.shared.data(for: req)
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

        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "q", value: q), URLQueryItem(name: "from", value: "auto"),
            URLQueryItem(name: "to", value: target.baiduCode), URLQueryItem(name: "appid", value: appid),
            URLQueryItem(name: "salt", value: salt), URLQueryItem(name: "sign", value: sign)
        ]
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: req)
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
        let chars = Array(text)
        let input = chars.count <= 20 ? text : (String(chars.prefix(10)) + "\(chars.count)" + String(chars.suffix(10)))
        let sign = sha256Hex(Data((appKey + input + salt + curtime + appSecret).utf8))

        let ep = profile.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "https://openapi.youdao.com/api"
            : profile.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: ep) else { throw CloudError.badConfig(ep) }

        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "q", value: text), URLQueryItem(name: "from", value: "auto"),
            URLQueryItem(name: "to", value: target.youdaoCode), URLQueryItem(name: "appKey", value: appKey),
            URLQueryItem(name: "salt", value: salt), URLQueryItem(name: "sign", value: sign),
            URLQueryItem(name: "signType", value: "v3"), URLQueryItem(name: "curtime", value: curtime)
        ]
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: req)
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
        let parts = text.components(separatedBy: .newlines)
        if parts.count == expected.count { return parts }
        var out = expected
        for i in 0..<min(out.count, parts.count) { out[i] = parts[i] }
        return out
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
