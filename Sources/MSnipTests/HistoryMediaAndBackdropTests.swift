import AppKit
import AVFoundation
import Carbon
import CoreGraphics
import Foundation
import ImageIO
import MSnipCore

func testMilestone3To5Features() {
    // 1) KeyCombo 显示文案、菜单修饰掩码与 JSON 编解码
    let combo = KeyCombo(keyCode: UInt32(kVK_ANSI_X), carbonModifiers: UInt32(cmdKey | shiftKey))
    check(combo.displayString == "⇧⌘X", "KeyCombo 应输出标准修饰符顺序文案，实际: \(combo.displayString)")
    check(combo.menuKeyEquivalent == "x", "菜单等效键应为小写字母 x")
    check(combo.cocoaModifierMask.contains(.command) && combo.cocoaModifierMask.contains(.shift), "应正确还原 Cocoa 修饰键掩码")
    if let data = try? JSONEncoder().encode(combo),
       let decoded = try? JSONDecoder().decode(KeyCombo.self, from: data) {
        check(decoded == combo, "KeyCombo JSON 持久化往返应完全一致")
    } else {
        check(false, "KeyCombo 编解码不应失败")
    }

    let f3 = KeyCombo(keyCode: UInt32(kVK_F3), carbonModifiers: 0)
    check(f3.displayString == "F3", "功能键 F3 应直接显示 F3")

    // 2) CaptureHistoryRing 有界 15 张环形淘汰、磁盘文件回收与重启索引恢复
    let tempHistDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("MSnipTestHist-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempHistDir) }

    let ring = CaptureHistoryRing(directoryURL: tempHistDir, maxCount: 15)
    var recordedEntries: [CaptureHistoryEntry] = []
    for i in 0..<18 {
        let frame = makeSolidFrame(width: 64 + i * 2, height: 48, r: Double(i * 12) / 255.0, g: 0.4, b: 0.8)
        if let entry = ring.record(cgImage: frame, scaleFactor: 2.0) {
            recordedEntries.append(entry)
        }
    }
    check(ring.entries.count == 15, "超出 15 张上限后内存列表应严格保持 15 条，实际: \(ring.entries.count)")
    check(ring.entries.first?.id == recordedEntries.last?.id, "最新一张截图应位于历史队首")
    ring.flushPendingWrites()
    for evicted in recordedEntries.prefix(3) {
        let path = tempHistDir.appendingPathComponent(evicted.fileName).path
        check(!FileManager.default.fileExists(atPath: path), "被淘汰的最早 3 张 PNG 文件必须从磁盘清理")
    }

    // 模拟应用重启重新加载历史目录，并校验缩略图绝不常驻全尺寸位图内存
    let reloaded = CaptureHistoryRing(directoryURL: tempHistDir, maxCount: 15)
    check(reloaded.entries.count == 15 && reloaded.entries.first?.pixelWidth == 64 + 17 * 2, "重启加载应完整恢复最近 15 条索引")
    check(reloaded.loadCGImage(for: reloaded.entries[0])?.width == 64 + 17 * 2, "应能按需从磁盘解码原尺寸 CGImage")
    if let thumb = reloaded.menuThumbnail(for: reloaded.entries[0]) {
        let rep = thumb.representations.first
        check((rep?.pixelsWide ?? 999) <= 64 && (rep?.pixelsHigh ?? 999) <= 64, "菜单栏缩略图必须为 56×36 轻量独立小位图，绝不驻留原尺寸大图")
    } else {
        check(false, "应能生成菜单栏圆角缩略图")
    }
    reloaded.clearAll()
    check(reloaded.entries.isEmpty, "清空历史后列表应为空")

    // 2b) ClipboardImagePromise 延迟剪贴板提供器：按需兑现 PNG 与 Retina 逻辑尺寸 NSImage
    let testPB = NSPasteboard.withUniqueName()
    defer { testPB.releaseGlobally() }
    let retinaShot = makeSolidFrame(width: 240, height: 140, r: 0.18, g: 0.62, b: 0.95)
    _ = ClipboardImagePromise.write(cgImage: retinaShot, scaleFactor: 2.0, to: testPB)
    if let pngBytes = testPB.data(forType: .png),
       let decodedRep = NSBitmapImageRep(data: pngBytes) {
        check(decodedRep.pixelsWide == 240 && decodedRep.pixelsHigh == 140, "延迟剪贴板按需编码的 PNG 应保留完整 240×140 物理像素")
    } else {
        check(false, "外部应用请求 .png 时 ClipboardImagePromise 应按需编码返回有效 PNG 数据")
    }
    if let pastedImages = testPB.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
       let pastedFirst = pastedImages.first {
        check(abs(pastedFirst.size.width - 120) < 0.5 && abs(pastedFirst.size.height - 70) < 0.5, "延迟剪贴板兑现的 NSImage 应保留 @2x 逻辑点尺寸 120×70")
    } else {
        check(false, "外部应用请求 NSImage 时应能成功兑现")
    }
    AnnotationRenderer.purgeCaches()

    // 3) MediaClipEncoder 零依赖原生 GIF 与 H.264 MP4 动图合成测试
    let clipDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("MSnipTestClips-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: clipDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: clipDir) }

    let gifURL = clipDir.appendingPathComponent("sample.gif")
    let gifEnc = MediaClipEncoder(format: .gif, outputURL: gifURL)
    for i in 0..<6 {
        let img = makeSolidFrame(width: 160, height: 120, r: Double(i) * 0.16, g: 0.5, b: 0.9)
        gifEnc.appendFrame(img, at: Double(i) * 0.12)
    }
    check(FileManager.default.fileExists(atPath: gifEnc.spoolFileURL.path), "GIF 录制期应将帧数据流式写入磁盘暂存池而非堆积内存")
    let finishedGIF = runAsyncSync { await gifEnc.finish(finalTimestamp: 0.80) }
    check(finishedGIF == gifURL && FileManager.default.fileExists(atPath: gifURL.path), "GIF 编码器应生成有效 .gif 文件")
    check(!FileManager.default.fileExists(atPath: gifEnc.spoolFileURL.path), "GIF 合成完成后磁盘暂存池文件必须立即自动清理")
    if let src = CGImageSourceCreateWithURL(gifURL as CFURL, nil) {
        check(CGImageSourceGetCount(src) == 6, "合成的动画 GIF 应包含完整 6 帧，实际: \(CGImageSourceGetCount(src))")
    } else {
        check(false, "ImageIO 应能读取生成的 GIF")
    }

    // 验证超宽大图自动限幅 (<=880px) 与取消录制时磁盘暂存清理
    let largeGifURL = clipDir.appendingPathComponent("large.gif")
    let largeEnc = MediaClipEncoder(format: .gif, outputURL: largeGifURL)
    largeEnc.appendFrame(makeSolidFrame(width: 1200, height: 600, r: 0.9, g: 0.3, b: 0.2), at: 0.0)
    let finishedLargeGIF = runAsyncSync { await largeEnc.finish(finalTimestamp: 0.25) }
    if let url = finishedLargeGIF, let src = CGImageSourceCreateWithURL(url as CFURL, nil),
       let firstCG = CGImageSourceCreateImageAtIndex(src, 0, nil) {
        check(firstCG.width == 880 && firstCG.height == 440, "超大尺寸 GIF 帧应自动等比缩放到 880px 长边，实际: \(firstCG.width)×\(firstCG.height)")
    } else {
        check(false, "大图降采样 GIF 应成功导出")
    }

    let cancelGifURL = clipDir.appendingPathComponent("cancelled.gif")
    let cancelEnc = MediaClipEncoder(format: .gif, outputURL: cancelGifURL)
    cancelEnc.appendFrame(makeSolidFrame(width: 120, height: 90, r: 0.2, g: 0.8, b: 0.4), at: 0.0)
    cancelEnc.cancel()
    check(!FileManager.default.fileExists(atPath: cancelEnc.spoolFileURL.path) && !FileManager.default.fileExists(atPath: cancelGifURL.path), "取消录制后暂存文件与目标文件均应彻底移除")

    let mp4URL = clipDir.appendingPathComponent("sample.mp4")
    let mp4Enc = MediaClipEncoder(format: .mp4, outputURL: mp4URL)
    for i in 0..<6 {
        let img = makeSolidFrame(width: 160, height: 120, r: 0.2, g: Double(i) * 0.15, b: 0.8)
        mp4Enc.appendFrame(img, at: Double(i) * 0.10)
    }
    let finishedMP4 = runAsyncSync { await mp4Enc.finish(finalTimestamp: 0.70) }
    check(finishedMP4 == mp4URL && FileManager.default.fileExists(atPath: mp4URL.path), "MP4 编码器应生成有效 .mp4 文件")
    let asset = AVURLAsset(url: mp4URL)
    let tracks = asset.tracks(withMediaType: .video)
    check(tracks.count == 1 && tracks[0].naturalSize == CGSize(width: 160, height: 120), "H.264 MP4 视频轨分辨率应精准为 160×120")

    // 4) BackdropBeautifier 一键美观背景衬底（渐变留白 + 圆角 + 悬浮阴影）测试
    check(BackdropStyle.none.next == .oceanAurora && BackdropStyle.noirCarbon.next == .none, "衬底主题循环顺序应闭环")
    let whiteCard = makeSolidFrame(width: 160, height: 120, r: 1.0, g: 1.0, b: 1.0)
    let sampler = PixelSampler(cgImage: whiteCard)
    let beautified = AnnotationRenderer.bakeExportImage(
        sampler: sampler,
        selection: CGRect(x: 0, y: 0, width: 80, height: 60),
        imageScale: 2.0,
        annotations: [],
        cornerRadiusPt: 0,
        backdropStyle: .oceanAurora
    )
    check(beautified != nil, "启用极光蓝紫衬底后应成功烘焙导出")
    if let bImg = beautified {
        // 80×60 pt 最小边距 32pt -> @2x 下四周各扩 64px => 288 × 248 px
        check(bImg.width == 288 && bImg.height == 248, "2x 渐变衬底尺寸应包含均衡留白边距 (288×248)，实际: \(bImg.width)×\(bImg.height)")
        let bSampler = PixelSampler(cgImage: bImg)
        let cornerGrad = bSampler.sampleRGB(px: 6, py: 6)
        let centerWhite = bSampler.sampleRGB(px: bImg.width / 2, py: bImg.height / 2)
        check(cornerGrad.2 > 150 && cornerGrad.1 < 120, "外圈画布角部应呈现极光蓝紫渐变色: \(cornerGrad)")
        check(centerWhite.0 > 250 && centerWhite.1 > 250 && centerWhite.2 > 250, "衬底中心截图卡片区域应保持纯白不偏色: \(centerWhite)")
    }

    // 5) CaptureImageExporter 多格式 (PNG/JPG/HEIC/AVIF/BMP/TIFF) 运行时探测与 Retina 1× 缩放回归单测
    let src2x = makeSolidFrame(width: 160, height: 120, r: 0.12, g: 0.48, b: 0.92)
    let supportedFmts = CaptureExportFormat.supportedFormats
    check(
        supportedFmts.contains(.png) && supportedFmts.contains(.jpeg) && supportedFmts.contains(.bmp) && supportedFmts.contains(.tiff),
        "所有 macOS 12+ 系统均应原生支持 PNG / JPG / BMP / TIFF 编码"
    )
    for fmt in supportedFmts {
        let encoded = CaptureImageExporter.encodeWithFallback(cgImage: src2x, scaleFactor: 2.0, format: fmt, exportAt1x: false)
        check(encoded != nil && encoded?.actualFormat == fmt && (encoded?.data.count ?? 0) > 40, "当前系统已声明支持的 \(fmt.segmentTitle) 格式应无依赖编码成功")
    }
    check(
        CaptureExportFormat.from(fileExtension: "jpeg") == .jpeg
            && CaptureExportFormat.from(fileExtension: "AVIF") == .avif
            && CaptureExportFormat.from(fileExtension: "tif") == .tiff
            && CaptureExportFormat.from(fileExtension: "bmp") == .bmp,
        "扩展名反查应准确识别各图片保存格式"
    )
    let jpgData = CaptureImageExporter.encode(cgImage: src2x, scaleFactor: 2.0, format: .jpeg, exportAt1x: false)
    let scaled1x = CaptureImageExporter.prepareImage(src2x, scaleFactor: 2.0, exportAt1x: true)
    check(
        scaled1x.image.width == 80 && scaled1x.image.height == 60 && scaled1x.effectiveScale == 1.0,
        "开启 1× 导出后 2x Retina 图像应精准缩放至逻辑点尺寸 (80×60 @1x)"
    )
    if let jpg = jpgData, let src = CGImageSourceCreateWithData(jpg as CFData, nil), let dec = CGImageSourceCreateImageAtIndex(src, 0, nil) {
        check(dec.width == 160 && dec.height == 120, "JPEG 编码解码应保持精确像素尺寸")
    }

    // 6) ClipboardTerminalAdapter 终端/访达动态剪贴板投影与惰性临时路径单测
    check(
        ClipboardTerminalAdapter.projectionMode(forBundleID: "com.mitchellh.ghostty", adaptiveEnabled: true) == .terminalImageAndPath
            && ClipboardTerminalAdapter.projectionMode(forBundleID: "com.googlecode.iterm2", adaptiveEnabled: true) == .terminalImageAndPath
            && ClipboardTerminalAdapter.projectionMode(forBundleID: "com.apple.Terminal", adaptiveEnabled: true) == .terminalImageAndPath
            && ClipboardTerminalAdapter.projectionMode(forBundleID: "dev.warp.Warp-Stable", adaptiveEnabled: true) == .terminalImageAndPath
            && ClipboardTerminalAdapter.projectionMode(forBundleID: "com.apple.finder", adaptiveEnabled: true) == .imageAndFileURL
            && ClipboardTerminalAdapter.projectionMode(forBundleID: "com.google.Chrome", adaptiveEnabled: true) == .imageOnly
            && ClipboardTerminalAdapter.projectionMode(forBundleID: "com.mitchellh.ghostty", adaptiveEnabled: false) == .imageOnly,
        "剪贴板投影策略应精准区分终端、访达、普通应用与总开关关闭态"
    )
    let termPB = NSPasteboard(name: NSPasteboard.Name("MSnipTermAdaptTest-\(UUID().uuidString)"))
    _ = ClipboardImagePromise.write(cgImage: src2x, scaleFactor: 2.0, to: termPB, mode: .terminalImageAndPath, transient: true)
    let termPNG = termPB.data(forType: .png)
    let termPath = termPB.string(forType: .string)
    let termURL = (termPB.readObjects(forClasses: [NSURL.self])?.first as? URL)
    check(
        (termPNG?.count ?? 0) > 40 && termPath != nil && termURL?.path == termPath && FileManager.default.fileExists(atPath: termPath ?? ""),
        "终端投影模式应同时提供无损 PNG、fileURL 与真实落盘的无空格临时 PNG 路径"
    )
    if let p = termPath { try? FileManager.default.removeItem(atPath: p) }

    // 7) 编辑器 Bundle 识别、AX 焦点语义分类与消费探针单测
    check(
        ClipboardTerminalAdapter.isEditorBundleID("com.microsoft.VSCode")
            && ClipboardTerminalAdapter.isEditorBundleID("com.todesktop.230313mzl4w4u92")
            && ClipboardTerminalAdapter.isEditorBundleID("dev.zed.Zed")
            && ClipboardTerminalAdapter.isEditorBundleID("com.jetbrains.intellij")
            && ClipboardTerminalAdapter.isEditorBundleID("com.google.antigravity")
            && !ClipboardTerminalAdapter.isEditorBundleID("com.google.Chrome")
            && !ClipboardTerminalAdapter.isEditorBundleID("com.mitchellh.ghostty"),
        "编辑器 Bundle ID 识别应覆盖主流 IDE 且绝不误伤浏览器或独立终端"
    )
    check(
        ClipboardTerminalAdapter.projectionMode(forBundleID: "com.microsoft.VSCode", adaptiveEnabled: true, editorFocus: .terminal) == .terminalImageAndPath
            && ClipboardTerminalAdapter.projectionMode(forBundleID: "com.microsoft.VSCode", adaptiveEnabled: true, editorFocus: .nonTerminalInput) == .imageOnly
            && ClipboardTerminalAdapter.projectionMode(forBundleID: "com.microsoft.VSCode", adaptiveEnabled: true, editorFocus: .indeterminate) == .imageOnly,
        "编辑器在焦点明确命中终端时应立即投影路径，编辑区与不透明态应先保持纯净图像"
    )
    let xtermChain = [AXNodeSnapshot(role: "AXTextArea", domClasses: ["xterm-helper-textarea"], description: "Terminal 1, zsh")]
    let zhTermChain = [AXNodeSnapshot(role: "AXTextArea", description: "终端 1, zsh")]
    let jbTermChain = [
        AXNodeSnapshot(role: "AXTextArea"),
        AXNodeSnapshot(role: "AXScrollArea"),
        AXNodeSnapshot(role: "AXGroup", title: "Terminal")
    ]
    let xcodeConsoleChain = [AXNodeSnapshot(role: "AXTextArea", identifier: "IDEConsoleTextView", description: "Debug Console")]
    let codeFilenameTrap = [AXNodeSnapshot(role: "AXTextArea", domClasses: ["inputarea", "monaco-mouse-cursor-text"], description: "ClipboardTerminalAdapter.swift")]
    let aiChatChain = [AXNodeSnapshot(role: "AXTextArea", domClasses: ["aislash-editor-input"], description: "Ask anything")]
    let opaqueWebChain = [AXNodeSnapshot(role: "AXWebArea")]
    check(
        EditorTerminalFocusDetector.classifyFocusChain(xtermChain) == .terminal
            && EditorTerminalFocusDetector.classifyFocusChain(zhTermChain) == .terminal
            && EditorTerminalFocusDetector.classifyFocusChain(jbTermChain) == .terminal
            && EditorTerminalFocusDetector.classifyFocusChain(xcodeConsoleChain) == .terminal
            && EditorTerminalFocusDetector.classifyFocusChain(codeFilenameTrap) == .nonTerminalInput
            && EditorTerminalFocusDetector.classifyFocusChain(aiChatChain) == .nonTerminalInput
            && EditorTerminalFocusDetector.classifyFocusChain(opaqueWebChain) == .indeterminate
            && EditorTerminalFocusDetector.classifyFocusChain([]) == .indeterminate,
        "编辑器 AX 焦点语义分类应精准区分终端、代码文件名陷阱、AI 聊天框与不透明节点"
    )
    let probePB = NSPasteboard(name: NSPasteboard.Name("MSnipProbeTest-\(UUID().uuidString)"))
    let probeFired = AsyncResultBox<Bool>()
    let probe = ClipboardConsumptionProbe { probeFired.value = true }
    _ = ClipboardImagePromise.write(cgImage: src2x, scaleFactor: 2.0, to: probePB, mode: .imageOnly, transient: true, probe: probe)
    check(!probe.wasImageRequested && probeFired.value == nil, "目标应用未读取图像前消费探针应保持未触发状态")
    _ = probePB.data(forType: .png)
    check(probe.wasImageRequested && probeFired.value == true, "目标应用读取 PNG 后消费探针应立即感知并回调")

    // 8) 录屏交互回显快速探测 hasActiveVisuals 与 MP4 零拷贝 CVPixelBuffer 直通单测
    let comp = RecordingOverlayCompositor(isEnabled: true)
    check(!comp.hasActiveVisuals(at: 1.0), "无交互事件时 hasActiveVisuals 应返回 false 以启用零拷贝直通")
    comp.recordClick(normalizedX: 0.5, normalizedY: 0.5, isRightClick: false, at: 1.0)
    check(comp.hasActiveVisuals(at: 1.1) && !comp.hasActiveVisuals(at: 2.0), "点击波纹应在有效期内返回 true、过期后回落为 false")
    comp.recordKeyBadge("⌘C", at: 2.5)
    check(comp.hasActiveVisuals(at: 3.0) && !comp.hasActiveVisuals(at: 4.5), "按键角标应在有效期内返回 true、过期后回落为 false")
    comp.isEnabled = false
    check(!comp.hasActiveVisuals(at: 3.0), "关闭交互回显后 hasActiveVisuals 应立即返回 false")

    let zcURL = clipDir.appendingPathComponent("zerocopy.mp4")
    let zcEnc = MediaClipEncoder(format: .mp4, outputURL: zcURL)
    var tinyPB: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 33, 33, kCVPixelFormatType_32BGRA, nil, &tinyPB)
    if let tinyPB { check(!zcEnc.appendPixelBuffer(tinyPB, at: 0.0), "奇数/过小 PixelBuffer 应返回 false 以便回退 CGImage 路径") }
    var bgraPB: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 160, 120, kCVPixelFormatType_32BGRA, nil, &bgraPB)
    if let bgraPB {
        for i in 0..<4 { check(zcEnc.appendPixelBuffer(bgraPB, at: Double(i) * 0.08), "偶数 32BGRA PixelBuffer 应零拷贝直通成功") }
    }
    let finishedZC = runAsyncSync { await zcEnc.finish(finalTimestamp: 0.45) }
    check(finishedZC == zcURL && FileManager.default.fileExists(atPath: zcURL.path), "零拷贝 CVPixelBuffer 直通应成功封装有效 MP4")
}

private func makeSolidFrame(width: Int, height: Int, r: Double, g: Double, b: Double) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1.0))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

private final class AsyncResultBox<T>: @unchecked Sendable {
    var value: T?
}

private func runAsyncSync<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = AsyncResultBox<T>()
    Task.detached {
        box.value = await operation()
        sem.signal()
    }
    sem.wait()
    return box.value!
}
