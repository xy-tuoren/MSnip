import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 贴图原位无损二次圈记画布（坐标自动按 `zoomFactor` 映射回 `baseSize`，缩放贴图下依旧像素级精准）
final class PinAnnotationCanvasView: NSView, NSTextFieldDelegate {
    let baseSampler: PixelSampler
    let baseSize: NSSize
    let imageScale: CGFloat
    var zoomProvider: () -> CGFloat = { 1.0 }
    var onCommit: ((AnnotationDocument) -> Void)?
    var onCancel: (() -> Void)?
    var onDocStateChanged: (() -> Void)?

    var doc = AnnotationDocument()
    var activeTool: ToolKind? = .rect { didSet { needsDisplay = true } }
    var style = AnnotationStyle()
    var colorIndex: Int = 0 {
        didSet { style.color = RGBAColor.presets[min(max(0, colorIndex), RGBAColor.presets.count - 1)] }
    }

    private enum CanvasDrag {
        case drawing(tool: ToolKind, start: CGPoint)
        case moving(index: Int, lastPt: CGPoint, moved: Bool)
    }

    private var dragState: CanvasDrag?
    var draft: Annotation? { didSet { needsDisplay = true } }
    var selectedIndex: Int? { didSet { needsDisplay = true } }
    var textField: NSTextField?
    var editingOrigin: CGPoint?
    var editingIndex: Int?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(baseSampler: PixelSampler, baseSize: NSSize, imageScale: CGFloat) {
        self.baseSampler = baseSampler
        self.baseSize = baseSize
        self.imageScale = imageScale
        super.init(frame: NSRect(origin: .zero, size: baseSize))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    func logicalPoint(for event: NSEvent) -> CGPoint {
        let raw = convert(event.locationInWindow, from: nil)
        let z = max(0.25, zoomProvider())
        return CGPoint(
            x: min(max(0, raw.x / z), baseSize.width),
            y: min(max(0, raw.y / z), baseSize.height)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let z = max(0.25, zoomProvider())
        ctx.saveGState()
        ctx.scaleBy(x: z, y: z)
        let canvasRect = CGRect(origin: .zero, size: baseSize)
        AnnotationRenderer.drawAnnotations(
            in: ctx,
            annotations: doc.objects,
            draft: draft,
            skipIndex: editingIndex,
            sampler: baseSampler,
            imageScale: imageScale,
            clipRect: canvasRect
        )
        if let idx = selectedIndex, doc.objects.indices.contains(idx) {
            ctx.setStrokeColor(NSColor.systemCyan.cgColor)
            ctx.setLineWidth(1.2 / z)
            ctx.setLineDash(phase: 0, lengths: [4 / z, 3 / z])
            ctx.stroke(doc.objects[idx].bounds)
        }
        ctx.restoreGState()
    }

    // MARK: - Mouse Drawing & Hit-Testing

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if textField != nil {
            commitTextField()
            return
        }
        let p = logicalPoint(for: event)
        if event.clickCount == 2, let hit = doc.hitIndex(at: p), case .text = doc.objects[hit].payload {
            startTextField(at: p, existing: hit)
            return
        }

        if let hit = doc.hitIndex(at: p) {
            let directStep: Bool = {
                guard case .step(let c, _, _) = doc.objects[hit].payload else { return false }
                return hypot(p.x - c.x, p.y - c.y) <= doc.objects[hit].style.stepBadgeRadius
            }()
            if activeTool == nil || event.modifierFlags.contains(.command) || selectedIndex == hit || directStep {
                selectedIndex = hit
                doc.beginTransaction()
                dragState = .moving(index: hit, lastPt: p, moved: false)
                return
            }
        }

        selectedIndex = nil
        guard let tool = activeTool else { return }
        if tool == .text {
            startTextField(at: p, existing: nil)
        } else {
            dragState = .drawing(tool: tool, start: p)
            draft = buildDraft(tool: tool, from: p, to: p, shift: false)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let state = dragState else { return }
        let p = logicalPoint(for: event)
        let shift = event.modifierFlags.contains(.shift)
        switch state {
        case .drawing(let tool, let start):
            if tool == .pen, var cur = draft, case .pen(var pts) = cur.payload {
                if let last = pts.last, hypot(p.x - last.x, p.y - last.y) >= 2.0 {
                    pts.append(p); cur.payload = .pen(points: pts); draft = cur
                }
            } else if tool == .highlighter, var cur = draft, case .highlighter(var pts) = cur.payload {
                if shift {
                    cur.payload = .highlighter(points: [start, Geometry.angleSnappedEnd(from: start, to: p)])
                    draft = cur
                } else if let last = pts.last, hypot(p.x - last.x, p.y - last.y) >= 2.0 {
                    pts.append(p); cur.payload = .highlighter(points: pts); draft = cur
                }
            } else {
                draft = buildDraft(tool: tool, from: start, to: p, shift: shift)
            }
        case .moving(let index, let lastPt, let moved):
            let dx = p.x - lastPt.x, dy = p.y - lastPt.y
            doc.updateWithoutHistory(at: index) { $0.translate(dx: dx, dy: dy) }
            dragState = .moving(index: index, lastPt: p, moved: moved || hypot(dx, dy) > 0.5)
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let state = dragState else { return }
        dragState = nil
        switch state {
        case .drawing(_, let start):
            let p = logicalPoint(for: event)
            if let d = draft, !d.isTrivial {
                doc.append(d)
                onDocStateChanged?()
            } else if hypot(p.x - start.x, p.y - start.y) < 3.5, let hit = doc.hitIndex(at: p) {
                selectedIndex = hit
            }
            draft = nil
        case .moving(_, _, let moved):
            doc.commitTransaction(changed: moved)
            onDocStateChanged?()
        }
    }
}
