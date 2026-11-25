import AppKit
import CoreGraphics
import Foundation

/// 顶部紧凑暂存条根容器：负责拖入文件/文本高亮、右侧操作区竖向分割线与规整内边距
final class ShelfClotheslineView: NSView {
    var onDropFiles: (([URL]) -> Void)?
    var onDropText: ((String) -> Void)?
    var dividerX: CGFloat = 0 { didSet { if abs(oldValue - dividerX) > 0.5 { needsDisplay = true } } }

    private var isDragTargeted = false { didSet { if oldValue != isDragTargeted { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .string])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDragTargeted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { isDragTargeted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragTargeted = false
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onDropFiles?(urls)
            return true
        }
        if let txt = pb.string(forType: .string), !txt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onDropText?(txt)
            return true
        }
        return false
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let isDark = GeekTheme.isDark

        // 右侧实用控制区规整 1pt 竖向分割线
        if dividerX > 10 && dividerX < bounds.width - 10 {
            ctx.setFillColor((isDark ? NSColor.white.withAlphaComponent(0.11) : NSColor.black.withAlphaComponent(0.09)).cgColor)
            ctx.fill(CGRect(x: floor(dividerX) + 0.5, y: 10, width: 1, height: bounds.height - 20))
        }

        // 拖入文件/文字时的整框虚线接纳反馈
        guard isDragTargeted else { return }
        let r = bounds.insetBy(dx: 2.5, dy: 2.5)
        let path = CGPath(roundedRect: r, cornerWidth: 11.5, cornerHeight: 11.5, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(GeekTheme.accent.withAlphaComponent(isDark ? 0.16 : 0.10).cgColor)
        ctx.addPath(path); ctx.fillPath()
        ctx.setStrokeColor(GeekTheme.accent.withAlphaComponent(0.92).cgColor)
        ctx.setLineWidth(1.8); ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.addPath(path); ctx.strokePath()
        ctx.restoreGState()
    }
}

/// 顶部实用暂存条布局、翻页对称指示与卡片填充扩展
extension ShelfPanelController {
    func layoutSubviews(width w: CGFloat, height h: CGFloat) {
        effectView?.frame = NSRect(x: 0, y: 0, width: w, height: h)
        rootView?.frame = NSRect(x: 0, y: 0, width: w, height: h)
        let railX = w - Self.railWidth
        rootView?.dividerX = railX

        // 右侧 3 行规整工具列（88pt 宽，杜绝文字截断）
        let colX = railX + 8, colW: CGFloat = Self.railWidth - 16
        countLabel?.frame = NSRect(x: colX, y: 10, width: 42, height: 16)
        closeBtn?.frame = NSRect(x: colX + colW - 21, y: 7, width: 21, height: 22)
        pinBtn?.frame = NSRect(x: colX + colW - 45, y: 7, width: 21, height: 22)
        clipBtn?.frame = NSRect(x: colX, y: 36, width: colW, height: 24)
        secondaryBtn?.frame = NSRect(x: colX, y: 66, width: colW, height: 24)

        leftNavBtn?.frame = NSRect(x: 5, y: 7, width: 18, height: h - 14)
        rightNavBtn?.frame = NSRect(x: railX - 23, y: 7, width: 18, height: h - 14)
        emptyLabel?.frame = NSRect(x: 12, y: round(h * 0.5 - 9), width: railX - 24, height: 18)
        applyScrollFrame(railX: railX, height: h, hasOverflow: !(leftNavBtn?.isHidden ?? true) || !(rightNavBtn?.isHidden ?? true))
    }

    func applyScrollFrame(railX: CGFloat, height h: CGFloat, hasOverflow: Bool) {
        let inset: CGFloat = hasOverflow ? 26 : 8
        scrollView?.frame = NSRect(x: inset, y: 7, width: max(60, railX - inset * 2), height: h - 14)
    }

    func updateScrollNavButtons() {
        guard let sv = scrollView, let doc = sv.documentView, let root = rootView else { return }
        let railX = root.bounds.width - Self.railWidth
        let overflow = doc.frame.width > (railX - 16) + 2
        applyScrollFrame(railX: railX, height: root.bounds.height, hasOverflow: overflow)
        let maxX = max(0, doc.frame.width - sv.contentView.bounds.width)
        let curX = sv.contentView.bounds.origin.x
        leftNavBtn?.isHidden = !overflow
        rightNavBtn?.isHidden = !overflow
        leftNavBtn?.alphaValue = curX > 2 ? 1.0 : 0.28
        rightNavBtn?.alphaValue = curX < maxX - 2 ? 1.0 : 0.28
    }

    func applyTheme() {
        let isDark = GeekTheme.isDark
        effectView?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        effectView?.layer?.borderColor = (isDark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.12)).cgColor
        countLabel?.textColor = GeekTheme.inkSecondary
        emptyLabel?.textColor = GeekTheme.inkMuted
        rootView?.needsDisplay = true
    }

    func populateCards(_ items: [ShelfCardItem]) {
        guard let stripView, let scrollView else { return }
        activeHoveredCard = nil
        let validIDs = Set(items.map(\.id))
        selectedItemIDs.removeAll { !validIDs.contains($0) }
        stripView.subviews.forEach { $0.removeFromSuperview() }
        countLabel?.stringValue = "\(items.count) 项"
        updateCollageButtonTitle()
        emptyLabel?.isHidden = !items.isEmpty

        let cardW = ShelfCardView.cardSize.width, cardH = ShelfCardView.cardSize.height
        var x: CGFloat = 0
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        for item in items {
            let card = buildCardView(for: item, timeFormatter: tf)
            card.selectionOrder = selectedItemIDs.firstIndex(of: item.id).map { $0 + 1 }
            card.onHoverStart = { [weak self] c in self?.setActiveHoveredCard(c) }
            card.onToggleSelect = { [weak self] it in self?.toggleSelection(for: it) }
            card.frame = NSRect(x: x, y: 0, width: cardW, height: cardH)
            stripView.addSubview(card)
            x += cardW + Self.cardGap
        }
        let totalW = max(0, x - (items.isEmpty ? 0 : Self.cardGap))
        stripView.frame = NSRect(x: 0, y: 0, width: max(scrollView.bounds.width, totalW), height: cardH)
        updateScrollNavButtons()
    }

    func updateCollageButtonTitle() {
        let selCount = selectedItemIDs.count
        secondaryBtn?.title = selCount > 0 ? "拼图 (\(selCount))" : "拼图 / PDF"
        secondaryBtn?.style = selCount >= 2 ? .accent : .subtle
    }

    func toggleSelection(for item: ShelfCardItem) {
        if let idx = selectedItemIDs.firstIndex(of: item.id) {
            selectedItemIDs.remove(at: idx)
        } else {
            selectedItemIDs.append(item.id)
        }
        if let stripView {
            for case let card as ShelfCardView in stripView.subviews {
                card.selectionOrder = selectedItemIDs.firstIndex(of: card.item.id).map { $0 + 1 }
            }
        }
        updateCollageButtonTitle()
    }
}
