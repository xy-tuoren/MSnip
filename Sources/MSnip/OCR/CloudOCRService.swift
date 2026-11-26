import CoreGraphics
import CryptoKit
import Foundation
import MSnipCore

/// 统一多引擎 OCR 文字识别调度器：
/// 覆盖视觉大模型、百度智能云 OCR（高精度）、腾讯云 OCR（TC3 签名）、有道智云 OCR（V3 签名）与通用自定义 HTTP OCR 适配器。
enum CloudOCRService {
    enum OCRError: LocalizedError {
        case badConfig(String)
        case apiError(String)
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .badConfig(let m): return m
            case .apiError(let m):  return "OCR 接口返回错误：\(m)"
            case .emptyResult:      return "未识别到有效文字"
            }
        }
    }

    private final class BaiduTokenBox: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: [String: (token: String, expiresAt: Date)] = [:]

        func get(for key: String) -> String? {
            lock.withLock {
                guard let hit = cache[key], hit.expiresAt > Date().addingTimeInterval(120) else { return nil }
                return hit.token
            }
        }

        func set(_ token: String, ttl: TimeInterval, for key: String) {
            lock.withLock { cache[key] = (token, Date().addingTimeInterval(ttl)) }
        }
    }
    private static let baiduTokens = BaiduTokenBox()

    static func recognizeText(
        image: CGImage,
        engine: OCREngineKind,
        config: OCRRecognitionConfig,
        activeProfileID: UUID?,
        profiles: [TranslationProviderProfile]
    ) async throws -> VisionLLMOCROutcome {
        let t0 = CFAbsoluteTimeGetCurrent()
        switch engine {
        case .visionLLM:
            return try await VisionLLMOCRService.recognizeText(
                image: image, config: config, activeProfileID: activeProfileID, profiles: profiles
            )
        case .baiduOCR:
            let text = try await callBaiduOCR(image: image, apiKey: config.baiduAPIKey, secretKey: config.baiduSecretKey)
            return makeOutcome(text: text, provider: "百度 OCR", t0: t0)
        case .tencentOCR:
            let text = try await callTencentOCR(
                image: image, secretID: config.tencentSecretID, secretKey: config.tencentSecretKey, region: config.tencentRegion
            )
            return makeOutcome(text: text, provider: "腾讯 OCR", t0: t0)
        case .youdaoOCR:
            let text = try await callYoudaoOCR(image: image, appKey: config.youdaoAppKey, appSecret: config.youdaoAppSecret)
            return makeOutcome(text: text, provider: "有道 OCR", t0: t0)
        case .customHTTP:
            let text = try await callCustomHTTPOCR(image: image, config: config)
            return makeOutcome(text: text, provider: "自定义 OCR", t0: t0)
        case .appleVision:
            throw OCRError.badConfig("Apple 离线 Vision 请走本地管线")
        }
    }

    private static func makeOutcome(text: String, provider: String, t0: CFAbsoluteTime) -> VisionLLMOCROutcome {
        let ms = max(1, Int(((CFAbsoluteTimeGetCurrent() - t0) * 1000).rounded()))
        return VisionLLMOCROutcome(text: text, providerName: provider, elapsedMs: ms)
    }

    // MARK: - 百度智能云 OCR (OAuth2 Token 自动缓存 + 高精度版 accurate_basic)

    private static func callBaiduOCR(image: CGImage, apiKey: String, secretKey: String) async throws -> String {
        let ak = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let sk = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ak.isEmpty, !sk.isEmpty else { throw OCRError.badConfig("请先在「设置 → 识字与翻译」填写百度 OCR API Key 与 Secret Key") }
        guard let png = VisionLLMOCRService.encodePNG(image: image, maxLongSide: 2048) else { throw OCRError.apiError("图片编码失败") }

        let token = try await fetchBaiduAccessToken(apiKey: ak, secretKey: sk)
        guard let url = URL(string: "https://aip.baidubce.com/rest/2.0/ocr/v1/accurate_basic?access_token=\(formEncode(token))") else {
            throw OCRError.badConfig("百度 OCR 地址无效")
        }
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("image=\(formEncode(png.base64EncodedString()))".utf8)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OCRError.apiError("百度 OCR 响应解析失败")
        }
        if let errMsg = obj["error_msg"] as? String { throw OCRError.apiError(errMsg) }
        guard let arr = obj["words_result"] as? [[String: Any]] else { throw OCRError.emptyResult }
        let lines = arr.compactMap { $0["words"] as? String }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw OCRError.emptyResult }
        return lines.joined(separator: "\n")
    }

    private static func fetchBaiduAccessToken(apiKey: String, secretKey: String) async throws -> String {
        let cacheKey = "\(apiKey):\(secretKey)"
        if let cached = baiduTokens.get(for: cacheKey) { return cached }

        let q = "grant_type=client_credentials&client_id=\(formEncode(apiKey))&client_secret=\(formEncode(secretKey))"
        guard let url = URL(string: "https://aip.baidubce.com/oauth/2.0/token?\(q)") else { throw OCRError.badConfig("百度鉴权地址无效") }
        var req = URLRequest(url: url, timeoutInterval: 15); req.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OCRError.apiError("百度鉴权响应异常") }
        if let tok = obj["access_token"] as? String, !tok.isEmpty {
            let ttl = (obj["expires_in"] as? TimeInterval) ?? 86400
            baiduTokens.set(tok, ttl: ttl, for: cacheKey)
            return tok
        }
        throw OCRError.apiError((obj["error_description"] as? String) ?? "百度鉴权失败，请检查 API Key / Secret Key")
    }

    // MARK: - 腾讯云 OCR (GeneralAccurateOCR · TC3-HMAC-SHA256)

    private static func callTencentOCR(image: CGImage, secretID: String, secretKey: String, region: String) async throws -> String {
        let sid = secretID.trimmingCharacters(in: .whitespacesAndNewlines)
        let skey = secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sid.isEmpty, !skey.isEmpty else { throw OCRError.badConfig("请先在「设置 → 识字与翻译」填写腾讯云 SecretId 与 SecretKey") }
        guard let png = VisionLLMOCRService.encodePNG(image: image, maxLongSide: 2048) else { throw OCRError.apiError("图片编码失败") }

        let host = "ocr.tencentcloudapi.com", service = "ocr"
        let reg = region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "ap-guangzhou" : region.trimmingCharacters(in: .whitespacesAndNewlines)
        let ts = Int(Date().timeIntervalSince1970)
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd"; fmt.timeZone = TimeZone(secondsFromGMT: 0)
        let dateStr = fmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))

        let payloadData = try JSONSerialization.data(withJSONObject: ["ImageBase64": png.base64EncodedString()])
        let canonicalHeaders = "content-type:application/json; charset=utf-8\nhost:\(host)\n"
        let signedHeaders = "content-type;host"
        let canonicalReq = "POST\n/\n\n\(canonicalHeaders)\n\(signedHeaders)\n\(sha256Hex(payloadData))"
        let credScope = "\(dateStr)/\(service)/tc3_request"
        let stringToSign = "TC3-HMAC-SHA256\n\(ts)\n\(credScope)\n\(sha256Hex(Data(canonicalReq.utf8)))"
        let kDate = hmacSHA256(key: Data(("TC3" + skey).utf8), msg: Data(dateStr.utf8))
        let kService = hmacSHA256(key: kDate, msg: Data(service.utf8))
        let kSigning = hmacSHA256(key: kService, msg: Data("tc3_request".utf8))
        let sig = hmacSHA256(key: kSigning, msg: Data(stringToSign.utf8)).map { String(format: "%02x", $0) }.joined()
        let auth = "TC3-HMAC-SHA256 Credential=\(sid)/\(credScope), SignedHeaders=\(signedHeaders), Signature=\(sig)"

        var req = URLRequest(url: URL(string: "https://\(host)")!, timeoutInterval: 25)
        req.httpMethod = "POST"; req.httpBody = payloadData
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue(host, forHTTPHeaderField: "Host")
        req.setValue("GeneralAccurateOCR", forHTTPHeaderField: "X-TC-Action")
        req.setValue("2018-11-19", forHTTPHeaderField: "X-TC-Version")
        req.setValue("\(ts)", forHTTPHeaderField: "X-TC-Timestamp")
        req.setValue(reg, forHTTPHeaderField: "X-TC-Region")
        req.setValue(auth, forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resp = root["Response"] as? [String: Any] else { throw OCRError.apiError("腾讯 OCR 响应异常") }
        if let err = resp["Error"] as? [String: Any], let msg = err["Message"] as? String { throw OCRError.apiError(msg) }
        let dets = (resp["TextDetections"] as? [[String: Any]]) ?? []
        let lines = dets.compactMap { $0["DetectedText"] as? String }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw OCRError.emptyResult }
        return lines.joined(separator: "\n")
    }

    // MARK: - 有道智云 OCR (ocrapi · V3 SHA256 签名)

    private static func callYoudaoOCR(image: CGImage, appKey: String, appSecret: String) async throws -> String {
        let ak = appKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let sec = appSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ak.isEmpty, !sec.isEmpty else { throw OCRError.badConfig("请先在「设置 → 识字与翻译」填写有道智云应用 ID 与密钥") }
        guard let png = VisionLLMOCRService.encodePNG(image: image, maxLongSide: 2048) else { throw OCRError.apiError("图片编码失败") }

        let b64 = png.base64EncodedString()
        let salt = UUID().uuidString, curtime = "\(Int(Date().timeIntervalSince1970))"
        let input = b64.count <= 20 ? b64 : (String(b64.prefix(10)) + "\(b64.count)" + String(b64.suffix(10)))
        let sign = sha256Hex(Data((ak + input + salt + curtime + sec).utf8))

        let pairs: [(String, String)] = [
            ("img", b64), ("langType", "auto"), ("detectType", "10012"), ("imageType", "1"),
            ("appKey", ak), ("salt", salt), ("sign", sign), ("docType", "json"), ("signType", "v3"), ("curtime", curtime)
        ]
        var req = URLRequest(url: URL(string: "https://openapi.youdao.com/ocrapi")!, timeoutInterval: 25)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(pairs.map { "\($0.0)=\(formEncode($0.1))" }.joined(separator: "&").utf8)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OCRError.apiError("有道 OCR 响应异常") }
        if let code = obj["errorCode"] as? String, code != "0" { throw OCRError.apiError("errorCode \(code)") }
        let regions = ((obj["Result"] as? [String: Any])?["regions"] as? [[String: Any]]) ?? []
        let lines = regions.flatMap { ($0["lines"] as? [[String: Any]]) ?? [] }.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw OCRError.emptyResult }
        return lines.joined(separator: "\n")
    }

    // MARK: - 通用自定义 HTTP OCR 适配器（支持 PaddleOCR / RapidOCR / Umi-OCR / 阿里云 / 火山等任意接口）

    private static func callCustomHTTPOCR(image: CGImage, config: OCRRecognitionConfig) async throws -> String {
        let ep = config.customEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ep.isEmpty, let url = URL(string: ep) else { throw OCRError.badConfig("请先填写有效的自定义 OCR 接口 URL") }
        guard let png = VisionLLMOCRService.encodePNG(image: image, maxLongSide: 2048) else { throw OCRError.apiError("图片编码失败") }

        let b64 = png.base64EncodedString()
        let tpl = config.customBodyTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "{\"base64\": \"{{image_base64}}\"}"
            : config.customBodyTemplate
        let bodyStr = tpl
            .replacingOccurrences(of: "{{image_data_uri}}", with: "data:image/png;base64,\(b64)")
            .replacingOccurrences(of: "{{image_base64}}", with: b64)

        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        LLMTranslator.applyCustomHeaders(config.customHeadersJSON, to: &req)
        req.httpBody = Data(bodyStr.utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let msg = LLMProtocolHelpers.extractErrorMessage(from: data) ?? (String(data: data.prefix(240), encoding: .utf8) ?? "HTTP \(http.statusCode)")
            throw OCRError.apiError("HTTP \(http.statusCode): \(msg)")
        }
        guard let text = OCRRecognitionConfig.extractCustomOCRText(from: data, path: config.customResponsePath) else {
            throw OCRError.apiError("未能按路径「\(config.customResponsePath)」提取到文字")
        }
        return text
    }

    private static let formAllowed: CharacterSet = {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        return cs
    }()
    private static func formEncode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? s }
    private static func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func hmacSHA256(key: Data, msg: Data) -> Data { Data(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key))) }
}
