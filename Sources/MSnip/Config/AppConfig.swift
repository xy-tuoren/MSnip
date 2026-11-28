import AppKit
import Foundation
import MSnipCore
import ServiceManagement
import UniformTypeIdentifiers

/// 应用持久化配置（存储于 ~/Library/Application Support/MSnip/config.json）
struct AppConfig: Codable {
    var hotKeyPreset: HotKeyPreset = .optASD
    var hotKeysEnabled: Bool = true
    var forcePriorityHotKeys: Bool = false
    var globalHotKeyOverrides: [String: HotKeyBindingOverride] = [:]
    var customCanvasKeys: [String: String] = [:]
    var defaultColorIndex: Int = 0
    var defaultLineWidth: CGFloat = 3.0
    var lastSaveDirectory: String?
    var recentSaveDirectories: [String] = []
    var colorCopyFormat: ColorCopyFormat = .hex
    var showShortcutTips: Bool = true
    var preferredRecordingFormat: RecordingFormat = .gif
    var recordInteractionHUD: Bool = true
    var recordingOptions: RecordingOptions = RecordingOptions()
    var defaultTextCapsule: Bool = false
    var ocrAutoOpenDualPane: Bool = false
    var ocrPresentation: OCRDefaultPresentation = .inPlace
    var translateAutoOpenDualPane: Bool = false
    var ocrAutoCopy: Bool = true
    var exportImageFormat: CaptureExportFormat = .png
    var exportAt1xScale: Bool = false
    var appearanceMode: AppAppearanceMode = .dark
    var terminalPasteAdaptEnabled: Bool = true
    var filenameTemplate: String = SaveFilenameTemplate.defaultTemplate
    var soundFeedbackEnabled: Bool = false
    var backdropAspectRatio: BackdropAspectRatio = .auto
    var backdropWatermark: String = ""
    var delayedCaptureSeconds: Int = DelayedCaptureSettings.defaultSeconds
    var fullScreenCaptureAction: FullScreenCaptureAction = .copy
    var pinGlowStrength: CGFloat = 0.45
    var topShelfHoverEnabled: Bool = true
    var topShelfTriggerMode: TopShelfTriggerMode = .topEdgeHover
    var showQuickAccessOverlay: Bool = true
    var collageOptions: CollageOptions = CollageOptions()

    private enum CodingKeys: String, CodingKey {
        case hotKeyPreset, hotKeysEnabled, forcePriorityHotKeys, globalHotKeyOverrides, customCanvasKeys
        case customCaptureCombo, customPinCombo, customOCRCombo
        case defaultColorIndex, defaultLineWidth, lastSaveDirectory, recentSaveDirectories
        case colorCopyFormat, showShortcutTips, preferredRecordingFormat, recordInteractionHUD, recordingOptions, defaultTextCapsule
        case ocrAutoOpenDualPane, ocrPresentation, translateAutoOpenDualPane, ocrAutoCopy
        case exportImageFormat, exportAt1xScale, appearanceMode, terminalPasteAdaptEnabled
        case filenameTemplate, soundFeedbackEnabled, backdropAspectRatio, backdropWatermark
        case delayedCaptureSeconds, fullScreenCaptureAction, pinGlowStrength, topShelfHoverEnabled, topShelfTriggerMode
        case showQuickAccessOverlay, collageOptions
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 逐字段宽松解码：单个字段类型异常或出现本版本未知的枚举值（如降级运行）时仅该项回退默认，不再整份偏好重置
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            try? c.decodeIfPresent(type, forKey: key)
        }
        hotKeyPreset = value(HotKeyPreset.self, .hotKeyPreset) ?? .optASD
        hotKeysEnabled = value(Bool.self, .hotKeysEnabled) ?? true
        forcePriorityHotKeys = value(Bool.self, .forcePriorityHotKeys) ?? false
        var overrides = value([String: HotKeyBindingOverride].self, .globalHotKeyOverrides) ?? [:]
        if overrides[GlobalHotKeyAction.capture.rawValue] == nil, let cap = value(KeyCombo.self, .customCaptureCombo) {
            overrides[GlobalHotKeyAction.capture.rawValue] = .custom(cap)
        }
        if overrides[GlobalHotKeyAction.pin.rawValue] == nil, let pin = value(KeyCombo.self, .customPinCombo) {
            overrides[GlobalHotKeyAction.pin.rawValue] = .custom(pin)
        }
        if overrides[GlobalHotKeyAction.ocr.rawValue] == nil, let ocr = value(KeyCombo.self, .customOCRCombo) {
            overrides[GlobalHotKeyAction.ocr.rawValue] = .custom(ocr)
        }
        globalHotKeyOverrides = overrides
        customCanvasKeys = value([String: String].self, .customCanvasKeys) ?? [:]
        defaultColorIndex = value(Int.self, .defaultColorIndex) ?? 0
        defaultLineWidth = value(CGFloat.self, .defaultLineWidth) ?? 3.0
        lastSaveDirectory = value(String.self, .lastSaveDirectory)
        recentSaveDirectories = value([String].self, .recentSaveDirectories) ?? []
        colorCopyFormat = value(ColorCopyFormat.self, .colorCopyFormat) ?? .hex
        showShortcutTips = value(Bool.self, .showShortcutTips) ?? true
        preferredRecordingFormat = value(RecordingFormat.self, .preferredRecordingFormat) ?? .gif
        recordInteractionHUD = value(Bool.self, .recordInteractionHUD) ?? true
        recordingOptions = value(RecordingOptions.self, .recordingOptions) ?? RecordingOptions()
        defaultTextCapsule = value(Bool.self, .defaultTextCapsule) ?? false
        let legacyDualOCR = value(Bool.self, .ocrAutoOpenDualPane) ?? false
        ocrPresentation = value(OCRDefaultPresentation.self, .ocrPresentation) ?? (legacyDualOCR ? .dualPane : .inPlace)
        ocrAutoOpenDualPane = (ocrPresentation == .dualPane)
        translateAutoOpenDualPane = value(Bool.self, .translateAutoOpenDualPane) ?? false
        ocrAutoCopy = value(Bool.self, .ocrAutoCopy) ?? true
        exportImageFormat = value(CaptureExportFormat.self, .exportImageFormat) ?? .png
        exportAt1xScale = value(Bool.self, .exportAt1xScale) ?? false
        appearanceMode = value(AppAppearanceMode.self, .appearanceMode) ?? .dark
        terminalPasteAdaptEnabled = value(Bool.self, .terminalPasteAdaptEnabled) ?? true
        filenameTemplate = value(String.self, .filenameTemplate) ?? SaveFilenameTemplate.defaultTemplate
        soundFeedbackEnabled = value(Bool.self, .soundFeedbackEnabled) ?? false
        backdropAspectRatio = value(BackdropAspectRatio.self, .backdropAspectRatio) ?? .auto
        backdropWatermark = value(String.self, .backdropWatermark) ?? ""
        let rawDelay = value(Int.self, .delayedCaptureSeconds) ?? DelayedCaptureSettings.defaultSeconds
        delayedCaptureSeconds = DelayedCaptureSettings.clampedSeconds(rawDelay)
        fullScreenCaptureAction = value(FullScreenCaptureAction.self, .fullScreenCaptureAction) ?? .copy
        let rawGlow = value(CGFloat.self, .pinGlowStrength) ?? 0.45
        pinGlowStrength = min(1.0, max(0.0, rawGlow))
        let legacyShelfHover = value(Bool.self, .topShelfHoverEnabled) ?? true
        topShelfTriggerMode = value(TopShelfTriggerMode.self, .topShelfTriggerMode)
            ?? (legacyShelfHover ? .topEdgeHover : .manualOnly)
        topShelfHoverEnabled = (topShelfTriggerMode != .manualOnly)
        showQuickAccessOverlay = value(Bool.self, .showQuickAccessOverlay) ?? true
        collageOptions = value(CollageOptions.self, .collageOptions) ?? CollageOptions()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hotKeyPreset, forKey: .hotKeyPreset)
        try c.encode(hotKeysEnabled, forKey: .hotKeysEnabled)
        try c.encode(forcePriorityHotKeys, forKey: .forcePriorityHotKeys)
        try c.encode(globalHotKeyOverrides, forKey: .globalHotKeyOverrides)
        try c.encode(customCanvasKeys, forKey: .customCanvasKeys)
        try c.encode(defaultColorIndex, forKey: .defaultColorIndex)
        try c.encode(defaultLineWidth, forKey: .defaultLineWidth)
        try c.encodeIfPresent(lastSaveDirectory, forKey: .lastSaveDirectory)
        try c.encode(recentSaveDirectories, forKey: .recentSaveDirectories)
        try c.encode(colorCopyFormat, forKey: .colorCopyFormat)
        try c.encode(showShortcutTips, forKey: .showShortcutTips)
        try c.encode(preferredRecordingFormat, forKey: .preferredRecordingFormat)
        try c.encode(recordInteractionHUD, forKey: .recordInteractionHUD)
        try c.encode(recordingOptions, forKey: .recordingOptions)
        try c.encode(defaultTextCapsule, forKey: .defaultTextCapsule)
        try c.encode(ocrPresentation == .dualPane, forKey: .ocrAutoOpenDualPane)
        try c.encode(ocrPresentation, forKey: .ocrPresentation)
        try c.encode(translateAutoOpenDualPane, forKey: .translateAutoOpenDualPane)
        try c.encode(ocrAutoCopy, forKey: .ocrAutoCopy)
        try c.encode(exportImageFormat, forKey: .exportImageFormat)
        try c.encode(exportAt1xScale, forKey: .exportAt1xScale)
        try c.encode(appearanceMode, forKey: .appearanceMode)
        try c.encode(terminalPasteAdaptEnabled, forKey: .terminalPasteAdaptEnabled)
        try c.encode(filenameTemplate, forKey: .filenameTemplate)
        try c.encode(soundFeedbackEnabled, forKey: .soundFeedbackEnabled)
        try c.encode(backdropAspectRatio, forKey: .backdropAspectRatio)
        try c.encode(backdropWatermark, forKey: .backdropWatermark)
        try c.encode(DelayedCaptureSettings.clampedSeconds(delayedCaptureSeconds), forKey: .delayedCaptureSeconds)
        try c.encode(fullScreenCaptureAction, forKey: .fullScreenCaptureAction)
        try c.encode(min(1.0, max(0.0, pinGlowStrength)), forKey: .pinGlowStrength)
        try c.encode(topShelfTriggerMode != .manualOnly, forKey: .topShelfHoverEnabled)
        try c.encode(topShelfTriggerMode, forKey: .topShelfTriggerMode)
        try c.encode(showQuickAccessOverlay, forKey: .showQuickAccessOverlay)
        try c.encode(collageOptions, forKey: .collageOptions)
    }

    func activeCombo(for action: GlobalHotKeyAction) -> KeyCombo? {
        if let ov = globalHotKeyOverrides[action.rawValue] {
            switch ov {
            case .custom(let combo): return combo
            case .disabled:          return nil
            }
        }
        return hotKeyPreset.defaultCombo(for: action)
    }

    mutating func setGlobalCombo(_ combo: KeyCombo?, for action: GlobalHotKeyAction) {
        let def = hotKeyPreset.defaultCombo(for: action)
        if combo == def {
            globalHotKeyOverrides.removeValue(forKey: action.rawValue)
        } else if let combo {
            globalHotKeyOverrides[action.rawValue] = .custom(combo)
        } else {
            globalHotKeyOverrides[action.rawValue] = .disabled
        }
    }

    var hasCustomHotKeys: Bool { !globalHotKeyOverrides.isEmpty }

    mutating func clearCustomHotKeys() {
        globalHotKeyOverrides.removeAll()
    }

    func canvasKey(for action: CanvasAction) -> String {
        (customCanvasKeys[action.rawValue] ?? action.defaultKey).lowercased()
    }

    var resolvedCanvasKeyMap: [CanvasAction: String] {
        Dictionary(uniqueKeysWithValues: CanvasAction.allCases.map { ($0, canvasKey(for: $0)) })
    }

    @discardableResult
    mutating func setCanvasKey(_ key: String, for action: CanvasAction) -> CanvasAction? {
        CanvasAction.bind(key: key, to: action, in: &customCanvasKeys)
    }

    mutating func resetCanvasKey(for action: CanvasAction) {
        let def = action.defaultKey
        _ = CanvasAction.bind(key: def, to: action, in: &customCanvasKeys)
    }

    mutating func resetAllCanvasKeys() {
        customCanvasKeys.removeAll()
    }

    var hasCustomCanvasKeys: Bool { !customCanvasKeys.isEmpty }

    mutating func recordSaveDirectory(_ path: String, updateDefault: Bool = false) {
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        if updateDefault { lastSaveDirectory = std }
        recentSaveDirectories.removeAll { URL(fileURLWithPath: $0).standardizedFileURL.path == std }
        recentSaveDirectories.insert(std, at: 0)
        if recentSaveDirectories.count > 4 {
            recentSaveDirectories = Array(recentSaveDirectories.prefix(4))
        }
    }

    static var configURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("MSnip", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: configURL) else { return AppConfig() }
        do {
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            MSnipLog.warning(.config, "config.json unreadable (\(data.count) bytes); using defaults", error: error)
            return AppConfig()
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(self).write(to: Self.configURL, options: .atomic)
        } catch {
            MSnipLog.error(.config, "Saving config.json failed", error: error)
        }
    }

    var selectedColor: RGBAColor {
        let presets = RGBAColor.presets
        let idx = min(max(0, defaultColorIndex), presets.count - 1)
        return presets[idx]
    }
}

/// 开机自启兼容管理（macOS 13+ 走 SMAppService，macOS 12 自动回退 LaunchAgents plist）
enum LaunchAtLoginManager {
    private static let agentLabel = "top.xy.msnip.launch"
    private static var cachedEnabled: Bool?

    private static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    static var isEnabled: Bool {
        if let cached = cachedEnabled { return cached }
        return refreshCache()
    }

    @discardableResult
    static func refreshCache() -> Bool {
        let hasPlist = FileManager.default.fileExists(atPath: plistURL.path)
        let enabled: Bool
        if #available(macOS 13.0, *), Bundle.main.bundlePath.hasSuffix(".app") {
            enabled = (SMAppService.mainApp.status == .enabled || hasPlist)
        } else {
            enabled = hasPlist
        }
        cachedEnabled = enabled
        return enabled
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        if #available(macOS 13.0, *), Bundle.main.bundlePath.hasSuffix(".app") {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                    try? FileManager.default.removeItem(at: plistURL)
                } else {
                    try SMAppService.mainApp.unregister()
                    try? FileManager.default.removeItem(at: plistURL)
                }
                cachedEnabled = enabled
                return true
            } catch {
                MSnipLog.warning(.config, "SMAppService \(enabled ? "register" : "unregister") failed; falling back to LaunchAgent", error: error)
            }
        }
        if enabled {
            guard let execPath = Bundle.main.executablePath else { return false }
            let plist: [String: Any] = ["Label": agentLabel, "ProgramArguments": [execPath], "RunAtLoad": true]
            let dir = plistURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
                return false
            }
            do {
                try data.write(to: plistURL, options: .atomic)
            } catch {
                MSnipLog.error(.config, "Writing LaunchAgent plist failed", error: error)
                return false
            }
            cachedEnabled = true
            return true
        } else {
            try? FileManager.default.removeItem(at: plistURL)
            cachedEnabled = false
            return true
        }
    }
}

// MARK: - 配置导出导入与诊断报告

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
              let rawObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Self.looksLikeMSnipConfig(rawObj),
              let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            ToastHUD.show(message: "导入失败：文件格式无效或不是 MSnip 配置文件")
            return nil
        }
        ToastHUD.show(message: "✓ 已导入配置并即时生效")
        return decoded
    }

    private static func looksLikeMSnipConfig(_ dict: [String: Any]) -> Bool {
        let knownKeys: Set<String> = [
            "hotKeyPreset", "colorCopyFormat", "exportImageFormat", "appearanceMode",
            "recordingOptions", "ocrPresentation", "preferredRecordingFormat", "topShelfTriggerMode",
            "pinGlowStrength", "terminalPasteAdaptEnabled"
        ]
        return !knownKeys.isDisjoint(with: dict.keys)
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
        \(DiagnosticLogging.reportSection())
        """
    }
}
