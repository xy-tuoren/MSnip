import CoreGraphics
import Foundation
import MSnipCore

/// 渲染包含「左侧 22% 静态目录栏」与「大片段落留白」的奇数宽高视口帧，检验抗侧边栏干扰、防留白误锁与跨屏自愈能力
private func renderSidebarScrollFrame(w: Int, h: Int, scrollY: Int) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)

    let sidebarW = w * 22 / 100
    // 左侧固定目录栏（不随 scrollY 变化）
    ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.13, blue: 0.16, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: sidebarW, height: h))
    for i in 0..<8 {
        ctx.setFillColor(CGColor(srgbRed: 0.35, green: 0.55, blue: 0.85, alpha: 1))
        ctx.fill(CGRect(x: 8, y: 16 + i * 26, width: max(8, sidebarW - 16), height: 8))
    }

    // 右侧正文：混合纯白段落留白与唯一纹理行
    ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1))
    ctx.fill(CGRect(x: sidebarW, y: 0, width: w - sidebarW, height: h))
    for vy in 0..<h {
        let docY = scrollY + vy
        // 每 90px 留出 32px 纯白段落空白，验证不会被误判为固定顶栏/底栏
        if (docY % 90) < 32 { continue }
        let r = CGFloat((docY * 11 + 17) % 180 + 30) / 255.0
        let g = CGFloat((docY * 23 + 53) % 170 + 30) / 255.0
        let b = CGFloat((docY * 37 + 91) % 170 + 30) / 255.0
        let bx = sidebarW + 14 + ((docY / 4) * 31) % max(20, w - sidebarW - 110)
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: bx, y: vy, width: 78, height: 1))
    }
    return ctx.makeImage()!
}

func testScrollStitcherSidebarFastJumpAndSelfResync() {
    // 故意采用奇数宽高 (301 × 241)，验证 1:1 物理像素无损拼接
    let w = 301, h = 241
    let stitcher = ScrollStitcher()
    check(stitcher.ingest(frame: renderSidebarScrollFrame(w: w, h: h, scrollY: 0)) == .initialized(widthPx: w, heightPx: h),
          "奇数尺寸长截图首帧初始化应精确保留原尺寸")

    // 大跨度快滚 (+160px，占视口高度 66%) 且含左侧静态侧边栏与空白段落间距
    let stepFast = stitcher.ingest(frame: renderSidebarScrollFrame(w: w, h: h, scrollY: 160))
    check(stepFast == .appended(addedPx: 160, totalHeightPx: h + 160),
          "含静态侧边栏与留白的 66% 大跨度快滚应零误判拼接，实际: \(stepFast)")
    check(stitcher.lockedTopFixed == 0 && stitcher.lockedBottomFixed == 0,
          "纯白段落间距绝不应被误锁为 Sticky 固定栏，实际 top=\(stitcher.lockedTopFixed), bot=\(stitcher.lockedBottomFixed)")

    // 模拟用户按 PageDown 跨整屏跳到 900px（完全无重叠 -> 首次告警）
    let jump = stitcher.ingest(frame: renderSidebarScrollFrame(w: w, h: h, scrollY: 900))
    check(jump == .mismatchLostOverlap, "跨整屏跳跃首次应温和提示 mismatchLostOverlap")

    // 用户不回滚，而是继续向下正常滚到 948px (+48px)：应触发自动重锚自愈续接，彻底告别死锁报错！
    let healed = stitcher.ingest(frame: renderSidebarScrollFrame(w: w, h: h, scrollY: 948))
    if case .appended(let added, _) = healed {
        check(added == h + 48, "跨屏后继续下滚应自动续接新视口与 +48px 增量，实际 added=\(added)")
    } else {
        check(false, "跨屏后继续下滚应自动自愈为 .appended，实际: \(healed)")
    }
}

func testTranslationConfigAndModels() {
    // 1) 自动中英双向语种识别
    let enPair = TranslationTargetLang.resolve(target: .autoZhEn, sampleText: "Click here to configure API providers.")
    check(enPair.sourceApple == "en" && enPair.concreteTarget == .zhHans, "英文原文在自动互译模式下应译为简体中文")

    let zhPair = TranslationTargetLang.resolve(target: .autoZhEn, sampleText: "点击此处配置大模型与云端翻译接口")
    check(zhPair.sourceApple == "zh-Hans" && zhPair.concreteTarget == .en, "中文原文在自动互译模式下应自动互译为英文")

    let jaPair = TranslationTargetLang.resolve(target: .autoZhEn, sampleText: "スクリーンショットのテキストを翻訳します")
    check(jaPair.sourceApple == "ja" && jaPair.concreteTarget == .zhHans, "日文假名原文应识别为 ja 并译为简体中文")

    // 2) OpenAI 兼容端点智能补全
    check(
        TranslationSettingsConfig.resolveChatCompletionsURL("https://api.deepseek.com")?.absoluteString
            == "https://api.deepseek.com/v1/chat/completions",
        "裸域名应自动补全 /v1/chat/completions"
    )
    check(
        TranslationSettingsConfig.resolveChatCompletionsURL("https://open.bigmodel.cn/api/paas/v4/")?.absoluteString
            == "https://open.bigmodel.cn/api/paas/v4/chat/completions",
        "带 /v4/ 的智谱地址应直接补全 /chat/completions"
    )

    // 3) 自定义 JSON 点分路径提取
    let mockJSON: [String: Any] = ["data": ["translations": [["text": "你好世界"]]]]
    check(
        TranslationSettingsConfig.extractJSONPath(mockJSON, path: "data.translations.0.text") == "你好世界",
        "点分 JSON 路径应支持嵌套字典与数组下标提取"
    )

    // 4) 0600 仅本人可读写权限持久化校验
    let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("msnip_trans_test_\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmpURL) }

    var cfg = TranslationSettingsConfig()
    check(cfg.resolvedActiveProfile?.kind == .appleNative, "开箱默认主引擎应为免费的 macOS 原生离线翻译")
    cfg.targetLang = .en
    cfg.save(to: tmpURL)

    let loaded = TranslationSettingsConfig.load(from: tmpURL)
    check(loaded.targetLang == .en && loaded.profiles.count == cfg.profiles.count, "翻译配置文件读写往返应完整一致")
    let perms = (try? FileManager.default.attributesOfItem(atPath: tmpURL.path)[.posixPermissions] as? NSNumber)?.int16Value ?? 0
    check(perms == 0o600, "翻译密钥配置文件权限必须严格为 0600，实际: \(String(perms, radix: 8))")

    // 5) 钥匙串加密隔离存储：开启后本地 JSON 自动脱敏清空 API Key，加载时透明回填，关闭时无损迁回
    let vault = MemoryCredentialStore()
    var secureCfg = TranslationSettingsConfig()
    secureCfg.preferKeychainStorage = true
    secureCfg.profiles[1].apiKey = "sk-secret-zhipu-999"
    secureCfg.save(to: tmpURL, secretStore: vault)

    let rawDiskText = (try? String(contentsOf: tmpURL, encoding: .utf8)) ?? ""
    check(!rawDiskText.contains("sk-secret-zhipu-999"), "开启钥匙串存储后磁盘 JSON 中绝不应残留明文 API Key")

    let hydrated = TranslationSettingsConfig.load(from: tmpURL, secretStore: vault)
    check(hydrated.preferKeychainStorage && hydrated.profiles[1].apiKey == "sk-secret-zhipu-999", "加载配置时应从凭据仓透明回填 API Key")

    var migratedBack = hydrated
    migratedBack.preferKeychainStorage = false
    migratedBack.save(to: tmpURL, secretStore: vault)
    let acct = "translation.profile.\(migratedBack.profiles[1].id.uuidString)"
    check(vault.readSecret(account: acct) == nil, "关闭钥匙串存储后应清理凭据仓中的旧密钥条目")
    let reloadedPlain = TranslationSettingsConfig.load(from: tmpURL, secretStore: vault)
    check(reloadedPlain.profiles[1].apiKey == "sk-secret-zhipu-999", "关闭钥匙串存储后应无损恢复为 0600 本地配置存储")

    // 6) LaTeX 配置钥匙串脱敏及旧版缺省字段向后兼容
    let latexURL = FileManager.default.temporaryDirectory.appendingPathComponent("msnip_latex_test_\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: latexURL) }
    var latexCfg = LatexRecognitionConfig()
    latexCfg.simpleTexToken = "uat-token-888"
    latexCfg.save(to: latexURL, secretStore: vault, useKeychain: true)
    let latexRaw = (try? String(contentsOf: latexURL, encoding: .utf8)) ?? ""
    let latexLoaded = LatexRecognitionConfig.load(from: latexURL, secretStore: vault)
    check(!latexRaw.contains("uat-token-888") && latexLoaded.simpleTexToken == "uat-token-888", "LaTeX Token 开启钥匙串后应落盘脱敏并加载回填")

    // 7) Google 翻译级百种语种目录、搜索匹配与自由自定义目标语言测试
    check(TranslationLanguageCatalog.allEntries.count >= 110, "内置世界语种目录应不少于 110 种，实际: \(TranslationLanguageCatalog.allEntries.count)")
    let esHits = TranslationLanguageCatalog.allEntries.filter { $0.matches("西班牙") }
    check(esHits.contains(where: { $0.code == "es" }), "中文关键字搜索应命中 es 西班牙语")
    check(TranslationTargetLang.language("es").baiduCode == "spa" && TranslationTargetLang.language("vi").baiduCode == "vie", "百度不规则语种代码映射应准确")

    let customStyle = TranslationTargetLang.custom("地道粤语口语")
    check(customStyle.isCustom && customStyle.promptLanguageName == "地道粤语口语" && customStyle.baiduCode == "yue", "自定义目标应保留原始大模型提示词并智能推断云 API 回退语种码")
    let customCfg = TranslationSettingsConfig(targetLang: customStyle)
    customCfg.save(to: tmpURL)
    let reloadedCustom = TranslationSettingsConfig.load(from: tmpURL)
    check(reloadedCustom.targetLang == customStyle && reloadedCustom.targetLang.displayName == "自定义：地道粤语口语", "自定义目标语言 JSON 读写往返应完全一致")

    // 8) 兼容协议 URL 自动补全、Anthropic /v1 去重、局域网免 Key、思考标签剥离与 /models 解析
    check(
        LLMProtocolHelpers.resolveOpenAIModelsURL("https://api.deepseek.com/v1/chat/completions")?.absoluteString
            == "https://api.deepseek.com/v1/models",
        "完整 chat/completions 地址应自动推导对应的 /v1/models 地址"
    )
    check(
        LLMProtocolHelpers.resolveAnthropicMessagesURL("https://proxy.example.com/v1")?.absoluteString
            == "https://proxy.example.com/v1/messages",
        "Anthropic 兼容地址以 /v1 结尾时绝不应重复拼接 /v1/v1/messages"
    )
    check(
        LLMProtocolHelpers.isLocalOrPrivateEndpoint("http://192.168.1.88:8000/v1")
            && LLMProtocolHelpers.isLocalOrPrivateEndpoint("http://10.0.0.12:11434/v1")
            && LLMProtocolHelpers.isLocalOrPrivateEndpoint("http://macstudio.local:8080/v1")
            && !LLMProtocolHelpers.isLocalOrPrivateEndpoint("https://api.deepseek.com/v1"),
        "局域网私有 IP 与 .local 地址应判定为本地免 Key 兼容端点，公网域名仍需 API Key"
    )
    check(
        LLMProtocolHelpers.stripThinkingTags("<think>step 1\nstep 2</think>\n你好世界") == "你好世界",
        "应自动剥离思考类模型内联输出的 <think>...</think> 标签"
    )
    check(
        LLMProtocolHelpers.stripThinkingTags("<think>正在推理尚未闭合") == "",
        "流式传输未闭合 <think> 前缀时应暂不暴露推理草稿"
    )
    let openAIModelsJSON = Data("{\"data\":[{\"id\":\"deepseek-reasoner\"},{\"id\":\"deepseek-chat\"}]}".utf8)
    let parsedOpenAI = LLMProtocolHelpers.parseModelIDs(from: openAIModelsJSON, kind: .openAICompatible)
    check(parsedOpenAI == ["deepseek-chat", "deepseek-reasoner"], "OpenAI /v1/models JSON 应解析并排序模型列表")
    let geminiModelsJSON = Data("{\"models\":[{\"name\":\"models/gemini-2.0-flash\"}]}".utf8)
    let parsedGemini = LLMProtocolHelpers.parseModelIDs(from: geminiModelsJSON, kind: .geminiNative)
    check(parsedGemini == ["gemini-2.0-flash"], "Gemini 模型列表应自动去除 models/ 前缀")
    check(
        LLMQuickPreset.deepseek.providerKind == .openAICompatible
            && LLMQuickPreset.claude.providerKind == .anthropicCompatible
            && LLMQuickPreset.gemini.providerKind == .geminiNative
            && LLMQuickPreset.allCases.count >= 20,
        "统一 LLM 官网预设应覆盖 20+ 主流国内外厂商并准确映射到 OpenAI / Anthropic / Gemini 协议"
    )
    check(
        LLMQuickPreset.match(endpoint: "https://api.hunyuan.cloud.tencent.com/v1") == .hunyuan
            && LLMQuickPreset.match(endpoint: "https://api.groq.com/openai/v1") == .groq
            && LLMQuickPreset.match(endpoint: "https://qianfan.baidubce.com/v2") == .qianfan
            && LLMQuickPreset.match(endpoint: "http://127.0.0.1:1234/v1") == .lmStudioLocal,
        "根据官网端点地址应准确反查对应的官方预设与密钥控制台链接"
    )

    // 长截图原生广色域 ICC 透传验证（Display P3 帧经拼接导出后仍保持 Display P3，不强制降级为 sRGB）
    if let p3 = CGColorSpace(name: CGColorSpace.displayP3),
       let ctx = CGContext(data: nil, width: 64, height: 96, bitsPerComponent: 8, bytesPerRow: 0, space: p3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        ctx.setFillColor(CGColor(colorSpace: p3, components: [0.95, 0.2, 0.1, 1.0])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 96))
        if let f1 = ctx.makeImage() {
            let p3Stitcher = ScrollStitcher()
            _ = p3Stitcher.ingest(frame: f1)
            let finalP3 = p3Stitcher.renderFinalImage()
            check(
                finalP3?.colorSpace?.name == CGColorSpace.displayP3,
                "长截图拼接导出应保留源帧 Display P3 原生 ICC 色彩空间而非强制降级 sRGB"
            )
        }
    }

    // 三协议 SSE 增量块解析、批量编号行解包与剪贴板文本便签卡渲染回归单测
    check(
        LLMProtocolHelpers.parseOpenAISSEChunk("{\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}") == "你好"
            && LLMProtocolHelpers.parseAnthropicSSEChunk("{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"世界\"}}") == "世界"
            && LLMProtocolHelpers.parseGeminiSSEChunk("{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"MSnip\"}]}}]}") == "MSnip",
        "OpenAI / Anthropic / Gemini 三协议 SSE 增量文本解析应全部准确提取"
    )
    let unpacked = LLMProtocolHelpers.unpackNumberedLines("⟦2⟧ 第二行\n⟦1⟧ 第一行", original: ["Line 1", "Line 2"])
    check(unpacked == ["第一行", "第二行"], "批量多行译文解包应按 ⟦N⟧ 编号严格还原顺序")

    check(
        TextPinCardRenderer.looksLikeCode("{\"status\": 200, \"ok\": true}")
            && !TextPinCardRenderer.looksLikeCode("这是一段普通的中文备忘便签"),
        "文本便签渲染器应准确区分代码片段与普通文本"
    )
    let noteImg = TextPinCardRenderer.render(text: "Hello MSnip\n第二行便签内容", scale: 2.0)
    check(noteImg != nil && (noteImg?.width ?? 0) >= 480 && (noteImg?.height ?? 0) >= 120, "剪贴板纯文本应生成清晰 Retina 便签贴图")
}
