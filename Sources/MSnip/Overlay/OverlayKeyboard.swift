import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 覆盖层的键盘快捷键、方向键微调与导出生成扩展
extension OverlayView {
    enum FinishMode { case copy, save, pin }

    override func keyDown(with event: NSEvent) {
        if isEditingText { return }
        let cmd = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if event.keyCode == 49 { // Space
            spacePressed = true
            return
        }
        if event.keyCode == 53 { // Esc 分层回退
            if selectedObjectIndex != nil {
                selectedObjectIndex = nil
            } else {
                onCancel?()
            }
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
        if cmd && (chars == "z" || chars == "y") {
            selectedObjectIndex = nil
            let isRedo = (chars == "y") || shift
            _ = isRedo ? doc.redo() : doc.undo()
            updateToolbarLayout()
            needsDisplay = true
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 { // Delete / ForwardDelete
            if let idx = selectedObjectIndex {
                doc.remove(at: idx)
                selectedObjectIndex = nil
                updateToolbarLayout()
                needsDisplay = true
            }
            return
        }

        // 方向键 1pt / Shift 5pt 微调（优先微调选中的标注，否则微调选区框）
        let step: CGFloat = shift ? 5.0 : 1.0
        switch event.keyCode {
        case 123: nudge(dx: -step, dy: 0); return // ←
        case 124: nudge(dx: step, dy: 0); return  // →
        case 125: nudge(dx: 0, dy: step); return  // ↓ (isFlipped 向下为正)
        case 126: nudge(dx: 0, dy: -step); return // ↑
        default: break
        }

        if !cmd, let n = Int(chars), let tool = ToolKind(rawValue: n) {
            activeTool = (activeTool == tool) ? nil : tool
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spacePressed = false }
    }

    func exportAndFinish(mode: FinishMode) {
        commitTextEditing()
        guard let sel = selection, sel.width >= 2, sel.height >= 2,
              let baked = AnnotationRenderer.bakeExportImage(
                  sampler: snapshot.sampler,
                  selection: sel,
                  imageScale: snapshot.scaleFactor,
                  annotations: doc.objects
              ) else { return }

        switch mode {
        case .copy: onFinishCopy?(baked, snapshot.scaleFactor)
        case .save: onFinishSave?(baked, snapshot.scaleFactor)
        case .pin:  onFinishPin?(baked, snapshot.scaleFactor, sel.origin, snapshot.screen)
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

    private func nudge(dx: CGFloat, dy: CGFloat) {
        if let idx = selectedObjectIndex {
            doc.modifyWithHistory(at: idx) { $0.translate(dx: dx, dy: dy) }
            updateToolbarLayout()
            needsDisplay = true
        } else if let sel = selection {
            selection = Geometry.clampRect(sel.offsetBy(dx: dx, dy: dy), within: bounds)
        }
    }
}
