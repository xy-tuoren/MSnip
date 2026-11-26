import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 底部紧凑单行素材缩略卡（支持单击看大图、左下角 ✎ 编辑裁剪/打码、右键快捷旋转/还原、直接拖拽换序、右上角 ✕ 移除）
final class CollageFilmstripCardView: NSView {
    static let cardSize = NSSize(width: 68, height: 48)
    static let spacing: CGFloat = 6
    static let step: CGFloat = cardSize.width + spacing

    let index: Int
    let totalCount: Int
    let item: CollageSourceItem
    var onInspect: ((Int) -> Void)?
    var onEdit: ((Int) -> Void)?
    var onRotate90: ((Int) -> Void)?
    var onFlipH: ((Int) -> Void)?
    var onRevert: ((Int) -> Void)?
    var onRemove: ((Int) -> Void)?
    var onDragMove: ((Int, CGFloat) -> Void)?
    var onDragEnd: ((Int) -> Void)?

    private var hovered = false { didSet { if oldValue != hovered { needsDisplay = true } } }
    private var hoveredRemove = false { didSet { if oldValue != hoveredRemove { needsDisplay = true } } }
    private var hoveredEdit = false { didSet { if oldValue != hoveredEdit { needsDisplay = true } } }
    private var isDragging = false { didSet { if oldValue != isDragging { needsDisplay = true } } }
    private var dragDownInParent: CGPoint?
    private var origOriginX: CGFloat = 0

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: isDragging ? .closedHand : .pointingHand) }

    init(index: Int, totalCount: Int, item: CollageSourceItem) {
        self.index = index; self.totalCount = totalCount; self.item = item
        super.init(frame: NSRect(origin: .zero, size: Self.cardSize))
        self.toolTip = "\(item.title) · \(item.cgImage.width)×\(item.cgImage.height)\n单击看大图 · 左下 ✎ 编辑/裁剪 · 拖拽换序 · 右键更多"
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private var removeRect: CGRect { CGRect(x: bounds.width - 17, y: 3, width: 14, height: 14) }
    private var editRect: CGRect { CGRect(x: 3, y: bounds.height - 17, width: 15, height: 14) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false; hoveredRemove = false; hoveredEdit = false }
    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoveredRemove = removeRect.contains(p)
        hoveredEdit = editRect.contains(p)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if removeRect.contains(p) { onRemove?(index); return }
        if editRect.contains(p) { onEdit?(index); return }
        dragDownInParent = superview?.convert(event.locationInWindow, from: nil)
        origOriginX = frame.origin.x; isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragDownInParent, let parent = superview, totalCount > 1 else { return }
        let cur = parent.convert(event.locationInWindow, from: nil), dx = cur.x - start.x
        if !isDragging && hypot(dx, cur.y - start.y) > 5 {
            isDragging = true; parent.addSubview(self, positioned: .above, relativeTo: nil)
            alphaValue = 0.92; window?.invalidateCursorRects(for: self)
        }
        guard isDragging else { return }
        frame.origin.x = min(CGFloat(max(0, totalCount - 1)) * Self.step, max(0, origOriginX + dx))
        onDragMove?(index, frame.midX)
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = isDragging, hadDown = (dragDownInParent != nil)
        dragDownInParent = nil; isDragging = false; alphaValue = 1.0
        if wasDragging { onDragEnd?(index) }
        else if hadDown && bounds.contains(convert(event.locationInWindow, from: nil)) { onInspect?(index) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        func add(_ t: String, _ sel: Selector) { let i = NSMenuItem(title: t, action: sel, keyEquivalent: ""); i.target = self; m.addItem(i) }
        add("编辑 / 裁剪 / 标注此图…", #selector(actEdit))
        add("顺时针旋转 90°", #selector(actRot))
        add("水平镜像翻转", #selector(actFlip))
        if item.originalBackup != nil { add("还原初始原图", #selector(actRevert)) }
        m.addItem(.separator())
        add("全尺寸大图预览", #selector(actInspect))
        add("从列表中移除", #selector(actRemove))
        return m
    }

    @objc private func actEdit() { onEdit?(index) }
    @objc private func actRot() { onRotate90?(index) }
    @objc private func actFlip() { onFlipH?(index) }
    @objc private func actRevert() { onRevert?(index) }
    @objc private func actInspect() { onInspect?(index) }
    @objc private func actRemove() { onRemove?(index) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: r, cornerWidth: 7.5, cornerHeight: 7.5, transform: nil)
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        ctx.setFillColor((GeekTheme.isDark ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.93, alpha: 1)).cgColor)
        ctx.fill(r)
        let img = item.thumbnail
        let sc = max(r.width / max(1, img.size.width), r.height / max(1, img.size.height))
        let dw = img.size.width * sc, dh = img.size.height * sc
        img.draw(in: NSRect(x: r.midX - dw * 0.5, y: r.midY - dh * 0.5, width: dw, height: dh), from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(((hovered || isDragging) ? GeekTheme.accent : GeekTheme.borderStrong).cgColor)
        ctx.setLineWidth(isDragging ? 2.0 : (hovered ? 1.4 : 0.75)); ctx.addPath(path); ctx.strokePath()

        let badge = CGRect(x: 3.5, y: 3.5, width: 15, height: 14)
        let bp = CGPath(roundedRect: badge, cornerWidth: 7, cornerHeight: 7, transform: nil)
        ctx.setFillColor((item.originalBackup != nil ? GeekTheme.accent : NSColor.black).withAlphaComponent(0.68).cgColor)
        ctx.addPath(bp); ctx.fillPath()
        GeekTheme.drawText("\(index + 1)", in: badge, font: .monospacedDigitSystemFont(ofSize: 8.8, weight: .bold), color: .white, align: .center)

        if hovered && !isDragging {
            let rr = removeRect, rp = CGPath(roundedRect: rr, cornerWidth: 7, cornerHeight: 7, transform: nil)
            ctx.setFillColor((hoveredRemove ? NSColor.systemRed.withAlphaComponent(0.92) : NSColor.black.withAlphaComponent(0.68)).cgColor)
            ctx.addPath(rp); ctx.fillPath()
            ToolbarView.drawSymbol("xmark", in: rr.insetBy(dx: 2, dy: 2), alpha: 0.96, tint: .white)

            let er = editRect, ep = CGPath(roundedRect: er, cornerWidth: 7, cornerHeight: 7, transform: nil)
            ctx.setFillColor((hoveredEdit ? GeekTheme.accent.withAlphaComponent(0.95) : NSColor.black.withAlphaComponent(0.68)).cgColor)
            ctx.addPath(ep); ctx.fillPath()
            ToolbarView.drawSymbol("pencil", in: er.insetBy(dx: 2.2, dy: 2.0), alpha: 0.96, tint: .white)

            let mag = CGRect(x: bounds.width - 17, y: bounds.height - 17, width: 14, height: 14)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.54).cgColor); ctx.fillEllipse(in: mag)
            ToolbarView.drawSymbol("magnifyingglass", in: mag.insetBy(dx: 2.2, dy: 2.2), alpha: 0.94, tint: .white)
        }
        ctx.restoreGState()
    }
}

/// 拼图工作室紧凑左右分栏布局与拖拽排序扩展
extension CollageStudioController {
    func layoutUI() {
        guard let root = rootView else { return }
        let w = root.bounds.width, h = root.bounds.height
        let barH: CGFloat = 38, pad: CGFloat = 10, gap: CGFloat = 9, sideW: CGFloat = 228
        topBarView?.frame = NSRect(x: 0, y: 0, width: w, height: barH)
        topBarDivider?.frame = NSRect(x: 0, y: barH, width: w, height: 1)
        layoutTopBarMeta()

        if inlineEditor.isActive {
            [canvasView, stripCard, inspectorCard].forEach { $0?.isHidden = true }
            inlineEditor.isHidden = false
            inlineEditor.frame = NSRect(x: 0, y: barH + 1, width: w, height: max(200, h - barH - 1))
            inlineEditor.layoutEditor()
            return
        }
        inlineEditor.isHidden = true
        [canvasView, stripCard, inspectorCard].forEach { $0?.isHidden = false }

        let workY = barH + 1 + pad, workH = max(340, h - workY - pad)
        let leftW = max(420, w - sideW - pad * 2 - gap), stripH: CGFloat = 66
        let canvasH = max(240, workH - stripH - 8)

        canvasView?.frame = NSRect(x: pad, y: workY, width: leftW, height: canvasH)
        stripCard?.frame = NSRect(x: pad, y: workY + canvasH + 8, width: leftW, height: stripH)
        let railW: CGFloat = 100, railX = leftW - railW - 8
        stripDivider?.frame = NSRect(x: railX - 8, y: 9, width: 1, height: stripH - 18)
        stripScrollView?.frame = NSRect(x: 8, y: 7, width: max(120, railX - 24), height: 52)
        addClipBtn?.frame = NSRect(x: railX, y: 7, width: railW, height: 24)
        addRecentBtn?.frame = NSRect(x: railX, y: 35, width: 68, height: 24)
        clearBtn?.frame = NSRect(x: railX + 72, y: 35, width: 28, height: 24)

        let rx = pad + leftW + gap, isPDF = (studioMode == .pdfMerge)
        inspectorCard?.frame = NSRect(x: rx, y: workY, width: sideW, height: workH)
        let ix: CGFloat = 10, inW = sideW - 20
        var cy: CGFloat = 10

        let showCols = (!isPDF && options.layout == .grid)
        let showWMInput = (options.watermark != .none)
        [layoutSeg, div1, styleHeaderLabel, presetBar, gapRow, radiusRow, shadowPill, alignLabel, alignSeg, aspectLabel, aspectSeg, div3, badgeSeg].forEach { $0?.isHidden = isPDF }
        colsSeg?.isHidden = !showCols; pdfPageNumSeg?.isHidden = !isPDF; pdfHintLabel?.isHidden = !isPDF
        watermarkBox?.isHidden = !showWMInput
        badgeLabel?.stringValue = isPDF ? "页码" : "角标"

        if !isPDF {
            layoutSeg?.frame = NSRect(x: ix, y: cy, width: inW, height: 25); cy += 30
            if showCols { colsSeg?.frame = NSRect(x: ix, y: cy, width: inW, height: 22); cy += 27 }
            div1?.frame = NSRect(x: ix, y: cy, width: inW, height: 1); cy += 8
            styleHeaderLabel?.frame = NSRect(x: ix, y: cy + 1.5, width: 70, height: 16)
            presetBar?.frame = NSRect(x: ix + inW - 110, y: cy, width: 110, height: 19); cy += 23
            gapRow?.frame = NSRect(x: ix, y: cy, width: inW, height: 21); cy += 23
            padRow?.frame = NSRect(x: ix, y: cy, width: inW, height: 21); cy += 23
            radiusRow?.frame = NSRect(x: ix, y: cy, width: inW, height: 21); cy += 25
            bgLabel?.frame = NSRect(x: ix, y: cy + 3, width: 28, height: 16)
            bgTrigger?.frame = NSRect(x: ix + 29, y: cy, width: 95, height: 22)
            bgEyedropperBtn?.frame = NSRect(x: ix + 127, y: cy, width: 24, height: 22)
            shadowPill?.frame = NSRect(x: ix + inW - 53, y: cy + 0.5, width: 53, height: 21); cy += 28
            div2?.frame = NSRect(x: ix, y: cy, width: inW, height: 1); cy += 8
            alignLabel?.frame = NSRect(x: ix, y: cy + 3, width: 30, height: 16)
            alignSeg?.frame = NSRect(x: ix + 33, y: cy, width: inW - 33, height: 22); cy += 27
            aspectLabel?.frame = NSRect(x: ix, y: cy + 3, width: 30, height: 16)
            aspectSeg?.frame = NSRect(x: ix + 33, y: cy, width: inW - 33, height: 22); cy += 28
            div3?.frame = NSRect(x: ix, y: cy, width: inW, height: 1); cy += 8
            badgeLabel?.frame = NSRect(x: ix, y: cy + 3, width: 30, height: 16)
            badgeSeg?.frame = NSRect(x: ix + 33, y: cy, width: inW - 33, height: 22); cy += 27
            watermarkLabel?.frame = NSRect(x: ix, y: cy + 3, width: 30, height: 16)
            watermarkSeg?.frame = NSRect(x: ix + 33, y: cy, width: inW - 33, height: 22); cy += 27
            if showWMInput { watermarkBox?.frame = NSRect(x: ix, y: cy, width: inW, height: 25) }
        } else {
            padRow?.frame = NSRect(x: ix, y: cy, width: inW, height: 22); cy += 28
            bgLabel?.frame = NSRect(x: ix, y: cy + 3, width: 28, height: 16)
            bgTrigger?.frame = NSRect(x: ix + 29, y: cy, width: 147, height: 22)
            bgEyedropperBtn?.frame = NSRect(x: ix + 180, y: cy, width: 28, height: 22); cy += 30
            div2?.frame = NSRect(x: ix, y: cy, width: inW, height: 1); cy += 9
            badgeLabel?.frame = NSRect(x: ix, y: cy + 3, width: 30, height: 16)
            pdfPageNumSeg?.frame = NSRect(x: ix + 33, y: cy, width: inW - 33, height: 23); cy += 29
            watermarkLabel?.frame = NSRect(x: ix, y: cy + 3, width: 30, height: 16)
            watermarkSeg?.frame = NSRect(x: ix + 33, y: cy, width: inW - 33, height: 23); cy += 29
            if showWMInput { watermarkBox?.frame = NSRect(x: ix, y: cy, width: inW, height: 26); cy += 32 }
            pdfHintLabel?.frame = NSRect(x: ix, y: cy + 2, width: inW, height: 38)
        }

        [copyBtn, annotateBtn, pinBtn, saveBtn].forEach { $0?.isHidden = isPDF }
        pdfBtn?.isHidden = !isPDF
        if isPDF {
            let py = workH - 10 - 32
            pdfBtn?.frame = NSRect(x: ix, y: py, width: inW, height: 32)
            divExport?.frame = NSRect(x: ix, y: py - 9, width: inW, height: 1)
        } else {
            let row2Y = workH - 10 - 27, row1Y = row2Y - 5 - 30, thirdW = floor((inW - 10) / 3.0)
            copyBtn?.frame = NSRect(x: ix, y: row1Y, width: inW, height: 30)
            annotateBtn?.frame = NSRect(x: ix, y: row2Y, width: thirdW, height: 27)
            pinBtn?.frame = NSRect(x: ix + thirdW + 5, y: row2Y, width: thirdW, height: 27)
            saveBtn?.frame = NSRect(x: ix + (thirdW + 5) * 2, y: row2Y, width: inW - (thirdW + 5) * 2, height: 27)
            divExport?.frame = NSRect(x: ix, y: row1Y - 8, width: inW, height: 1)
        }
    }

    func reloadFilmstrip() {
        guard let doc = stripDocView, let sv = stripScrollView else { return }
        doc.subviews.forEach { $0.removeFromSuperview() }
        let hasItems = !items.isEmpty
        [copyBtn, annotateBtn, pinBtn, saveBtn, pdfBtn, clearBtn].forEach { $0?.isEnabled = hasItems }

        let step = CollageFilmstripCardView.step
        for (i, item) in items.enumerated() {
            let card = CollageFilmstripCardView(index: i, totalCount: items.count, item: item)
            card.frame = NSRect(x: CGFloat(i) * step, y: 2, width: CollageFilmstripCardView.cardSize.width, height: CollageFilmstripCardView.cardSize.height)
            card.onInspect = { [weak self] idx in self?.openSourceLightbox(startIndex: idx) }
            card.onEdit = { [weak self] idx in self?.openSourceEditor(at: idx) }
            card.onRotate90 = { [weak self] idx in self?.transformSourceItem(at: idx, using: ImageTransform.rotateClockwise90) }
            card.onFlipH = { [weak self] idx in self?.transformSourceItem(at: idx, using: ImageTransform.flipHorizontal) }
            card.onRevert = { [weak self] idx in self?.revertSourceItem(at: idx) }
            card.onRemove = { [weak self] idx in
                guard let self, self.items.indices.contains(idx) else { return }
                self.items.remove(at: idx); self.reloadFilmstrip(); self.invalidateCollageEditsAndRender()
            }
            card.onDragMove = { [weak self] from, midX in self?.handleCardDragMove(from: from, midX: midX) }
            card.onDragEnd = { [weak self] from in self?.handleCardDragEnd(from: from) }
            doc.addSubview(card)
        }
        let addX = CGFloat(items.count) * step
        let addTile = CollageAddTileView(frame: NSRect(x: addX, y: 2, width: 50, height: CollageFilmstripCardView.cardSize.height))
        addTile.onClick = { [weak self] in self?.pickImageFiles() }
        doc.addSubview(addTile)
        doc.frame = NSRect(x: 0, y: 0, width: max(sv.bounds.width, addX + 54), height: sv.bounds.height)
    }

    func handleCardDragMove(from: Int, midX: CGFloat) {
        guard let doc = stripDocView, items.count > 1 else { return }
        let step = CollageFilmstripCardView.step
        let target = min(items.count - 1, max(0, Int(floor(midX / step))))
        guard target != dragTargetIndex else { return }
        dragTargetIndex = target
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            for case let card as CollageFilmstripCardView in doc.subviews where card.index != from {
                let slot = (from < target && card.index > from && card.index <= target) ? card.index - 1
                    : (from > target && card.index >= target && card.index < from) ? card.index + 1 : card.index
                card.animator().frame.origin.x = CGFloat(slot) * step
            }
        }
    }

    func handleCardDragEnd(from: Int) {
        let target = dragTargetIndex; dragTargetIndex = nil
        if let target, target != from, items.indices.contains(from), items.indices.contains(target) {
            items.insert(items.remove(at: from), at: target); reloadFilmstrip(); invalidateCollageEditsAndRender()
        } else { reloadFilmstrip() }
    }
}
