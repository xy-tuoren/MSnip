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
