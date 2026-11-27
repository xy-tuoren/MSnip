import Foundation
import MSnipCore

/// 审阅加固回归：外部触发安全降级、翻译配置逐字段/逐条容错与损坏备份、UTF-8 安全截断
func testReviewHardening() {
    // 1) URL Scheme / 命令行 / IPC 等外部渠道不得触发静默全屏截图（防止无权限进程借道屏幕录制权限）
    check(MSnipLaunchCommand.fullscreen.resolvedForExternalTrigger == .capture, "外部触发的全屏截图应降级为需用户确认的交互式截图")
    check(
        !MSnipLaunchCommand.allCases.contains { $0.resolvedForExternalTrigger == .fullscreen },
        "任何外部命令降级后都不应再是静默全屏截图"
    )
    for cmd in MSnipLaunchCommand.allCases where cmd != .fullscreen {
        check(cmd.resolvedForExternalTrigger == cmd, "非静默截屏类外部命令应保持原语义: \(cmd)")
    }
    check(
        MSnipLaunchCommand.parse(url: URL(string: "msnip://fullscreen")!)?.resolvedForExternalTrigger == .capture
            && MSnipLaunchCommand.parse(arguments: ["MSnip", "--fullscreen"])?.resolvedForExternalTrigger == .capture,
        "msnip://fullscreen 与 --fullscreen 解析后都应降级为交互式截图"
    )

    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("msnip_review_\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    // 2) 旧版缺字段、降级遇到未知协议、个别字段类型异常：只跳过/回退出问题的部分，绝不清空其余密钥
    let tolerantURL = dir.appendingPathComponent("translation_providers.json")
    let keepID = UUID()
    let legacyJSON = """
    {
      "activeProfileID": "\(keepID.uuidString)",
      "targetLang": "en",
      "profiles": [
        {"id": "\(keepID.uuidString)", "name": "My DeepSeek", "kind": "openai_compatible",
         "endpoint": "https://api.deepseek.com", "apiKey": "sk-keep-me", "model": "deepseek-chat"},
        {"id": "\(UUID().uuidString)", "name": "Future", "kind": "future_protocol_v9", "apiKey": "sk-future"},
        {"id": "\(UUID().uuidString)", "name": "Odd", "kind": "baidu_fanyi", "isEnabled": "yes",
         "appIdOrSecretId": 12345, "apiKey": "baidu-secret", "fieldFromNewerVersion": true}
      ]
    }
    """
    try? Data(legacyJSON.utf8).write(to: tolerantURL)
    let tolerant = TranslationSettingsConfig.load(from: tolerantURL)
    check(tolerant.profiles.count == 2, "未知协议档案应单条跳过、其余保留，实际 \(tolerant.profiles.count) 条")
    if tolerant.profiles.count == 2 {
        let ds = tolerant.profiles[0], bd = tolerant.profiles[1]
        check(ds.id == keepID && ds.name == "My DeepSeek" && ds.apiKey == "sk-keep-me" && ds.systemPrompt.isEmpty,
              "缺少字段的旧版档案应完整保留 API Key 并以空串补齐缺省字段")
        check(bd.kind == .baidu && bd.apiKey == "baidu-secret" && bd.isEnabled && bd.appIdOrSecretId.isEmpty,
              "字段类型异常时应仅该字段回退默认，不影响同条档案的密钥")
    }
    check(tolerant.activeProfileID == keepID && tolerant.targetLang == .en, "顶层偏好应在档案容错后照常保留")
    let backupsAfterTolerant = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.contains("unreadable") }
    check(backupsAfterTolerant.isEmpty, "可解析的配置文件不应产生损坏备份")

    // 3) 完全无法解析的配置文件：重建默认前必须先 0600 备份原件
    let brokenURL = dir.appendingPathComponent("broken_providers.json")
    let brokenBytes = Data("{\"profiles\": [{\"apiKey\": \"sk-truncated".utf8)
    try? brokenBytes.write(to: brokenURL)
    let rebuilt = TranslationSettingsConfig.load(from: brokenURL)
    check(!rebuilt.profiles.isEmpty, "损坏配置应回退为可用的默认服务列表")
    let backupName = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).first { $0.hasPrefix("broken_providers.unreadable-") }
    check(backupName != nil, "损坏配置在重建前应留下 .unreadable 备份")
    if let backupName {
        let backupURL = dir.appendingPathComponent(backupName)
        let perms = (try? fm.attributesOfItem(atPath: backupURL.path)[.posixPermissions] as? NSNumber)?.int16Value ?? 0
        check((try? Data(contentsOf: backupURL)) == brokenBytes, "备份应逐字节保留原件以便找回密钥")
        check(perms == 0o600, "含密钥的备份文件权限必须为 0600，实际: \(String(perms, radix: 8))")
    }

    // 4) 错误响应按字节截断落在中文字符中间时不应整体丢失
    let zh = Data("参数错误".utf8) // 12 字节，每字 3 字节
    check(String(data: zh.prefix(7), encoding: .utf8) == nil, "前置条件：按字节截断中文时 String(data:) 会整体返回 nil")
    check(LLMProtocolHelpers.utf8Snippet(zh, maxBytes: 7) == "参数", "截断残缺尾字节后应保留完整的前序中文")
    check(LLMProtocolHelpers.utf8Snippet(zh, maxBytes: 100) == "参数错误", "未截断时应原样返回")
    check(LLMProtocolHelpers.utf8Snippet(Data(), maxBytes: 10).isEmpty, "空响应体应返回空串")
}
