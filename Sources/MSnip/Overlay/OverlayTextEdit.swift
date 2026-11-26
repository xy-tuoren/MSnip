import AppKit
import CoreGraphics
import Foundation
import MSnipCore

private final class CapsuleAwareTextField: NSTextField {
    var onToggleCapsule: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "b" {
            onToggleCapsule?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// 覆盖层原位文本标注输入扩展（支持中文输入法、二次双击重编辑及 `⌘B` 一键切换圆角胶囊底色字）
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
            style.textCapsule = doc.objects[idx].style.textCapsule
            toolbar.textCapsule = style.textCapsule
        } else {
            origin = point
            initialText = ""
        }
        editingTextOrigin = origin

        let field = CapsuleAwareTextField(
            frame: NSRect(
                x: origin.x - 2,
                y: origin.y - 2,
                width: 240,
                height: max(30, style.fontSize * 1.65)
            )
        )
        field.stringValue = initialText
        field.placeholderString = style.textCapsule ? "输入胶囊标签文字（⌘B 切换纯字）" : "输入文字（⌘B 切胶囊底色）"
        field.drawsBackground = true
        field.isBordered = true
        field.focusRingType = .exterior
        field.wantsLayer = true
        field.delegate = self
        field.onToggleCapsule = { [weak self] in
            self?.toggleTextCapsuleMode()
        }
        textField = field
        applyTextFieldVisualStyle()
        addSubview(field)
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeFirstResponder(field)
        syncMagnifierView()
        syncShortcutTipsView()
        needsDisplay = true
    }

    func applyTextFieldVisualStyle() {
        guard let field = textField else { return }
        field.font = NSFont.systemFont(ofSize: style.fontSize, weight: .semibold)
        if style.textCapsule {
            let luma = 0.299 * Double(style.color.r) + 0.587 * Double(style.color.g) + 0.114 * Double(style.color.b)
            field.backgroundColor = NSColor(cgColor: style.color.cgColor) ?? .systemRed
            field.textColor = luma > 195.0 ? .black : .white
            field.layer?.cornerRadius = 7
        } else {
            field.backgroundColor = NSColor.black.withAlphaComponent(0.48)
            field.textColor = NSColor(cgColor: style.color.cgColor) ?? .systemRed
            field.layer?.cornerRadius = 4
        }
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
            let measured = AnnotationRenderer.measureText(
                content,
                fontSize: style.fontSize,
                capsule: style.textCapsule
            )
            if let idx = existing {
                doc.modifyWithHistory(at: idx) { obj in
                    obj.style.textCapsule = style.textCapsule
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
        syncShortcutTipsView()
        needsDisplay = true
    }

    func cancelTextEditing() {
        textField?.removeFromSuperview()
        textField = nil
        editingTextOrigin = nil
        editingExistingIndex = nil
        window?.makeFirstResponder(self)
        syncShortcutTipsView()
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
