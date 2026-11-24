import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 覆盖层的标注草稿构建、取色/坐标复制、1px 边缘微调与导出烘焙扩展
extension OverlayView {
    enum FinishMode: Equatable { case copy, copyWithPath, save, quickSave, saveToFolder(String), pin, extractText, recognizeLatex, translateWindow }

    func currentExportableImage(for targetRect: CGRect, plainForOCR: Bool) -> CGImage? {
        if !plainForOCR, let translated = inPlaceTranslateView?.translatedImage {
            if backdropStyle != .none {
                return BackdropBeautifier.apply(
                    to: translated,
                    style: backdropStyle,
                    imageScale: snapshot.scaleFactor,
                    innerCornerRadiusPt: cornerRadiusPt
                )
            }
            if cornerRadiusPt > 0.5 {
                let rPx = min(cornerRadiusPt * snapshot.scaleFactor, CGFloat(min(translated.width, translated.height)) * 0.5)
                let cs = (translated.colorSpace?.model == .rgb && translated.colorSpace?.supportsOutput == true)
                    ? translated.colorSpace!
                    : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
                if let ctx = CGContext(
                    data: nil, width: translated.width, height: translated.height,
                    bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) {
                    let rect = CGRect(x: 0, y: 0, width: translated.width, height: translated.height)
                    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rPx, cornerHeight: rPx, transform: nil))
                    ctx.clip()
                    ctx.draw(translated, in: rect)
                    if let clipped = ctx.makeImage() { return clipped }
                }
            }
            return translated
        }
        return AnnotationRenderer.bakeExportImage(
            sampler: snapshot.sampler,
            selection: targetRect,
            imageScale: snapshot.scaleFactor,
            annotations: doc.objects,
            cornerRadiusPt: plainForOCR ? 0 : cornerRadiusPt,
            backdropStyle: plainForOCR ? .none : backdropStyle
        )
    }

    func cycleColorFormat() {
        colorCopyFormat = colorCopyFormat.next
        onPrefsChanged?(colorCopyFormat, showShortcutTips)
    }

    func copyColorAtCursorAndFinish() {
        guard let sample = samplePixelAtCursor() else { return }
        let formatted = sample.color.formatted(as: colorCopyFormat)
        onFinishCopyColor?(formatted, sample.color, NSEvent.mouseLocation)
    }

    func copyCoordinatesAtCursorAndFinish() {
        guard let sample = samplePixelAtCursor() else { return }
        let coord = formattedCoordinateAtCursor(px: sample.px, py: sample.py)
        onFinishCopyText?(coord.copyValue, NSEvent.mouseLocation)
    }

    func exportAndFinish(mode: FinishMode) {
        commitTextEditing()
        let isPlainOCR = (mode == .extractText || mode == .recognizeLatex || mode == .translateWindow)
        guard let targetRect = selection ?? hoveredAutoRect,
              targetRect.width >= 2, targetRect.height >= 2,
              let baked = currentExportableImage(for: targetRect, plainForOCR: isPlainOCR) else { return }

        switch mode {
        case .copy:            onFinishCopy?(baked, snapshot.scaleFactor, targetRect)
        case .copyWithPath:    onFinishCopyWithPath?(baked, snapshot.scaleFactor, targetRect)
        case .save:              onFinishSave?(baked, snapshot.scaleFactor, targetRect)
        case .quickSave:         onQuickSaveInPlace?(baked, snapshot.scaleFactor, targetRect)
        case .saveToFolder(let d): onFinishSaveToFolder?(baked, snapshot.scaleFactor, d, targetRect)
        case .pin:
            let s = max(1.0, snapshot.scaleFactor)
            let snappedOrigin = CGPoint(x: round(targetRect.minX * s) / s, y: round(targetRect.minY * s) / s)
            onFinishPin?(baked, snapshot.scaleFactor, snappedOrigin, snapshot.screen, targetRect)
        case .extractText:     onFinishExtractText?(baked, snapshot.scaleFactor, snapshot.screen, targetRect)
        case .recognizeLatex:  onFinishRecognizeLatex?(baked, snapshot.scaleFactor, snapshot.screen, targetRect)
        case .translateWindow: onFinishTranslateWindow?(baked, snapshot.scaleFactor, snapshot.screen, targetRect)
        }
    }

    /// 识别当前光标或选区中心命中的顶层窗口，一键执行独立窗口纯净透明阴影截图
    func captureCurrentWindowAndFinish(pin: Bool) {
        commitTextEditing()
        let probe = selection.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? lastMousePoint
            ?? CGPoint(x: bounds.midX, y: bounds.midY)
        guard let hit = regionDetector.topWindow(at: probe, in: snapshot) else {
            ToastHUD.show(message: "当前位置未命中独立应用窗口，请将鼠标移至目标窗口上再按 F 或 ⇧↩")
            return
        }
        onFinishIsolatedWindow?(
            hit.windowID,
            snapshot.scaleFactor,
            backdropStyle,
            pin,
            hit.localRect.origin,
            snapshot.screen
        )
    }

    func makeDraft(tool: ToolKind, from a: CGPoint, to b: CGPoint, shift: Bool) -> Annotation {
        let endForBox = shift ? Geometry.squareConstrainedEnd(from: a, to: b) : b
        let endForLine = shift ? Geometry.angleSnappedEnd(from: a, to: b) : b
        let payload: AnnotationPayload
        switch tool {
        case .rect:
            payload = .rect(Geometry.normalizedRect(from: a, to: endForBox))
        case .ellipse:
            payload = .ellipse(Geometry.normalizedRect(from: a, to: endForBox))
        case .mosaic:
            payload = .mosaic(Geometry.normalizedRect(from: a, to: b))
        case .gaussianBlur:
            payload = .gaussianBlur(Geometry.normalizedRect(from: a, to: b))
        case .arrow:
            payload = .arrow(from: a, to: endForLine)
        case .line:
            payload = .line(from: a, to: endForLine)
        case .pen:
            payload = .pen(points: [a, b])
        case .highlighter:
            payload = .highlighter(points: [a, endForLine])
        case .step:
            let stepNum: Int
            if let existing = draftAnnotation, case .step(_, _, let n) = existing.payload {
                stepNum = n
            } else {
                stepNum = doc.nextStepNumber()
            }
            let dist = hypot(endForLine.x - a.x, endForLine.y - a.y)
            let tail = dist >= (style.stepBadgeRadius + 6.0) ? endForLine : nil
            payload = .step(center: a, tail: tail, number: stepNum)
        case .text, .eraser:
            payload = .text(origin: a, content: "", measuredSize: .zero)
        }
        return Annotation(payload: payload, style: style)
    }

    // MARK: - Cursor 1px Warp & PixPin Edge Fine-Tuning

    func warpCursorByPixels(dx: Int, dy: Int) {
        let stepPt = 1.0 / max(1.0, snapshot.scaleFactor)
        let curLocal = lastMousePoint ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let nextLocal = CGPoint(
            x: min(max(0, curLocal.x + CGFloat(dx) * stepPt), bounds.width - stepPt),
            y: min(max(0, curLocal.y + CGFloat(dy) * stepPt), bounds.height - stepPt)
        )
        lastMousePoint = nextLocal

        if let primaryH = NSScreen.screens.first?.frame.height {
            let screenOriginTopY = primaryH - snapshot.screen.frame.maxY
            let globalQuartz = CGPoint(x: snapshot.screen.frame.minX + nextLocal.x, y: screenOriginTopY + nextLocal.y)
            CGWarpMouseCursorPosition(globalQuartz)
        }

        if selection == nil {
            updateAutoSnap(at: nextLocal)
        }
        invalidateMagnifierMove(from: curLocal, to: nextLocal)
    }

    /// 统一同步画笔粗细、文字字号、马赛克/毛玻璃颗粒大小与二级进度条读数
    func applyAnnotationSize(_ rawWidth: CGFloat) {
        let w = min(ToolbarSubbarView.maxStroke, max(ToolbarSubbarView.minStroke, rawWidth.rounded()))
        style.lineWidth = w
        style.fontSize = min(64.0, max(12.0, round(10.0 + w * 3.0)))
        style.mosaicBlockSize = min(36.0, max(5.0, round(4.0 + w * 1.8)))
        toolbar.lineWidth = w
        subbar.lineWidth = w
        applyTextFieldVisualStyle()
        if let selIdx = selectedObjectIndex {
            doc.modifyWithHistory(at: selIdx) {
                $0.style.lineWidth = style.lineWidth
                $0.style.fontSize = style.fontSize
                $0.style.mosaicBlockSize = style.mosaicBlockSize
            }
        }
        onStyleChanged?(colorIndex, style.lineWidth)
        needsDisplay = true
    }

    func adjustAnnotationSize(by delta: CGFloat) {
        applyAnnotationSize(style.lineWidth + delta)
    }

    func handleArrowKey(dx: CGFloat, dy: CGFloat, ctrl: Bool, shift: Bool) {
        if let idx = selectedObjectIndex {
            let step: CGFloat = shift ? 5.0 : 1.0
            doc.modifyWithHistory(at: idx) { $0.translate(dx: dx * step, dy: dy * step) }
            updateToolbarLayout()
            needsDisplay = true
            return
        }

        // 激活任意标注工具时（画笔/马赛克/毛玻璃/矩形/箭头/文字/序号），方向键 ↑/→ 调大、↓/← 缩小（按住 ⇧ 加速）
        if selection != nil, activeTool != nil, !ctrl {
            let step: CGFloat = shift ? 3.0 : 1.0
            let dir: CGFloat = (dy < 0 || dx > 0) ? 1.0 : -1.0
            adjustAnnotationSize(by: dir * step)
            return
        }

        guard var sel = selection else {
            let mul = shift ? 5 : 1
            warpCursorByPixels(dx: Int(dx) * mul, dy: Int(dy) * mul)
            return
        }

        if ctrl {
            if dx < 0 { sel.origin.x -= 1; sel.size.width += 1 }
            if dx > 0 { sel.size.width += 1 }
            if dy < 0 { sel.origin.y -= 1; sel.size.height += 1 }
            if dy > 0 { sel.size.height += 1 }
            selection = sel.intersection(bounds)
        } else if shift {
            if dx < 0, sel.width > 8 { sel.size.width -= 1 }
            if dx > 0, sel.width > 8 { sel.origin.x += 1; sel.size.width -= 1 }
            if dy < 0, sel.height > 8 { sel.size.height -= 1 }
            if dy > 0, sel.height > 8 { sel.origin.y += 1; sel.size.height -= 1 }
            selection = sel.intersection(bounds)
        } else {
            let clamped = Geometry.clampRect(sel.offsetBy(dx: dx, dy: dy), within: bounds)
            let actualDx = clamped.minX - sel.minX
            let actualDy = clamped.minY - sel.minY
            if abs(actualDx) > 0.01 || abs(actualDy) > 0.01 {
                for i in doc.objects.indices {
                    doc.updateWithoutHistory(at: i) { $0.translate(dx: actualDx, dy: actualDy) }
                }
            }
            selection = clamped
        }
    }

    func drawEraserCursorRingIfNeeded(in ctx: CGContext, sel: CGRect) {
        guard activeTool == .eraser, !isRecordingMode, let pt = lastMousePoint, sel.contains(pt) else { return }
        if (!toolbar.isHidden && toolbar.frame.contains(pt)) || (!subbar.isHidden && subbar.frame.contains(pt)) { return }
        let r = style.eraserRadius
        let circle = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
        ctx.saveGState()
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        ctx.fillEllipse(in: circle)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(2.0); ctx.strokeEllipse(in: circle)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(1.2); ctx.setLineDash(phase: 0, lengths: [3, 2.5]); ctx.strokeEllipse(in: circle)
        ctx.restoreGState()
    }

    func beginEraserDrag(at p: CGPoint) {
        selectedObjectIndex = nil
        doc.beginTransaction()
        let hit = doc.eraseAlongSegment(from: p, to: p, radius: style.eraserRadius)
        dragOp = .erasing(lastPoint: p, erased: hit)
        if hit { needsDisplay = true }
    }

    func continueEraserDrag(from last: CGPoint, to p: CGPoint, erased: Bool) {
        let hit = doc.eraseAlongSegment(from: last, to: p, radius: style.eraserRadius)
        dragOp = .erasing(lastPoint: p, erased: erased || hit)
        if hit { needsDisplay = true }
        invalidateMagnifierMove(from: last, to: p)
    }
}
