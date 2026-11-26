import Foundation

public extension Notification.Name {
    /// OCR 识字、LaTeX 公式或服务池配置变更后发出，通知已打开的双栏对照窗实时同步
    static let msnipOCRLatexConfigChanged = Notification.Name("top.xy.msnip.ocrLatexConfigChanged")
}

/// 文字识别 (OCR) 引擎类型：支持原生离线、视觉大模型、国内三大云 OCR 及统一自定义 HTTP 适配接口
public enum OCREngineKind: String, CaseIterable, Codable, Sendable {
    case appleVision = "apple_vision"
    case visionLLM = "vision_llm"
    case baiduOCR = "baidu_ocr"
    case tencentOCR = "tencent_ocr"
    case youdaoOCR = "youdao_ocr"
    case customHTTP = "custom_http"

    public var displayName: String {
        switch self {
        case .appleVision: return "Apple 原生离线 Vision（极速 · 免费）"
        case .visionLLM:   return "视觉大模型（复用「模型与服务」）"
        case .baiduOCR:    return "百度智能云 OCR（高精度 · 含免费额度）"
        case .tencentOCR:  return "腾讯云 OCR（通用高精度 · TC3 签名）"
        case .youdaoOCR:   return "有道智云 OCR（通用图文识别）"
        case .customHTTP:  return "自定义 HTTP OCR（通用适配接口）"
        }
    }

    public var shortName: String {
        switch self {
        case .appleVision: return "Apple 离线"
        case .visionLLM:   return "AI 视觉"
        case .baiduOCR:    return "百度 OCR"
        case .tencentOCR:  return "腾讯 OCR"
        case .youdaoOCR:   return "有道 OCR"
        case .customHTTP:  return "自定义 OCR"
        }
    }
}

/// 文字识别 (OCR) 引擎偏好配置（持久化于 `Application Support/MSnip/ocr_config.json`，支持可选钥匙串加密）
public struct OCRRecognitionConfig: Codable, Equatable, Sendable {
    public var engineKind: OCREngineKind = .appleVision
    /// 视觉大模型接口 ID（为空时自动跟随「模型与服务」当前启用大模型）
    public var visionProfileID: UUID? = nil
    public var visionModelOverride: String = ""

    public var baiduAPIKey: String = ""
    public var baiduSecretKey: String = ""
    public var tencentSecretID: String = ""
    public var tencentSecretKey: String = ""
    public var tencentRegion: String = "ap-guangzhou"
    public var youdaoAppKey: String = ""
    public var youdaoAppSecret: String = ""

    public var customEndpoint: String = "http://127.0.0.1:1224/api/ocr"
    public var customHeadersJSON: String = "{\"Content-Type\": \"application/json\"}"
    public var customBodyTemplate: String = "{\"base64\": \"{{image_base64}}\"}"
    public var customResponsePath: String = "data.*.text"

    public init(
        engineKind: OCREngineKind = .appleVision,
        visionProfileID: UUID? = nil,
        visionModelOverride: String = ""
    ) {
        self.engineKind = engineKind
        self.visionProfileID = visionProfileID
        self.visionModelOverride = visionModelOverride
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engineKind = (try? c.decodeIfPresent(OCREngineKind.self, forKey: .engineKind)) ?? .appleVision
        visionProfileID = try c.decodeIfPresent(UUID.self, forKey: .visionProfileID)
        visionModelOverride = try c.decodeIfPresent(String.self, forKey: .visionModelOverride) ?? ""
        baiduAPIKey = try c.decodeIfPresent(String.self, forKey: .baiduAPIKey) ?? ""
        baiduSecretKey = try c.decodeIfPresent(String.self, forKey: .baiduSecretKey) ?? ""
        tencentSecretID = try c.decodeIfPresent(String.self, forKey: .tencentSecretID) ?? ""
        tencentSecretKey = try c.decodeIfPresent(String.self, forKey: .tencentSecretKey) ?? ""
        tencentRegion = try c.decodeIfPresent(String.self, forKey: .tencentRegion) ?? "ap-guangzhou"
        youdaoAppKey = try c.decodeIfPresent(String.self, forKey: .youdaoAppKey) ?? ""
        youdaoAppSecret = try c.decodeIfPresent(String.self, forKey: .youdaoAppSecret) ?? ""
        customEndpoint = try c.decodeIfPresent(String.self, forKey: .customEndpoint) ?? "http://127.0.0.1:1224/api/ocr"
        customHeadersJSON = try c.decodeIfPresent(String.self, forKey: .customHeadersJSON) ?? "{\"Content-Type\": \"application/json\"}"
        customBodyTemplate = try c.decodeIfPresent(String.self, forKey: .customBodyTemplate) ?? "{\"base64\": \"{{image_base64}}\"}"
        customResponsePath = try c.decodeIfPresent(String.self, forKey: .customResponsePath) ?? "data.*.text"
    }

    private static var configURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("MSnip", isDirectory: true).appendingPathComponent("ocr_config.json")
    }

    public static func load(from customURL: URL? = nil, secretStore: CredentialStoring? = nil) -> OCRRecognitionConfig {
        let url = customURL ?? configURL
        guard let data = try? Data(contentsOf: url),
              var cfg = try? JSONDecoder().decode(OCRRecognitionConfig.self, from: data) else {
            return OCRRecognitionConfig()
        }
        let vault = secretStore ?? (customURL == nil ? CredentialVault.shared : nil)
        if let vault {
            if cfg.baiduSecretKey.isEmpty, let s = vault.readSecret(account: "ocr.baidu.secret"), !s.isEmpty { cfg.baiduSecretKey = s }
            if cfg.tencentSecretKey.isEmpty, let s = vault.readSecret(account: "ocr.tencent.secret"), !s.isEmpty { cfg.tencentSecretKey = s }
            if cfg.youdaoAppSecret.isEmpty, let s = vault.readSecret(account: "ocr.youdao.secret"), !s.isEmpty { cfg.youdaoAppSecret = s }
        }
        return cfg
    }

    public func save(to customURL: URL? = nil, secretStore: CredentialStoring? = nil, useKeychain: Bool? = nil) {
        let url = customURL ?? Self.configURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let preferKeychain = useKeychain ?? (customURL == nil ? TranslationSettingsConfig.load().preferKeychainStorage : false)
        let vault = secretStore ?? (customURL == nil ? CredentialVault.shared : nil)

        var diskCopy = self
        if let vault {
            func syncSecret(_ value: inout String, account: String) {
                if preferKeychain {
                    if !value.isEmpty, vault.writeSecret(value, account: account) { value = "" }
                    else if value.isEmpty { _ = vault.deleteSecret(account: account) }
                } else {
                    _ = vault.deleteSecret(account: account)
                }
            }
            syncSecret(&diskCopy.baiduSecretKey, account: "ocr.baidu.secret")
            syncSecret(&diskCopy.tencentSecretKey, account: "ocr.tencent.secret")
            syncSecret(&diskCopy.youdaoAppSecret, account: "ocr.youdao.secret")
        }

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(diskCopy) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
        }
    }

    /// 按优先顺序解析最终可用的多模态大模型配置：指定接口 → 当前活跃大模型 → 首个已就绪大模型
    public static func resolveVisionProfile(
        preferredID: UUID?,
        activeID: UUID?,
        profiles: [TranslationProviderProfile]
    ) -> TranslationProviderProfile? {
        let readyLLMs = profiles.filter { $0.isEnabled && $0.kind.isLLMProtocol && $0.isConfiguredReady }
        if let pid = preferredID, let exact = readyLLMs.first(where: { $0.id == pid }) { return exact }
        if let aid = activeID, let active = readyLLMs.first(where: { $0.id == aid }) { return active }
        return readyLLMs.first
    }

    /// 通用自定义 HTTP OCR 响应文本提取器：支持点分路径与 `*` 数组通配符（如 `data.*.text`、`words_result.*.words`、`text`）
    public static func extractCustomOCRText(from data: Data, path: String) -> String? {
        let cleanPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.isEmpty ? nil : raw
        }
        let segments = cleanPath.isEmpty ? [] : cleanPath.split(separator: ".").map(String.init)
        let lines = collectPathStrings(from: root, segments: ArraySlice(segments))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private static func collectPathStrings(from node: Any, segments: ArraySlice<String>) -> [String] {
        guard let head = segments.first else {
            if let s = node as? String { return [s] }
            if let arr = node as? [String] { return arr }
            return []
        }
        let tail = segments.dropFirst()
        if head == "*", let arr = node as? [Any] {
            return arr.flatMap { collectPathStrings(from: $0, segments: tail) }
        }
        if let dict = node as? [String: Any], let next = dict[head] {
            return collectPathStrings(from: next, segments: tail)
        }
        if let arr = node as? [Any], let idx = Int(head), arr.indices.contains(idx) {
            return collectPathStrings(from: arr[idx], segments: tail)
        }
        return []
    }
}
