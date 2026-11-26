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
        VisionLLMOCRService.availableVisionLLMProfiles()
    }

    static func recognize(
        image: CGImage,
        config: LatexRecognitionConfig,
        activeProfileID: UUID? = nil,
        visionProfiles: [TranslationProviderProfile]
    ) async throws -> LatexRecognitionOutcome {
        let t0 = CFAbsoluteTimeGetCurrent()
        guard let pngData = VisionLLMOCRService.encodePNG(image: image, maxLongSide: 1600) else {
            throw LatexError.imageEncodeFailed
        }

        switch config.engineKind {
        case .simpleTex:
            let token = config.simpleTexToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                return await offlineFallback(image: image, t0: t0, notice: "尚未填写 SimpleTex Token，已自动使用本地离线基础识别（点击「设置」填入免费 Token）")
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
            guard let profile = OCRRecognitionConfig.resolveVisionProfile(
                preferredID: config.visionProfileID,
                activeID: activeProfileID,
                profiles: visionProfiles
            ) else {
                return await offlineFallback(image: image, t0: t0, notice: "尚未配置视觉大模型或 SimpleTex，当前为离线基础识别（前往「设置 → 识字与翻译」配置）")
            }
            let raw = try await VisionLLMOCRService.callMultimodalVisionLLM(
                pngData: pngData,
                systemPrompt: visionSystemPrompt,
                userPrompt: "Transcribe the formula in this image into pure LaTeX:",
                profile: profile,
                modelOverride: config.visionModelOverride,
                maxTokens: 2048
            )
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
}
