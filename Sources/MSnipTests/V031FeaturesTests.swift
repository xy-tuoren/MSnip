import CoreGraphics
import Foundation
import MSnipCore

func testV031Features() {
    // 1) SensitiveTextDetector：精确匹配 API Key / JWT / 邮箱 / 手机号 / 18 位身份证 / IPv4 / 银行卡，忽略环回地址
    let apiHits = SensitiveTextDetector.detect(in: "export OPENAI_API_KEY=sk-proj-AbCdEf1234567890XyZ")
    check(apiHits.count == 1 && apiHits[0].kind == .apiKey && apiHits[0].matchedText.hasPrefix("sk-proj-"), "应精准定位 sk-proj API Key 子串")

    let multiLine = "联系邮箱 dev.user@example.com，手机 138-0013-8000，服务器 192.168.10.24 (本地 127.0.0.1 忽略)"
    let multiHits = SensitiveTextDetector.detect(in: multiLine)
    check(multiHits.map(\.kind) == [.email, .phone, .ipv4], "应按序命中邮箱、手机号与非环回 IP，实际: \(multiHits.map(\.kind))")

    let idHits = SensitiveTextDetector.detect(in: "身份证 11010519900307123X 与 GitHub ghp_1234567890abcdefghij123456")
    check(idHits.count == 2 && idHits[0].kind == .idCard && idHits[1].kind == .apiKey, "18 位身份证不应被误拆成手机号，且应同时命中 ghp_ token")

    let cleanHits = SensitiveTextDetector.detect(in: "Hello MSnip v0.3.1 release notes 2026")
    check(cleanHits.isEmpty, "普通文案不应误报敏感隐私信息")

    // 2) Spotlight 聚光灯标注：控制柄、碰撞检测与压暗框外渲染
    let spot = Annotation(payload: .spotlight(CGRect(x: 40, y: 30, width: 60, height: 40)), style: AnnotationStyle())
    check(spot.editableHandles().count == 4 && spot.hitTest(CGPoint(x: 70, y: 50)), "聚光灯应支持 4 角控制柄与区域命中")
    let whiteBg = makeSolidTestImage(w: 160, h: 120, r: 1, g: 1, b: 1)
    let spotSampler = PixelSampler(cgImage: whiteBg)
    if let bakedSpot = AnnotationRenderer.bakeExportImage(
        sampler: spotSampler,
        selection: CGRect(x: 0, y: 0, width: 160, height: 120),
        imageScale: 1.0,
        annotations: [spot]
    ) {
        let bs = PixelSampler(cgImage: bakedSpot)
        let inside = bs.sampleRGB(px: 70, py: 50)
        let outside = bs.sampleRGB(px: 10, py: 10)
        check(inside.0 > 245 && outside.0 < 160, "聚光灯框内应保持原亮度、框外应明显压暗: in=\(inside) out=\(outside)")
    } else {
        check(false, "聚光灯标注烘焙导出不应失败")
    }

    // 3) ImageCollageStitcher：横向并排与纵向长图拼接
    let redImg = makeSolidTestImage(w: 120, h: 80, r: 0.9, g: 0.15, b: 0.15)
    let blueImg = makeSolidTestImage(w: 160, h: 80, r: 0.12, g: 0.4, b: 0.95)
    if let hCol = ImageCollageStitcher.stitch(images: [redImg, blueImg], direction: .horizontal, gapPx: 20, padPx: 20) {
        check(hCol.width == 20 * 2 + 120 + 160 + 20 && hCol.height == 20 * 2 + 80, "横向拼图尺寸应精确为 340×120，实际: \(hCol.width)×\(hCol.height)")
    } else {
        check(false, "横向对比拼图应合成成功")
    }
    if let vCol = ImageCollageStitcher.stitch(images: [redImg, blueImg], direction: .vertical, gapPx: 20, padPx: 20) {
        check(vCol.height > vCol.width, "纵向拼图总高应大于总宽，实际: \(vCol.width)×\(vCol.height)")
    } else {
        check(false, "纵向对比拼图应合成成功")
    }

    // 4) SaveFilenameTemplate：占位符渲染与路径穿越安全清洗
    let refDate = Date(timeIntervalSince1970: 1_700_000_000)
    let customName = SaveFilenameTemplate.render(template: "截屏_{w}x{h}_{date}", date: refDate, pixelWidth: 800, pixelHeight: 600, fileExtension: "png")
    check(customName.hasPrefix("截屏_800x600_") && customName.hasSuffix(".png"), "自定义文件名模板应正确替换宽高与日期: \(customName)")
    let evilName = SaveFilenameTemplate.render(template: "../../etc:passwd/bad*name", date: refDate, fileExtension: "jpg")
    check(!evilName.contains("/") && !evilName.contains("..") && !evilName.contains(":") && evilName.hasSuffix(".jpg"), "非法路径字符必须彻底清洗: \(evilName)")

    // 5) BackdropBeautifier：16:9 / 1:1 比例扩展与文字水印
    let card = makeSolidTestImage(w: 200, h: 200, r: 1, g: 1, b: 1)
    if let wideCard = BackdropBeautifier.apply(
        to: card, style: .oceanAurora, imageScale: 1.0,
        aspectRatio: .ratio16x9, watermarkText: "@MSnip"
    ) {
        let ratio = CGFloat(wideCard.width) / CGFloat(wideCard.height)
        check(abs(ratio - (16.0 / 9.0)) < 0.03, "16:9 衬底画幅比例应精准对齐 1.778，实际: \(ratio)")
    } else {
        check(false, "带 16:9 比例与水印的美化衬底应烘焙成功")
    }
    if let squareCard = BackdropBeautifier.apply(
        to: makeSolidTestImage(w: 300, h: 120, r: 1, g: 1, b: 1),
        style: .cleanStudio, imageScale: 1.0, aspectRatio: .ratio1x1
    ) {
        check(abs(squareCard.width - squareCard.height) <= 2, "1:1 衬底画幅宽高应相等: \(squareCard.width)×\(squareCard.height)")
    } else {
        check(false, "1:1 比例美化衬底应烘焙成功")
    }

    // 6) 贴图自适应屏幕边界 + 8 向边角拖拽等比缩放算法
    let screenVF = CGRect(x: 0, y: 40, width: 1440, height: 830)
    let hugeCollage = CGSize(width: 3600, height: 900)
    let fitted = ImageTransform.fittedPinRect(baseSize: hugeCollage, visibleBounds: screenVF)
    check(fitted.zoom < 1.0 && fitted.frame.width <= screenVF.width && fitted.frame.height <= screenVF.height, "超宽多图拼图贴图应自动缩入屏幕可视区: \(fitted)")
    check(screenVF.contains(fitted.frame), "自适应后的贴图必须完全落在屏幕可见区域内: \(fitted.frame)")
    check(abs((fitted.frame.width / fitted.frame.height) - (hugeCollage.width / hugeCollage.height)) < 0.05, "自适应缩放必须严格保持原图宽高比")

    let smallPin = CGSize(width: 320, height: 200)
    let smallFit = ImageTransform.fittedPinRect(baseSize: smallPin, visibleBounds: screenVF)
    check(abs(smallFit.zoom - 1.0) < 0.001 && smallFit.frame.size == smallPin, "小于屏幕的贴图应保持 100% 原始尺寸")

    let pinBounds = CGRect(x: 0, y: 0, width: 300, height: 200)
    check(PinResizeEdge.hitTest(point: CGPoint(x: 4, y: 196), in: pinBounds) == .topLeft, "左上角应命中 .topLeft")
    check(PinResizeEdge.hitTest(point: CGPoint(x: 296, y: 4), in: pinBounds) == .bottomRight, "右下角应命中 .bottomRight")
    check(PinResizeEdge.hitTest(point: CGPoint(x: 298, y: 100), in: pinBounds) == .right, "右侧边缘应命中 .right")
    check(PinResizeEdge.hitTest(point: CGPoint(x: 150, y: 100), in: pinBounds) == nil, "贴图中心区域不应命中缩放热区")

    let initFrame = CGRect(x: 100, y: 200, width: 400, height: 200)
    let resizedBR = ImageTransform.resizedPinFrame(edge: .bottomRight, initialFrame: initFrame, baseSize: CGSize(width: 400, height: 200), delta: CGPoint(x: 200, y: -100))
    check(abs(resizedBR.zoom - 1.5) < 0.01 && abs(resizedBR.frame.minX - initFrame.minX) < 1 && abs(resizedBR.frame.maxY - initFrame.maxY) < 1, "拖拽右下角放大 1.5× 时左上角锚点必须纹丝不动: \(resizedBR)")

    let resizedTL = ImageTransform.resizedPinFrame(edge: .topLeft, initialFrame: initFrame, baseSize: CGSize(width: 400, height: 200), delta: CGPoint(x: -200, y: 100))
    check(abs(resizedTL.zoom - 1.5) < 0.01 && abs(resizedTL.frame.maxX - initFrame.maxX) < 1 && abs(resizedTL.frame.minY - initFrame.minY) < 1, "拖拽左上角放大 1.5× 时右下角锚点必须纹丝不动: \(resizedTL)")

    // 7) 历史环拼图标记过滤：拼图入库后不得被再次当作原图递归套娃拼接
    let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("msnip-collage-hist-\(UUID().uuidString)", isDirectory: true)
    let ring = CaptureHistoryRing(directoryURL: tmpDir, maxCount: 6)
    ring.record(cgImage: redImg, scaleFactor: 2.0)
    ring.record(cgImage: blueImg, scaleFactor: 2.0)
    ring.record(cgImage: redImg, scaleFactor: 2.0, isCollage: true)
    ring.flushPendingWrites()
    check(ring.entries.count == 3 && ring.entries[0].isCollage, "生成的拼图应保留在最近历史中并标记 isCollage=true")
    check(ring.originalEntries.count == 2 && ring.originalEntries.allSatisfy { !$0.isCollage }, "originalEntries 必须自动排除历史拼图防止套娃")
    try? FileManager.default.removeItem(at: tmpDir)

    // 8) BackdropBeautifier 发光白边导出（0% 零改动，>0% 生成透明外边距柔和发光晕）
    let noGlow = BackdropBeautifier.applyLuminousGlow(to: card, imageScale: 1.0, glowIntensity: 0.0)
    check(noGlow?.width == card.width && noGlow?.height == card.height, "发光强度为 0 时应原样直出不扩边")
    if let glowed = BackdropBeautifier.applyLuminousGlow(to: card, imageScale: 1.0, glowIntensity: 0.6, innerCornerRadiusPt: 8) {
        check(glowed.width > card.width && glowed.height > card.height, "发光边 >0% 应向外扩展透明光晕边距: \(glowed.width)×\(glowed.height)")
        if let data = glowed.dataProvider?.data, let ptr = CFDataGetBytePtr(data) {
            let cornerAlpha = ptr[3]
            check(cornerAlpha < 40, "发光边最外角应柔和衰减至接近透明，实际 alpha=\(cornerAlpha)")
        }
    } else {
        check(false, "发光边烘焙导出不应失败")
    }

    // 9) 标注图形复制粘贴 (⌘C / ⌘V / ⌘D)：独立 UUID、步骤序号自增、边界约束与单步撤销
    var copyDoc = AnnotationDocument()
    let rectAnn = Annotation(payload: .rect(CGRect(x: 20, y: 20, width: 60, height: 40)), style: AnnotationStyle())
    copyDoc.append(rectAnn)
    let pastedIdx = copyDoc.pasteClone(of: rectAnn, offset: CGPoint(x: 16, y: 16), within: CGRect(x: 0, y: 0, width: 120, height: 100))
    check(pastedIdx == 1 && copyDoc.objects.count == 2 && copyDoc.objects[1].id != rectAnn.id, "粘贴副本应生成新 UUID 并追加至文档")
    if case .rect(let r2) = copyDoc.objects[1].payload {
        check(abs(r2.minX - 36) < 0.5 && abs(r2.minY - 36) < 0.5, "粘贴副本应精确偏移 +16pt，实际: \(r2)")
    } else { check(false, "粘贴副本应保持 .rect 载荷") }

    let step1 = Annotation(payload: .step(center: CGPoint(x: 40, y: 40), tail: nil, number: 1), style: AnnotationStyle())
    copyDoc.append(step1)
    let dupStepIdx = copyDoc.duplicate(at: copyDoc.objects.count - 1, offset: CGPoint(x: 20, y: 20), within: CGRect(x: 0, y: 0, width: 200, height: 200))
    if let i = dupStepIdx, case .step(let c2, _, let n2) = copyDoc.objects[i].payload {
        check(n2 == 2 && abs(c2.x - 60) < 0.5, "克隆步骤序号 ① 应自动自增为 ② 且偏移，实际: n=\(n2), c=\(c2)")
    } else { check(false, "克隆步骤序号应返回有效新副本") }
    check(copyDoc.undo() && copyDoc.objects.count == 3, "克隆标注应支持单步 ⌘Z 精确撤回")

    // 10) CLI 命令行参数与 msnip:// URL Scheme 直达解析 + OCR 三模式与暂存架模型
    check(MSnipLaunchCommand.parse(arguments: ["MSnip", "--enter=ocr"]) == .ocr, "--enter=ocr 应解析为 .ocr")
    check(MSnipLaunchCommand.parse(arguments: ["MSnip", "--enter=video"]) == .record, "--enter=video 应解析为 .record")
    check(MSnipLaunchCommand.parse(arguments: ["MSnip", "--shelf"]) == .shelf, "--shelf 应解析为 .shelf")
    check(MSnipLaunchCommand.parse(arguments: ["MSnip", "--silent-ocr"]) == .silentOCR, "--silent-ocr 应解析为 .silentOCR")
    check(MSnipLaunchCommand.parse(url: URL(string: "msnip://silent-ocr")!) == .silentOCR, "msnip://silent-ocr URL Scheme 应解析为 .silentOCR")
    check(MSnipLaunchCommand.parse(url: URL(string: "msnip://shelf")!) == .shelf, "msnip://shelf URL Scheme 应解析为 .shelf")
    check(MSnipLaunchCommand.parse(url: URL(string: "msnip://long")!) == .long, "msnip://long URL Scheme 应解析为 .long")
    check(OCRDefaultPresentation.allCases == [.inPlace, .dualPane, .silentCopy], "OCR 默认方式应完整包含原位/双栏/静默直拷 3 项")
    check(GlobalHotKeyAction.allCases.contains(.toggleShelf), "全局热键应包含顶部暂存架开关")

    let textShelf = ShelfCustomItem(kind: .text, title: "Demo", textContent: "Hello MSnip Shelf")
    if let data = try? JSONEncoder().encode(textShelf),
       let decoded = try? JSONDecoder().decode(ShelfCustomItem.self, from: data) {
        check(decoded == textShelf && decoded.isValidOnDisk, "暂存架文本条目应完整支持 JSON 编解码且有效")
    } else { check(false, "暂存架条目编解码不应失败") }

    // 11) 顶部暂存架闭区间贴顶触发与菜单栏贯通安全保持区
    let scr = CGRect(x: 0, y: 0, width: 1512, height: 982)
    check(ShelfTriggerGeometry.hitsTopCenterTrigger(point: CGPoint(x: 756, y: 982), screenFrame: scr, isDragging: false),
          "光标紧贴物理顶边 y == maxY 时必须 100% 命中顶部暂存架触发区")
    check(!ShelfTriggerGeometry.hitsTopCenterTrigger(point: CGPoint(x: 60, y: 982), screenFrame: scr, isDragging: false),
          "光标在左上角系统菜单区不应误触发顶部暂存架")
    let panelF = CGRect(x: 410, y: 795, width: 692, height: 148) // 刘海屏菜单栏下方 39pt
    let safeF = ShelfTriggerGeometry.safeKeepRect(panelFrame: panelF, screenFrame: scr)
    check(ShelfTriggerGeometry.containsInclusive(safeF, point: CGPoint(x: 756, y: 982)),
          "展开后的安全保持区必须向上贯通至顶边，防止刚弹出即被菜单栏间隙误收")
    let wheelRight = ShelfTriggerGeometry.nextHorizontalScrollX(currentX: 0, maxX: 600, deltaX: 0, deltaY: -3, hasPreciseDeltas: false)
    let wheelClamp = ShelfTriggerGeometry.nextHorizontalScrollX(currentX: 580, maxX: 600, deltaX: 0, deltaY: -10, hasPreciseDeltas: false)
    check(wheelRight > 40 && wheelClamp == 600, "普通鼠标上下滚轮应平滑映射为横向滚动并精确钳位，实际: \(wheelRight), \(wheelClamp)")
    check(HotKeyPreset.optASD.defaultCombo(for: .toggleShelf)?.displayString == "⌥Q"
          && HotKeyPreset.ctrl123.defaultCombo(for: .toggleShelf)?.displayString == "⌃9"
          && HotKeyPreset.fnKeys.defaultCombo(for: .toggleShelf)?.displayString == "F9"
          && HotKeyPreset.ctrlCmd.defaultCombo(for: .toggleShelf)?.displayString == "⌃⌘K",
          "4 套快捷键预设应为顶部暂存架分配零冲突默认键位")

    // 12) 贴图外置悬浮操作条锚定、桥接走廊与遮挡/透明像素穿透判定
    let vf = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let barSz = CGSize(width: 196, height: 28)
    let normalPin = CGRect(x: 200, y: 300, width: 320, height: 200)
    let aboveBar = PinHoverGeometry.hoverBarFrame(anchoringTo: normalPin, barSize: barSz, visibleBounds: vf)
    check(aboveBar.minY == 505 && aboveBar.maxX == 520, "常规贴图悬浮条应右对齐并锚定于贴图上方 5pt 处，实际: \(aboveBar)")
    check(PinHoverGeometry.isPointInHoverZone(point: CGPoint(x: 420, y: 502), pinFrame: normalPin, barFrame: aboveBar, isBarVisible: true),
          "鼠标跨过贴图与悬浮条之间的 5pt 桥接走廊时应保持悬浮态不闪退")
    check(!PinHoverGeometry.isPointInHoverZone(point: CGPoint(x: 210, y: 502), pinFrame: normalPin, barFrame: aboveBar, isBarVisible: true),
          "远离悬浮条横向范围的贴图外空白区不应误入桥接热区")
    check(PinHoverGeometry.isPointInHoverZone(point: CGPoint(x: 520, y: 500), pinFrame: normalPin, barFrame: nil, isBarVisible: false),
          "贴图右上角精确物理边线 (maxX, maxY) 必须闭区间命中")

    let topPin = CGRect(x: 200, y: 660, width: 320, height: 205) // 触顶
    let belowBar = PinHoverGeometry.hoverBarFrame(anchoringTo: topPin, barSize: barSz, visibleBounds: vf)
    check(belowBar.maxY == 655, "贴图贴顶时悬浮条应自动翻至贴图下方 5pt 处，实际: \(belowBar)")
    check(PinHoverGeometry.isPointInHoverZone(point: CGPoint(x: 420, y: 658), pinFrame: topPin, barFrame: belowBar, isBarVisible: true),
          "下置悬浮条的 5pt 桥接走廊同样应无缝衔接")

    check(PinHoverGeometry.isWindowUncovered(pinWindowNumber: 101, topWindowNumber: 101, belowPinWindowNumber: 55),
          "顶层窗口就是贴图自身时应判定未被遮挡")
    check(PinHoverGeometry.isWindowUncovered(pinWindowNumber: 101, topWindowNumber: 55, belowPinWindowNumber: 55),
          "悬停在透明圆角/透明 PNG 区域时 topWin == belowPinWin 应仍判定未被遮挡")
    check(!PinHoverGeometry.isWindowUncovered(pinWindowNumber: 101, topWindowNumber: 202, belowPinWindowNumber: 55),
          "上方存在菜单/Spotlight/另一张贴图时 topWin != belowPinWin 必须正确识别遮挡")

    check(PinResizeEdge.hitTest(point: CGPoint(x: -3, y: 100), in: pinBounds, outerSlop: 4) == .left,
          "贴图外发光轮廓外侧 3pt 内应命中左向缩放热区")
    check(PinResizeEdge.hitTest(point: CGPoint(x: 303, y: 203), in: pinBounds, outerSlop: 4) == .topRight,
          "贴图右上角外侧 3pt 内应命中右上角对角缩放热区")
    check(PinResizeEdge.hitTest(point: CGPoint(x: -6, y: 100), in: pinBounds, outerSlop: 4) == nil,
          "超出外沿 4pt 的柔和光晕区应继续穿透不截获缩放热区")

    // 13) 轻盈晾衣架 3 模式迁移、悬链弧线公式与顶栏秒收热区
    check(TopShelfTriggerMode.allCases == [.topEdgeHover, .manualOnly, .alwaysShown],
          "晾衣架显示方式应包含悬停展开/快捷键切换/常驻显示 3 项")
    if let legacyData = "\"smartDragAndOption\"".data(using: .utf8),
       let migrated = try? JSONDecoder().decode(TopShelfTriggerMode.self, from: legacyData) {
        check(migrated == .topEdgeHover, "旧配置 smartDragAndOption 应平滑迁移至悬停展开")
    } else { check(false, "旧配置字符串应成功解码迁移") }
    let midRopeY = ShelfTriggerGeometry.ropeY(atX: 400, startX: 0, endX: 800, baseY: 10, sag: 8)
    let endRopeY = ShelfTriggerGeometry.ropeY(atX: 0, startX: 0, endX: 800, baseY: 10, sag: 8)
    check(abs(midRopeY - 18.0) < 0.01 && abs(endRopeY - 10.0) < 0.01, "悬链晾衣绳中点应自然下垂 sag，两端回归 baseY")
    check(ShelfTriggerGeometry.hitsTopBarDismissBand(point: CGPoint(x: 120, y: 970), screenFrame: scr),
          "点击屏幕顶部 30pt 菜单栏带应触发晾衣架秒收")
    check(!ShelfTriggerGeometry.hitsTopBarDismissBand(point: CGPoint(x: 120, y: 920), screenFrame: scr),
          "菜单栏下方常规工作区点击不应误判为顶栏秒收")
    let compactW = ShelfTriggerGeometry.dockPanelWidth(itemCount: 2, maxWidth: 1140)
    let fullW = ShelfTriggerGeometry.dockPanelWidth(itemCount: 18, maxWidth: 1140)
    check(compactW < 400 && fullW == 1140, "实用暂存条应按条目数自适应宽窄并上限钳位，实际: \(compactW), \(fullW)")

    // 14) 多图网格拼图、透明底与原生多页 PDF 合并导出
    let c1 = makeSolidTestImage(w: 200, h: 120, r: 0.9, g: 0.2, b: 0.2)
    let c2 = makeSolidTestImage(w: 200, h: 120, r: 0.2, g: 0.7, b: 0.3)
    let c3 = makeSolidTestImage(w: 200, h: 120, r: 0.2, g: 0.4, b: 0.9)
    let gridOpts = CollageOptions(layout: .grid, gridColumns: 2, gapPx: 16, padPx: 20, cornerRadiusPx: 10, background: .transparent)
    if let gridImg = ImageCollageStitcher.stitch(images: [c1, c2, c3], options: gridOpts) {
        check(gridImg.width == 20 * 2 + 200 * 2 + 16 && gridImg.height > 240, "2 列网格拼图尺寸应精准对齐，实际: \(gridImg.width)x\(gridImg.height)")
    } else { check(false, "网格透明底拼图不应失败") }
    let pdfURL = FileManager.default.temporaryDirectory.appendingPathComponent("msnip-test-merge-\(UUID().uuidString).pdf")
    defer { try? FileManager.default.removeItem(at: pdfURL) }
    let pdfOK = ImageCollageStitcher.exportMultiPagePDF(images: [c1, c2, c3], padPx: 16, background: .white, to: pdfURL)
    let pdfBytes = (try? Data(contentsOf: pdfURL)) ?? Data()
    check(pdfOK && pdfBytes.count > 200 && String(data: pdfBytes.prefix(5), encoding: .ascii) == "%PDF-",
          "多图合并 PDF 应输出有效原生 PDF 文件，字节数: \(pdfBytes.count)")
}

private func makeSolidTestImage(w: Int, h: Int, r: CGFloat, g: CGFloat, b: CGFloat) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}
