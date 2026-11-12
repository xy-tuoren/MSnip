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
        case .cmd12:      return "⌘1 截图  /  ⌘2 贴图（默认）"
        case .cmdShiftAP: return "⌘⇧A 截图  /  ⌘⇧P 贴图"
        case .optAP:      return "⌥A 截图  /  ⌥P 贴图"
        case .f1f3:       return "F1 截图  /  F3 贴图"
        }
    }

    var captureShortcut: (keyCode: UInt32, modifiers: UInt32, keyEquivalent: String, mask: UInt) {
        switch self {
        case .cmd12:
            return (UInt32(kVK_ANSI_1), UInt32(cmdKey), "1", 1 << 20)
        case .cmdShiftAP:
            return (UInt32(kVK_ANSI_A), UInt32(cmdKey | shiftKey), "A", (1 << 20) | (1 << 17))
        case .optAP:
            return (UInt32(kVK_ANSI_A), UInt32(optionKey), "a", 1 << 19)
        case .f1f3:
            return (UInt32(kVK_F1), 0, "\u{F704}", 0)
        }
    }

    var pinShortcut: (keyCode: UInt32, modifiers: UInt32, keyEquivalent: String, mask: UInt) {
        switch self {
        case .cmd12:
            return (UInt32(kVK_ANSI_2), UInt32(cmdKey), "2", 1 << 20)
        case .cmdShiftAP:
            return (UInt32(kVK_ANSI_P), UInt32(cmdKey | shiftKey), "P", (1 << 20) | (1 << 17))
        case .optAP:
            return (UInt32(kVK_ANSI_P), UInt32(optionKey), "p", 1 << 19)
        case .f1f3:
            return (UInt32(kVK_F3), 0, "\u{F706}", 0)
        }
    }

    var pinBadgeLabel: String {
        switch self {
        case .cmd12:      return "⌘2"
        case .cmdShiftAP: return "⌘⇧P"
        case .optAP:      return "⌥P"
        case .f1f3:       return "F3"
        }
    }
}

/// 应用持久化配置（存储于 ~/Library/Application Support/MSnip/config.json）
struct AppConfig: Codable {
    var hotKeyPreset: HotKeyPreset = .cmd12
    var hotKeysEnabled: Bool = true
    var defaultColorIndex: Int = 0
    var defaultLineWidth: CGFloat = 3.0
    var lastSaveDirectory: String?

    private static var configURL: URL {
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
            } catch {
                // 未签名或本地开发目录运行时自动回退 LaunchAgent plist
            }
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
