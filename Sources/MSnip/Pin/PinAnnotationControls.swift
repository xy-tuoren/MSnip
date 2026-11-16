import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 贴图窗口伴随悬浮标注工具栏面板（自动吸附在贴图下方或上方，不受小尺寸贴图边框裁切）
final class PinToolbarPanel: NSPanel {
    let barView = ToolbarView()
    let subbarView = ToolbarSubbarView()
    private let container = NSView()

    init() {
        barView.isPinEditorMode = true
        barView.activeTool = .rect
        barView.refreshState()
        subbarView.isPinEditorMode = true
        subbarView.activeTool = .rect
        subbarView.refresh()

        let w = max(barView.frame.width, subbarView.frame.width)
        let h = ToolbarView.barHeight + 6 + ToolbarSubbarView.subHeight
        container.frame = NSRect(x: 0, y: 0, width: w, height: h)

        super.init(
            contentRect: container.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = .floating
        self.isFloatingPanel = true
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.acceptsMouseMovedEvents = true
        container.addSubview(subbarView)
        container.addSubview(barView)
        self.contentView = container
    }

    override var canBecomeKey: Bool { false }

    func reposition(anchoringTo pinFrame: NSRect, on screen: NSScreen?) {
        barView.refreshState()
        let showSub = (barView.activeTool != nil)
        subbarView.isHidden = !showSub
        if showSub { subbarView.refresh() }

        let totalW = showSub ? max(barView.frame.width, subbarView.frame.width) : barView.frame.width
        let totalH = showSub ? (ToolbarView.barHeight + 6 + ToolbarSubbarView.subHeight) : ToolbarView.barHeight
        container.setFrameSize(NSSize(width: totalW, height: totalH))
        // container 为标准左下角原点：barView 在顶部，subbarView 在下方
        barView.setFrameOrigin(NSPoint(x: 0, y: totalH - ToolbarView.barHeight))
        subbarView.setFrameOrigin(NSPoint(x: 0, y: 0))

        let visible = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = min(max(visible.minX + 8, pinFrame.midX - totalW * 0.5), visible.maxX - totalW - 8)
        let belowY = pinFrame.minY - totalH - 8
        let aboveY = pinFrame.maxY + 8
        let y = belowY >= visible.minY + 4 ? belowY : min(aboveY, visible.maxY - totalH - 4)
        setFrame(NSRect(origin: NSPoint(x: round(x), y: round(y)), size: NSSize(width: totalW, height: totalH)), display: true)
    }
}

/// 贴图内联标注画布的样式同步、键盘快捷键与文本输入框扩展
extension PinAnnotationCanvasView {
    func applyStyleColor(_ idx: Int) {
        colorIndex = idx
        if let sel = selectedIndex {
            doc.modifyWithHistory(at: sel) { $0.style.color = style.color }
            onDocStateChanged?()
            needsDisplay = true
        }
    }

    func applyStrokeWidth(_ w: CGFloat) {
        style.lineWidth = w
        style.fontSize = max(14, w * 4.5)
        if let sel = selectedIndex {
            doc.modifyWithHistory(at: sel) {
                $0.style.lineWidth = w
                $0.style.fontSize = max(14, w * 4.5)
            }
            onDocStateChanged?()
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        if textField != nil { return }
        let cmd = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if event.keyCode == 53 { // Esc
            if selectedIndex != nil { selectedIndex = nil } else { onCancel?() }
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 { // Return
            commitTextField()
            onCommit?(doc)
            return
        }
        if cmd && (chars == "z" || chars == "y") {
            selectedIndex = nil
            _ = ((chars == "y") || shift) ? doc.redo() : doc.undo()
            onDocStateChanged?()
            needsDisplay = true
            return
        }
        if event.keyCode == 51 || event.keyCode == 117, let idx = selectedIndex {
            doc.remove(at: idx)
            selectedIndex = nil
            onDocStateChanged?()
            needsDisplay = true
            return
        }
        if !cmd, chars == "k" || (cmd && chars == "b") {
            togglePinTextCapsule()
            return
        }
        if cmd, chars == "b" {
            togglePinTextCapsule()
            return
        }
        if !cmd, let n = Int(chars), let tool = ToolKind(rawValue: n) {
            activeTool = (activeTool == tool) ? nil : tool
            onDocStateChanged?()
        }
    }

    func togglePinTextCapsule() {
        style.textCapsule.toggle()
        if let idx = selectedIndex, case .text(let o, let c, _) = doc.objects[idx].payload {
            let newCap = !doc.objects[idx].style.textCapsule
            style.textCapsule = newCap
            let sz = AnnotationRenderer.measureText(c, fontSize: doc.objects[idx].style.fontSize, capsule: newCap)
            doc.modifyWithHistory(at: idx) {
                $0.style.textCapsule = newCap
                $0.payload = .text(origin: o, content: c, measuredSize: sz)
            }
        }
        onDocStateChanged?()
        needsDisplay = true
    }

    func buildDraft(tool: ToolKind, from a: CGPoint, to b: CGPoint, shift: Bool) -> Annotation {
        let boxEnd = shift ? Geometry.squareConstrainedEnd(from: a, to: b) : b
        let lineEnd = shift ? Geometry.angleSnappedEnd(from: a, to: b) : b
        let payload: AnnotationPayload
        switch tool {
        case .rect:         payload = .rect(Geometry.normalizedRect(from: a, to: boxEnd))
        case .ellipse:      payload = .ellipse(Geometry.normalizedRect(from: a, to: boxEnd))
        case .mosaic:       payload = .mosaic(Geometry.normalizedRect(from: a, to: b))
        case .gaussianBlur: payload = .gaussianBlur(Geometry.normalizedRect(from: a, to: b))
        case .arrow:        payload = .arrow(from: a, to: lineEnd)
        case .line:         payload = .line(from: a, to: lineEnd)
        case .pen:          payload = .pen(points: [a, b])
        case .highlighter:  payload = .highlighter(points: [a, lineEnd])
        case .step:
            let num = (draft.flatMap { if case .step(_, _, let n) = $0.payload { return n } else { return nil } }) ?? doc.nextStepNumber()
            let tail = hypot(lineEnd.x - a.x, lineEnd.y - a.y) >= (style.stepBadgeRadius + 6.0) ? lineEnd : nil
            payload = .step(center: a, tail: tail, number: num)
        case .text:         payload = .text(origin: a, content: "", measuredSize: .zero)
        }
        return Annotation(payload: payload, style: style)
    }

    func startTextField(at pt: CGPoint, existing: Int?) {
        commitTextField()
        let z = max(0.25, zoomProvider())
        var origin = pt
        var text = ""
        if let idx = existing, case .text(let o, let c, _) = doc.objects[idx].payload {
            origin = o; text = c; editingIndex = idx
        }
        editingOrigin = origin
        let tf = NSTextField(frame: NSRect(x: origin.x * z, y: origin.y * z, width: max(120, bounds.width - origin.x * z - 6), height: max(26, style.fontSize * z * 1.4)))
        tf.stringValue = text
        tf.isBordered = true; tf.drawsBackground = true
        tf.backgroundColor = NSColor.black.withAlphaComponent(0.65)
        tf.textColor = .white
        tf.font = .systemFont(ofSize: style.fontSize * z, weight: .semibold)
        tf.focusRingType = .none; tf.delegate = self
        addSubview(tf)
        window?.makeFirstResponder(tf)
        textField = tf
        needsDisplay = true
    }

    func commitTextField() {
        guard let tf = textField, let origin = editingOrigin else { return }
        let content = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        tf.removeFromSuperview()
        textField = nil; editingOrigin = nil
        let editIdx = editingIndex; editingIndex = nil
        if !content.isEmpty {
            let sz = AnnotationRenderer.measureText(content, fontSize: style.fontSize, capsule: style.textCapsule)
            if let idx = editIdx {
                doc.modifyWithHistory(at: idx) {
                    $0.style.textCapsule = style.textCapsule
                    $0.payload = .text(origin: origin, content: content, measuredSize: sz)
                }
            } else {
                doc.append(Annotation(payload: .text(origin: origin, content: content, measuredSize: sz), style: style))
            }
            onDocStateChanged?()
        }
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) || commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) { textField?.stringValue = "" }
            commitTextField()
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }
}
