import Foundation
import Security

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
