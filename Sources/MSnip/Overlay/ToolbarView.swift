import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 截图选区下方的原生毛玻璃深色悬浮工具栏（含标注、吸管取色、圆角截图、识字提取与导出动作）
final class ToolbarView: NSView {
    enum Action {
        case selectTool(ToolKind?)
        case selectColor(Int)
        case toggleEyedropper
        case selectStroke(CGFloat)
        case undo
        case redo
        case cycleCornerRadius
        case cycleBackdrop
        case extractText
        case startLongShot
        case startRecording
        case pin
        case save
        case cancel
        case confirmCopy
    }

    struct HitItem {
        let rect: CGRect
        let tooltip: String
        let enabled: Bool
        let draw: (CGContext, CGRect, Bool) -> Void
        let action: Action
    }

    var onAction: ((Action) -> Void)?

    var activeTool: ToolKind? { didSet { needsDisplay = true } }
    var nextStepNumber: Int = 1 { didSet { needsDisplay = true } }
    var colorIndex: Int = 0 { didSet { needsDisplay = true } }
    var customColor: RGBAColor? { didSet { needsDisplay = true } }
    var eyedropperActive: Bool = false { didSet { needsDisplay = true } }
    var lineWidth: CGFloat = 3.0 { didSet { needsDisplay = true } }
    var cornerRadiusPt: CGFloat = 0 { didSet { needsDisplay = true } }
    var backdropStyle: BackdropStyle = .none { didSet { needsDisplay = true } }
    var canUndo: Bool = false { didSet { needsDisplay = true } }
    var canRedo: Bool = false { didSet { needsDisplay = true } }
    var pinHint: String = "⌘2" { didSet { needsDisplay = true } }
    var isPinEditorMode: Bool = false { didSet { needsDisplay = true } }

    var items: [HitItem] = []
    private var hoveredIndex: Int?

    override var isFlipped: Bool { true }

    static let barHeight: CGFloat = 42
    static let barWidth: CGFloat = 850

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.barWidth, height: Self.barHeight))
        rebuildItems()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    func refreshState() {
        rebuildItems()
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = items.firstIndex(where: { $0.rect.contains(p) && $0.enabled })
        if idx != hoveredIndex {
            hoveredIndex = idx
            toolTip = idx.map { items[$0].tooltip }
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let item = items.first(where: { $0.rect.contains(p) && $0.enabled }) {
            onAction?(item.action)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        rebuildItems()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let bgRect = bounds.insetBy(dx: 1, dy: 1)
        let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 9, cornerHeight: 9, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(NSColor(calibratedWhite: 0.12, alpha: 0.92).cgColor)
        ctx.addPath(bgPath)
        ctx.fillPath()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(bgPath)
        ctx.strokePath()
        ctx.restoreGState()

        for (i, item) in items.enumerated() {
            item.draw(ctx, item.rect, hoveredIndex == i)
        }
    }
}
