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

/// 顶部暂存架边缘呼出模式（默认智能防误触：仅拖文件到顶边或按住 ⌥ 顶边时展开，避免切标签页/选应用误触）
public enum TopShelfTriggerMode: String, CaseIterable, Codable, Sendable {
    case smartDragAndOption = "smartDragAndOption"
    case topEdgeHover       = "topEdgeHover"
    case manualOnly         = "manualOnly"

    public var title: String {
        switch self {
        case .smartDragAndOption: return "智能防误触"
        case .topEdgeHover:       return "顶边悬停"
        case .manualOnly:         return "仅热键"
        }
    }
}

/// 顶部暂存架边缘命中与防误收安全区纯几何计算（AppKit 左下角原点坐标系，严格兼容 `pt.y == screenFrame.maxY` 顶边贴边）
public enum ShelfTriggerGeometry {
    /// 含闭区间边界校验判断光标是否落入目标屏幕（避免 `CGRect.contains` 在 `pt.y == maxY` 顶边处返回 false）
    public static func containsInclusive(_ rect: CGRect, point: CGPoint) -> Bool {
        point.x >= rect.minX - 1.0 && point.x <= rect.maxX + 1.0
            && point.y >= rect.minY - 1.0 && point.y <= rect.maxY + 2.0
    }

    /// 判断光标是否命中屏幕顶部中央触发热区（避开左侧系统菜单与右侧状态栏图标）
    public static func hitsTopCenterTrigger(point: CGPoint, screenFrame: CGRect, isDragging: Bool) -> Bool {
        guard containsInclusive(screenFrame, point: point) else { return false }
        let topDist = screenFrame.maxY - point.y
        let topThreshold: CGFloat = isDragging ? 22.0 : 8.0
        let halfBand = max(220.0, screenFrame.width * 0.16)
        return topDist <= topThreshold && abs(point.x - screenFrame.midX) <= halfBand
    }

    /// 计算展开后的安全保持区：向上完整贯通至物理屏幕顶边 `screenFrame.maxY + 4`，避免光标刚触发即被菜单栏间隙误判离开
    public static func safeKeepRect(panelFrame: CGRect, screenFrame: CGRect) -> CGRect {
        let minX = panelFrame.minX - 24.0
        let maxX = panelFrame.maxX + 24.0
        let minY = panelFrame.minY - 24.0
        let maxY = max(panelFrame.maxY + 24.0, screenFrame.maxY + 4.0)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 将普通鼠标上下滚轮或触控板双指滚动统一换算为横向滚动条目标偏移量 `X`
    public static func nextHorizontalScrollX(
        currentX: CGFloat,
        maxX: CGFloat,
        deltaX: CGFloat,
        deltaY: CGFloat,
        hasPreciseDeltas: Bool
    ) -> CGFloat {
        guard maxX > 0 else { return 0 }
        let rawStep: CGFloat
        if abs(deltaX) > abs(deltaY) {
            rawStep = -deltaX * (hasPreciseDeltas ? 1.0 : 18.0)
        } else {
            rawStep = -deltaY * (hasPreciseDeltas ? 1.0 : 22.0)
        }
        return min(max(0, currentX + rawStep), maxX)
    }
}
