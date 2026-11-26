import Foundation
import Security

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
        case .openAICompatible, .openAIResponses:
            guard !ep.isEmpty else { return false }
            return isLocalNoKeyEndpoint || !key.isEmpty
        case .anthropicCompatible:
            return isLocalNoKeyEndpoint || !key.isEmpty
        case .geminiNative:
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
            return TranslationProviderProfile(name: "Apple 离线翻译", kind: .appleNative, isEnabled: true)
        case .openAICompatible:
            let p = llmPreset ?? .deepseek
            return TranslationProviderProfile(
                name: p.shortName,
                kind: .openAICompatible,
                isEnabled: true,
                endpoint: p.baseURL,
                model: p.defaultModel
            )
        case .openAIResponses:
            return TranslationProviderProfile(
                name: "OpenAI Responses",
                kind: .openAIResponses,
                isEnabled: true,
                endpoint: LLMQuickPreset.openai.baseURL,
                model: "gpt-5-mini"
            )
        case .anthropicCompatible:
            return TranslationProviderProfile(
                name: "Claude",
                kind: .anthropicCompatible,
                endpoint: LLMQuickPreset.claude.baseURL,
                model: LLMQuickPreset.claude.defaultModel
            )
        case .geminiNative:
            return TranslationProviderProfile(
                name: "Google Gemini",
                kind: .geminiNative,
                endpoint: LLMQuickPreset.gemini.baseURL,
                model: LLMQuickPreset.gemini.defaultModel
            )
        case .tencent:
            return TranslationProviderProfile(
                name: "腾讯云翻译",
                kind: .tencent,
                endpoint: "https://tmt.tencentcloudapi.com",
                model: "ap-guangzhou"
            )
        case .baidu:
            return TranslationProviderProfile(
                name: "百度翻译",
                kind: .baidu,
                endpoint: "https://fanyi-api.baidu.com/api/trans/vip/translate"
            )
        case .youdao:
            return TranslationProviderProfile(
                name: "有道智云",
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
                name: "自定义接口",
                kind: .customWebhook,
                endpoint: "http://127.0.0.1:1188/translate",
                customHeadersJSON: "{\"Content-Type\": \"application/json\"}",
                customBodyTemplate: "{\"text\": \"{{text}}\", \"source_lang\": \"auto\", \"target_lang\": \"{{to}}\"}",
                customResponsePath: "data"
            )
        }
    }
}

/// 翻译全局配置：默认采用 `0600` 仅当前用户可读本地存储（免无证书签名弹窗），亦支持开启系统钥匙串加密存储
public struct TranslationSettingsConfig: Codable, Equatable, Sendable {
    public var activeProfileID: UUID?
    public var fallbackProfileID: UUID?
    public var targetLang: TranslationTargetLang
    public var autoCopyTranslation: Bool
    public var preferKeychainStorage: Bool
    public var profiles: [TranslationProviderProfile]

    public init(
        activeProfileID: UUID? = nil,
        fallbackProfileID: UUID? = nil,
        targetLang: TranslationTargetLang = .autoZhEn,
        autoCopyTranslation: Bool = true,
        preferKeychainStorage: Bool = false,
        profiles: [TranslationProviderProfile] = Self.defaultStarterProfiles()
    ) {
        self.profiles = profiles
        self.activeProfileID = activeProfileID ?? profiles.first?.id
        self.fallbackProfileID = fallbackProfileID ?? profiles.first(where: { $0.kind == .appleNative })?.id
        self.targetLang = targetLang
        self.autoCopyTranslation = autoCopyTranslation
        self.preferKeychainStorage = preferKeychainStorage
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let list = try c.decodeIfPresent([TranslationProviderProfile].self, forKey: .profiles) ?? Self.defaultStarterProfiles()
        self.profiles = list
        self.activeProfileID = try c.decodeIfPresent(UUID.self, forKey: .activeProfileID) ?? list.first?.id
        self.fallbackProfileID = try c.decodeIfPresent(UUID.self, forKey: .fallbackProfileID)
            ?? list.first(where: { $0.kind == .appleNative })?.id
        self.targetLang = try c.decodeIfPresent(TranslationTargetLang.self, forKey: .targetLang) ?? .autoZhEn
        self.autoCopyTranslation = try c.decodeIfPresent(Bool.self, forKey: .autoCopyTranslation) ?? true
        self.preferKeychainStorage = try c.decodeIfPresent(Bool.self, forKey: .preferKeychainStorage) ?? false
    }

    public static func defaultStarterProfiles() -> [TranslationProviderProfile] {
        let apple = TranslationProviderProfile.makePreset(.appleNative)
        let zhipu = TranslationProviderProfile.makePreset(.openAICompatible, llmPreset: .zhipuFree)
        let deepseek = TranslationProviderProfile.makePreset(.openAICompatible, llmPreset: .deepseek)
        let tencent = TranslationProviderProfile.makePreset(.tencent)
        let baidu = TranslationProviderProfile.makePreset(.baidu)
        var ollama = TranslationProviderProfile.makePreset(.openAICompatible, llmPreset: .ollamaLocal)
        ollama.isEnabled = false
        return [apple, zhipu, deepseek, tencent, baidu, ollama]
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

    /// 轻量读取是否启用钥匙串加密（首次升级尚未写入 UserDefaults 时按需回读本地 JSON 布尔位，零钥匙串 IPC）
    public static func cachedPreferKeychainFlag() -> Bool {
        let key = "MSnip.preferKeychainStorage"
        if UserDefaults.standard.object(forKey: key) != nil { return UserDefaults.standard.bool(forKey: key) }
        let prefer = (try? Data(contentsOf: storageURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["preferKeychainStorage"] as? Bool } ?? false
        UserDefaults.standard.set(prefer, forKey: key)
        return prefer
    }

    public static func load(from customURL: URL? = nil, secretStore: CredentialStoring? = nil) -> TranslationSettingsConfig {
        let url = customURL ?? storageURL
        let vault = secretStore ?? (customURL == nil ? CredentialVault.shared : nil)
        guard let data = try? Data(contentsOf: url),
              var decoded = try? JSONDecoder().decode(TranslationSettingsConfig.self, from: data),
              !decoded.profiles.isEmpty else {
            let initial = TranslationSettingsConfig()
            if customURL == nil { initial.save(secretStore: secretStore) }
            return initial
        }
        if customURL == nil { UserDefaults.standard.set(decoded.preferKeychainStorage, forKey: "MSnip.preferKeychainStorage") }
        if decoded.preferKeychainStorage, let vault {
            for i in decoded.profiles.indices where decoded.profiles[i].apiKey.isEmpty {
                if let s = vault.readSecret(account: keychainAccount(for: decoded.profiles[i].id)), !s.isEmpty { decoded.profiles[i].apiKey = s }
            }
        }
        return decoded
    }

    public func save(to customURL: URL? = nil, secretStore: CredentialStoring? = nil) {
        let url = customURL ?? Self.storageURL
        if customURL == nil { UserDefaults.standard.set(preferKeychainStorage, forKey: "MSnip.preferKeychainStorage") }
        let vault = secretStore ?? (customURL == nil ? CredentialVault.shared : nil)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var diskCopy = self
        if let vault {
            for i in diskCopy.profiles.indices {
                let acct = Self.keychainAccount(for: diskCopy.profiles[i].id), secret = diskCopy.profiles[i].apiKey
                if preferKeychainStorage {
                    if !secret.isEmpty, vault.writeSecret(secret, account: acct) { diskCopy.profiles[i].apiKey = "" }
                    else if secret.isEmpty { _ = vault.deleteSecret(account: acct) }
                } else { _ = vault.deleteSecret(account: acct) }
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(diskCopy) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
    }

    private static func keychainAccount(for id: UUID) -> String { "translation.profile.\(id.uuidString)" }

    /// 删除指定服务配置对应的系统钥匙串孤儿条目
    public static func deleteKeychainSecret(for profileID: UUID, secretStore: CredentialStoring? = nil) {
        let vault = secretStore ?? CredentialVault.shared
        _ = vault.deleteSecret(account: keychainAccount(for: profileID))
    }

    /// 智能补全 OpenAI 兼容接口路径（兼容用户粘贴域名、`/v1` 或完整 `/chat/completions`）
    public static func resolveChatCompletionsURL(_ raw: String) -> URL? {
        LLMProtocolHelpers.resolveOpenAIChatURL(raw)
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

// MARK: - 0600 本地隔离与系统钥匙串凭据仓

/// 敏感凭据存储抽象（支持生产环境系统钥匙串 `Security.framework` 与单测内存隔离实现）
public protocol CredentialStoring: Sendable {
    func readSecret(account: String) -> String?
    @discardableResult func writeSecret(_ secret: String, account: String) -> Bool
    @discardableResult func deleteSecret(account: String) -> Bool
}

/// 基于 macOS 原生 `Security` 框架的钥匙串密钥存储
public struct KeychainCredentialStore: CredentialStoring {
    public let service: String

    public init(service: String = "top.xy.msnip.credentials") {
        self.service = service
    }

    public func readSecret(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return nil
        }
        return str
    }

    @discardableResult
    public func writeSecret(_ secret: String, account: String) -> Bool {
        guard !secret.isEmpty else {
            return deleteSecret(account: account)
        }
        guard let encoded = secret.data(using: .utf8) else { return false }
        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let attrsToUpdate: [CFString: Any] = [
            kSecValueData: encoded
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attrsToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData] = encoded
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    @discardableResult
    public func deleteSecret(account: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// 线程安全内存凭据仓（供无界面自动化单测验证密钥脱敏、回填与迁移逻辑，零系统弹窗）
public final class MemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init() {}

    public func readSecret(account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[account]
    }

    @discardableResult
    public func writeSecret(_ secret: String, account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if secret.isEmpty {
            storage.removeValue(forKey: account)
        } else {
            storage[account] = secret
        }
        return true
    }

    @discardableResult
    public func deleteSecret(account: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: account)
        return true
    }
}

/// 凭据安全工具集：提供默认钥匙串实例与当前进程代码签名稳定性检测
public enum CredentialVault {
    public static let shared: CredentialStoring = KeychainCredentialStore()

    /// 检测当前运行二进制是否具备非 Ad-hoc 的固定代码签名身份（如 `MSnip Local Signer` 或 `Developer ID`）
    public static func hasStableCodeSignature() -> Bool {
        var codeRef: SecCode?
        guard SecCodeCopySelf([], &codeRef) == errSecSuccess, let code = codeRef else { return false }
        var staticCodeRef: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCodeRef) == errSecSuccess,
              let staticCode = staticCodeRef else { return false }
        var infoRef: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &infoRef) == errSecSuccess,
              let info = infoRef as? [String: Any],
              info[kSecCodeInfoIdentifier as String] != nil else { return false }
        // 非 Ad-hoc 签名（如本机固定证书或 Developer ID）必包含至少一张 X.509 签名证书链
        let certs = info[kSecCodeInfoCertificates as String] as? [Any] ?? []
        return !certs.isEmpty
    }
}
