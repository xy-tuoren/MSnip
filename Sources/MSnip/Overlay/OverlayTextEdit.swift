import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 覆盖层原位文本标注输入扩展（支持系统中文输入法候选窗与二次双击重编辑）
extension OverlayView {
    var isEditingText: Bool { textField != nil }

    func beginTextEditing(at point: CGPoint, existingIndex: Int? = nil) {
        commitTextEditing()
        editingExistingIndex = existingIndex

        let initialText: String
        let origin: CGPoint
        if let idx = existingIndex, case .text(let o, let s, _) = doc.objects[idx].payload {
            origin = o
            initialText = s
        } else {
            origin = point
            initialText = ""
        }
        editingTextOrigin = origin

        let field = NSTextField(
            frame: NSRect(
                x: origin.x - 2,
                y: origin.y - 2,
                width: 220,
                height: max(28, style.fontSize * 1.6)
            )
        )
        field.stringValue = initialText
        field.font = NSFont.systemFont(ofSize: style.fontSize, weight: .semibold)
        field.textColor = NSColor(cgColor: style.color.cgColor) ?? .systemRed
        field.backgroundColor = NSColor.black.withAlphaComponent(0.45)
        field.drawsBackground = true
        field.isBordered = true
        field.focusRingType = .exterior
        field.delegate = self
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
        needsDisplay = true
    }

    func commitTextEditing() {
        guard let field = textField, let origin = editingTextOrigin else { return }
        let content = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = editingExistingIndex
        field.removeFromSuperview()
        textField = nil
        editingTextOrigin = nil
        editingExistingIndex = nil
        window?.makeFirstResponder(self)

        if !content.isEmpty {
            let measured = AnnotationRenderer.measureText(content, fontSize: style.fontSize)
            if let idx = existing {
                doc.modifyWithHistory(at: idx) { obj in
                    obj.payload = .text(origin: origin, content: content, measuredSize: measured)
                }
            } else {
                let item = Annotation(
                    payload: .text(origin: origin, content: content, measuredSize: measured),
                    style: style
                )
                doc.append(item)
            }
        } else if let idx = existing {
            doc.remove(at: idx)
        }
        updateToolbarLayout()
        needsDisplay = true
    }

    func cancelTextEditing() {
        textField?.removeFromSuperview()
        textField = nil
        editingTextOrigin = nil
        editingExistingIndex = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            commitTextEditing()
            return true
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            cancelTextEditing()
            return true
        }
        return false
    }
}
