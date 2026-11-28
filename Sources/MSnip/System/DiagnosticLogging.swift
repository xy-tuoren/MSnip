import AppKit
import Foundation
import MSnipCore

/// 应用层诊断日志接入：启动时挂载 `~/Library/Logs/MSnip/msnip.log`、捕获未处理的 Objective-C 异常，
/// 并为「复制诊断信息」拼装最近日志与崩溃报告摘要（只在用户主动复制时才离开本机）。
enum DiagnosticLogging {
    static let logDirectory: URL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/MSnip", isDirectory: true)
    static var logFileURL: URL { logDirectory.appendingPathComponent("msnip.log") }

    /// 诊断信息中附带的最近日志行数（约 15 KB，便于直接粘贴进 GitHub Issue）
    static let reportLogLineLimit = 120

    static func bootstrap() {
        MSnipLog.bootstrap(file: DiagnosticLogFile(url: logFileURL))
        NSSetUncaughtExceptionHandler { exception in
            MSnipLog.error(.app, "Uncaught exception \(exception.name.rawValue): \(exception.reason ?? "no reason")")
            MSnipLog.flush()
        }
        let info = Bundle.main.infoDictionary ?? [:]
        let ver = (info["CFBundleShortVersionString"] as? String) ?? "dev"
        let build = (info["CFBundleVersion"] as? String) ?? "1"
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        MSnipLog.info(.app, "Launch MSnip v\(ver) (\(build)) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(arch) · displays=\(NSScreen.screens.count)")
    }

    /// 最近 `days` 天内系统为 MSnip 生成的崩溃/卡死报告（文件名与时间，最新在前）
    static func recentCrashReports(days: Int = 14, limit: Int = 5) -> [(name: String, date: Date)] {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/DiagnosticReports", isDirectory: true)
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url -> (name: String, date: Date)? in
            let name = url.lastPathComponent
            guard name.hasPrefix("MSnip"), ["ips", "crash", "hang", "spin", "diag"].contains(url.pathExtension.lowercased()),
                  let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  date >= cutoff else { return nil }
            return (name, date)
        }
        .sorted { $0.date > $1.date }
        .prefix(limit)
        .map { $0 }
    }

    /// 诊断报告末尾的日志段：日志位置、近期崩溃报告与最近若干行运行日志
    static func reportSection() -> String {
        MSnipLog.flush()
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let crashes = recentCrashReports()
        var lines = ["Log File: \(DiagnosticLogText.sanitize(logFileURL.path))"]
        lines.append("Crash Reports (14d): \(crashes.isEmpty ? "none" : "\(crashes.count)") — ~/Library/Logs/DiagnosticReports")
        lines += crashes.map { "  - \($0.name) (\(df.string(from: $0.date)))" }
        let recent = MSnipLog.currentFile?.recentLines(limit: reportLogLineLimit) ?? []
        lines.append("Recent Log (\(recent.count) lines):")
        lines += recent.isEmpty ? ["  (empty)"] : recent.map { "  \($0)" }
        return lines.joined(separator: "\n")
    }

    /// 在访达中定位日志文件（尚未生成时打开日志目录）
    @MainActor
    static func revealLogFile() {
        MSnipLog.flush()
        let fm = FileManager.default
        if fm.fileExists(atPath: logFileURL.path) {
            ClipboardAndSave.revealInFinder(logFileURL)
        } else {
            try? fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(logDirectory)
        }
    }
}
