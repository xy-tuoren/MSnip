import Foundation

/// 单个翻译服务实例配置档案（可同时配置多个大模型与云翻译实例并一键切换）
public struct TranslationProviderProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: TranslationProviderKind
    public var isEnabled: Bool
    public var endpoint: String
    public var apiKey: String
    public var appIdOrSecretId: String
    public var model: String
    public var systemPrompt: String
    public var customHeadersJSON: String
    public var customBodyTemplate: String
    public var customResponsePath: String

    public init(
        id: UUID = UUID(),
        name: String,
        kind: TranslationProviderKind,
        isEnabled: Bool = true,
        endpoint: String = "",
        apiKey: String = "",
        appIdOrSecretId: String = "",
        model: String = "",
        systemPrompt: String = "",
        customHeadersJSON: String = "",
        customBodyTemplate: String = "",
        customResponsePath: String = ""
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isEnabled = isEnabled
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.appIdOrSecretId = appIdOrSecretId
        self.model = model
        self.systemPrompt = systemPrompt
        self.customHeadersJSON = customHeadersJSON
        self.customBodyTemplate = customBodyTemplate
        self.customResponsePath = customResponsePath
    }

    /// 检查必填鉴权参数是否完备（原生离线、本地 Ollama 及自建 DeepLX 免 Key 即可就绪）
    public var isConfiguredReady: Bool {
        let ep = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let appId = appIdOrSecretId.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .appleNative:
            return true
        case .openAICompatible:
            guard !ep.isEmpty else { return false }
            let lower = ep.lowercased()
            if lower.contains("127.0.0.1") || lower.contains("localhost") || lower.contains(":11434") {
                return true
            }
            return !key.isEmpty
        case .anthropicCompatible, .geminiNative:
            return !key.isEmpty
        case .tencent, .baidu, .youdao:
            return !appId.isEmpty && !key.isEmpty
        case .deepl:
            guard !ep.isEmpty else { return !key.isEmpty }
            if ep.lowercased().contains("deepl.com") { return !key.isEmpty }
            return true // 自建 DeepLX 免 Key
        case .customWebhook:
            return !ep.isEmpty && !customBodyTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public static func makePreset(_ kind: TranslationProviderKind, llmPreset: LLMQuickPreset? = nil) -> TranslationProviderProfile {
        switch kind {
        case .appleNative:
            return TranslationProviderProfile(name: "macOS 原生离线翻译（免费）", kind: .appleNative, isEnabled: true)
        case .openAICompatible:
            let p = llmPreset ?? .deepseek
            return TranslationProviderProfile(
                name: p.title,
                kind: .openAICompatible,
                isEnabled: true,
                endpoint: p.baseURL,
                model: p.defaultModel
            )
        case .anthropicCompatible:
            return TranslationProviderProfile(
                name: "Claude (Anthropic 协议)",
                kind: .anthropicCompatible,
                endpoint: "https://api.anthropic.com/v1/messages",
                model: "claude-3-5-haiku-latest"
            )
        case .geminiNative:
            return TranslationProviderProfile(
                name: "Google Gemini Flash",
                kind: .geminiNative,
                endpoint: "https://generativelanguage.googleapis.com/v1beta",
                model: "gemini-2.0-flash"
            )
        case .tencent:
            return TranslationProviderProfile(
                name: "腾讯云机器翻译 TMT",
                kind: .tencent,
                endpoint: "https://tmt.tencentcloudapi.com",
                model: "ap-guangzhou"
            )
        case .baidu:
            return TranslationProviderProfile(
                name: "百度翻译开放平台",
                kind: .baidu,
                endpoint: "https://fanyi-api.baidu.com/api/trans/vip/translate"
            )
        case .youdao:
            return TranslationProviderProfile(
                name: "有道智云文本翻译",
                kind: .youdao,
                endpoint: "https://openapi.youdao.com/api"
            )
        case .deepl:
            return TranslationProviderProfile(
                name: "DeepL / DeepLX",
                kind: .deepl,
                endpoint: "https://api-free.deepl.com/v2/translate"
            )
        case .customWebhook:
            return TranslationProviderProfile(
                name: "自定义 HTTP JSON 翻译",
                kind: .customWebhook,
                endpoint: "http://127.0.0.1:1188/translate",
                customHeadersJSON: "{\"Content-Type\": \"application/json\"}",
                customBodyTemplate: "{\"text\": \"{{text}}\", \"source_lang\": \"auto\", \"target_lang\": \"{{to}}\"}",
                customResponsePath: "data"
            )
        }
    }
}

/// 翻译全局配置与 `0600` 仅当前用户可读本地存储（免钥匙串弹窗且方便备份迁移）
public struct TranslationSettingsConfig: Codable, Equatable, Sendable {
    public var activeProfileID: UUID?
    public var fallbackProfileID: UUID?
    public var targetLang: TranslationTargetLang
    public var autoCopyTranslation: Bool
    public var profiles: [TranslationProviderProfile]

    public init(
        activeProfileID: UUID? = nil,
        fallbackProfileID: UUID? = nil,
        targetLang: TranslationTargetLang = .autoZhEn,
        autoCopyTranslation: Bool = true,
        profiles: [TranslationProviderProfile] = Self.defaultStarterProfiles()
    ) {
        self.profiles = profiles
        self.activeProfileID = activeProfileID ?? profiles.first?.id
        self.fallbackProfileID = fallbackProfileID ?? profiles.first(where: { $0.kind == .appleNative })?.id
        self.targetLang = targetLang
        self.autoCopyTranslation = autoCopyTranslation
    }

    public static func defaultStarterProfiles() -> [TranslationProviderProfile] {
        let apple = TranslationProviderProfile.makePreset(.appleNative)
        var deepseek = TranslationProviderProfile.makePreset(.openAICompatible, llmPreset: .deepseek)
        deepseek.isEnabled = true
        var ollama = TranslationProviderProfile.makePreset(.openAICompatible, llmPreset: .ollamaLocal)
        ollama.isEnabled = false
        var tencent = TranslationProviderProfile.makePreset(.tencent)
        tencent.isEnabled = true
        var baidu = TranslationProviderProfile.makePreset(.baidu)
        baidu.isEnabled = true
        return [apple, deepseek, tencent, baidu, ollama]
    }

    public var resolvedActiveProfile: TranslationProviderProfile? {
        if let id = activeProfileID,
           let hit = profiles.first(where: { $0.id == id && $0.isEnabled && $0.isConfiguredReady }) {
            return hit
        }
        return profiles.first(where: { $0.isEnabled && $0.isConfiguredReady }) ?? profiles.first
    }

    public static var storageURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("MSnip", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("translation_providers.json")
    }

    public static func load(from customURL: URL? = nil) -> TranslationSettingsConfig {
        let url = customURL ?? storageURL
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(TranslationSettingsConfig.self, from: data),
              !decoded.profiles.isEmpty else {
            let initial = TranslationSettingsConfig()
            if customURL == nil { initial.save() }
            return initial
        }
        return decoded
    }

    public func save(to customURL: URL? = nil) {
        let url = customURL ?? Self.storageURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: url, options: .atomic)
        // 强制 0600 仅当前登录用户可读写，隔离保护 API Key 隐私且不弹系统钥匙串密码框
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
    }

    /// 智能补全 OpenAI 兼容接口路径（兼容用户粘贴域名、`/v1` 或完整 `/chat/completions`）
    public static func resolveChatCompletionsURL(_ raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix("/chat/completions") {
            return URL(string: trimmed)
        }
        if trimmed.hasSuffix("/v1") || trimmed.hasSuffix("/v3") || trimmed.hasSuffix("/v4") {
            return URL(string: trimmed + "/chat/completions")
        }
        return URL(string: trimmed + "/v1/chat/completions")
    }

    /// 按点分路径提取任意 JSON 响应字段（如 `data.translations.0.text` 或 `data`）
    public static func extractJSONPath(_ root: Any, path: String) -> String? {
        let clean = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty {
            return (root as? String)
        }
        var current: Any = root
        for seg in clean.split(separator: ".").map(String.init) {
            if let dict = current as? [String: Any], let next = dict[seg] {
                current = next
            } else if let arr = current as? [Any], let idx = Int(seg), arr.indices.contains(idx) {
                current = arr[idx]
            } else {
                return nil
            }
        }
        if let s = current as? String { return s }
        if let arr = current as? [String] { return arr.joined(separator: "\n") }
        return nil
    }
}
