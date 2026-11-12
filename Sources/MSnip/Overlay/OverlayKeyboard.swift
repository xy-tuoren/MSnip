import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 覆盖层的 PixPin 风格全键盘快捷操作、1px 像素微调、取色复制、OCR 提取与导出生成扩展
extension OverlayView {
    enum FinishMode { case copy, save, pin, extractText }

    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        optionPressed = flags.contains(.option)

        // 轻按并松开单独 Shift 键：循环切换放大镜色值格式（HEX / RGB / HSL / HSV）
        if event.keyCode == 56 || event.keyCode == 60 {
            if flags == .shift {
                shiftTapCandidate = true
            } else if !flags.contains(.shift), shiftTapCandidate {
                shiftTapCandidate = false
                if !isEditingText { cycleColorFormat() }
            } else {
                shiftTapCandidate = false
            }
        } else {
            shiftTapCandidate = false
        }
    }

    override func keyDown(with event: NSEvent) {
        shiftTapCandidate = false
        if isEditingText { return }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let ctrl = flags.contains(.control)
        let shift = flags.contains(.shift)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if event.keyCode == 49 { // Space
            spacePressed = true
            return
        }
        if event.keyCode == 53 { // Esc 分层回退
            if eyedropperActive {
                eyedropperActive = false
            } else if selectedObjectIndex != nil {
                selectedObjectIndex = nil
            } else if selection != nil && doc.isEmpty {
                selection = nil
                activeTool = nil
                cornerRadiusPt = 0
                refreshAutoSnapAtCurrentMouse()
            } else {
                onCancel?()
            }
            return
        }
        if event.keyCode == 48 { // Tab 切换色值格式
            cycleColorFormat()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 || (cmd && chars == "c") { // Return / Enter / ⌘C
            exportAndFinish(mode: .copy)
            return
        }
        if cmd && chars == "s" {
            exportAndFinish(mode: .save)
            return
        }
        if (cmd && chars == "2") || event.keyCode == 99 { // ⌘2 或 F3 贴图
            exportAndFinish(mode: .pin)
            return
        }
        if cmd && chars == "a" { // ⌘A 全选当前屏幕
            selection = bounds
            return
        }
        if cmd && chars == "o" { // ⌘O 识别文字
            exportAndFinish(mode: .extractText)
            return
        }
        if cmd && (chars == "z" || chars == "y") {
            selectedObjectIndex = nil
            let isRedo = (chars == "y") || shift
            _ = isRedo ? doc.redo() : doc.undo()
            updateToolbarLayout()
            needsDisplay = true
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 { // Delete / ForwardDelete
            if cmd && shift {
                doc.clearAll()
                selectedObjectIndex = nil
                updateToolbarLayout()
                needsDisplay = true
            } else if let idx = selectedObjectIndex {
                doc.remove(at: idx)
                selectedObjectIndex = nil
                updateToolbarLayout()
                needsDisplay = true
            }
            return
        }

        // 方向键：未选定时 1px 移动光标；已选定时 平移 / ⌃扩展边缘 / ⇧收缩边缘
        switch event.keyCode {
        case 123: handleArrowKey(dx: -1, dy: 0, ctrl: ctrl, shift: shift); return // ←
        case 124: handleArrowKey(dx: 1, dy: 0, ctrl: ctrl, shift: shift); return  // →
        case 125: handleArrowKey(dx: 0, dy: 1, ctrl: ctrl, shift: shift); return  // ↓
        case 126: handleArrowKey(dx: 0, dy: -1, ctrl: ctrl, shift: shift); return // ↑
        default: break
        }

        // 单字母 PixPin 快捷操作（无 ⌘ / ⌃ 修饰）
        if !cmd, !ctrl {
            switch chars {
            case "c":
                copyColorAtCursorAndFinish()
                return
            case "x":
                copyCoordinatesAtCursorAndFinish()
                return
            case "g":
                useRelativeCoordinates.toggle()
                return
            case "t":
                exportAndFinish(mode: .extractText)
                return
            case "r":
                if let prev = lastHistorySelection {
                    selection = Geometry.clampRect(prev, within: bounds)
                }
                return
            case "b":
                cycleCornerRadius()
                return
            case "i":
                if selection == nil, let snap = hoveredAutoRect { selection = snap }
                eyedropperActive.toggle()
                return
            case "m", "`", "~":
                magnifierPinned.toggle()
                return
            case "h", "/", "?":
                showShortcutTips.toggle()
                onPrefsChanged?(colorCopyFormat, showShortcutTips)
                return
            case "w":
                warpCursorByPixels(dx: 0, dy: shift ? -5 : -1); return
            case "s":
                warpCursorByPixels(dx: 0, dy: shift ? 5 : 1); return
            case "a":
                warpCursorByPixels(dx: shift ? -5 : -1, dy: 0); return
            case "d":
                warpCursorByPixels(dx: shift ? 5 : 1, dy: 0); return
            default:
                break
            }

            if let n = Int(chars), let tool = ToolKind(rawValue: n) {
                eyedropperActive = false
                if selection == nil, let snap = hoveredAutoRect {
                    selection = snap
                }
                activeTool = (activeTool == tool) ? nil : tool
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spacePressed = false }
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
        guard let targetRect = selection ?? hoveredAutoRect,
              targetRect.width >= 2, targetRect.height >= 2,
              let baked = AnnotationRenderer.bakeExportImage(
                  sampler: snapshot.sampler,
                  selection: targetRect,
                  imageScale: snapshot.scaleFactor,
                  annotations: doc.objects,
                  cornerRadiusPt: (mode == .extractText) ? 0 : cornerRadiusPt
              ) else { return }

        switch mode {
        case .copy:        onFinishCopy?(baked, snapshot.scaleFactor, targetRect)
        case .save:        onFinishSave?(baked, snapshot.scaleFactor, targetRect)
        case .pin:         onFinishPin?(baked, snapshot.scaleFactor, targetRect.origin, snapshot.screen, targetRect)
        case .extractText: onFinishExtractText?(baked, NSEvent.mouseLocation, targetRect)
        }
    }

    func makeDraft(tool: ToolKind, from a: CGPoint, to b: CGPoint, shift: Bool) -> Annotation {
        let endForBox = shift ? Geometry.squareConstrainedEnd(from: a, to: b) : b
        let endForLine = shift ? Geometry.angleSnappedEnd(from: a, to: b) : b
        let payload: AnnotationPayload
        switch tool {
        case .rect:    payload = .rect(Geometry.normalizedRect(from: a, to: endForBox))
        case .ellipse: payload = .ellipse(Geometry.normalizedRect(from: a, to: endForBox))
        case .mosaic:  payload = .mosaic(Geometry.normalizedRect(from: a, to: b))
        case .arrow:   payload = .arrow(from: a, to: endForLine)
        case .line:    payload = .line(from: a, to: endForLine)
        case .pen:     payload = .pen(points: [a, b])
        case .text:    payload = .text(origin: a, content: "", measuredSize: .zero)
        }
        return Annotation(payload: payload, style: style)
    }

    // MARK: - Cursor 1px Warp & PixPin Edge Fine-Tuning

    private func warpCursorByPixels(dx: Int, dy: Int) {
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

    private func handleArrowKey(dx: CGFloat, dy: CGFloat, ctrl: Bool, shift: Bool) {
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
            // ⌃ + 方向键：向外扩展选区对应边 (PixPin Expand Select)
            if dx < 0 { sel.origin.x -= 1; sel.size.width += 1 }
            if dx > 0 { sel.size.width += 1 }
            if dy < 0 { sel.origin.y -= 1; sel.size.height += 1 }
            if dy > 0 { sel.size.height += 1 }
            selection = sel.intersection(bounds)
        } else if shift {
            // ⇧ + 方向键：向内收缩选区对应边 (PixPin Shrink Select)
            if dx < 0, sel.width > 8 { sel.size.width -= 1 }
            if dx > 0, sel.width > 8 { sel.origin.x += 1; sel.size.width -= 1 }
            if dy < 0, sel.height > 8 { sel.size.height -= 1 }
            if dy > 0, sel.height > 8 { sel.origin.y += 1; sel.size.height -= 1 }
            selection = sel.intersection(bounds)
        } else {
            // 普通方向键：整体平移选区及内部标注 1pt
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
