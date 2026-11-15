import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 覆盖层的标注草稿构建、取色/坐标复制、1px 边缘微调与导出烘焙扩展
extension OverlayView {
    enum FinishMode { case copy, save, pin, extractText }

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
        guard let targetRect = selection ?? hoveredAutoRect,
              targetRect.width >= 2, targetRect.height >= 2,
              let baked = AnnotationRenderer.bakeExportImage(
                  sampler: snapshot.sampler,
                  selection: targetRect,
                  imageScale: snapshot.scaleFactor,
                  annotations: doc.objects,
                  cornerRadiusPt: (mode == .extractText) ? 0 : cornerRadiusPt,
                  backdropStyle: (mode == .extractText) ? .none : backdropStyle
              ) else { return }

        switch mode {
        case .copy:        onFinishCopy?(baked, snapshot.scaleFactor, targetRect)
        case .save:        onFinishSave?(baked, snapshot.scaleFactor, targetRect)
        case .pin:         onFinishPin?(baked, snapshot.scaleFactor, targetRect.origin, snapshot.screen, targetRect)
        case .extractText: onFinishExtractText?(baked, snapshot.scaleFactor, snapshot.screen, targetRect)
        }
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
        case .text:
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
        needsDisplay = true
    }

    func handleArrowKey(dx: CGFloat, dy: CGFloat, ctrl: Bool, shift: Bool) {
        if let idx = selectedObjectIndex {
            let step: CGFloat = shift ? 5.0 : 1.0
            doc.modifyWithHistory(at: idx) { $0.translate(dx: dx * step, dy: dy * step) }
            updateToolbarLayout()
            needsDisplay = true
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
}
