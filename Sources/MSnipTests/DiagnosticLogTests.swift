import Foundation
import MSnipCore

/// 本地诊断日志：脱敏规则、失败提示识别、错误摘要、单行格式与双文件滚动
func testDiagnosticLog() {
    // 1) 脱敏：主目录折叠、密钥遮盖、单行化与截断
    let home = "/Users/alice"
    let pathMsg = DiagnosticLogText.sanitize("save failed: /Users/alice/Desktop/a.png", homeDirectory: home)
    check(pathMsg == "save failed: ~/Desktop/a.png", "用户主目录应折叠为 ~，实际: \(pathMsg)")
    check(DiagnosticLogText.sanitize("/Users/alice/x", homeDirectory: home + "/") == "~/x", "主目录带结尾斜杠时也应正确折叠")
    check(DiagnosticLogText.sanitize("bundle /Users/alice", homeDirectory: home) == "bundle ~", "路径末尾正好是主目录时也应折叠")
    check(DiagnosticLogText.sanitize("/Users/alicebob/x", homeDirectory: home) == "/Users/alicebob/x", "只应折叠完整的主目录路径段")

    let secrets = DiagnosticLogText.sanitize(
        "auth Bearer abc.DEF-123 key sk-proj-AbCdEf123456 g AIzaSyA1234567890abcdefghij url ?api_key=XYZ123&x=1 tok 0123456789abcdef0123456789abcdef",
        homeDirectory: home
    )
    for leaked in ["abc.DEF-123", "sk-proj-AbCdEf123456", "AIzaSyA1234567890abcdefghij", "XYZ123", "0123456789abcdef0123456789abcdef"] {
        check(!secrets.contains(leaked), "疑似密钥不应写入日志: \(leaked) → \(secrets)")
    }
    check(secrets.contains("Bearer <redacted>") && secrets.contains("api_key=<redacted>") && secrets.contains("&x=1"),
          "遮盖后应保留可读结构，实际: \(secrets)")
    check(DiagnosticLogText.sanitize("hotkey=⌥A forceTap=true", homeDirectory: home) == "hotkey=⌥A forceTap=true",
          "普通的 key=value 设置项不应被误判为密钥")

    let multi = DiagnosticLogText.sanitize("line1\nline2\r\nline3\tend", homeDirectory: home)
    check(multi == "line1 line2 line3 end", "多行消息应压成单行，避免伪造日志行，实际: \(multi)")
    let long = DiagnosticLogText.sanitize(String(repeating: "长", count: 2000), homeDirectory: home)
    check(long.count == DiagnosticLogText.maxMessageLength + 1 && long.hasSuffix("…"), "超长消息应截断并标注省略号")

    // 2) 失败提示识别：只把失败提示写入日志（普通提示可能含二维码等用户内容）
    check(DiagnosticLogText.looksLikeFailure("保存图片失败"), "含「失败」的提示应记录")
    check(DiagnosticLogText.looksLikeFailure("⚠ 2 项全局快捷键注册冲突"), "警告符号与冲突提示应记录")
    check(!DiagnosticLogText.looksLikeFailure("✓ 已复制到剪贴板"), "成功提示不应记录")
    check(!DiagnosticLogText.looksLikeFailure("已识别二维码：https://example.com/?code=123"), "普通内容提示不应记录")
    check(DiagnosticLogText.looksLikeFailure("Failed to save the image") && DiagnosticLogText.looksLikeFailure("Window capture failed. Check permissions"),
          "英文界面的失败提示同样应记录")
    check(!DiagnosticLogText.looksLikeFailure("✓ Copied to the clipboard"), "英文成功提示不应记录")

    // 3) 错误摘要：域#码 + 底层错误 + 描述；Swift 枚举错误保留 case 名
    let underlying = NSError(domain: NSPOSIXErrorDomain, code: 13)
    let cocoa = NSError(domain: NSCocoaErrorDomain, code: 513, userInfo: [
        NSUnderlyingErrorKey: underlying, NSLocalizedDescriptionKey: "没有权限"
    ])
    let cocoaDesc = DiagnosticLogText.describe(cocoa)
    check(cocoaDesc == "NSCocoaErrorDomain#513 · underlying NSPOSIXErrorDomain#13 · 没有权限", "Cocoa 错误摘要格式不符: \(cocoaDesc)")
    enum SampleError: Error { case httpError(Int) }
    let swiftDesc = DiagnosticLogText.describe(SampleError.httpError(401))
    check(swiftDesc.contains("httpError(401)"), "Swift 原生错误应保留 case 与关联值: \(swiftDesc)")
    struct Described: LocalizedError { var errorDescription: String? { "密钥无效" } }
    check(DiagnosticLogText.describe(Described()).hasSuffix("密钥无效"), "LocalizedError 应使用其 errorDescription")

    // 4) 单行格式
    let utc8 = TimeZone(secondsFromGMT: 8 * 3600)!
    let line = DiagnosticLogText.formatLine(
        date: Date(timeIntervalSince1970: 1_764_237_912.345), level: .warning, category: .capture,
        message: "SCK failed", timeZone: utc8
    )
    check(line == "2025-11-27 18:05:12.345 +08:00 [WARN] [capture] SCK failed", "日志行格式不符: \(line)")

    // 5) 双文件滚动：总占用有上限、跨备份按时间顺序读取、权限 0600
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("msnip_log_\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: dir) }
    let logURL = dir.appendingPathComponent("msnip.log")
    let file = DiagnosticLogFile(url: logURL, maxBytes: 1024)
    for i in 0..<200 { file.append(String(format: "line-%03d ", i) + String(repeating: "x", count: 40)) }
    file.flush()

    let size = { (u: URL) -> Int in ((try? fm.attributesOfItem(atPath: u.path)[.size]) as? NSNumber)?.intValue ?? -1 }
    check(size(logURL) > 0 && size(logURL) <= 1024, "当前日志文件应不超过上限，实际 \(size(logURL)) 字节")
    check(size(file.rotatedURL) > 0 && size(file.rotatedURL) <= 1024, "轮转备份应存在且不超过上限")
    check(file.rotatedURL.lastPathComponent == "msnip.1.log", "轮转备份文件名应为 msnip.1.log")
    let entries = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    check(entries == ["msnip.1.log", "msnip.log"], "目录中只应保留当前文件与一份备份，实际: \(entries)")

    let recent = file.recentLines(limit: 5)
    check(recent.count == 5 && recent.last?.hasPrefix("line-199") == true && recent.first?.hasPrefix("line-195") == true,
          "最近日志应按时间顺序返回末尾几行，实际: \(recent.map { String($0.prefix(8)) })")
    let all = file.recentLines(limit: 1000)
    let numbers = all.compactMap { Int($0.dropFirst(5).prefix(3)) }
    check(numbers == numbers.sorted() && numbers.count == Set(numbers).count, "跨越轮转备份读取时行序应连续递增")
    let perms = ((try? fm.attributesOfItem(atPath: logURL.path)[.posixPermissions]) as? NSNumber)?.int16Value ?? 0
    check(perms == 0o600, "日志文件权限应为 0600，实际: \(String(perms, radix: 8))")

    // 6) 重新打开时续写而不是覆盖
    let reopened = DiagnosticLogFile(url: logURL, maxBytes: 1024)
    reopened.append("after-reopen")
    reopened.flush()
    check(reopened.recentLines(limit: 2) == [recent.last ?? "", "after-reopen"], "重启后应接着已有日志续写")
}
