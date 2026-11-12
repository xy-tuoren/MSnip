import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 覆盖层交互阶段与拖拽状态
enum DragOperation {
    case creatingSelection(anchor: CGPoint)
    case movingSelection(initialRect: CGRect, mouseStart: CGPoint)
    case resizingSelection(handle: ResizeHandle, initialRect: CGRect, mouseStart: CGPoint)
    case drawingAnnotation(tool: ToolKind, start: CGPoint)
    case movingAnnotation(index: Int, lastPoint: CGPoint, moved: Bool)
}

/// 单块显示器的全屏冻结覆盖层画布（`isFlipped = true`，左上角为 `(0, 0)`）
final class OverlayView: NSView, NSTextFieldDelegate {
    let snapshot: ScreenSnapshot
    private let frozenNSImage: NSImage
    let toolbar = ToolbarView()

    // 外部会话回调
    var onSelectionActivated: ((OverlayView) -> Void)?
    var onFinishCopy: ((CGImage, CGFloat) -> Void)?
    var onFinishSave: ((CGImage, CGFloat) -> Void)?
    var onFinishPin: ((CGImage, CGFloat, CGPoint, NSScreen) -> Void)?
    var onCancel: (() -> Void)?
    var onStyleChanged: ((Int, CGFloat) -> Void)?

    // 编辑状态
    var selection: CGRect? {
        didSet {
            updateToolbarLayout()
            needsDisplay = true
        }
    }
    var doc = AnnotationDocument()
    var activeTool: ToolKind? {
        didSet {
            toolbar.activeTool = activeTool
            needsDisplay = true
        }
    }
    var colorIndex: Int = 0 {
        didSet {
            style.color = RGBAColor.presets[min(max(0, colorIndex), RGBAColor.presets.count - 1)]
            toolbar.colorIndex = colorIndex
        }
    }
    var style = AnnotationStyle()
    var selectedObjectIndex: Int? { didSet { needsDisplay = true } }
    var draftAnnotation: Annotation? { didSet { needsDisplay = true } }
    var dragOp: DragOperation?
    var spacePressed = false

    // 文本标注原位输入框（原生支持中文拼音输入法候选窗）
    private var textField: NSTextField?
    private var editingTextOrigin: CGPoint?
    private var editingExistingIndex: Int?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(snapshot: ScreenSnapshot, initialColorIndex: Int, initialLineWidth: CGFloat, pinHint: String) {
        self.snapshot = snapshot
        let screenSize = snapshot.screen.frame.size
        self.frozenNSImage = NSImage(cgImage: snapshot.cgImage, size: screenSize)
        super.init(frame: NSRect(origin: .zero, size: screenSize))

        self.colorIndex = initialColorIndex
        self.style.color = RGBAColor.presets[min(max(0, initialColorIndex), RGBAColor.presets.count - 1)]
        self.style.lineWidth = initialLineWidth

        toolbar.colorIndex = initialColorIndex
        toolbar.lineWidth = initialLineWidth
        toolbar.pinHint = pinHint
        toolbar.isHidden = true
        toolbar.onAction = { [weak self] action in
            self?.handleToolbarAction(action)
        }
        addSubview(toolbar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1) 绘制全屏冻结底图
        frozenNSImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0)

        // 2) 绘制暗化遮罩（选区内部镂空保留 100% 原始亮度）
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.46).cgColor)
        if let sel = selection, sel.width > 0, sel.height > 0 {
            ctx.addRect(bounds)
            ctx.addRect(sel)
            ctx.fillPath(using: .evenOdd)
        } else {
            ctx.fill(bounds)
        }
        ctx.restoreGState()

        guard let sel = selection, sel.width >= 1, sel.height >= 1 else { return }

        // 3) 绘制选区内的标注与实时草稿
        AnnotationRenderer.drawAnnotations(
            in: ctx,
            annotations: doc.objects,
            draft: draftAnnotation,
            skipIndex: editingExistingIndex,
            sampler: snapshot.sampler,
            imageScale: snapshot.scaleFactor,
            clipRect: sel
        )

        // 4) 若有选中的标注对象，绘制虚线高亮框
        if let idx = selectedObjectIndex, doc.objects.indices.contains(idx) {
            let objBounds = doc.objects[idx].bounds
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.systemCyan.cgColor)
            ctx.setLineWidth(1.2)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(objBounds)
            ctx.restoreGState()
        }

        // 5) 选区外框 + 八向控制柄 + 物理像素尺寸徽标
        drawSelectionChrome(ctx: ctx, sel: sel)
    }

    private func drawSelectionChrome(ctx: CGContext, sel: CGRect) {
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(sel)

        for handle in ResizeHandle.allCases {
            let p = handle.point(in: sel)
            let hr = CGRect(x: p.x - 4.0, y: p.y - 4.0, width: 8.0, height: 8.0)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: hr)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: hr)
        }

        let pxW = Int((sel.width * snapshot.scaleFactor).rounded())
        let pxH = Int((sel.height * snapshot.scaleFactor).rounded())
        let label = "\(pxW) × \(pxH)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = label.size(withAttributes: attrs)
        let badgeW = ceil(textSize.width + 14)
        let badgeH: CGFloat = 22
        let badgeX = min(max(4, sel.minX), bounds.width - badgeW - 4)
        let badgeY = sel.minY >= (badgeH + 8) ? (sel.minY - badgeH - 6) : (sel.minY + 6)
        let badgeRect = CGRect(x: badgeX, y: badgeY, width: badgeW, height: badgeH)

        let pill = CGPath(roundedRect: badgeRect, cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.76).cgColor)
        ctx.addPath(pill)
        ctx.fillPath()
        label.draw(at: CGPoint(x: badgeRect.minX + 7, y: badgeRect.minY + (badgeH - textSize.height) * 0.5), withAttributes: attrs)
        ctx.restoreGState()
    }

    // MARK: - Toolbar & Text Input Helpers

    func updateToolbarLayout() {
        toolbar.canUndo = doc.canUndo
        toolbar.canRedo = doc.canRedo
        toolbar.refreshState()

        guard let sel = selection, sel.width >= 6, sel.height >= 6 else {
            toolbar.isHidden = true
            return
        }
        toolbar.isHidden = false
        let barSize = toolbar.frame.size
        let x = min(max(8, sel.maxX - barSize.width), bounds.width - barSize.width - 8)
        let belowY = sel.maxY + 8
        let aboveY = sel.minY - barSize.height - 8
        let y: CGFloat
        if belowY + barSize.height + 8 <= bounds.height {
            y = belowY
        } else if aboveY >= 8 {
            y = aboveY
        } else {
            y = max(8, sel.maxY - barSize.height - 8)
        }
        toolbar.setFrameOrigin(NSPoint(x: round(x), y: round(y)))
    }

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

        let field = NSTextField(frame: NSRect(x: origin.x - 2, y: origin.y - 2, width: 220, height: max(28, style.fontSize * 1.6)))
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

    var isEditingText: Bool { textField != nil }

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
                let item = Annotation(payload: .text(origin: origin, content: content, measuredSize: measured), style: style)
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

    /// 清除本屏幕上的选区（当用户在另一块显示器开始框选时调用）
    func clearSelectionFromSibling() {
        cancelTextEditing()
        selection = nil
        selectedObjectIndex = nil
        draftAnnotation = nil
        doc = AnnotationDocument()
    }
}
