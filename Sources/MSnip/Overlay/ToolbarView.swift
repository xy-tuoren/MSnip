import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 截图选区下方的原生毛玻璃深色悬浮工具栏（含标注、吸管取色、圆角截图、识字提取与导出动作）
final class ToolbarView: NSView {
    enum Action {
        case selectTool(ToolKind?)
        case toggleTextCapsule
        case selectColor(Int)
        case toggleEyedropper
        case selectStroke(CGFloat)
        case undo
        case redo
        case cycleCornerRadius
        case cycleBackdrop
        case captureWindow
        case extractText
        case startLongShot
        case startRecording
        case pin
        case save
        case quickSave
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

    var activeTool: ToolKind? { didSet { if oldValue != activeTool { markItemsDirty() } } }
    var textCapsule: Bool = false { didSet { if oldValue != textCapsule { markItemsDirty() } } }
    var nextStepNumber: Int = 1 { didSet { if oldValue != nextStepNumber { markItemsDirty() } } }
    var colorIndex: Int = 0 { didSet { if oldValue != colorIndex { markItemsDirty() } } }
    var customColor: RGBAColor? { didSet { if oldValue != customColor { markItemsDirty() } } }
    var eyedropperActive: Bool = false { didSet { if oldValue != eyedropperActive { markItemsDirty() } } }
    var lineWidth: CGFloat = 3.0 { didSet { if oldValue != lineWidth { markItemsDirty() } } }
    var cornerRadiusPt: CGFloat = 0 { didSet { if oldValue != cornerRadiusPt { markItemsDirty() } } }
    var backdropStyle: BackdropStyle = .none { didSet { if oldValue != backdropStyle { markItemsDirty() } } }
    var canUndo: Bool = false { didSet { if oldValue != canUndo { markItemsDirty() } } }
    var canRedo: Bool = false { didSet { if oldValue != canRedo { markItemsDirty() } } }
    var pinHint: String = "⌘2" { didSet { if oldValue != pinHint { markItemsDirty() } } }
    var isPinEditorMode: Bool = false { didSet { if oldValue != isPinEditorMode { markItemsDirty() } } }

    var items: [HitItem] = []
    private var itemsDirty = true
    private var hoveredIndex: Int?

    override var isFlipped: Bool { true }

    static let barHeight: CGFloat = 42
    static let barWidth: CGFloat = 850

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.barWidth, height: Self.barHeight))
        rebuildItems()
        itemsDirty = false
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

    private func markItemsDirty() {
        itemsDirty = true
        needsDisplay = true
    }

    func refreshState() {
        rebuildItems()
        itemsDirty = false
        needsDisplay = true
    }

    private func ensureItemsUpToDate() {
        if itemsDirty {
            rebuildItems()
            itemsDirty = false
        }
    }

    override func mouseMoved(with event: NSEvent) {
        ensureItemsUpToDate()
        let p = convert(event.locationInWindow, from: nil)
        let idx = items.firstIndex(where: { $0.rect.contains(p) && $0.enabled })
        if idx != hoveredIndex {
            let oldIdx = hoveredIndex
            hoveredIndex = idx
            toolTip = idx.map { items[$0].tooltip }
            if let o = oldIdx, items.indices.contains(o) {
                setNeedsDisplay(items[o].rect.insetBy(dx: -3, dy: -3))
            }
            if let n = idx, items.indices.contains(n) {
                setNeedsDisplay(items[n].rect.insetBy(dx: -3, dy: -3))
            }
        }
    }

    override func mouseExited(with event: NSEvent) {
        if let old = hoveredIndex {
            hoveredIndex = nil
            if items.indices.contains(old) {
                setNeedsDisplay(items[old].rect.insetBy(dx: -3, dy: -3))
            } else {
                needsDisplay = true
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        ensureItemsUpToDate()
        let p = convert(event.locationInWindow, from: nil)
        if let item = items.first(where: { $0.rect.contains(p) && $0.enabled }) {
            if case .save = item.action, event.modifierFlags.contains(.option) {
                onAction?(.quickSave)
            } else {
                onAction?(item.action)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        ensureItemsUpToDate()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.saveGState()
        ctx.clip(to: dirtyRect)

        let bgRect = bounds.insetBy(dx: 1, dy: 1)
        let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 9, cornerHeight: 9, transform: nil)
        ctx.setFillColor(NSColor(calibratedWhite: 0.12, alpha: 0.92).cgColor)
        ctx.addPath(bgPath)
        ctx.fillPath()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(bgPath)
        ctx.strokePath()

        for (i, item) in items.enumerated() where item.rect.insetBy(dx: -4, dy: -4).intersects(dirtyRect) {
            item.draw(ctx, item.rect, hoveredIndex == i)
        }
        ctx.restoreGState()
    }
}
