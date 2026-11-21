import Carbon
import Foundation
import MSnipCore
import ServiceManagement

/// 全局快捷键预设方案
enum HotKeyPreset: String, CaseIterable, Codable {
    case cmd12 = "cmd12"
    case cmdShiftAP = "cmdShiftAP"
    case optAP = "optAP"
    case f1f3 = "f1f3"

    var menuTitle: String {
        switch self {
        case .cmd12:      return "⌘1 截图  /  ⌘2 贴图  /  ⌘3 识字（默认）"
        case .cmdShiftAP: return "⌘⇧A 截图  /  ⌘⇧P 贴图  /  ⌘⇧O 识字"
        case .optAP:      return "⌥A 截图  /  ⌥P 贴图  /  ⌥O 识字"
        case .f1f3:       return "F1 截图  /  F3 贴图  /  F2 识字"
        }
    }

    var captureCombo: KeyCombo {
        switch self {
        case .cmd12:      return KeyCombo(keyCode: UInt32(kVK_ANSI_1), carbonModifiers: UInt32(cmdKey))
        case .cmdShiftAP: return KeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(cmdKey | shiftKey))
        case .optAP:      return KeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(optionKey))
        case .f1f3:       return KeyCombo(keyCode: UInt32(kVK_F1), carbonModifiers: 0)
        }
    }

    var pinCombo: KeyCombo {
        switch self {
        case .cmd12:      return KeyCombo(keyCode: UInt32(kVK_ANSI_2), carbonModifiers: UInt32(cmdKey))
        case .cmdShiftAP: return KeyCombo(keyCode: UInt32(kVK_ANSI_P), carbonModifiers: UInt32(cmdKey | shiftKey))
        case .optAP:      return KeyCombo(keyCode: UInt32(kVK_ANSI_P), carbonModifiers: UInt32(optionKey))
        case .f1f3:       return KeyCombo(keyCode: UInt32(kVK_F3), carbonModifiers: 0)
        }
    }

    var ocrCombo: KeyCombo {
        switch self {
        case .cmd12:      return KeyCombo(keyCode: UInt32(kVK_ANSI_3), carbonModifiers: UInt32(cmdKey))
        case .cmdShiftAP: return KeyCombo(keyCode: UInt32(kVK_ANSI_O), carbonModifiers: UInt32(cmdKey | shiftKey))
        case .optAP:      return KeyCombo(keyCode: UInt32(kVK_ANSI_O), carbonModifiers: UInt32(optionKey))
        case .f1f3:       return KeyCombo(keyCode: UInt32(kVK_F2), carbonModifiers: 0)
        }
    }
}

/// 应用持久化配置（存储于 ~/Library/Application Support/MSnip/config.json）
struct AppConfig: Codable {
    var hotKeyPreset: HotKeyPreset = .cmd12
    var hotKeysEnabled: Bool = true
    var customCaptureCombo: KeyCombo?
    var customPinCombo: KeyCombo?
    var customOCRCombo: KeyCombo?
    var defaultColorIndex: Int = 0
    var defaultLineWidth: CGFloat = 3.0
    var lastSaveDirectory: String?
    var recentSaveDirectories: [String] = []
    var colorCopyFormat: ColorCopyFormat = .hex
    var showShortcutTips: Bool = true
    var preferredRecordingFormat: RecordingFormat = .gif
    var recordInteractionHUD: Bool = true
    var defaultTextCapsule: Bool = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotKeyPreset = try c.decodeIfPresent(HotKeyPreset.self, forKey: .hotKeyPreset) ?? .cmd12
        hotKeysEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotKeysEnabled) ?? true
        customCaptureCombo = try c.decodeIfPresent(KeyCombo.self, forKey: .customCaptureCombo)
        customPinCombo = try c.decodeIfPresent(KeyCombo.self, forKey: .customPinCombo)
        customOCRCombo = try c.decodeIfPresent(KeyCombo.self, forKey: .customOCRCombo)
        defaultColorIndex = try c.decodeIfPresent(Int.self, forKey: .defaultColorIndex) ?? 0
        defaultLineWidth = try c.decodeIfPresent(CGFloat.self, forKey: .defaultLineWidth) ?? 3.0
        lastSaveDirectory = try c.decodeIfPresent(String.self, forKey: .lastSaveDirectory)
        recentSaveDirectories = try c.decodeIfPresent([String].self, forKey: .recentSaveDirectories) ?? []
        colorCopyFormat = try c.decodeIfPresent(ColorCopyFormat.self, forKey: .colorCopyFormat) ?? .hex
        showShortcutTips = try c.decodeIfPresent(Bool.self, forKey: .showShortcutTips) ?? true
        preferredRecordingFormat = try c.decodeIfPresent(RecordingFormat.self, forKey: .preferredRecordingFormat) ?? .gif
        recordInteractionHUD = try c.decodeIfPresent(Bool.self, forKey: .recordInteractionHUD) ?? true
        defaultTextCapsule = try c.decodeIfPresent(Bool.self, forKey: .defaultTextCapsule) ?? false
    }

    var activeCaptureCombo: KeyCombo { customCaptureCombo ?? hotKeyPreset.captureCombo }
    var activePinCombo: KeyCombo     { customPinCombo ?? hotKeyPreset.pinCombo }
    var activeOCRCombo: KeyCombo     { customOCRCombo ?? hotKeyPreset.ocrCombo }
    var hasCustomHotKeys: Bool       { customCaptureCombo != nil || customPinCombo != nil || customOCRCombo != nil }

    mutating func clearCustomHotKeys() {
        customCaptureCombo = nil
        customPinCombo = nil
        customOCRCombo = nil
    }

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
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                return true
            } catch {}
        }
        if enabled {
            guard let execPath = Bundle.main.executablePath else { return false }
            let plist: [String: Any] = [
                "Label": agentLabel,
                "ProgramArguments": [execPath],
                "RunAtLoad": true
            ]
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
