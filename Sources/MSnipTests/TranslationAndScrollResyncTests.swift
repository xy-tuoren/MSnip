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
}
