import CoreGraphics
import Foundation
import MSnipCore

func testWindowCapsuleAndRecordingHUD() {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!

    // 1) 独立窗口透明柔和阴影合成测试（四角全透明 Alpha + 底部阴影半透明过渡 + 中心原色不偏）
    let rawWinCtx = CGContext(
        data: nil, width: 200, height: 140, bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    rawWinCtx.setFillColor(CGColor(srgbRed: 0.96, green: 0.97, blue: 0.99, alpha: 1.0))
    rawWinCtx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 200, height: 140), cornerWidth: 16, cornerHeight: 16, transform: nil))
    rawWinCtx.fillPath()
    let rawWinImg = rawWinCtx.makeImage()!

    if let shadowed = BackdropBeautifier.applyTransparentWindowShadow(to: rawWinImg, imageScale: 2.0) {
        check(shadowed.width == 200 + 136 && shadowed.height == 140 + 48 + 88, "2x 独立窗口阴影画布应包含四周标准阴影边距，实际: \(shadowed.width)×\(shadowed.height)")
        if let cfData = shadowed.dataProvider?.data, let ptr = CFDataGetBytePtr(cfData) {
            let bpr = shadowed.bytesPerRow
            let cornerAlpha = ptr[2 * bpr + 2 * 4 + 3]
            let centerOffset = (shadowed.height / 2) * bpr + (shadowed.width / 2) * 4
            let centerAlpha = ptr[centerOffset + 3]
            let bottomShadowY = shadowed.height - 76
            let bottomShadowAlpha = ptr[bottomShadowY * bpr + (shadowed.width / 2) * 4 + 3]
            check(cornerAlpha == 0, "独立窗口导出 PNG 最外角必须为全透明 Alpha=0，实际: \(cornerAlpha)")
            check(centerAlpha == 255, "窗口中心内容区域应保持完全不透明 Alpha=255")
            check(bottomShadowAlpha > 8 && bottomShadowAlpha < 180, "窗口下边缘外侧应呈现半透明柔和阴影过渡，实际 Alpha: \(bottomShadowAlpha)")
        }
    } else {
        check(false, "applyTransparentWindowShadow 不应返回 nil")
    }

    // 2) 圆角胶囊底色文字标注（排版加宽、Codable 兼容与烘焙底色验证）
    let plainSz = AnnotationRenderer.measureText("重点批注", fontSize: 18, capsule: false)
    let capSz = AnnotationRenderer.measureText("重点批注", fontSize: 18, capsule: true)
    check(capSz.width > plainSz.width + 8 && capSz.height > plainSz.height + 4, "胶囊底色文字应包含均衡圆角内边距")

    let darkBgCtx = CGContext(
        data: nil, width: 320, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    darkBgCtx.setFillColor(CGColor(srgbRed: 0.12, green: 0.13, blue: 0.16, alpha: 1.0))
    darkBgCtx.fill(CGRect(x: 0, y: 0, width: 320, height: 160))
    let darkBg = darkBgCtx.makeImage()!
    let bgSampler = PixelSampler(cgImage: darkBg)

    let capStyle = AnnotationStyle(color: RGBAColor(255, 59, 48), lineWidth: 3, fontSize: 18, textCapsule: true)
    let capNote = Annotation(
        payload: .text(origin: CGPoint(x: 24, y: 20), content: "修复此处偏移", measuredSize: capSz),
        style: capStyle
    )
    if let bakedCap = AnnotationRenderer.bakeExportImage(
        sampler: bgSampler,
        selection: CGRect(x: 0, y: 0, width: 160, height: 80),
        imageScale: 2.0,
        annotations: [capNote]
    ) {
        let outSampler = PixelSampler(cgImage: bakedCap)
        // 采样胶囊左内侧边缘纯底色区 (28pt, 32pt) -> (56px, 64px)
        let pillEdge = outSampler.sampleRGB(px: 54, py: 52)
        check(pillEdge.0 > 200 && pillEdge.2 < 90, "胶囊文字标签背景应渲染为鲜明预设红底，实际: \(pillEdge)")
    } else {
        check(false, "胶囊底色文字烘焙不应失败")
    }

    // 3) RecordingOverlayCompositor 录屏点击波纹与快捷键胶囊叠加（含空闲零拷贝直通校验）
    let compositor = RecordingOverlayCompositor(isEnabled: true)
    let idleOut = compositor.compositeIfNeeded(onto: darkBg, at: 1.0)
    check(idleOut === darkBg, "无活跃点击或快捷键时录屏合成器应 O(1) 零拷贝直通原帧对象")

    compositor.recordClick(normalizedX: 0.5, normalizedY: 0.5, isRightClick: false, at: 2.0)
    compositor.recordKeyBadge("⌘C", at: 2.0)
    let activeOut = compositor.compositeIfNeeded(onto: darkBg, at: 2.15)
    check(activeOut !== darkBg && activeOut.width == darkBg.width, "存在点击波纹与按键角标时应合成叠加帧")

    // 验证底部居中快捷键角标与波纹过期自动消退
    let expiredOut = compositor.compositeIfNeeded(onto: darkBg, at: 4.0)
    check(expiredOut === darkBg, "点击波纹与按键角标超时消退后应恢复零拷贝直通")
}
