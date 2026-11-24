import AppKit
import Foundation
import MSnipCore
import UniformTypeIdentifiers

/// 非敏感常规偏好配置导入/导出与系统环境诊断报告工具（严格排除所有 API Key 与凭据）
@MainActor
enum AppConfigPortability {
    static func exportConfigInteractive(_ config: AppConfig) {
        let panel = NSSavePanel()
        let df = DateFormatter(); df.dateFormat = "yyyyMMdd"
        panel.nameFieldStringValue = "MSnip-config-\(df.string(from: Date())).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.title = "导出 MSnip 配置文件（不含任何 API 密钥）"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(config) else {
            ToastHUD.show(message: "导出配置失败：序列化异常")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            ToastHUD.show(
                message: "✓ 已导出配置文件（不含 API 密钥）",
                subtitle: url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                actionTitle: "在访达中显示 ›",
                onAction: { ClipboardAndSave.revealInFinder(url) }
            )
        } catch {
            ToastHUD.show(message: "写入配置文件失败：\(error.localizedDescription)")
        }
    }

    static func importConfigInteractive() -> AppConfig? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "选择 MSnip 配置文件 (.json)"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            ToastHUD.show(message: "导入失败：文件格式无效或不是 MSnip 配置文件")
            return nil
        }
        ToastHUD.show(message: "✓ 已导入配置并即时生效")
        return decoded
    }

    static func buildDiagnosticReport(config: AppConfig) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let ver = (info["CFBundleShortVersionString"] as? String) ?? "dev"
        let build = (info["CFBundleVersion"] as? String) ?? "1"
        let osVer = ProcessInfo.processInfo.operatingSystemVersionString
        #if arch(arm64)
        let arch = "arm64 (Apple Silicon)"
        #else
        let arch = "x86_64 (Intel)"
        #endif
        let screenOK = ScreenCapturer.runtimeVerifiedAccess || CGPreflightScreenCaptureAccess()
        let axOK = RegionDetector.checkAccessibilityPermission(prompt: false)
        let signed = CredentialVault.hasStableCodeSignature()
        let screens = NSScreen.screens.enumerated().map { idx, scr in
            let f = scr.frame
            return "  - Display \(idx + 1): \(Int(f.width))×\(Int(f.height)) @\(Int(scr.backingScaleFactor))x \(scr.maximumFramesPerSecond)Hz origin=(\(Int(f.minX)), \(Int(f.minY)))"
        }.joined(separator: "\n")
        let transKind = TranslationService.shared.settings.resolvedActiveProfile?.kind.rawValue ?? "none"
        let ro = config.recordingOptions

        return """
        MSnip Diagnostic Report
        -----------------------
        App: MSnip v\(ver) (\(build))
        Bundle: \(Bundle.main.bundlePath)
        Architecture: \(arch)
        macOS: \(osVer)
        Code Signature Stable: \(signed ? "Yes" : "Ad-hoc/Dev")
        TCC Screen Recording: \(screenOK ? "Granted" : "Missing")
        TCC Accessibility: \(axOK ? "Granted" : "Missing")
        Displays (\(NSScreen.screens.count)):
        \(screens)
        Preferences (Non-Secret):
          - HotKey Preset: \(config.hotKeyPreset.rawValue) (forceTap=\(config.forcePriorityHotKeys))
          - Quick Capture: delay=\(config.delayedCaptureSeconds)s, fullScreen=\(config.fullScreenCaptureAction.rawValue), pinGlow=\(Int((config.pinGlowStrength * 100).rounded()))%
          - Export Format: \(config.exportImageFormat.rawValue) (1xScale=\(config.exportAt1xScale))
          - Recording: \(config.preferredRecordingFormat.rawValue), GIF \(ro.clampedGifFPS)fps/\(ro.clampedGifMaxLongSide)px, MP4 \(ro.mp4Resolution.rawValue)/\(ro.mp4FPSMode.rawValue), cursor=\(ro.showsCursor), audio=\(ro.captureSystemAudio)
          - Translation Active Kind: \(transKind)
          - Appearance: \(config.appearanceMode.rawValue)
          - Terminal Paste Adapt: \(config.terminalPasteAdaptEnabled)
        """
    }
}
