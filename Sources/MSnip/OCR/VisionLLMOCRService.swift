import CoreGraphics
import Foundation
import ImageIO
import MSnipCore
import UniformTypeIdentifiers

/// 视觉大模型 OCR 识别结果
struct VisionLLMOCROutcome: Sendable {
    let text: String
    let providerName: String
    let elapsedMs: Int
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
        guard let pngData = encodePNG(image: image, maxLongSide: 2048) else {
            throw VisionError.imageEncodeFailed
        }
        let raw = try await callMultimodalVisionLLM(
            pngData: pngData,
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
        pngData: Data,
        systemPrompt: String,
        userPrompt: String,
        profile: TranslationProviderProfile,
        modelOverride: String,
        maxTokens: Int
    ) async throws -> String {
        let b64 = pngData.base64EncodedString()
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
                ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(b64)"]]
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
                ["type": "input_image", "image_url": "data:image/png;base64,\(b64)"]
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
                    ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": b64]],
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
                    ["inline_data": ["mime_type": "image/png", "data": b64]]
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

    static func encodePNG(image: CGImage, maxLongSide: Int) -> Data? {
        let target: CGImage
        let longest = max(image.width, image.height)
        if longest > maxLongSide, longest > 0 {
            let ratio = CGFloat(maxLongSide) / CGFloat(longest)
            let nw = max(1, Int((CGFloat(image.width) * ratio).rounded()))
            let nh = max(1, Int((CGFloat(image.height) * ratio).rounded()))
            let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            if let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
                target = ctx.makeImage() ?? image
            } else { target = image }
        } else { target = image }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, target, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
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
