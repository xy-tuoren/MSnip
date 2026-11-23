import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 截图选区下方的浅色紧凑悬浮主工具栏（复刻 PixPin 单行清爽工具条，支持左侧手柄自由拖拽位置）
final class ToolbarView: NSView {
    enum Action {
        case selectTool(ToolKind?)
        case toggleTextCapsule
        case selectColor(Int)
        case toggleEyedropper
        case selectStroke(CGFloat)
        case undo
        case redo
        case clearAnnotations
        case cycleCornerRadius
        case cycleBackdrop
        case captureWindow
        case toggleInPlaceOCR
        case extractTextWindow
        case recognizeLatex
        case toggleInPlaceTranslate
        case translateWindow
        case startLongShot
        case startRecording
        case selectRecordingFormat(RecordingFormat)
        case toggleRecordingHUD
        case confirmBeginRecording
        case exitRecordingMode
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
    var onDraggedOrigin: ((NSPoint) -> Void)?

    var activeTool: ToolKind? {
        didSet {
            if let t = activeTool { rememberGroupChoice(t) }
            if oldValue != activeTool { markItemsDirty() }
        }
    }
    var lastShapeTool: ToolKind = .rect
    var lastBrushTool: ToolKind = .pen
    var lastRedactTool: ToolKind = .mosaic

    var textCapsule: Bool = false { didSet { if oldValue != textCapsule { markItemsDirty() } } }
    var inPlaceOCRActive: Bool = false { didSet { if oldValue != inPlaceOCRActive { markItemsDirty() } } }
    var inPlaceTranslateActive: Bool = false { didSet { if oldValue != inPlaceTranslateActive { markItemsDirty() } } }
    var ocrAutoOpenDualPane: Bool = false { didSet { if oldValue != ocrAutoOpenDualPane { markItemsDirty() } } }
    var translateAutoOpenDualPane: Bool = false { didSet { if oldValue != translateAutoOpenDualPane { markItemsDirty() } } }
    var nextStepNumber: Int = 1 { didSet { if oldValue != nextStepNumber { markItemsDirty() } } }
    var colorIndex: Int = 0 { didSet { if oldValue != colorIndex { markItemsDirty() } } }
    var customColor: RGBAColor? { didSet { if oldValue != customColor { markItemsDirty() } } }
    var eyedropperActive: Bool = false { didSet { if oldValue != eyedropperActive { markItemsDirty() } } }
    var lineWidth: CGFloat = 3.0 { didSet { if oldValue != lineWidth { markItemsDirty() } } }
    var cornerRadiusPt: CGFloat = 0 { didSet { if oldValue != cornerRadiusPt { markItemsDirty() } } }
    var backdropStyle: BackdropStyle = .none { didSet { if oldValue != backdropStyle { markItemsDirty() } } }
    var canUndo: Bool = false { didSet { if oldValue != canUndo { markItemsDirty() } } }
    var canRedo: Bool = false { didSet { if oldValue != canRedo { markItemsDirty() } } }
    var pinHint: String = "⌥T" { didSet { if oldValue != pinHint { markItemsDirty() } } }
    var canvasKeyMap: [CanvasAction: String] = CanvasAction.defaultMap { didSet { if oldValue != canvasKeyMap { markItemsDirty() } } }
    var isPinEditorMode: Bool = false { didSet { if oldValue != isPinEditorMode { markItemsDirty() } } }

    func keyUpper(_ action: CanvasAction) -> String {
        (canvasKeyMap[action] ?? action.defaultKey).uppercased()
    }
    var isRecordingMode: Bool = false { didSet { if oldValue != isRecordingMode { markItemsDirty() } } }
    var recordingFormat: RecordingFormat = .gif { didSet { if oldValue != recordingFormat { markItemsDirty() } } }
    var recordingHUDEnabled: Bool = true { didSet { if oldValue != recordingHUDEnabled { markItemsDirty() } } }

    var items: [HitItem] = []
    private var itemsDirty = true
    private var hoveredIndex: Int?
    private var isDraggingBar = false
    private var dragMouseStart: NSPoint = .zero
    private var dragOriginStart: NSPoint = .zero

    override var isFlipped: Bool { true }

    static let barHeight: CGFloat = 40
    static let gripWidth: CGFloat = 18

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 540, height: Self.barHeight))
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor(srgbRed: 0.04, green: 0.08, blue: 0.16, alpha: 1.0).cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: 4)
        rebuildItems()
        itemsDirty = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func rememberGroupChoice(_ tool: ToolKind) {
        switch tool {
        case .rect, .ellipse: lastShapeTool = tool
        case .pen, .highlighter, .line: lastBrushTool = tool
        case .mosaic, .gaussianBlur: lastRedactTool = tool
        default: break
        }
    }

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
        if itemsDirty { rebuildItems(); itemsDirty = false }
    }

    override func mouseMoved(with event: NSEvent) {
        ensureItemsUpToDate()
        let p = convert(event.locationInWindow, from: nil)
        let idx = items.firstIndex(where: { $0.rect.contains(p) && $0.enabled })
        if idx != nil {
            NSCursor.pointingHand.set()
        } else if !isPinEditorMode && p.x <= Self.gripWidth + 2 {
            NSCursor.openHand.set()
        } else {
            NSCursor.arrow.set()
        }
        if idx != hoveredIndex {
            let oldIdx = hoveredIndex
            hoveredIndex = idx
            toolTip = idx.map { items[$0].tooltip } ?? (p.x <= Self.gripWidth ? "按住拖拽移动工具栏位置" : nil)
            if let o = oldIdx, items.indices.contains(o) { setNeedsDisplay(items[o].rect.insetBy(dx: -3, dy: -3)) }
            if let n = idx, items.indices.contains(n) { setNeedsDisplay(items[n].rect.insetBy(dx: -3, dy: -3)) }
        }
    }

    override func mouseExited(with event: NSEvent) {
        if let old = hoveredIndex {
            hoveredIndex = nil
            if items.indices.contains(old) { setNeedsDisplay(items[old].rect.insetBy(dx: -3, dy: -3)) }
            else { needsDisplay = true }
        }
    }

    override func mouseDown(with event: NSEvent) {
        ensureItemsUpToDate()
        let p = convert(event.locationInWindow, from: nil)
        if !isPinEditorMode && p.x <= Self.gripWidth + 2 {
            isDraggingBar = true
            dragMouseStart = NSEvent.mouseLocation
            dragOriginStart = frame.origin
            NSCursor.closedHand.push()
            return
        }
        guard let item = items.first(where: { $0.rect.contains(p) && $0.enabled }) else { return }
        if case .save = item.action, event.modifierFlags.contains(.option) {
            onAction?(.quickSave)
        } else if case .toggleInPlaceOCR = item.action {
            let openDual = event.modifierFlags.contains(.option) ? !ocrAutoOpenDualPane : (ocrAutoOpenDualPane && !inPlaceOCRActive)
            onAction?(openDual ? .extractTextWindow : .toggleInPlaceOCR)
        } else if case .toggleInPlaceTranslate = item.action {
            let openDual = event.modifierFlags.contains(.option) ? !translateAutoOpenDualPane : (translateAutoOpenDualPane && !inPlaceTranslateActive)
            onAction?(openDual ? .translateWindow : .toggleInPlaceTranslate)
        } else {
            onAction?(item.action)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingBar, let sup = superview else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - dragMouseStart.x
        let dy = -(now.y - dragMouseStart.y) // superview (OverlayView) isFlipped = true
        let nx = min(max(6, round(dragOriginStart.x + dx)), sup.bounds.width - bounds.width - 6)
        let ny = min(max(6, round(dragOriginStart.y + dy)), sup.bounds.height - bounds.height - 6)
        let nextOrigin = NSPoint(x: nx, y: ny)
        setFrameOrigin(nextOrigin)
        onDraggedOrigin?(nextOrigin)
    }

    override func mouseUp(with event: NSEvent) {
        if isDraggingBar {
            isDraggingBar = false
            NSCursor.pop()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        ensureItemsUpToDate()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.saveGState()
        ctx.clip(to: dirtyRect)

        MSnipUITheme.drawPorcelainBar(ctx: ctx, bounds: bounds, radius: 9.5)

        if !isPinEditorMode {
            Self.drawGripDots(ctx: ctx, in: CGRect(x: 4, y: 0, width: Self.gripWidth - 2, height: Self.barHeight))
        }

        for (i, item) in items.enumerated() where item.rect.insetBy(dx: -4, dy: -4).intersects(dirtyRect) {
            item.draw(ctx, item.rect, hoveredIndex == i)
        }
        ctx.restoreGState()
    }
}
