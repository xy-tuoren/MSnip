import CoreGraphics
import Foundation

/// 快捷识字（OCR）默认呈现方式：原位实况划词 / 双栏对照窗 / 静默直拷（松手即退、后台识别直写剪贴板）
public enum OCRDefaultPresentation: String, CaseIterable, Codable, Sendable {
    case inPlace    = "inPlace"
    case dualPane   = "dualPane"
    case silentCopy = "silentCopy"

    public var title: String {
        switch self {
        case .inPlace:    return "原位划词"
        case .dualPane:   return "双栏面板"
        case .silentCopy: return "静默直拷"
        }
    }
}

/// 命令行参数与 `msnip://` URL Scheme 统一启动动作（适配 Raycast / Alfred / Apple Shortcuts / 终端联动）
public enum MSnipLaunchCommand: String, CaseIterable, Codable, Sendable {
    case capture
    case fullscreen
    case delay
    case pin
    case ocr
    case silentOCR
    case translate
    case long
    case record
    case latex
    case shelf
    case settings
    case tray

    public static let ipcNotificationName = "top.xy.msnip.remoteCommand"

    /// 解析命令行参数（支持 `--enter=ocr` / `--ocr` / `--capture` / `--shelf` 等常见写法）
    public static func parse(arguments: [String]) -> MSnipLaunchCommand? {
        for raw in arguments.dropFirst() {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.lowercased().hasPrefix("--enter=") {
                let val = String(trimmed.dropFirst("--enter=".count))
                if let cmd = matchToken(val) { return cmd }
            } else if trimmed.hasPrefix("--") {
                let val = String(trimmed.dropFirst(2))
                if let cmd = matchToken(val) { return cmd }
            } else if trimmed.lowercased().hasPrefix("msnip://"), let url = URL(string: trimmed) {
                if let cmd = parse(url: url) { return cmd }
            }
        }
        return nil
    }

    /// 解析 `msnip://<action>` URL Scheme（如 `msnip://ocr`、`msnip://silent-ocr`、`msnip://shelf`）
    public static func parse(url: URL) -> MSnipLaunchCommand? {
        guard url.scheme?.lowercased() == "msnip" else { return nil }
        let host = (url.host ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !host.isEmpty, let cmd = matchToken(host) { return cmd }
        let pathToken = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !pathToken.isEmpty, let cmd = matchToken(pathToken) { return cmd }
        return nil
    }

    private static func matchToken(_ raw: String) -> MSnipLaunchCommand? {
        let key = raw.lowercased().replacingOccurrences(of: "_", with: "-")
        switch key {
        case "capture", "snip", "shot", "area":           return .capture
        case "fullscreen", "full", "screen":              return .fullscreen
        case "delay", "delayed", "timer":                 return .delay
        case "pin":                                       return .pin
        case "ocr", "text":                               return .ocr
        case "silent-ocr", "silentocr", "ocr-copy":       return .silentOCR
        case "translate", "trans":                        return .translate
        case "long", "longshot", "scroll":                return .long
        case "record", "video", "gif", "mp4":             return .record
        case "latex", "formula", "math":                  return .latex
        case "shelf", "rack", "tray-shelf", "hanger":     return .shelf
        case "settings", "prefs", "preferences":          return .settings
        case "tray", "idle":                              return .tray
        default:                                          return nil
        }
    }
}

/// 顶部暂存架（MSnip Shelf）自定义挂架条目类型（图片截图直接共享 `CaptureHistoryRing`，零重复落盘）
public enum ShelfCustomItemKind: String, Codable, Equatable, Sendable {
    case file
    case text
}

/// 顶部暂存架用户主动拖入或挂起的非截图条目（文件引用 / 文本便签片段）
public struct ShelfCustomItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let kind: ShelfCustomItemKind
    public let createdAt: Date
    public let title: String
    public let filePath: String?
    public let textContent: String?

    public init(
        id: UUID = UUID(),
        kind: ShelfCustomItemKind,
        createdAt: Date = Date(),
        title: String,
        filePath: String? = nil,
        textContent: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.title = title
        self.filePath = filePath
        self.textContent = textContent
    }

    public var isValidOnDisk: Bool {
        switch kind {
        case .text:
            return !(textContent ?? "").isEmpty
        case .file:
            guard let p = filePath, !p.isEmpty else { return false }
            return FileManager.default.fileExists(atPath: p)
        }
    }
}
