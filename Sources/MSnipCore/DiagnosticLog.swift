import Foundation
import os

/// 本地诊断日志等级（文件中按 `[INFO]` / `[WARN]` / `[ERROR]` 标注）
public enum MSnipLogLevel: String, Sendable {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"

    var osLogType: OSLogType {
        switch self {
        case .info:    return .info
        case .warning: return .default
        case .error:   return .error
        }
    }
}

/// 日志分类：同时作为系统统一日志的 category，便于在「控制台」App 中按 `top.xy.msnip` 子系统过滤
public enum MSnipLogCategory: String, Sendable {
    case app, permission, capture, recording, hotkey, export, ocr, translation, latex, config, ui
}

/// 日志文本加工的纯函数集合：脱敏、单行化、截断与失败提示识别（零全局状态，可单测）
public enum DiagnosticLogText {
    public static let maxMessageLength = 600

    private static let secretPatterns: [(NSRegularExpression, String)] = ([
        (#"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]+"#, "Bearer <redacted>"),
        (#"\bsk-[A-Za-z0-9_-]{8,}"#, "sk-<redacted>"),
        (#"\bAIza[0-9A-Za-z_-]{20,}"#, "<redacted-key>"),
        (#"(?i)\b(api[_-]?key|access[_-]?token|token|secret|password|key)=[^&\s]+"#, "$1=<redacted>"),
        (#"\b[A-Za-z0-9_-]{32,}\b"#, "<redacted-token>")
    ] as [(String, String)]).compactMap { pattern, template in
        (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
    }

    /// 写盘前的统一脱敏：用户主目录折叠为 `~`、遮盖疑似密钥/令牌、换行压成单行并截断超长内容
    public static func sanitize(_ raw: String, homeDirectory: String = NSHomeDirectory()) -> String {
        var s = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        if home.count > 1,
           let homeRegex = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: home) + #"(?=/|$|[\s"'”’),;:])"#) {
            s = homeRegex.stringByReplacingMatches(in: s, options: [], range: NSRange(s.startIndex..., in: s), withTemplate: "~")
        }
        for (regex, template) in secretPatterns {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: template)
        }
        if s.count > maxMessageLength { s = String(s.prefix(maxMessageLength)) + "…" }
        return s
    }

    private static let failureMarkers = ["失败", "无法", "错误", "⚠", "✗", "未能", "异常", "超时", "拒绝", "缺少", "不可用", "过短", "未找到", "冲突"]
    /// 英文界面下的同义词（按小写匹配），译文中的失败提示需包含其一
    private static let englishFailureMarkers = ["failed", "couldn't", "could not", "cannot", "can't", "unable", "error", "denied", "timed out", "not found", "unavailable", "too short"]

    /// 判断一条用户可见提示是否在报告失败（只有失败提示会写入日志，普通提示可能含二维码等用户内容）
    public static func looksLikeFailure(_ message: String) -> Bool {
        if failureMarkers.contains(where: { message.contains($0) }) { return true }
        let lower = message.lowercased()
        return englishFailureMarkers.contains { lower.contains($0) }
    }

    /// 错误摘要：`域#码` + 底层错误 + 截断后的描述；Swift 原生错误枚举额外保留 case 名，方便定位
    public static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var parts = ["\(ns.domain)#\(ns.code)"]
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying \(underlying.domain)#\(underlying.code)")
        }
        let detail: String
        if let localized = (error as? LocalizedError)?.errorDescription, !localized.isEmpty {
            detail = localized
        } else if type(of: error) is NSError.Type {
            detail = ns.localizedDescription
        } else {
            detail = String(describing: error)
        }
        if !detail.isEmpty { parts.append(String(detail.prefix(200))) }
        return parts.joined(separator: " · ")
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
        return f
    }()

    /// 文件中的单行格式：`2026-11-27 18:05:12.345 +08:00 [WARN] [capture] message`
    public static func formatLine(
        date: Date,
        level: MSnipLogLevel,
        category: MSnipLogCategory,
        message: String,
        timeZone: TimeZone = .current
    ) -> String {
        let stamp: String
        if timeZone == .current {
            stamp = timestampFormatter.string(from: date)
        } else {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = timestampFormatter.dateFormat
            f.timeZone = timeZone
            stamp = f.string(from: date)
        }
        return "\(stamp) [\(level.rawValue)] [\(category.rawValue)] \(message)"
    }
}

/// 双文件滚动日志：当前文件超过 `maxBytes` 时整体轮转为 `.1` 备份，磁盘占用恒定不超过约 `2 × maxBytes`。
/// 所有写入都在串行队列上直写文件（不在内存驻留缓冲），崩溃前已写入的行不会丢失；文件与目录分别为 `0600` / `0700`。
public final class DiagnosticLogFile: @unchecked Sendable {
    public let url: URL
    public let rotatedURL: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "top.xy.msnip.diagnostic-log", qos: .utility)
    private var handle: FileHandle?
    private var currentSize = 0

    public init(url: URL, maxBytes: Int = 512 * 1024) {
        self.url = url
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "log" : url.pathExtension
        self.rotatedURL = url.deletingLastPathComponent().appendingPathComponent("\(base).1.\(ext)")
        self.maxBytes = max(256, maxBytes)
    }

    deinit { try? handle?.close() }

    public func append(_ line: String) {
        queue.async { [self] in write(line) }
    }

    /// 等待此前排队的写入全部落盘（导出诊断信息、进程退出或捕获到未处理异常时调用）
    public func flush() {
        queue.sync {}
    }

    /// 读取最近的若干行（跨越轮转备份，按时间先后排列）
    public func recentLines(limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        return queue.sync {
            let lines = Self.readLines(rotatedURL) + Self.readLines(url)
            return Array(lines.suffix(limit))
        }
    }

    private func write(_ line: String) {
        var data = Data(line.utf8)
        data.append(0x0A)
        if handle == nil { openOrCreate() }
        if currentSize > 0, currentSize + data.count > maxBytes { rotate() }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            currentSize += data.count
        } catch {
            try? handle.close()
            self.handle = nil
        }
    }

    private func openOrCreate() {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        currentSize = Int((try? h.seekToEnd()) ?? 0)
        handle = h
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: rotatedURL)
        try? fm.moveItem(at: url, to: rotatedURL)
        currentSize = 0
        openOrCreate()
    }

    private static func readLines(_ url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }
}

/// 全局日志入口：所有消息先脱敏，再同时写入系统统一日志（子系统 `top.xy.msnip`）与本地滚动文件。
/// 隐私约定：只记录事件、状态、计数与错误码，绝不传入截图内容、识别/翻译文本、API Key、接口地址或完整路径。
/// 未调用 `bootstrap` 时（如单测）只写系统日志，不落盘。
public enum MSnipLog {
    public static let subsystem = "top.xy.msnip"
    private static let lock = NSLock()
    private static var file: DiagnosticLogFile?

    public static func bootstrap(file newFile: DiagnosticLogFile?) {
        lock.lock()
        file = newFile
        lock.unlock()
    }

    public static var currentFile: DiagnosticLogFile? {
        lock.lock()
        defer { lock.unlock() }
        return file
    }

    public static func info(_ category: MSnipLogCategory, _ message: @autoclosure () -> String) {
        write(.info, category, message())
    }

    public static func warning(_ category: MSnipLogCategory, _ message: @autoclosure () -> String, error: Error? = nil) {
        write(.warning, category, compose(message(), error))
    }

    public static func error(_ category: MSnipLogCategory, _ message: @autoclosure () -> String, error: Error? = nil) {
        write(.error, category, compose(message(), error))
    }

    public static func flush() {
        currentFile?.flush()
    }

    private static func compose(_ message: String, _ error: Error?) -> String {
        guard let error else { return message }
        return "\(message) — \(DiagnosticLogText.describe(error))"
    }

    private static func write(_ level: MSnipLogLevel, _ category: MSnipLogCategory, _ message: String) {
        let text = DiagnosticLogText.sanitize(message)
        Logger(subsystem: subsystem, category: category.rawValue).log(level: level.osLogType, "\(text, privacy: .public)")
        currentFile?.append(DiagnosticLogText.formatLine(date: Date(), level: level, category: category, message: text))
    }
}
