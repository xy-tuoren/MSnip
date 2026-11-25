import Foundation
import MSnipCore
import ServiceManagement

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
    var topShelfTriggerMode: TopShelfTriggerMode = .smartDragAndOption

    private enum CodingKeys: String, CodingKey {
        case hotKeyPreset, hotKeysEnabled, forcePriorityHotKeys, globalHotKeyOverrides, customCanvasKeys
        case customCaptureCombo, customPinCombo, customOCRCombo
        case defaultColorIndex, defaultLineWidth, lastSaveDirectory, recentSaveDirectories
        case colorCopyFormat, showShortcutTips, preferredRecordingFormat, recordInteractionHUD, recordingOptions, defaultTextCapsule
        case ocrAutoOpenDualPane, ocrPresentation, translateAutoOpenDualPane, ocrAutoCopy
        case exportImageFormat, exportAt1xScale, appearanceMode, terminalPasteAdaptEnabled
        case filenameTemplate, soundFeedbackEnabled, backdropAspectRatio, backdropWatermark
        case delayedCaptureSeconds, fullScreenCaptureAction, pinGlowStrength, topShelfHoverEnabled, topShelfTriggerMode
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotKeyPreset = try c.decodeIfPresent(HotKeyPreset.self, forKey: .hotKeyPreset) ?? .optASD
        hotKeysEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotKeysEnabled) ?? true
        forcePriorityHotKeys = try c.decodeIfPresent(Bool.self, forKey: .forcePriorityHotKeys) ?? false
        var overrides = try c.decodeIfPresent([String: HotKeyBindingOverride].self, forKey: .globalHotKeyOverrides) ?? [:]
        if overrides[GlobalHotKeyAction.capture.rawValue] == nil,
           let cap = try c.decodeIfPresent(KeyCombo.self, forKey: .customCaptureCombo) {
            overrides[GlobalHotKeyAction.capture.rawValue] = .custom(cap)
        }
        if overrides[GlobalHotKeyAction.pin.rawValue] == nil,
           let pin = try c.decodeIfPresent(KeyCombo.self, forKey: .customPinCombo) {
            overrides[GlobalHotKeyAction.pin.rawValue] = .custom(pin)
        }
        if overrides[GlobalHotKeyAction.ocr.rawValue] == nil,
           let ocr = try c.decodeIfPresent(KeyCombo.self, forKey: .customOCRCombo) {
            overrides[GlobalHotKeyAction.ocr.rawValue] = .custom(ocr)
        }
        globalHotKeyOverrides = overrides
        customCanvasKeys = try c.decodeIfPresent([String: String].self, forKey: .customCanvasKeys) ?? [:]
        defaultColorIndex = try c.decodeIfPresent(Int.self, forKey: .defaultColorIndex) ?? 0
        defaultLineWidth = try c.decodeIfPresent(CGFloat.self, forKey: .defaultLineWidth) ?? 3.0
        lastSaveDirectory = try c.decodeIfPresent(String.self, forKey: .lastSaveDirectory)
        recentSaveDirectories = try c.decodeIfPresent([String].self, forKey: .recentSaveDirectories) ?? []
        colorCopyFormat = try c.decodeIfPresent(ColorCopyFormat.self, forKey: .colorCopyFormat) ?? .hex
        showShortcutTips = try c.decodeIfPresent(Bool.self, forKey: .showShortcutTips) ?? true
        preferredRecordingFormat = try c.decodeIfPresent(RecordingFormat.self, forKey: .preferredRecordingFormat) ?? .gif
        recordInteractionHUD = try c.decodeIfPresent(Bool.self, forKey: .recordInteractionHUD) ?? true
        recordingOptions = try c.decodeIfPresent(RecordingOptions.self, forKey: .recordingOptions) ?? RecordingOptions()
        defaultTextCapsule = try c.decodeIfPresent(Bool.self, forKey: .defaultTextCapsule) ?? false
        let legacyDualOCR = try c.decodeIfPresent(Bool.self, forKey: .ocrAutoOpenDualPane) ?? false
        ocrPresentation = (try? c.decodeIfPresent(OCRDefaultPresentation.self, forKey: .ocrPresentation)) ?? (legacyDualOCR ? .dualPane : .inPlace)
        ocrAutoOpenDualPane = (ocrPresentation == .dualPane)
        translateAutoOpenDualPane = try c.decodeIfPresent(Bool.self, forKey: .translateAutoOpenDualPane) ?? false
        ocrAutoCopy = try c.decodeIfPresent(Bool.self, forKey: .ocrAutoCopy) ?? true
        exportImageFormat = (try? c.decodeIfPresent(CaptureExportFormat.self, forKey: .exportImageFormat)) ?? .png
        exportAt1xScale = try c.decodeIfPresent(Bool.self, forKey: .exportAt1xScale) ?? false
        appearanceMode = try c.decodeIfPresent(AppAppearanceMode.self, forKey: .appearanceMode) ?? .dark
        terminalPasteAdaptEnabled = try c.decodeIfPresent(Bool.self, forKey: .terminalPasteAdaptEnabled) ?? true
        filenameTemplate = try c.decodeIfPresent(String.self, forKey: .filenameTemplate) ?? SaveFilenameTemplate.defaultTemplate
        soundFeedbackEnabled = try c.decodeIfPresent(Bool.self, forKey: .soundFeedbackEnabled) ?? false
        backdropAspectRatio = try c.decodeIfPresent(BackdropAspectRatio.self, forKey: .backdropAspectRatio) ?? .auto
        backdropWatermark = try c.decodeIfPresent(String.self, forKey: .backdropWatermark) ?? ""
        let rawDelay = try c.decodeIfPresent(Int.self, forKey: .delayedCaptureSeconds) ?? DelayedCaptureSettings.defaultSeconds
        delayedCaptureSeconds = DelayedCaptureSettings.clampedSeconds(rawDelay)
        fullScreenCaptureAction = try c.decodeIfPresent(FullScreenCaptureAction.self, forKey: .fullScreenCaptureAction) ?? .copy
        let rawGlow = try c.decodeIfPresent(CGFloat.self, forKey: .pinGlowStrength) ?? 0.45
        pinGlowStrength = min(1.0, max(0.0, rawGlow))
        let legacyShelfHover = try c.decodeIfPresent(Bool.self, forKey: .topShelfHoverEnabled) ?? true
        topShelfTriggerMode = (try? c.decodeIfPresent(TopShelfTriggerMode.self, forKey: .topShelfTriggerMode))
            ?? (legacyShelfHover ? .smartDragAndOption : .manualOnly)
        topShelfHoverEnabled = (topShelfTriggerMode != .manualOnly)
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
        guard let data = try? Data(contentsOf: configURL),
              let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        return decoded
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: Self.configURL, options: .atomic)
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

    private static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *), Bundle.main.bundlePath.hasSuffix(".app") {
            return SMAppService.mainApp.status == .enabled
        }
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        if #available(macOS 13.0, *), Bundle.main.bundlePath.hasSuffix(".app") {
            do {
                if enabled { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
                return true
            } catch {}
        }
        if enabled {
            guard let execPath = Bundle.main.executablePath else { return false }
            let plist: [String: Any] = ["Label": agentLabel, "ProgramArguments": [execPath], "RunAtLoad": true]
            let dir = plistURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else {
                return false
            }
            return (try? data.write(to: plistURL, options: .atomic)) != nil
        } else {
            try? FileManager.default.removeItem(at: plistURL)
            return true
        }
    }
}
