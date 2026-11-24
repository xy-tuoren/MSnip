import CoreGraphics
import Foundation
import MSnipCore

func testColorSamplingAndRoundedBake() {
    // 1) 验证 PixPin 四种取色格式转换与循环顺序
    let c = RGBAColor(51, 136, 255)
    check(c.formatted(as: .hex) == "#3388FF", "HEX 格式应为 #3388FF，实际: \(c.formatted(as: .hex))")
    check(c.formatted(as: .rgb) == "rgb(51, 136, 255)", "RGB 格式应为 rgb(51, 136, 255)")
    check(c.formatted(as: .hsl) == "hsl(215, 100%, 60%)", "HSL 格式应为 hsl(215, 100%, 60%)，实际: \(c.formatted(as: .hsl))")
    check(c.formatted(as: .hsv) == "hsv(215, 80%, 100%)", "HSV 格式应为 hsv(215, 80%, 100%)，实际: \(c.formatted(as: .hsv))")
    check(ColorCopyFormat.hex.next == .rgb && ColorCopyFormat.hsv.next == .hex, "Shift 色值格式循环顺序应闭环")

    // 2) 验证剪贴板色值文本解析与色彩贴图卡渲染
    check(RGBAColor.parseColorString(" #3388ff ") == c, "应支持大小写 #RRGGBB 解析")
    check(RGBAColor.parseColorString("#38F") == c, "应支持简写 #RGB 解析")
    check(RGBAColor.parseColorString("rgb(51, 136, 255)") == c, "应支持 rgb(r, g, b) 解析")
    check(RGBAColor.parseColorString("not-a-color") == nil, "非法文本应返回 nil")

    let card = RGBAColor.renderColorPinCard(c, scale: 2.0)
    check(card != nil && card!.width == 448 && card!.height == 184, "2x 色彩贴图卡尺寸应为 448×184")

    // 3) 验证圆角截图烘焙（四角像素透明、中心像素不透明）
    let w = 100, h = 80
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1.0))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let sampler = PixelSampler(cgImage: ctx.makeImage()!)

    let rounded = AnnotationRenderer.bakeExportImage(
        sampler: sampler,
        selection: CGRect(x: 0, y: 0, width: 50, height: 40),
        imageScale: 2.0,
        annotations: [],
        cornerRadiusPt: 12
    )
    check(rounded != nil, "圆角截图应成功烘焙导出")
    if let img = rounded, let data = img.dataProvider?.data, let ptr = CFDataGetBytePtr(data) {
        let bpr = img.bytesPerRow
        let cornerAlpha = ptr[0 * bpr + 0 * 4 + 3]
        let centerAlpha = ptr[40 * bpr + 50 * 4 + 3]
        check(cornerAlpha == 0, "圆角裁切后的极角像素 (0,0) 必须完全透明 (alpha=0)，实际: \(cornerAlpha)")
        check(centerAlpha == 255, "圆角截图中心像素必须保持完全不透明 (alpha=255)，实际: \(centerAlpha)")
    }

    // 4) 验证原色域（如 Display P3）直出与带标注导出均 100% 保留原始色彩空间不降级 sRGB
    if let p3 = CGColorSpace(name: CGColorSpace.displayP3),
       let p3Ctx = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: p3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        p3Ctx.setFillColor(CGColor(colorSpace: p3, components: [0.95, 0.15, 0.2, 1.0])!)
        p3Ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        if let p3Img = p3Ctx.makeImage() {
            let p3Sampler = PixelSampler(cgImage: p3Img)
            let cleanOut = AnnotationRenderer.bakeExportImage(sampler: p3Sampler, selection: CGRect(x: 0, y: 0, width: 20, height: 20), imageScale: 1.0, annotations: [])
            check(cleanOut?.colorSpace?.name == CGColorSpace.displayP3, "无标注直出必须 100% 保留原生 Display P3 色彩空间")
            let roundedOut = AnnotationRenderer.bakeExportImage(sampler: p3Sampler, selection: CGRect(x: 0, y: 0, width: 20, height: 20), imageScale: 1.0, annotations: [], cornerRadiusPt: 4)
            check(roundedOut?.colorSpace?.name == CGColorSpace.displayP3, "带圆角/标注导出也必须保留原生 Display P3 色彩空间")
        }
    }
}

func testPixelCaliperMeasurement() {
    // 构造 120×80 白色画布，在中间 (30..<90, 20..<52) 绘制深色矩形块，验证精确 1px 四向测距
    let w = 120, h = 80
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // 注意 CGContext 原点在左下角，先清白再翻转到左上角坐标系绘制
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.14, blue: 0.18, alpha: 1))
    ctx.fill(CGRect(x: 30, y: 20, width: 60, height: 32))
    let sampler = PixelSampler(cgImage: ctx.makeImage()!)

    // 1) 光标落在深色按钮内部 (50, 35) -> 应精确量出 60×32 px
    let inside = PixelCaliper.measure(atX: 50, y: 35, in: sampler)
    check(inside != nil, "按钮内像素卡尺测距应返回有效结果")
    if let r = inside {
        check(r.widthPx == 60 && r.heightPx == 32, "按钮内部卡尺应测得 60×32 px，实际: \(r.widthPx)×\(r.heightPx)")
        check(r.leftPx == 30 && r.rightPx == 89 && r.topPx == 20 && r.bottomPx == 51, "按钮四边坐标应精确对齐")
        check(r.hitLeft && r.hitRight && r.hitTop && r.hitBottom, "按钮四边应全部命中真实色差边界")
    }

    // 2) 光标落在左侧空白间距 (15, 35) -> 水平 0..<30 (30px)，垂直穿透整高 80px
    let gap = PixelCaliper.measure(atX: 15, y: 35, in: sampler)
    check(gap != nil && gap!.widthPx == 30 && gap!.heightPx == 80, "左侧空白间距应测得 30×80 px")
    check(gap != nil && !gap!.hitLeft && gap!.hitRight, "左侧贴屏边缘不应标记 hitLeft，右侧撞按钮应标记 hitRight")
}

func testShortcutPresetsOverridesAndCanvasSwap() {
    // 1) 默认预设 optASD 必须采用零冲突左手双键（⌥+字母），严禁抢占 ⌘1 / ⌘⇧P
    let defPreset = HotKeyPreset.optASD
    check(defPreset.defaultCombo(for: .capture)?.displayString == "⌥A", "默认截图热键应为左手双键 ⌥A")
    check(defPreset.defaultCombo(for: .pin)?.displayString == "⌥T", "默认贴图热键应为左手双键 ⌥T")
    check(defPreset.defaultCombo(for: .ocr)?.displayString == "⌥S", "默认识字热键应为左手双键 ⌥S")
    check(defPreset.defaultCombo(for: .translate)?.displayString == "⌥D", "默认翻译热键应为左手双键 ⌥D")
    check(defPreset.defaultCombo(for: .longShot)?.displayString == "⌥E", "默认长截图热键应为左手双键 ⌥E")
    check(defPreset.defaultCombo(for: .record)?.displayString == "⌥R", "默认录屏热键应为左手双键 ⌥R")
    check(defPreset.defaultCombo(for: .latex) == nil, "低频公式热键默认留空不占全局键位")

    // 2) 数字双键预设 ctrl123 与历史旧版配置名兼容解码
    check(HotKeyPreset.ctrl123.defaultCombo(for: .capture)?.displayString == "⌃1", "数字双键预设应为 ⌃1")
    check(HotKeyPreset.ctrl123.defaultCombo(for: .pin)?.displayString == "⌃2", "数字双键贴图预设应为 ⌃2")
    let legacyOpt123 = try? JSONDecoder().decode(HotKeyPreset.self, from: Data("\"opt123\"".utf8))
    check(legacyOpt123 == .ctrl123, "旧版 opt123 配置解码时应平滑迁移至 ⌃1/⌃2 数字双键 ctrl123")
    check(HotKeyPreset.fnKeys.defaultCombo(for: .pin)?.displayString == "F2", "F 键预设应按 F1/F2 顺序排列")
    let legacyDecoded = try? JSONDecoder().decode(HotKeyPreset.self, from: Data("\"cmd12\"".utf8))
    check(legacyDecoded == .optASD, "旧版抢占浏览器的 cmd12 配置解码时应平滑迁移至推荐双键 optASD")

    // 3) 画布内 24 项单键重绑定与冲突自动互换（保证全表无重复键位）
    var customMap: [String: String] = [:]
    let swapped = CanvasAction.bind(key: "a", to: .ocr, in: &customMap)
    check(swapped == .arrow, "将识字 T 改为已占用的 A 时应与箭头自动互换")
    check((customMap[CanvasAction.ocr.rawValue] ?? "t") == "a", "识字应更新为 a")
    check((customMap[CanvasAction.arrow.rawValue] ?? "a") == "t", "原箭头应互换为 t")
    let allResolved = Set(CanvasAction.allCases.map { customMap[$0.rawValue] ?? $0.defaultKey })
    check(allResolved.count == CanvasAction.allCases.count, "自动互换后 24 项画布动作单键必须保持两两不冲突双射")

    // 4) 全局热键冲突检测引擎（MSnip 内部 / macOS 系统 / Carbon 独占 / 运行中第三方软件 / 通用快捷键 / 推荐零冲突键）
    let optA = KeyCombo(keyCode: 0, carbonModifiers: 2048)       // ⌥A
    let optT = KeyCombo(keyCode: 17, carbonModifiers: 2048)      // ⌥T
    let cmdSpace = KeyCombo(keyCode: 49, carbonModifiers: 256)   // ⌘␣
    let ctrlCmdA = KeyCombo(keyCode: 0, carbonModifiers: 4352)   // ⌃⌘A
    let cmdC = KeyCombo(keyCode: 8, carbonModifiers: 256)        // ⌘C

    let ownBindings: [GlobalHotKeyAction: KeyCombo] = [.capture: optA, .pin: optT]
    let sysEntries = [OccupiedHotKeyEntry(combo: cmdSpace, owner: "macOS", feature: "聚焦搜索 (Spotlight)", category: .system)]
    let wechatRunning = HotKeyConflictCatalog.runningAppEntries(for: ["com.tencent.xinWeChat"])
    let noAppsRunning = HotKeyConflictCatalog.runningAppEntries(for: ["com.apple.Finder"])

    let internalHits = HotKeyConflictCatalog.evaluate(
        combo: optT, excluding: .capture, ownBindings: ownBindings,
        systemEntries: sysEntries, runningAppEntries: noAppsRunning, carbonExclusiveOccupied: false
    )
    check(internalHits.first?.owner == "MSnip" && internalHits.first?.severity == .blocking, "应拦截 MSnip 内部重复按键")

    let sysHits = HotKeyConflictCatalog.evaluate(
        combo: cmdSpace, excluding: .capture, ownBindings: ownBindings,
        systemEntries: sysEntries, runningAppEntries: noAppsRunning, carbonExclusiveOccupied: true
    )
    check(sysHits.first?.owner == "macOS" && sysHits.first?.requiresDoublePressConfirm == true, "应检出 macOS Spotlight 系统热键冲突")

    let wechatHits = HotKeyConflictCatalog.evaluate(
        combo: ctrlCmdA, excluding: .capture, ownBindings: ownBindings,
        systemEntries: sysEntries, runningAppEntries: wechatRunning, carbonExclusiveOccupied: false
    )
    check(wechatHits.first?.owner == "微信" && wechatHits.first?.severity == .warning, "微信运行时应预警 ⌃⌘A 冲突")

    let cleanWhenClosed = HotKeyConflictCatalog.evaluate(
        combo: ctrlCmdA, excluding: .capture, ownBindings: ownBindings,
        systemEntries: sysEntries, runningAppEntries: noAppsRunning, carbonExclusiveOccupied: false
    )
    check(cleanWhenClosed.isEmpty, "微信未运行时 ⌃⌘A 不应误报冲突")

    let copyHits = HotKeyConflictCatalog.evaluate(
        combo: cmdC, excluding: .capture, ownBindings: ownBindings,
        systemEntries: sysEntries, runningAppEntries: noAppsRunning, carbonExclusiveOccupied: false
    )
    check(copyHits.first?.shortBadge == "拦截复制" && copyHits.first?.requiresDoublePressConfirm == true, "⌘C 应提示会拦截通用复制快捷键")

    let suggested = HotKeyConflictCatalog.suggestConflictFreeCombo(
        for: .capture, ownBindings: ownBindings, occupied: Set([optA, optT, KeyCombo(keyCode: 1, carbonModifiers: 2048)])
    )
    check(suggested != nil && suggested != optA && suggested != optT, "推荐算法应避开全部已占与内部绑定键位")

    // 5) PixPin 真实 Bundle ID 与 KeyboardShortcuts / Raycast 配置解析测试
    let pixpinEntries = HotKeyConflictCatalog.runningAppEntries(for: ["com.depthpicture.PixPin"])
    check(pixpinEntries.contains { $0.owner == "PixPin" && $0.combo.displayString == "⌥1" }, "应精准识别真实运行中的 PixPin (com.depthpicture.PixPin)")
    let parsedKS = HotKeyConflictProfiles.parseKeyboardShortcutsJSON("{\"carbonKeyCode\":1,\"carbonModifiers\":2048}")
    check(parsedKS?.displayString == "⌥S", "应精确解析 KeyboardShortcuts 标准 JSON 热键")
    let parsedRaycast = HotKeyConflictProfiles.parseRaycastHotkeyString("Option-49")
    check(parsedRaycast?.displayString == "⌥␣", "应精确解析 Raycast 全局热键配置字符串")
}

func testVisualDetectorRoundedLowContrastAndBoundaryFilter() {
    // 1) Retina @2x 下：浅灰底 (#F5F7FA) + 18pt 大圆角纯白卡片 (60, 40, 280, 180) + 卡片内多行文字条纹干扰
    let scale: CGFloat = 2.0
    let lw = 400, lh = 260
    let pw = Int(CGFloat(lw) * scale), ph = Int(CGFloat(lh) * scale)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.translateBy(x: 0, y: CGFloat(ph))
    ctx.scaleBy(x: scale, y: -scale)

    ctx.setFillColor(CGColor(srgbRed: 245.0 / 255.0, green: 247.0 / 255.0, blue: 250.0 / 255.0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: lw, height: lh))

    let card = CGRect(x: 60, y: 40, width: 280, height: 180)
    let roundedPath = CGPath(roundedRect: card, cornerWidth: 18, cornerHeight: 18, transform: nil)
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.addPath(roundedPath); ctx.fillPath()

    // 在卡片内部画 5 行文字横条（验证不会被旧的 4 条候选上限提前截断而漏掉外层大卡片）
    ctx.setFillColor(CGColor(srgbRed: 0.25, green: 0.28, blue: 0.34, alpha: 1))
    for i in 0..<5 {
        ctx.fill(CGRect(x: 84, y: 66 + i * 24, width: 190, height: 6))
    }

    let sampler = PixelSampler(cgImage: ctx.makeImage()!)
    let winBounds = CGRect(x: 0, y: 0, width: lw, height: lh)

    let hits = VisualDetector.detectVisualRects(at: CGPoint(x: 190, y: 130), within: winBounds, sampler: sampler, scale: scale)
    check(
        hits.contains(where: { abs($0.minX - card.minX) <= 3 && abs($0.minY - card.minY) <= 3 && abs($0.width - card.width) <= 6 && abs($0.height - card.height) <= 6 }),
        "应穿透多行文字并精准识别 @2x 低对比度 18pt 大圆角白卡，实际得到: \(hits)"
    )

    // 2) 验证 hasVisualBoundary：真实白卡返回 true，无边缘透明 AXGroup 包装盒返回 false
    check(
        VisualDetector.hasVisualBoundary(card, within: winBounds, sampler: sampler, scale: scale),
        "真实大圆角白卡应通过视觉边界验证"
    )
    let invisibleDiv = CGRect(x: 20, y: 15, width: 350, height: 220)
    check(
        !VisualDetector.hasVisualBoundary(invisibleDiv, within: winBounds, sampler: sampler, scale: scale),
        "无视觉边界的透明 AXGroup 容器应被过滤"
    )
}
