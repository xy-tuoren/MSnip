import AppKit
import Foundation
import MSnipCore

/// 统一翻译调度中心：
/// 负责路由 macOS 原生免费离线模型、通用大模型流式接口及国内/国际主流云翻译，并支持主备引擎自动容灾回退与连通性测速。
@MainActor
final class TranslationService {
    static let shared = TranslationService()

    struct RunResult: Sendable {
        let translatedText: String
        let providerName: String
        let usedFallback: Bool
        let elapsedMs: Int
    }

    private var suppressAutoSave = false
    var settings: TranslationSettingsConfig {
        didSet { if !suppressAutoSave { settings.save() } }
    }

    var onSettingsChanged: (() -> Void)?

    private init() {
        self.settings = TranslationSettingsConfig.load()
    }

    func reloadFromDisk() {
        suppressAutoSave = true
        self.settings = TranslationSettingsConfig.load()
        suppressAutoSave = false
        onSettingsChanged?()
    }

    func updateSettings(_ mutate: (inout TranslationSettingsConfig) -> Void) {
        var next = settings
        mutate(&next)
        settings = next
        onSettingsChanged?()
    }

    var selectableProfiles: [TranslationProviderProfile] {
        settings.profiles.filter { $0.isEnabled }
    }

    /// 流式/整段文本翻译（供双栏对照窗使用，主引擎报错时自动无缝切换备选引擎）
    func translateDocument(
        text: String,
        targetOverride: TranslationTargetLang? = nil,
        profileOverrideID: UUID? = nil,
        hostWindow: NSWindow? = nil,
        onStreamChunk: (@MainActor @Sendable (String) -> Void)? = nil
    ) async throws -> RunResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return RunResult(translatedText: "", providerName: "", usedFallback: false, elapsedMs: 0)
        }

        let target = targetOverride ?? settings.targetLang
        let primary = resolveProfile(preferredID: profileOverrideID)
        let t0 = ProcessInfo.processInfo.systemUptime

        do {
            let out = try await runSingleDocument(
                text: trimmed,
                target: target,
                profile: primary,
                hostWindow: hostWindow,
                onStreamChunk: onStreamChunk
            )
            let ms = Int(((ProcessInfo.processInfo.systemUptime - t0) * 1000).rounded())
            return RunResult(translatedText: out, providerName: primary.name, usedFallback: false, elapsedMs: ms)
        } catch let primaryError {
            if Task.isCancelled || primaryError is CancellationError || (primaryError as? URLError)?.code == .cancelled {
                throw primaryError
            }
            MSnipLog.warning(.translation, "Translation provider kind=\(primary.kind.rawValue) failed", error: primaryError)
            if let fb = resolveReadyFallback(excluding: primary.id) {
                do {
                    let out = try await runSingleDocument(
                        text: trimmed,
                        target: target,
                        profile: fb,
                        hostWindow: hostWindow,
                        onStreamChunk: onStreamChunk
                    )
                    let ms = Int(((ProcessInfo.processInfo.systemUptime - t0) * 1000).rounded())
                    MSnipLog.info(.translation, "Fallback provider kind=\(fb.kind.rawValue) succeeded in \(ms) ms")
                    return RunResult(translatedText: out, providerName: fb.displayName, usedFallback: true, elapsedMs: ms)
                } catch let fbError {
                    if Task.isCancelled || fbError is CancellationError || (fbError as? URLError)?.code == .cancelled {
                        throw fbError
                    }
                    MSnipLog.error(.translation, "Fallback provider kind=\(fb.kind.rawValue) also failed", error: fbError)
                    // 备选引擎也失败时保留主引擎的真实错误（如 401 密钥失效），避免被系统版本/语言包提示掩盖
                    throw primaryError
                }
            }
            throw primaryError
        }
    }

    /// 多行对齐批量翻译（供截图页内原位覆盖翻译 `OverlayInPlaceTranslate` 使用）
    func translateBatchLines(
        lines: [String],
        targetOverride: TranslationTargetLang? = nil,
        hostWindow: NSWindow? = nil
    ) async throws -> (lines: [String], providerName: String) {
        guard !lines.isEmpty else { return ([], "") }
        let target = targetOverride ?? settings.targetLang
        let primary = resolveProfile(preferredID: nil)
        do {
            let res = try await runBatch(lines: lines, target: target, profile: primary, hostWindow: hostWindow)
            return (res, primary.displayName)
        } catch let primaryError {
            if Task.isCancelled || primaryError is CancellationError || (primaryError as? URLError)?.code == .cancelled {
                throw primaryError
            }
            MSnipLog.warning(.translation, "Batch translation provider kind=\(primary.kind.rawValue) failed", error: primaryError)
            if let fb = resolveReadyFallback(excluding: primary.id) {
                do {
                    let res = try await runBatch(lines: lines, target: target, profile: fb, hostWindow: hostWindow)
                    return (res, L("%@ (自动回退)", fb.displayName))
                } catch let fbError {
                    if Task.isCancelled || fbError is CancellationError || (fbError as? URLError)?.code == .cancelled {
                        throw fbError
                    }
                    MSnipLog.error(.translation, "Batch fallback provider kind=\(fb.kind.rawValue) also failed", error: fbError)
                    throw primaryError
                }
            }
            throw primaryError
        }
    }

    private func resolveReadyFallback(excluding primaryID: UUID) -> TranslationProviderProfile? {
        guard let fbID = settings.fallbackProfileID, fbID != primaryID,
              let fb = settings.profiles.first(where: { $0.id == fbID && $0.isEnabled && $0.isConfiguredReady }) else { return nil }
        if fb.kind == .appleNative && !AppleNativeTranslator.isSupportedOnCurrentOS { return nil }
        return fb
    }

    /// 设置面板一键连通性与延迟测试
    func testConnectivity(
        profile: TranslationProviderProfile,
        hostWindow: NSWindow?
    ) async -> (ok: Bool, message: String) {
        let t0 = ProcessInfo.processInfo.systemUptime
        do {
            let sample = "Screenshot translation is ready."
            let out = try await runSingleDocument(
                text: sample,
                target: .zhHans,
                profile: profile,
                hostWindow: hostWindow,
                onStreamChunk: nil
            )
            let ms = Int(((ProcessInfo.processInfo.systemUptime - t0) * 1000).rounded())
            return (true, L("✓ 连通正常 (%@ ms) · 示例译文：%@", ms, out))
        } catch {
            return (false, L("✗ 测试失败：%@", error.localizedDescription))
        }
    }

    private func resolveProfile(preferredID: UUID?) -> TranslationProviderProfile {
        if let pid = preferredID, let p = settings.profiles.first(where: { $0.id == pid }) {
            return p
        }
        return settings.resolvedActiveProfile ?? TranslationProviderProfile.makePreset(.appleNative)
    }

    private func runSingleDocument(
        text: String,
        target: TranslationTargetLang,
        profile: TranslationProviderProfile,
        hostWindow: NSWindow?,
        onStreamChunk: (@MainActor @Sendable (String) -> Void)?
    ) async throws -> String {
        switch profile.kind {
        case .appleNative:
            let paragraphs = text.components(separatedBy: "\n")
            let nonEmptyIdx = paragraphs.indices.filter { !paragraphs[$0].trimmingCharacters(in: .whitespaces).isEmpty }
            let inputs = nonEmptyIdx.map { paragraphs[$0] }
            let translated = try await AppleNativeTranslator.translateBatch(lines: inputs, target: target, hostWindow: hostWindow)
            var merged = paragraphs
            for (k, origIdx) in nonEmptyIdx.enumerated() where translated.indices.contains(k) {
                merged[origIdx] = translated[k]
            }
            let finalStr = merged.joined(separator: "\n")
            onStreamChunk?(finalStr)
            return finalStr
        case .openAICompatible, .openAIResponses, .anthropicCompatible, .geminiNative:
            return try await LLMTranslator.translateStream(
                text: text,
                target: target,
                profile: profile,
                onChunk: onStreamChunk.map { cb in
                    { @Sendable chunk in Task { @MainActor in cb(chunk) } }
                }
            )
        case .tencent, .baidu, .youdao, .deepl, .customWebhook:
            // 仅送出非空行并按原索引回填，彻底杜绝空行引发腾讯云报错或百度/有道/DeepLX 尾部残留未译原文
            let paragraphs = text.components(separatedBy: "\n")
            let nonEmptyIdx = paragraphs.indices.filter { !paragraphs[$0].trimmingCharacters(in: .whitespaces).isEmpty }
            guard !nonEmptyIdx.isEmpty else { onStreamChunk?(""); return "" }
            let inputs = nonEmptyIdx.map { paragraphs[$0] }
            let translated = try await CloudAPITranslator.translateLines(lines: inputs, target: target, profile: profile)
            var merged = paragraphs
            for (k, origIdx) in nonEmptyIdx.enumerated() where translated.indices.contains(k) {
                merged[origIdx] = translated[k]
            }
            let joined = merged.joined(separator: "\n")
            onStreamChunk?(joined)
            return joined
        }
    }

    private func runBatch(
        lines: [String],
        target: TranslationTargetLang,
        profile: TranslationProviderProfile,
        hostWindow: NSWindow?
    ) async throws -> [String] {
        switch profile.kind {
        case .appleNative:
            return try await AppleNativeTranslator.translateBatch(lines: lines, target: target, hostWindow: hostWindow)
        case .openAICompatible, .openAIResponses, .anthropicCompatible, .geminiNative:
            return try await LLMTranslator.translateBatchLines(lines: lines, target: target, profile: profile)
        case .tencent, .baidu, .youdao, .deepl, .customWebhook:
            return try await CloudAPITranslator.translateLines(lines: lines, target: target, profile: profile)
        }
    }
}
