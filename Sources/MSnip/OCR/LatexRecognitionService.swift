import AppKit
import CoreGraphics
import Foundation
import ImageIO
import MSnipCore
import UniformTypeIdentifiers

/// LaTeX 数学公式识别结果
struct LatexRecognitionOutcome: Sendable {
    let rawLatex: String
    let providerName: String
    let elapsedMs: Int
    let usedOfflineFallback: Bool
    let notice: String?
}

/// 纯原生多引擎 LaTeX 数学公式识别服务：
/// 支持多模态视觉大模型（OpenAI / Claude / Gemini / 通义 Qwen-VL / 智谱 GLM-4V / Ollama）、SimpleTex、Mathpix 及 Apple Vision 离线兜底。
enum LatexRecognitionService {
    enum LatexError: LocalizedError {
        case imageEncodeFailed
        case missingCredentials(String)
        case invalidEndpoint(String)
        case httpError(Int, String)
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .imageEncodeFailed:         return "公式截图编码失败"
            case .missingCredentials(let m): return m
            case .invalidEndpoint(let ep):   return "无效的公式识别接口地址：\(ep)"
            case .httpError(let c, let m):   return "识别请求失败 (HTTP \(c))：\(m)"
            case .emptyResult:               return "未识别到有效的数学公式"
            }
        }
    }

    private static let visionSystemPrompt = """
    You are an expert mathematical formula OCR engine (like Mathpix/SimpleTex). Convert the mathematical formula(s) in the image into accurate, clean LaTeX code.
    Rules:
    - Output ONLY the pure LaTeX code itself. Do NOT wrap in markdown code fences (```), do NOT add explanations or comments, and do NOT include outer $$ or \\[ \\] delimiters unless the image contains multiple separate equations (in which case use \\begin{aligned} ... \\end{aligned}).
    - Preserve fractions (\\frac), integrals, sums, limits, matrices, subscripts/superscripts, and Greek letters with exact mathematical fidelity.
    """

    @MainActor
    static func availableVisionLLMProfiles() -> [TranslationProviderProfile] {
        TranslationService.shared.settings.profiles.filter { p in
            p.isEnabled && (p.kind == .openAICompatible || p.kind == .anthropicCompatible || p.kind == .geminiNative)
        }
    }

    static func recognize(
        image: CGImage,
        config: LatexRecognitionConfig,
        visionProfiles: [TranslationProviderProfile]
    ) async throws -> LatexRecognitionOutcome {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let pngData = encodePNG(image: image, maxLongSide: 1600) else {
            throw LatexError.imageEncodeFailed
        }

        switch config.engineKind {
        case .simpleTex:
            let token = config.simpleTexToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                return await offlineFallback(image: image, t0: t0, notice: "尚未填写 SimpleTex Token，已自动使用本地离线基础识别（点击「接口配置」填入免费 Token）")
            }
            let raw = try await callSimpleTex(pngData: pngData, token: token)
            return try makeOutcome(raw: raw, provider: "SimpleTex", t0: t0)

        case .mathpix:
            let appID = config.mathpixAppID.trimmingCharacters(in: .whitespacesAndNewlines)
            let appKey = config.mathpixAppKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !appID.isEmpty, !appKey.isEmpty else {
                return await offlineFallback(image: image, t0: t0, notice: "尚未填写 Mathpix App ID / Key，已自动使用本地离线基础识别")
            }
            let raw = try await callMathpix(pngData: pngData, appID: appID, appKey: appKey)
            return try makeOutcome(raw: raw, provider: "Mathpix", t0: t0)

        case .autoVisionLLM:
            let chosen = visionProfiles.first(where: { $0.id == config.visionProfileID && $0.isConfiguredReady })
                ?? visionProfiles.first(where: { $0.isConfiguredReady })
            guard let profile = chosen, profile.isConfiguredReady else {
                return await offlineFallback(image: image, t0: t0, notice: "尚未配置视觉大模型或 SimpleTex，当前为离线基础识别（配置后支持复杂分式/积分/矩阵）")
            }
            let raw = try await callVisionLLM(pngData: pngData, profile: profile, modelOverride: config.visionModelOverride)
            let modelTag = config.visionModelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = modelTag.isEmpty ? profile.name : "\(profile.name) · \(modelTag)"
            return try makeOutcome(raw: raw, provider: label, t0: t0)

        case .offlineBasic:
            return await offlineFallback(image: image, t0: t0, notice: "离线基础模式仅支持行内符号，复杂分式/矩阵建议切至 SimpleTex 或视觉大模型")
        }
    }

    private static func makeOutcome(raw: String, provider: String, t0: CFAbsoluteTime) throws -> LatexRecognitionOutcome {
        let clean = LatexPostProcessor.stripFencesAndDelimiters(raw)
        guard !clean.isEmpty else { throw LatexError.emptyResult }
        let ms = max(1, Int(((CFAbsoluteTimeGetCurrent() - t0) * 1000).rounded()))
        return LatexRecognitionOutcome(rawLatex: clean, providerName: provider, elapsedMs: ms, usedOfflineFallback: false, notice: nil)
    }

    private static func offlineFallback(image: CGImage, t0: CFAbsoluteTime, notice: String) async -> LatexRecognitionOutcome {
        let output: OCRRecognitionOutput = await withCheckedContinuation { cont in
            Task { @MainActor in
                VisionTextExtractor.recognizeAsync(from: image) { cont.resume(returning: $0) }
            }
        }
        let latex = LatexPostProcessor.heuristicUnicodeToLatex(output.formattedText(for: .preserveLines))
        let ms = max(1, Int(((CFAbsoluteTimeGetCurrent() - t0) * 1000).rounded()))
        return LatexRecognitionOutcome(rawLatex: latex, providerName: "Apple Vision 离线基础", elapsedMs: ms, usedOfflineFallback: true, notice: notice)
    }

    // MARK: - Multimodal Vision LLM (OpenAI / Anthropic / Gemini)

    private static func callVisionLLM(pngData: Data, profile: TranslationProviderProfile, modelOverride: String) async throws -> String {
        let b64 = pngData.base64EncodedString()
        let customModel = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = customModel.isEmpty ? profile.model.trimmingCharacters(in: .whitespacesAndNewlines) : customModel
        let userText = "Transcribe the formula in this image into pure LaTeX:"

        switch profile.kind {
        case .openAICompatible:
            guard let url = TranslationSettingsConfig.resolveChatCompletionsURL(profile.endpoint) else { throw LatexError.invalidEndpoint(profile.endpoint) }
            var req = URLRequest(url: url, timeoutInterval: 45); req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let key = profile.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            let body: [String: Any] = [
                "model": model.isEmpty ? "gpt-4o-mini" : model, "temperature": 0.1,
                "messages": [
                    ["role": "system", "content": visionSystemPrompt],
                    ["role": "user", "content": [["type": "text", "text": userText], ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(b64)"]]]]
                ]
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req); try validateHTTP(resp, data: data)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let msg = (obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
                  let content = msg["content"] as? String else { throw LatexError.emptyResult }
            return content

        case .anthropicCompatible:
            guard let url = LLMProtocolHelpers.resolveAnthropicMessagesURL(profile.endpoint) else {
                throw LatexError.invalidEndpoint(profile.endpoint)
            }
            var req = URLRequest(url: url, timeoutInterval: 45); req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(profile.apiKey.trimmingCharacters(in: .whitespacesAndNewlines), forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let body: [String: Any] = [
                "model": model.isEmpty ? "claude-3-5-sonnet-latest" : model, "max_tokens": 1024, "system": visionSystemPrompt,
                "messages": [["role": "user", "content": [["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": b64]], ["type": "text", "text": userText]]]]
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req); try validateHTTP(resp, data: data)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let txt = (obj["content"] as? [[String: Any]])?.first?["text"] as? String else { throw LatexError.emptyResult }
            return txt

        case .geminiNative:
            let key = profile.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let useModel = (model.isEmpty ? "gemini-2.0-flash" : model).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
            let base = profile.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "https://generativelanguage.googleapis.com/v1beta"
                : profile.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let url = URL(string: "\(base)/models/\(useModel):generateContent") else { throw LatexError.invalidEndpoint(base) }
            var req = URLRequest(url: url, timeoutInterval: 45); req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !key.isEmpty { req.setValue(key, forHTTPHeaderField: "x-goog-api-key") }
            let body: [String: Any] = [
                "systemInstruction": ["parts": [["text": visionSystemPrompt]]],
                "contents": [["role": "user", "parts": [["text": userText], ["inline_data": ["mime_type": "image/png", "data": b64]]]]]
            ]
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, resp) = try await URLSession.shared.data(for: req); try validateHTTP(resp, data: data)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = (obj["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any],
                  let txt = (content["parts"] as? [[String: Any]])?.first?["text"] as? String else { throw LatexError.emptyResult }
            return txt

        default:
            throw LatexError.missingCredentials("当前选中接口不支持视觉识图")
        }
    }

    // MARK: - SimpleTex & Mathpix Dedicated Formula APIs

    private static func callSimpleTex(pngData: Data, token: String) async throws -> String {
        guard let url = URL(string: "https://server.simpletex.cn/api/latex_ocr") else {
            throw LatexError.invalidEndpoint("SimpleTex")
        }
        let boundary = "MSnip-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"formula.png\"\r\nContent-Type: image/png\r\n\r\n".utf8))
        body.append(pngData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "token")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        try validateHTTP(resp, data: data)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LatexError.emptyResult
        }
        if let res = obj["res"] as? [String: Any], let latex = res["latex"] as? String, !latex.isEmpty {
            return latex
        }
        let errMsg = (obj["err_info"] as? [String: Any])?["err_msg"] as? String ?? (obj["msg"] as? String ?? "SimpleTex 识别返回为空")
        throw LatexError.httpError(200, errMsg)
    }

    private static func callMathpix(pngData: Data, appID: String, appKey: String) async throws -> String {
        guard let url = URL(string: "https://api.mathpix.com/v3/text") else {
            throw LatexError.invalidEndpoint("Mathpix")
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(appID, forHTTPHeaderField: "app_id")
        req.setValue(appKey, forHTTPHeaderField: "app_key")
        let body: [String: Any] = [
            "src": "data:image/png;base64,\(pngData.base64EncodedString())",
            "formats": ["latex_styled", "text"]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try validateHTTP(resp, data: data)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LatexError.emptyResult
        }
        if let styled = obj["latex_styled"] as? String, !styled.isEmpty { return styled }
        if let txt = obj["text"] as? String, !txt.isEmpty { return txt }
        let err = obj["error"] as? String ?? "Mathpix 未返回公式"
        throw LatexError.httpError(200, err)
    }

    private static func validateHTTP(_ resp: URLResponse, data: Data) throws {
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let txt = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw LatexError.httpError(http.statusCode, txt)
        }
    }

    private static func encodePNG(image: CGImage, maxLongSide: Int) -> Data? {
        let target: CGImage
        let longSide = max(image.width, image.height)
        if longSide > maxLongSide {
            let scale = Double(maxLongSide) / Double(longSide)
            let nw = max(32, Int((Double(image.width) * scale).rounded()))
            let nh = max(32, Int((Double(image.height) * scale).rounded()))
            let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            if let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
                target = ctx.makeImage() ?? image
            } else {
                target = image
            }
        } else {
            target = image
        }
        let buf = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(buf, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, target, nil)
        return CGImageDestinationFinalize(dest) ? (buf as Data) : nil
    }
}
