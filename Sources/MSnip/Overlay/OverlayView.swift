import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 覆盖层交互阶段与拖拽状态
enum DragOperation {
    case pendingSnapOrCreate(anchor: CGPoint, snapRect: CGRect?)
    case creatingSelection(anchor: CGPoint)
    case movingSelection(initialRect: CGRect, mouseStart: CGPoint)
    case resizingSelection(handle: ResizeHandle, initialRect: CGRect, mouseStart: CGPoint)
    case drawingAnnotation(tool: ToolKind, start: CGPoint)
    case movingAnnotation(index: Int, lastPoint: CGPoint, moved: Bool)
}

/// 单块显示器的全屏冻结覆盖层画布（`isFlipped = true`，左上角为 `(0, 0)`）
final class OverlayView: NSView, NSTextFieldDelegate {
    let snapshot: ScreenSnapshot
    let regionDetector: RegionDetector
    private let frozenNSImage: NSImage
    let toolbar = ToolbarView()

    // 外部会话回调
    var onSelectionActivated: ((OverlayView) -> Void)?
    var onFinishCopy: ((CGImage, CGFloat) -> Void)?
    var onFinishSave: ((CGImage, CGFloat) -> Void)?
    var onFinishPin: ((CGImage, CGFloat, CGPoint, NSScreen) -> Void)?
    var onCancel: (() -> Void)?
    var onStyleChanged: ((Int, CGFloat) -> Void)?

    // 自动矩阵识别预览状态（未锁定选区时生效）
    var autoSnapStack: [CGRect] = []
    var autoSnapIndex: Int = 0
    var scrollSnapAccumulator: CGFloat = 0

    var hoveredAutoRect: CGRect? {
        guard selection == nil, autoSnapStack.indices.contains(autoSnapIndex) else { return nil }
        return autoSnapStack[autoSnapIndex]
    }

    // 正式选区与标注编辑状态
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

    // 文本输入框状态（实现见 OverlayTextEdit.swift）
    var textField: NSTextField?
    var editingTextOrigin: CGPoint?
    var editingExistingIndex: Int?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(
        snapshot: ScreenSnapshot,
        regionDetector: RegionDetector,
        initialColorIndex: Int,
        initialLineWidth: CGFloat,
        pinHint: String
    ) {
        self.snapshot = snapshot
        self.regionDetector = regionDetector
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

    /// 刷新指定局部坐标处的自动识别矩阵栈
    func updateAutoSnap(at localPoint: CGPoint) {
        guard selection == nil else { return }
        let newStack = regionDetector.detectHierarchy(at: localPoint, in: snapshot)
        if newStack != autoSnapStack {
            autoSnapStack = newStack
            autoSnapIndex = 0
            scrollSnapAccumulator = 0
            needsDisplay = true
        }
    }

    /// 按全局鼠标位置初始化首帧自动高亮框
    func refreshAutoSnapAtCurrentMouse() {
        guard let win = window else { return }
        let winPt = win.convertPoint(fromScreen: NSEvent.mouseLocation)
        let localPt = convert(winPt, from: nil)
        if bounds.contains(localPt) {
            updateAutoSnap(at: localPt)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // 1) 绘制全屏冻结底图（isFlipped=true 下必须传 respectFlipped: true 防止画面倒置）
        frozenNSImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1.0, respectFlipped: true, hints: nil)

        let highlightRect = selection ?? hoveredAutoRect

        // 2) 绘制暗化遮罩（正式选区或自动识别预览框内部镂空保留 100% 原始亮度）
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.46).cgColor)
        if let hl = highlightRect, hl.width > 0, hl.height > 0 {
            ctx.addRect(bounds)
            ctx.addRect(hl)
            ctx.fillPath(using: .evenOdd)
        } else {
            ctx.fill(bounds)
        }
        ctx.restoreGState()

        // 3) 若尚未锁定正式选区，绘制自动识别矩阵高亮预览框与层级提示
        if selection == nil, let snap = hoveredAutoRect {
            drawAutoSnapChrome(ctx: ctx, rect: snap)
            return
        }

        guard let sel = selection, sel.width >= 1, sel.height >= 1 else { return }

        // 4) 绘制正式选区内的标注与实时草稿
        AnnotationRenderer.drawAnnotations(
            in: ctx,
            annotations: doc.objects,
            draft: draftAnnotation,
            skipIndex: editingExistingIndex,
            sampler: snapshot.sampler,
            imageScale: snapshot.scaleFactor,
            clipRect: sel
        )

        if let idx = selectedObjectIndex, doc.objects.indices.contains(idx) {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.systemCyan.cgColor)
            ctx.setLineWidth(1.2)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.stroke(doc.objects[idx].bounds)
            ctx.restoreGState()
        }

        // 5) 正式选区外框 + 八向控制柄 + 尺寸徽标
        drawSelectionChrome(ctx: ctx, sel: sel)
    }

    private func drawAutoSnapChrome(ctx: CGContext, rect: CGRect) {
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemCyan.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(2.0)
        ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        ctx.restoreGState()

        let pxW = Int((rect.width * snapshot.scaleFactor).rounded())
        let pxH = Int((rect.height * snapshot.scaleFactor).rounded())
        let tierHint = autoSnapStack.count > 1
            ? "  ·  \(autoSnapIndex + 1)/\(autoSnapStack.count) 滚轮切换 · 单击锁定"
            : "  ·  单击锁定"
        drawHUDPill(ctx: ctx, anchorRect: rect, text: "\(pxW) × \(pxH)\(tierHint)")
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
        ctx.restoreGState()

        let pxW = Int((sel.width * snapshot.scaleFactor).rounded())
        let pxH = Int((sel.height * snapshot.scaleFactor).rounded())
        drawHUDPill(ctx: ctx, anchorRect: sel, text: "\(pxW) × \(pxH)")
    }

    private func drawHUDPill(ctx: CGContext, anchorRect: CGRect, text: String) {
        let nsText = text as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let textSize = nsText.size(withAttributes: attrs)
        let badgeW = ceil(textSize.width + 14)
        let badgeH: CGFloat = 22
        let badgeX = min(max(6, anchorRect.minX), bounds.width - badgeW - 6)
        let badgeY = anchorRect.minY >= (badgeH + 8) ? (anchorRect.minY - badgeH - 6) : (anchorRect.minY + 6)
        let badgeRect = CGRect(x: badgeX, y: badgeY, width: badgeW, height: badgeH)

        ctx.saveGState()
        let pill = CGPath(roundedRect: badgeRect, cornerWidth: 5, cornerHeight: 5, transform: nil)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.78).cgColor)
        ctx.addPath(pill)
        ctx.fillPath()
        nsText.draw(
            at: CGPoint(x: badgeRect.minX + 7, y: badgeRect.minY + (badgeH - textSize.height) * 0.5),
            withAttributes: attrs
        )
        ctx.restoreGState()
    }

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
        let y = (belowY + barSize.height + 8 <= bounds.height)
            ? belowY
            : (aboveY >= 8 ? aboveY : max(8, sel.maxY - barSize.height - 8))
        toolbar.setFrameOrigin(NSPoint(x: round(x), y: round(y)))
    }

    func clearSelectionFromSibling() {
        cancelTextEditing()
        selection = nil
        autoSnapStack = []
        selectedObjectIndex = nil
        draftAnnotation = nil
        doc = AnnotationDocument()
    }
}
