import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 高密度实用型暂存卡片（`106 × 84pt`）：
/// - 静态底图与文字层独立缓存于 GPU 图层，鼠标快速滑过时零缩略图重采样、零 CoreText 重排；
/// - 动态高亮边框与右上角微操作胶囊（贴图 / 识字 / 删除）由轻量 `ShelfCardOverlayView` 独立瞬时绘制。
final class ShelfCardView: NSView, NSDraggingSource {
    static let cardSize = NSSize(width: 106, height: 84)

    let item: ShelfCardItem
    private let thumbnail: NSImage?
    private let thumbCG: CGImage?
    private let titleText: String
    private let subtitleText: String
    private let symbolName: String?
    private let textSnippet: String?
    private let canOCR: Bool
    private let isFileNonImage: Bool
    private let overlayView = ShelfCardOverlayView(frame: NSRect(origin: .zero, size: ShelfCardView.cardSize))

    var onHoverStart: ((ShelfCardView) -> Void)?
    var onToggleSelect: ((ShelfCardItem) -> Void)?
    var onCopy: ((ShelfCardItem) -> Void)?
    var onEdit: ((ShelfCardItem) -> Void)?
    var onPin: ((ShelfCardItem) -> Void)?
    var onOCR: ((ShelfCardItem) -> Void)?
    var onRemove: ((ShelfCardItem) -> Void)?
    var dragWriterProvider: ((ShelfCardItem) -> NSPasteboardWriting?)?

    var selectionOrder: Int? { didSet { overlayView.selectionOrder = selectionOrder } }
    private var dragStartPoint: NSPoint?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(item: ShelfCardItem, thumbnail: NSImage?, title: String, subtitle: String, symbol: String?, textSnippet: String?, canOCR: Bool, isFileNonImage: Bool = false) {
        self.item = item; self.thumbnail = thumbnail
        self.thumbCG = thumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        self.titleText = title; self.subtitleText = subtitle; self.symbolName = symbol
        self.textSnippet = textSnippet; self.canOCR = canOCR; self.isFileNonImage = isFileNonImage
        super.init(frame: NSRect(origin: .zero, size: Self.cardSize))
        self.wantsLayer = true; self.layerContentsRedrawPolicy = .onSetNeedsDisplay
        overlayView.canOCR = canOCR; overlayView.isFileNonImage = isFileNonImage
        addSubview(overlayView)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    func clearHover() { overlayView.setHover(active: false, btnTag: nil); toolTip = nil }

    func updateHover(at localPoint: CGPoint) {
        guard bounds.contains(localPoint) else { clearHover(); return }
        onHoverStart?(self)
        let hit = overlayView.actionSlots().slots.first(where: { $0.rect.contains(localPoint) })?.tag
        overlayView.setHover(active: true, btnTag: hit)
        switch hit {
        case 3:  toolTip = L("标注与编辑")
        case 0:  toolTip = isFileNonImage ? L("在访达中显示") : L("贴图到桌面")
        case 1:  toolTip = L("提取文字 (OCR)")
        case 2:  toolTip = L("从暂存架移除")
        default: toolTip = isFileNonImage ? L("点击复制文件 · 拖拽直接分享") : L("点击复制 · 拖拽分享 · ⌘+点击多选拼图")
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) { clearHover() }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = overlayView.actionSlots().slots.first(where: { $0.rect.contains(p) }) {
            switch hit.tag {
            case 3: onEdit?(item)
            case 0: onPin?(item)
            case 1: onOCR?(item)
            case 2: onRemove?(item)
            default: break
            }
            return
        }
        dragStartPoint = p
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartPoint else { return }
        let cur = convert(event.locationInWindow, from: nil)
        guard hypot(cur.x - start.x, cur.y - start.y) >= 5.0 else { return }
        dragStartPoint = nil
        guard let writer = dragWriterProvider?(item) else { return }
        let di = NSDraggingItem(pasteboardWriter: writer)
        let dragImg = thumbnail ?? NSImage(size: NSSize(width: 64, height: 46))
        di.setDraggingFrame(NSRect(x: cur.x - 32, y: cur.y - 23, width: 64, height: 46), contents: dragImg)
        beginDraggingSession(with: [di], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartPoint != nil else { return }
        dragStartPoint = nil
        if event.modifierFlags.contains(.command) { onToggleSelect?(item); return }
        onCopy?(item)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .generic]
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let isDark = GeekTheme.isDark
        let cardR = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: cardR, cornerWidth: 8.5, cornerHeight: 8.5, transform: nil)

        ctx.saveGState()
        let bg: NSColor = (textSnippet != nil)
            ? (isDark ? NSColor(srgbRed: 0.21, green: 0.20, blue: 0.16, alpha: 0.94) : NSColor(srgbRed: 0.99, green: 0.975, blue: 0.93, alpha: 0.98))
            : (isDark ? NSColor(white: 0.16, alpha: 0.94) : NSColor(white: 0.96, alpha: 0.98))
        ctx.setFillColor(bg.cgColor); ctx.addPath(path); ctx.fillPath()
        ctx.setStrokeColor((isDark ? NSColor.white.withAlphaComponent(0.11) : NSColor.black.withAlphaComponent(0.10)).cgColor)
        ctx.setLineWidth(0.8); ctx.addPath(path); ctx.strokePath()
        ctx.restoreGState()

        let mediaR = CGRect(x: 3.5, y: 3.5, width: bounds.width - 7, height: 61)
        let mediaClip = CGPath(roundedRect: mediaR, cornerWidth: 5.5, cornerHeight: 5.5, transform: nil)
        ctx.saveGState()
        ctx.addPath(mediaClip); ctx.clip()
        if textSnippet == nil {
            ctx.setFillColor((isDark ? NSColor(white: 0.10, alpha: 1) : NSColor(white: 0.91, alpha: 1)).cgColor)
            ctx.fill(mediaR)
        }
        if let cg = thumbCG {
            let iw = max(1, CGFloat(cg.width)), ih = max(1, CGFloat(cg.height))
            let sc = max(mediaR.width / iw, mediaR.height / ih)
            let dw = iw * sc, dh = ih * sc
            let dst = CGRect(x: mediaR.midX - dw * 0.5, y: mediaR.midY - dh * 0.5, width: dw, height: dh)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: dst.minY + dst.maxY); ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .medium; ctx.draw(cg, in: dst)
            ctx.restoreGState()
        } else if let snippet = textSnippet {
            (snippet as NSString).draw(in: mediaR.insetBy(dx: 4, dy: 3), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9.0, weight: .regular),
                .foregroundColor: isDark ? NSColor(white: 0.88, alpha: 1) : NSColor(white: 0.20, alpha: 1)
            ])
        } else if let sym = symbolName {
            GeekTheme.drawSymbol(sym, pointSize: 20, weight: .regular, in: mediaR, alpha: 0.82, tint: GeekTheme.inkSecondary)
        }
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor((isDark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.09)).cgColor)
        ctx.setLineWidth(0.6); ctx.addPath(mediaClip); ctx.strokePath()
        ctx.restoreGState()

        let footY: CGFloat = 67.5
        let metaFont = NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .regular)
        let metaW = min(50.0, ceil(GeekTheme.measureTextWidth(subtitleText, font: metaFont)))
        let titleW = max(24.0, bounds.width - 12.0 - metaW - 4.0)
        GeekTheme.drawText(titleText, in: CGRect(x: 5.5, y: footY - 0.5, width: titleW, height: 13), font: .systemFont(ofSize: 9.8, weight: .medium), color: GeekTheme.inkPrimary)
        GeekTheme.drawText(subtitleText, in: CGRect(x: bounds.width - 5.5 - metaW, y: footY, width: metaW, height: 12), font: metaFont, color: GeekTheme.inkMuted, align: .right)
    }
}

/// 卡片顶层轻量交互覆盖层（仅重绘悬停边框、选中角标与右上角微胶囊，零触碰底层缩略图）
private final class ShelfCardOverlayView: NSView {
    var canOCR: Bool = true
    var isFileNonImage: Bool = false
    var selectionOrder: Int? { didSet { if oldValue != selectionOrder { needsDisplay = true } } }
    private(set) var hovered = false
    private(set) var hoveredBtn: Int?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func setHover(active: Bool, btnTag: Int?) {
        guard hovered != active || hoveredBtn != btnTag else { return }
        hovered = active; hoveredBtn = btnTag
        needsDisplay = true
    }

    func actionSlots() -> (pill: CGRect, slots: [(tag: Int, rect: CGRect, sym: String, danger: Bool)]) {
        var defs: [(Int, String, Bool)] = []
        if canOCR { defs.append((3, "pencil", false)) }
        defs.append((0, isFileNonImage ? "folder" : "pin", false))
        if canOCR { defs.append((1, "text.viewfinder", false)) }
        defs.append((2, "xmark", true))
        let slotW: CGFloat = 18, slotH: CGFloat = 18, padX: CGFloat = 2
        let pillW = CGFloat(defs.count) * slotW + padX * 2
        let pill = CGRect(x: bounds.width - 4 - pillW, y: 5, width: pillW, height: slotH + 2)
        var slots: [(Int, CGRect, String, Bool)] = []
        var x = pill.minX + padX
        for (tag, sym, danger) in defs {
            slots.append((tag, CGRect(x: x, y: pill.minY + 1, width: slotW, height: slotH), sym, danger))
            x += slotW
        }
        return (pill, slots)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered || selectionOrder != nil, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let cardR = bounds.insetBy(dx: 0.7, dy: 0.7)
        let path = CGPath(roundedRect: cardR, cornerWidth: 8.5, cornerHeight: 8.5, transform: nil)

        ctx.saveGState()
        if hovered {
            ctx.setFillColor((GeekTheme.isDark ? NSColor.white.withAlphaComponent(0.045) : NSColor.white.withAlphaComponent(0.30)).cgColor)
            ctx.addPath(path); ctx.fillPath()
        }
        ctx.setStrokeColor(GeekTheme.accent.cgColor)
        ctx.setLineWidth(selectionOrder != nil ? 1.8 : 1.45)
        ctx.addPath(path); ctx.strokePath()
        ctx.restoreGState()

        if let order = selectionOrder {
            let badge = CGRect(x: 5, y: 5, width: 17, height: 17)
            ctx.saveGState()
            ctx.setFillColor(GeekTheme.accent.cgColor); ctx.fillEllipse(in: badge)
            GeekTheme.drawText("\(order)", in: badge, font: .monospacedDigitSystemFont(ofSize: 9.5, weight: .bold), color: .white, align: .center)
            ctx.restoreGState()
        }

        if hovered {
            let (pill, slots) = actionSlots()
            let pillPath = CGPath(roundedRect: pill, cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.saveGState()
            ctx.setFillColor(NSColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 0.82).cgColor)
            ctx.addPath(pillPath); ctx.fillPath()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.20).cgColor)
            ctx.setLineWidth(0.6); ctx.addPath(pillPath); ctx.strokePath()
            for btn in slots {
                if hoveredBtn == btn.tag {
                    let hi = CGPath(roundedRect: btn.rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 4.5, cornerHeight: 4.5, transform: nil)
                    ctx.setFillColor((btn.danger ? NSColor.systemRed : GeekTheme.accent).withAlphaComponent(0.94).cgColor)
                    ctx.addPath(hi); ctx.fillPath()
                }
                ToolbarView.drawSymbol(btn.sym, in: btn.rect.insetBy(dx: 1.5, dy: 1.5), alpha: 0.98, tint: .white)
            }
            ctx.restoreGState()
        }
    }
}

/// 支持「普通鼠标上下滚轮直接左右滚动 + 触控板双指横向轻扫 + 一键平滑翻页」的横向滚动容器
final class ShelfHorizontalScrollView: NSScrollView {
    var onScrollOffsetChanged: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        guard let doc = documentView else { super.scrollWheel(with: event); return }
        let maxX = max(0, doc.frame.width - contentView.bounds.width)
        guard maxX > 0.5 else { return }
        if event.hasPreciseScrollingDeltas && abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event); onScrollOffsetChanged?(); return
        }
        let nextX = ShelfTriggerGeometry.nextHorizontalScrollX(
            currentX: contentView.bounds.origin.x, maxX: maxX,
            deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY, hasPreciseDeltas: event.hasPreciseScrollingDeltas
        )
        contentView.scroll(to: NSPoint(x: nextX, y: 0))
        reflectScrolledClipView(contentView); onScrollOffsetChanged?()
    }

    func scrollBy(deltaX: CGFloat) {
        guard let doc = documentView else { return }
        let maxX = max(0, doc.frame.width - contentView.bounds.width)
        guard maxX > 0.5 else { return }
        let targetX = min(max(0, contentView.bounds.origin.x + deltaX), maxX)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18; ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            contentView.animator().setBoundsOrigin(NSPoint(x: targetX, y: 0))
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reflectScrolledClipView(self.contentView); self.onScrollOffsetChanged?()
            }
        })
    }
}

// MARK: - 暂存架顶栏与卡片操作控件

/// 暂存条左右边缘极简透明翻页控件（静止时仅呈现优雅 SF Symbol 箭头，悬停才浮出柔光微胶囊，告别笨重白条）
final class ShelfEdgeArrowButton: NSView {
    let symbolName: String
    var isNavEnabled: Bool = true { didSet { if oldValue != isNavEnabled { needsDisplay = true } } }
    var onClick: (() -> Void)?

    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    private var pressed = false { didSet { if oldValue != pressed { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(symbolName: String, toolTip: String) {
        self.symbolName = symbolName
        super.init(frame: .zero)
        self.toolTip = toolTip
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isNavEnabled ? .pointingHand : .arrow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false; pressed = false }
    override func mouseDown(with event: NSEvent) { guard isNavEnabled else { return }; pressed = true }
    override func mouseUp(with event: NSEvent) {
        let fire = pressed && isNavEnabled && bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if fire { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let isDark = GeekTheme.isDark
        let pill = CGRect(x: round(bounds.midX - 9.5), y: round(bounds.midY - 19), width: 19, height: 38)

        if isNavEnabled && (hovered || pressed) {
            let p = CGPath(roundedRect: pill, cornerWidth: 7, cornerHeight: 7, transform: nil)
            let fill = isDark
                ? NSColor.white.withAlphaComponent(pressed ? 0.18 : 0.11)
                : NSColor.black.withAlphaComponent(pressed ? 0.13 : 0.07)
            ctx.setFillColor(fill.cgColor)
            ctx.addPath(p); ctx.fillPath()
        }

        let alpha: CGFloat = !isNavEnabled ? 0.22 : (hovered ? 0.95 : 0.68)
        let tint = isDark ? NSColor.white : NSColor(white: 0.16, alpha: 1)
        GeekTheme.drawSymbol(symbolName, pointSize: 11.0, weight: .semibold, in: pill, alpha: alpha, tint: tint)
    }
}

/// 顶部暂存条右侧精炼控制列（原生毛玻璃调和色调 + SF Symbols 图标，彻底取代刺眼白底按钮块）
final class ShelfActionRailView: NSView {
    var itemCount: Int = 0 { didSet { if oldValue != itemCount { needsDisplay = true } } }
    var selectedCount: Int = 0 { didSet { if oldValue != selectedCount { needsDisplay = true } } }
    var isPinned: Bool = false { didSet { if oldValue != isPinned { needsDisplay = true } } }

    var onTogglePin: (() -> Void)?
    var onClose: (() -> Void)?
    var onAddClipboard: (() -> Void)?
    var onOpenCollage: (() -> Void)?

    private enum Slot: Int, CaseIterable { case pin, close, clipboard, collage }
    private var hoveredSlot: Slot? { didSet { if oldValue != hoveredSlot { needsDisplay = true; syncToolTip() } } }
    private var pressedSlot: Slot? { didSet { if oldValue != pressedSlot { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func rect(for slot: Slot) -> CGRect {
        let w = bounds.width
        switch slot {
        case .close:     return CGRect(x: w - 21, y: 0, width: 21, height: 21)
        case .pin:       return CGRect(x: w - 45, y: 0, width: 21, height: 21)
        case .clipboard: return CGRect(x: 0, y: 27, width: w, height: 25)
        case .collage:   return CGRect(x: 0, y: 57, width: w, height: 25)
        }
    }

    private func hitSlot(at pt: CGPoint) -> Slot? {
        Slot.allCases.first { rect(for: $0).contains(pt) }
    }

    override func resetCursorRects() {
        for s in Slot.allCases { addCursorRect(rect(for: s), cursor: .pointingHand) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        hoveredSlot = hitSlot(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) { hoveredSlot = nil; pressedSlot = nil }

    func clearHover() {
        if hoveredSlot != nil { hoveredSlot = nil }
    }

    func syncHover(atWindowPoint winPt: CGPoint) {
        let lp = convert(winPt, from: nil)
        hoveredSlot = bounds.contains(lp) ? hitSlot(at: lp) : nil
    }

    override func mouseDown(with event: NSEvent) {
        FloatingTooltipHUD.hide(for: self)
        pressedSlot = hitSlot(at: convert(event.locationInWindow, from: nil))
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { FloatingTooltipHUD.hide(for: self) }
    }

    override func mouseUp(with event: NSEvent) {
        let up = hitSlot(at: convert(event.locationInWindow, from: nil))
        let fire = (up != nil && up == pressedSlot) ? up : nil
        pressedSlot = nil
        switch fire {
        case .pin:       onTogglePin?()
        case .close:     onClose?()
        case .clipboard: onAddClipboard?()
        case .collage:   onOpenCollage?()
        case nil:        break
        }
    }

    private func syncToolTip() {
        guard let slot = hoveredSlot else { FloatingTooltipHUD.hide(for: self); return }
        let tip: String
        switch slot {
        case .pin:       tip = isPinned ? L("取消钉住（离开后自动收起）") : L("钉住暂存架保持展开")
        case .close:     tip = L("收起暂存架 (Esc)")
        case .clipboard: tip = L("将当前剪贴板图片、文件或文本加入暂存架")
        case .collage:   tip = L("打开多图拼接与合并 PDF 窗口（⌘+点击卡片可先自选顺序）")
        }
        FloatingTooltipHUD.show(tip, anchorRectInView: rect(for: slot), of: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let isDark = GeekTheme.isDark

        // Row 1 左侧：精炼计数标签
        let countRect = CGRect(x: 1, y: 1, width: max(20, bounds.width - 50), height: 19)
        GeekTheme.drawText(
            L("%@ 项", itemCount),
            in: countRect,
            font: .monospacedDigitSystemFont(ofSize: 11.2, weight: .semibold),
            color: isDark ? NSColor.white.withAlphaComponent(0.76) : NSColor(white: 0.24, alpha: 0.88)
        )

        // Row 1 右侧：原生 SF Symbol 幽灵图标按钮（钉住 / 关闭）
        drawIconButton(
            in: ctx, rect: rect(for: .pin),
            symbol: isPinned ? "pin.fill" : "pin",
            active: isPinned, hovered: hoveredSlot == .pin, pressed: pressedSlot == .pin,
            danger: false, isDark: isDark
        )
        drawIconButton(
            in: ctx, rect: rect(for: .close),
            symbol: "xmark",
            active: false, hovered: hoveredSlot == .close, pressed: pressedSlot == .close,
            danger: true, isDark: isDark
        )

        // Row 2：剪贴板入架（半透明融背景质感）
        drawRowButton(
            in: ctx, rect: rect(for: .clipboard),
            symbol: "plus.square.on.square", title: L("剪贴板"),
            accented: false, hovered: hoveredSlot == .clipboard, pressed: pressedSlot == .clipboard,
            isDark: isDark
        )

        // Row 3：拼图 / PDF（多选 ≥ 2 张时优雅点亮强调色）
        let collageTitle = selectedCount > 0 ? L("拼图 (%@)", selectedCount) : L("拼图 / PDF")
        drawRowButton(
            in: ctx, rect: rect(for: .collage),
            symbol: "rectangle.split.2x2", title: collageTitle,
            accented: selectedCount >= 2, hovered: hoveredSlot == .collage, pressed: pressedSlot == .collage,
            isDark: isDark
        )
    }

    private func drawIconButton(
        in ctx: CGContext, rect r: CGRect, symbol: String,
        active: Bool, hovered: Bool, pressed: Bool, danger: Bool, isDark: Bool
    ) {
        let path = CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil)
        if active || hovered || pressed {
            let fill: NSColor
            if active {
                fill = GeekTheme.accent.withAlphaComponent(pressed ? 0.95 : 0.88)
            } else if danger && hovered {
                fill = NSColor.systemRed.withAlphaComponent(pressed ? 0.24 : 0.14)
            } else {
                fill = isDark
                    ? NSColor.white.withAlphaComponent(pressed ? 0.18 : 0.11)
                    : NSColor.black.withAlphaComponent(pressed ? 0.12 : 0.065)
            }
            ctx.setFillColor(fill.cgColor)
            ctx.addPath(path); ctx.fillPath()
        }
        let tint: NSColor = active
            ? .white
            : (danger && hovered ? .systemRed : (isDark ? NSColor.white.withAlphaComponent(0.80) : NSColor(white: 0.22, alpha: 0.86)))
        GeekTheme.drawSymbol(symbol, pointSize: 10.5, weight: .semibold, in: r, alpha: 0.96, tint: tint)
    }

    private func drawRowButton(
        in ctx: CGContext, rect r: CGRect, symbol: String, title: String,
        accented: Bool, hovered: Bool, pressed: Bool, isDark: Bool
    ) {
        let p = CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 7, cornerHeight: 7, transform: nil)
        let fill: NSColor
        let stroke: NSColor
        let fg: NSColor
        if accented {
            fill = GeekTheme.accent.withAlphaComponent(pressed ? 0.96 : (hovered ? 0.92 : 0.86))
            stroke = GeekTheme.accent.withAlphaComponent(0.95)
            fg = .white
        } else {
            fill = isDark
                ? NSColor.white.withAlphaComponent(pressed ? 0.16 : (hovered ? 0.12 : 0.07))
                : NSColor.black.withAlphaComponent(pressed ? 0.11 : (hovered ? 0.075 : 0.045))
            stroke = isDark
                ? NSColor.white.withAlphaComponent(hovered ? 0.18 : 0.10)
                : NSColor.black.withAlphaComponent(hovered ? 0.14 : 0.08)
            fg = isDark ? NSColor.white.withAlphaComponent(0.92) : NSColor(white: 0.14, alpha: 0.94)
        }

        ctx.saveGState()
        ctx.setFillColor(fill.cgColor); ctx.addPath(p); ctx.fillPath()
        ctx.setStrokeColor(stroke.cgColor); ctx.setLineWidth(0.75); ctx.addPath(p); ctx.strokePath()
        ctx.restoreGState()

        let iconR = CGRect(x: r.minX + 7, y: r.minY, width: 13, height: r.height)
        GeekTheme.drawSymbol(symbol, pointSize: 10.8, weight: .medium, in: iconR, alpha: accented ? 0.96 : 0.82, tint: fg)
        let textR = CGRect(x: iconR.maxX + 5, y: r.minY, width: r.maxX - iconR.maxX - 9, height: r.height)
        GeekTheme.drawText(title, in: textR, font: .systemFont(ofSize: 11.2, weight: .medium), color: fg)
    }
}
