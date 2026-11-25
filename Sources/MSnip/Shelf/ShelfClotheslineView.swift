import AppKit
import CoreGraphics
import Foundation

/// 顶部紧凑暂存条根容器：负责高通透毛玻璃底衬、内圈微高光描边、右侧精致竖向分割线与拖入高亮
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
        isDragTargeted = true; return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { isDragTargeted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragTargeted = false
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onDropFiles?(urls); return true
        }
        if let txt = pb.string(forType: .string), !txt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onDropText?(txt); return true
        }
        return false
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let isDark = GeekTheme.isDark

        // 1) 柔和毛玻璃润色层：浅色下清透乳白不发灰，深色下沉稳深炭有层次
        let tint = isDark
            ? NSColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 0.62)
            : NSColor(srgbRed: 0.97, green: 0.975, blue: 0.985, alpha: 0.72)
        ctx.setFillColor(tint.cgColor)
        ctx.fill(bounds)

        // 2) 内圈 0.75pt 光学镜面细边（接近 macOS 控制中心 / Raycast 质感）
        let inner = bounds.insetBy(dx: 0.9, dy: 0.9)
        let innerPath = CGPath(roundedRect: inner, cornerWidth: 13.2, cornerHeight: 13.2, transform: nil)
        ctx.setStrokeColor((isDark ? NSColor.white.withAlphaComponent(0.11) : NSColor.white.withAlphaComponent(0.62)).cgColor)
        ctx.setLineWidth(0.75)
        ctx.addPath(innerPath); ctx.strokePath()

        // 3) 右侧实用工具列精致竖向分割线
        if dividerX > 10 && dividerX < bounds.width - 10 {
            ctx.setFillColor((isDark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.08)).cgColor)
            ctx.fill(CGRect(x: floor(dividerX) + 0.5, y: 11, width: 1, height: bounds.height - 22))
        }

        // 4) 拖入文件/文字时的虚线高亮反馈
        guard isDragTargeted else { return }
        let r = bounds.insetBy(dx: 2.5, dy: 2.5)
        let path = CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil)
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

        // 右侧精炼控制列（10pt 呼吸留白）
        railView?.frame = NSRect(x: railX + 9, y: 8, width: Self.railWidth - 18, height: h - 16)

        leftNavBtn?.frame = NSRect(x: 3, y: 7, width: 22, height: h - 14)
        rightNavBtn?.frame = NSRect(x: railX - 25, y: 7, width: 22, height: h - 14)
        emptyLabel?.frame = NSRect(x: 14, y: round(h * 0.5 - 9), width: railX - 28, height: 18)
        applyScrollFrame(railX: railX, height: h, hasOverflow: !(leftNavBtn?.isHidden ?? true) || !(rightNavBtn?.isHidden ?? true))
    }

    func applyScrollFrame(railX: CGFloat, height h: CGFloat, hasOverflow: Bool) {
        let inset: CGFloat = hasOverflow ? 27 : 8
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
        leftNavBtn?.isNavEnabled = curX > 2
        rightNavBtn?.isNavEnabled = curX < maxX - 2
    }

    func applyTheme() {
        let isDark = GeekTheme.isDark
        effectView?.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        effectView?.layer?.borderColor = (isDark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.12)).cgColor
        emptyLabel?.textColor = GeekTheme.inkMuted
        railView?.needsDisplay = true
        leftNavBtn?.needsDisplay = true
        rightNavBtn?.needsDisplay = true
        rootView?.needsDisplay = true
    }

    func populateCards(_ items: [ShelfCardItem]) {
        guard let stripView, let scrollView else { return }
        activeHoveredCard = nil
        let validIDs = Set(items.map(\.id))
        selectedItemIDs.removeAll { !validIDs.contains($0) }
        stripView.subviews.forEach { $0.removeFromSuperview() }
        railView?.itemCount = items.count
        railView?.selectedCount = selectedItemIDs.count
        railView?.isPinned = isPinnedOpen
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
        railView?.selectedCount = selectedItemIDs.count
    }
}
