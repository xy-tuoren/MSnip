import AppKit
import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO
import MSnipCore
import UniformTypeIdentifiers

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

        func invalidate(for key: String) {
            lock.withLock { _ = cache.removeValue(forKey: key) }
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
        guard let imgPayload = VisionLLMOCRService.encodeForUpload(image: image, maxLongSide: 2048, maxBytes: 2_600_000) else { throw OCRError.apiError("图片编码失败") }

        let token = try await fetchBaiduAccessToken(apiKey: ak, secretKey: sk)
        guard let url = URL(string: "https://aip.baidubce.com/rest/2.0/ocr/v1/accurate_basic?access_token=\(formEncode(token))") else {
            throw OCRError.badConfig("百度 OCR 地址无效")
        }
        var req = URLRequest(url: url, timeoutInterval: 25)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("image=\(formEncode(imgPayload.data.base64EncodedString()))".utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) { throw OCRError.apiError("HTTP \(http.statusCode)") }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OCRError.apiError("百度 OCR 响应解析失败")
        }
        if let code = obj["error_code"] as? Int, code == 110 || code == 111 { baiduTokens.invalidate(for: "\(ak):\(sk)") }
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
        guard let imgPayload = VisionLLMOCRService.encodeForUpload(image: image, maxLongSide: 2048, maxBytes: 3_500_000) else { throw OCRError.apiError("图片编码失败") }

        let host = "ocr.tencentcloudapi.com", service = "ocr"
        let reg = region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "ap-guangzhou" : region.trimmingCharacters(in: .whitespacesAndNewlines)
        let ts = Int(Date().timeIntervalSince1970)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.calendar = Calendar(identifier: .gregorian)
        fmt.dateFormat = "yyyy-MM-dd"; fmt.timeZone = TimeZone(secondsFromGMT: 0)
        let dateStr = fmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))

        let payloadData = try JSONSerialization.data(withJSONObject: ["ImageBase64": imgPayload.data.base64EncodedString()])
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

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) { throw OCRError.apiError("HTTP \(http.statusCode)") }
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
        guard let imgPayload = VisionLLMOCRService.encodeForUpload(image: image, maxLongSide: 2048, maxBytes: 2_600_000) else { throw OCRError.apiError("图片编码失败") }

        let b64 = imgPayload.data.base64EncodedString()
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

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) { throw OCRError.apiError("HTTP \(http.statusCode)") }
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
        guard let imgPayload = VisionLLMOCRService.encodeForUpload(image: image, maxLongSide: 2048, maxBytes: 2_800_000) else { throw OCRError.apiError("图片编码失败") }

        let b64 = imgPayload.data.base64EncodedString()
        let tpl = config.customBodyTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "{\"base64\": \"{{image_base64}}\"}"
            : config.customBodyTemplate
        let bodyStr = tpl
            .replacingOccurrences(of: "{{image_data_uri}}", with: "data:\(imgPayload.mimeType);base64,\(b64)")
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

// MARK: - 多模态大模型识字服务

/// 视觉大模型 OCR 识别结果
struct VisionLLMOCROutcome: Sendable {
    let text: String
    let providerName: String
    let elapsedMs: Int
}

/// 体积受控的上传图片载荷（优先清晰 PNG，超限时自动平滑降级高质量 JPEG，杜绝触发百度 4MB / Claude 5MB / 腾讯 7MB 限制）
struct EncodedUploadImage: Sendable {
    let data: Data
    let mimeType: String
    let fileExtension: String
}

/// 统一多模态视觉大模型调用层（OpenAI Chat / OpenAI Responses / Anthropic Messages / Gemini Native），
/// 同时服务于「AI 视觉增强识字 (OCR)」与「LaTeX 公式识别」，避免四协议请求与流式兜底代码重复。
enum VisionLLMOCRService {
    enum VisionError: LocalizedError {
        case imageEncodeFailed
        case missingProfile
        case invalidEndpoint(String)
        case httpError(Int, String)
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .imageEncodeFailed:       return "截图编码失败"
            case .missingProfile:          return "尚未配置可用的 AI 大模型接口，请前往「设置 → 模型与服务」添加"
            case .invalidEndpoint(let ep): return "无效的视觉大模型接口地址：\(ep)"
            case .httpError(let c, let m): return "视觉模型请求失败 (HTTP \(c))：\(m)"
            case .emptyResult:             return "视觉大模型未返回可识别文本"
            }
        }
    }

    private static let ocrSystemPrompt = """
    You are a high-precision OCR engine. Transcribe ALL visible text in the image faithfully and verbatim.
    Rules:
    - Output ONLY the extracted text itself. Do NOT add explanations, commentary, or outer markdown fences.
    - Preserve original language, paragraph structure, code indentation, and punctuation accurately.
    - If the image contains a structured table, format it cleanly as a Markdown table.
    - If the image contains inline mathematical formulas, transcribe them cleanly in standard LaTeX.
    """

    @MainActor
    static func availableVisionLLMProfiles() -> [TranslationProviderProfile] {
        TranslationService.shared.settings.profiles.filter { $0.isEnabled && $0.kind.isLLMProtocol }
    }

    static func recognizeText(
        image: CGImage,
        config: OCRRecognitionConfig,
        activeProfileID: UUID?,
        profiles: [TranslationProviderProfile]
    ) async throws -> VisionLLMOCROutcome {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let profile = OCRRecognitionConfig.resolveVisionProfile(
            preferredID: config.visionProfileID,
            activeID: activeProfileID,
            profiles: profiles
        ) else {
            throw VisionError.missingProfile
        }
        guard let payload = encodeForUpload(image: image, maxLongSide: 2048, maxBytes: 2_800_000) else {
            throw VisionError.imageEncodeFailed
        }
        let raw = try await callMultimodalVisionLLM(
            imageData: payload.data,
            mimeType: payload.mimeType,
            systemPrompt: ocrSystemPrompt,
            userPrompt: "Extract all visible text from this screenshot:",
            profile: profile,
            modelOverride: config.visionModelOverride,
            maxTokens: 4096
        )
        let cleaned = stripOuterFenceIfNeeded(raw)
        guard !cleaned.isEmpty else { throw VisionError.emptyResult }
        let ms = max(1, Int(((CFAbsoluteTimeGetCurrent() - t0) * 1000).rounded()))
        let modelTag = config.visionModelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = modelTag.isEmpty ? profile.name : "\(profile.name) · \(modelTag)"
        return VisionLLMOCROutcome(text: cleaned, providerName: label, elapsedMs: ms)
    }

    /// 四协议通用多模态看图请求（兼容思考块过滤、自定义请求头与 Codex 仅流式 Responses 代理自动重试）
    static func callMultimodalVisionLLM(
        imageData: Data,
        mimeType: String = "image/png",
        systemPrompt: String,
        userPrompt: String,
        profile: TranslationProviderProfile,
        modelOverride: String,
        maxTokens: Int
    ) async throws -> String {
        let b64 = imageData.base64EncodedString()
        let customModel = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = customModel.isEmpty ? profile.model.trimmingCharacters(in: .whitespacesAndNewlines) : customModel
        let key = profile.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        switch profile.kind {
        case .openAICompatible:
            guard let url = LLMProtocolHelpers.resolveOpenAIChatURL(profile.endpoint) else {
                throw VisionError.invalidEndpoint(profile.endpoint)
            }
            var req = URLRequest(url: url, timeoutInterval: 50); req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            LLMTranslator.applyCustomHeaders(profile.customHeadersJSON, to: &req)
            let useModel = model.isEmpty ? "gpt-4o-mini" : model
            let contentParts: [[String: Any]] = [
                ["type": "text", "text": userPrompt],
                ["type": "image_url", "image_url": ["url": "data:\(mimeType);base64,\(b64)"]]
            ]
            var body: [String: Any] = [
                "model": useModel,
                "messages": [["role": "system", "content": systemPrompt], ["role": "user", "content": contentParts]]
            ]
            if !LLMProtocolHelpers.modelRequiresDefaultTemperature(useModel) { body["temperature"] = 0.1 }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req); try validateHTTP(resp, data: data)
            if let text = LLMProtocolHelpers.extractOpenAIResponseText(from: data) { return text }
            if let err = LLMProtocolHelpers.extractErrorMessage(from: data) { throw VisionError.httpError(200, err) }
            throw VisionError.emptyResult

        case .openAIResponses:
            guard let url = LLMProtocolHelpers.resolveOpenAIResponsesURL(profile.endpoint) else {
                throw VisionError.invalidEndpoint(profile.endpoint)
            }
            var req = URLRequest(url: url, timeoutInterval: 50); req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            LLMTranslator.applyCustomHeaders(profile.customHeadersJSON, to: &req)
            let useModel = model.isEmpty ? "gpt-5-mini" : model
            let inputParts: [[String: Any]] = [
                ["type": "input_text", "text": userPrompt],
                ["type": "input_image", "image_url": "data:\(mimeType);base64,\(b64)"]
            ]
            func buildReq(stream: Bool, includeStore: Bool) throws -> URLRequest {
                var r = req
                var b: [String: Any] = [
                    "model": useModel, "instructions": systemPrompt, "stream": stream,
                    "input": [["type": "message", "role": "user", "content": inputParts]]
                ]
                if includeStore { b["store"] = false }
                r.httpBody = try JSONSerialization.data(withJSONObject: b)
                return r
            }
            do {
                let (data, resp) = try await URLSession.shared.data(for: try buildReq(stream: false, includeStore: true))
                try validateHTTP(resp, data: data)
                if let text = LLMProtocolHelpers.extractOpenAIResponsesText(from: data) { return text }
                if let err = LLMProtocolHelpers.extractErrorMessage(from: data) { throw VisionError.httpError(200, err) }
                throw VisionError.emptyResult
            } catch let VisionError.httpError(code, msg) where code == 400 && (msg.lowercased().contains("stream") || msg.lowercased().contains("store")) {
                let useStream = msg.lowercased().contains("stream")
                let r = try buildReq(stream: useStream, includeStore: !msg.lowercased().contains("store"))
                if useStream {
                    return try await LLMTranslator.consumeSSEStream(
                        request: r,
                        extractDelta: LLMProtocolHelpers.parseOpenAIResponsesSSEChunk,
                        fallbackExtract: LLMProtocolHelpers.extractOpenAIResponsesText,
                        onChunk: nil
                    )
                }
                let (data, resp) = try await URLSession.shared.data(for: r); try validateHTTP(resp, data: data)
                guard let text = LLMProtocolHelpers.extractOpenAIResponsesText(from: data) else { throw VisionError.emptyResult }
                return text
            }

        case .anthropicCompatible:
            guard let url = LLMProtocolHelpers.resolveAnthropicMessagesURL(profile.endpoint) else {
                throw VisionError.invalidEndpoint(profile.endpoint)
            }
            var req = URLRequest(url: url, timeoutInterval: 50); req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !key.isEmpty { req.setValue(key, forHTTPHeaderField: "x-api-key") }
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            LLMTranslator.applyCustomHeaders(profile.customHeadersJSON, to: &req)
            let body: [String: Any] = [
                "model": model.isEmpty ? "claude-3-5-sonnet-latest" : model,
                "max_tokens": maxTokens,
                "system": systemPrompt,
                "messages": [["role": "user", "content": [
                    ["type": "image", "source": ["type": "base64", "media_type": mimeType, "data": b64]],
                    ["type": "text", "text": userPrompt]
                ]]]
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req); try validateHTTP(resp, data: data)
            if let text = LLMProtocolHelpers.extractAnthropicResponseText(from: data) { return text }
            if let err = LLMProtocolHelpers.extractErrorMessage(from: data) { throw VisionError.httpError(200, err) }
            throw VisionError.emptyResult

        case .geminiNative:
            let useModel = model.isEmpty ? "gemini-2.5-flash" : model
            guard let url = LLMProtocolHelpers.resolveGeminiGenerateURL(endpoint: profile.endpoint, model: useModel, stream: false) else {
                throw VisionError.invalidEndpoint(profile.endpoint)
            }
            var req = URLRequest(url: url, timeoutInterval: 50); req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !key.isEmpty { req.setValue(key, forHTTPHeaderField: "x-goog-api-key") }
            LLMTranslator.applyCustomHeaders(profile.customHeadersJSON, to: &req)
            let body: [String: Any] = [
                "systemInstruction": ["parts": [["text": systemPrompt]]],
                "contents": [["role": "user", "parts": [
                    ["text": userPrompt],
                    ["inline_data": ["mime_type": mimeType, "data": b64]]
                ]]]
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req); try validateHTTP(resp, data: data)
            if let text = LLMProtocolHelpers.extractGeminiResponseText(from: data) { return text }
            if let err = LLMProtocolHelpers.extractErrorMessage(from: data) { throw VisionError.httpError(200, err) }
            throw VisionError.emptyResult

        default:
            throw VisionError.missingProfile
        }
    }

    static func encodeForUpload(image: CGImage, maxLongSide: Int, maxBytes: Int = 2_800_000) -> EncodedUploadImage? {
        let target: CGImage = {
            let longest = max(image.width, image.height)
            guard longest > maxLongSide, longest > 0 else { return image }
            let ratio = CGFloat(maxLongSide) / CGFloat(longest)
            let nw = max(1, Int((CGFloat(image.width) * ratio).rounded())), nh = max(1, Int((CGFloat(image.height) * ratio).rounded()))
            let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
            ctx.interpolationQuality = .high; ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
            return ctx.makeImage() ?? image
        }()
        func encode(_ type: UTType, quality: CGFloat? = nil) -> Data? {
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, type.identifier as CFString, 1, nil) else { return nil }
            let opts: CFDictionary? = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
            CGImageDestinationAddImage(dest, target, opts)
            return CGImageDestinationFinalize(dest) ? (out as Data) : nil
        }
        if let png = encode(.png), png.count <= maxBytes { return EncodedUploadImage(data: png, mimeType: "image/png", fileExtension: "png") }
        for q in [CGFloat(0.88), 0.76, 0.62] {
            if let jpg = encode(.jpeg, quality: q), jpg.count <= maxBytes { return EncodedUploadImage(data: jpg, mimeType: "image/jpeg", fileExtension: "jpg") }
        }
        guard let fallback = encode(.jpeg, quality: 0.55) else { return nil }
        return EncodedUploadImage(data: fallback, mimeType: "image/jpeg", fileExtension: "jpg")
    }

    private static func validateHTTP(_ resp: URLResponse, data: Data) throws {
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let txt = LLMProtocolHelpers.extractErrorMessage(from: data) ?? (String(data: data.prefix(300), encoding: .utf8) ?? "")
            throw VisionError.httpError(http.statusCode, txt)
        }
    }

    private static func stripOuterFenceIfNeeded(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```"), s.hasSuffix("```"), s.count > 6, let nl = s.firstIndex(of: "\n") {
            let inner = String(s[s.index(after: nl)..<s.index(s.endIndex, offsetBy: -3)]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !inner.isEmpty { s = inner }
        }
        return s
    }
}

// MARK: - OCR 与公式引擎连通性探测

/// 设置页「识字与翻译」内 OCR / LaTeX 一键连通性探测服务：
/// 内存实时渲染极小纯矢量样本图（不依赖外部资源文件），直接验证当前已选 OCR 或公式引擎与凭据是否可用。
enum OCRLatexTestService {
    static func renderSampleImage(text: String) -> CGImage? {
        let w = 280, h = 80
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 28, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(srgbRed: 0.08, green: 0.10, blue: 0.14, alpha: 1)
        ]
        guard let attr = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attrs as CFDictionary) else { return nil }
        let line = CTLineCreateWithAttributedString(attr)
        var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
        let tw = CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, &lead))
        ctx.textPosition = CGPoint(x: max(12, (CGFloat(w) - tw) * 0.5), y: (CGFloat(h) - (asc - desc)) * 0.5)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    static func testOCR(
        config: OCRRecognitionConfig,
        activeProfileID: UUID?,
        profiles: [TranslationProviderProfile]
    ) async -> (ok: Bool, message: String) {
        guard let sample = renderSampleImage(text: "MSnip OCR 123") else { return (false, "样本图生成失败") }
        let t0 = CFAbsoluteTimeGetCurrent()
        if config.engineKind == .appleVision {
            let out = await VisionTextExtractor.recognizeTextOnlyOffMain(cgImage: sample)
            let ms = max(1, Int(((CFAbsoluteTimeGetCurrent() - t0) * 1000).rounded()))
            let preview = out.preservedText.replacingOccurrences(of: "\n", with: " ")
            return preview.isEmpty
                ? (false, "✗ Apple Vision 未识别到样本文字")
                : (true, "✓ 离线就绪 (\(ms)ms) · 识别：\(preview)")
        }
        do {
            let out = try await CloudOCRService.recognizeText(
                image: sample, engine: config.engineKind, config: config, activeProfileID: activeProfileID, profiles: profiles
            )
            let preview = String(out.text.replacingOccurrences(of: "\n", with: " ").prefix(28))
            return (true, "✓ 连通正常 (\(out.elapsedMs)ms) · 识别：\(preview)")
        } catch {
            return (false, "✗ \(error.localizedDescription)")
        }
    }

    static func testLatex(
        config: LatexRecognitionConfig,
        activeProfileID: UUID?,
        profiles: [TranslationProviderProfile]
    ) async -> (ok: Bool, message: String) {
        guard let sample = renderSampleImage(text: "x^2 + y^2 = 1") else { return (false, "样本图生成失败") }
        do {
            let out = try await LatexRecognitionService.recognize(
                image: sample, config: config, activeProfileID: activeProfileID, visionProfiles: profiles
            )
            if out.usedOfflineFallback && config.engineKind != .offlineBasic {
                return (false, "✗ 凭据未就绪：\(out.notice ?? "已回退离线")")
            }
            let preview = String(out.rawLatex.replacingOccurrences(of: "\n", with: " ").prefix(28))
            return (true, "✓ 连通正常 (\(out.elapsedMs)ms) · \(preview)")
        } catch {
            return (false, "✗ \(error.localizedDescription)")
        }
    }
}
