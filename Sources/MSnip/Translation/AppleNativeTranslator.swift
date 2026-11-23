import AppKit
import Foundation
import MSnipCore
import NaturalLanguage
#if canImport(Translation)
import SwiftUI
import Translation
#endif

/// macOS 15+ 原生免费离线神经网络翻译适配器（基于 Apple `Translation.framework`）
/// - 已安装语言包时直接调用 `TranslationSession(installedSource:target:)` 纯后台毫秒级推理；
/// - 首次使用未下载语言包时，自动挂载 1×1 隐形 `NSHostingView` 唤起系统官方语言包免费下载弹窗。
enum AppleNativeTranslator {
    enum NativeError: LocalizedError {
        case unsupportedOS
        case unsupportedPair(String)
        case timedOutOrCancelled

        var errorDescription: String? {
            switch self {
            case .unsupportedOS:
                return "macOS 原生离线翻译需要 macOS 15.0 及以上系统，请切换大模型或云翻译接口"
            case .unsupportedPair(let pair):
                return "系统暂不支持该语种组合 (\(pair)) 的离线翻译"
            case .timedOutOrCancelled:
                return "离线语言包未完成下载或已取消（可在系统设置 › 通用 › 语言与地区 › 翻译语言 中下载）"
            }
        }
    }

    static var isSupportedOnCurrentOS: Bool {
        if #available(macOS 15.0, *) {
            #if canImport(Translation)
            return true
            #else
            return false
            #endif
        }
        return false
    }

    @MainActor
    static func queryAvailabilitySummary() async -> String {
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            let avail = LanguageAvailability()
            let en = Locale.Language(identifier: "en")
            let zh = Locale.Language(identifier: "zh-Hans")
            let st = await avail.status(from: en, to: zh)
            switch st {
            case .installed:
                return "✓ 中英离线神经网络模型已就绪（完全免费 · 断网可用）"
            case .supported:
                return "系统支持免费离线模型 · 首次点击翻译或「测试连接」将提示下载语言包"
            case .unsupported:
                return "当前系统暂不支持中英离线语言包"
            @unknown default:
                return "系统离线翻译可用"
            }
        }
        #endif
        return "当前系统版本低于 macOS 15，不支持原生离线翻译"
    }

    @MainActor
    static func translateBatch(
        lines: [String],
        target: TranslationTargetLang,
        hostWindow: NSWindow? = nil
    ) async throws -> [String] {
        guard !lines.isEmpty else { return [] }
        #if canImport(Translation)
        if #available(macOS 15.0, *) {
            let combinedSample = lines.joined(separator: "\n")
            let pair = detectLanguagePair(sample: combinedSample, target: target)
            let srcLang = Locale.Language(identifier: pair.sourceID)
            let dstLang = Locale.Language(identifier: pair.targetID)

            let avail = LanguageAvailability()
            let status = await avail.status(from: srcLang, to: dstLang)
            if status == .unsupported {
                throw NativeError.unsupportedPair("\(pair.sourceID) → \(pair.targetID)")
            }

            let requests = lines.enumerated().map { idx, txt in
                TranslationSession.Request(sourceText: txt, clientIdentifier: "\(idx)")
            }

            // 通过 1×1 隐形桥接视图获取系统 TranslationSession（兼容 macOS 15+ 全版本 SDK；未安装语言包时自动唤起下载）
            return try await translateViaDownloadBridge(
                src: srcLang,
                dst: dstLang,
                requests: requests,
                original: lines,
                needsDownload: (status != .installed),
                hostWindow: hostWindow
            )
        }
        #endif
        throw NativeError.unsupportedOS
    }

    private static func detectLanguagePair(sample: String, target: TranslationTargetLang) -> (sourceID: String, targetID: String) {
        let resolved = TranslationTargetLang.resolve(target: target, sampleText: sample)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(sample.prefix(600)))
        var src = resolved.sourceApple
        if let dom = recognizer.dominantLanguage, dom != .undetermined {
            switch dom {
            case .simplifiedChinese:  src = "zh-Hans"
            case .traditionalChinese: src = "zh-Hant"
            default:                  src = dom.rawValue
            }
        }
        var dst = resolved.concreteTarget.appleIdentifier
        if target == .autoZhEn {
            dst = (src.hasPrefix("zh")) ? "en" : "zh-Hans"
        } else if src == dst {
            src = (dst == "en") ? "zh-Hans" : "en"
        }
        return (src, dst)
    }

    #if canImport(Translation)
    @available(macOS 15.0, *)
    private static func mapOrderedResponses(
        _ responses: [TranslationSession.Response],
        original: [String]
    ) -> [String] {
        var out = original
        for (i, resp) in responses.enumerated() {
            if let cid = resp.clientIdentifier, let idx = Int(cid), out.indices.contains(idx) {
                out[idx] = resp.targetText
            } else if out.indices.contains(i) {
                out[i] = resp.targetText
            }
        }
        return out
    }

    @available(macOS 15.0, *)
    @MainActor
    private static func translateViaDownloadBridge(
        src: Locale.Language,
        dst: Locale.Language,
        requests: [TranslationSession.Request],
        original: [String],
        needsDownload: Bool,
        hostWindow: NSWindow?
    ) async throws -> [String] {
        var tempHelperPanel: NSPanel?
        let containerView: NSView
        if let content = hostWindow?.contentView {
            containerView = content
        } else {
            let panel = NSPanel(
                contentRect: NSRect(x: -2000, y: -2000, width: 2, height: 2),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.alphaValue = 0.01
            panel.orderFrontRegardless()
            tempHelperPanel = panel
            containerView = panel.contentView!
        }

        let box = BridgeCompletionBox()
        let cfg = TranslationSession.Configuration(source: src, target: dst)
        let hosting = NSHostingView(rootView: SystemTranslationTaskView(config: cfg) { session in
            do {
                if needsDownload {
                    try await session.prepareTranslation()
                }
                let responses = try await session.translations(from: requests)
                box.finish(.success(mapOrderedResponses(responses, original: original)))
            } catch {
                if needsDownload {
                    box.finish(.failure(NativeError.timedOutOrCancelled))
                } else {
                    box.finish(.failure(error))
                }
            }
        })
        hosting.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        containerView.addSubview(hosting)
        defer {
            hosting.removeFromSuperview()
            tempHelperPanel?.orderOut(nil)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                box.bind(cont)
            }
        } onCancel: {
            Task { @MainActor in
                box.finish(.failure(CancellationError()))
            }
        }
    }
    #endif
}

#if canImport(Translation)
@available(macOS 15.0, *)
private struct SystemTranslationTaskView: View {
    let config: TranslationSession.Configuration?
    let action: @MainActor (TranslationSession) async -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(config) { session in
                await action(session)
            }
    }
}

@MainActor
private final class BridgeCompletionBox {
    private var continuation: CheckedContinuation<[String], Error>?
    private var earlyResult: Result<[String], Error>?

    func bind(_ cont: CheckedContinuation<[String], Error>) {
        if let res = earlyResult {
            earlyResult = nil
            cont.resume(with: res)
        } else {
            continuation = cont
        }
    }

    func finish(_ res: Result<[String], Error>) {
        if let cont = continuation {
            continuation = nil
            cont.resume(with: res)
        } else if earlyResult == nil {
            earlyResult = res
        }
    }
}
#endif
