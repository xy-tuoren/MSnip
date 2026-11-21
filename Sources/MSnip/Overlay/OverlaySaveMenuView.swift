import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 截图工具栏「下载保存」按钮的悬浮快捷目录选择弹层（渲染在 OverlayView 内部，零层级遮挡、点击目录秒存）
final class OverlaySaveMenuView: NSView {
    enum Choice {
        case folder(String)
        case chooseFolder
        case saveAsPanel
    }

    private struct Row {
        let title: String
        let subtitle: String?
        let symbol: String
        let tint: NSColor
        let choice: Choice
        let rect: CGRect
    }

    var onChoice: ((Choice) -> Void)?

    private var rows: [Row] = []
    private var sepY: CGFloat = 0
    private var hoveredIdx: Int? { didSet { if oldValue != hoveredIdx { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    static let menuWidth: CGFloat = 204
    private static let rowH: CGFloat = 28

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.menuWidth, height: 180))
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor(srgbRed: 0.04, green: 0.08, blue: 0.16, alpha: 1.0).cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: 4)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

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

    func reload(folders: [QuickSaveFolder]) {
        var built: [Row] = []
        var y: CGFloat = 6
        let w = Self.menuWidth - 10

        for f in folders {
            let shortPath = f.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            built.append(Row(
                title: f.title,
                subtitle: shortPath,
                symbol: f.symbol,
                tint: f.isDefault ? MSnipUITheme.accent : MSnipUITheme.inkSecondary,
                choice: .folder(f.path),
                rect: CGRect(x: 5, y: y, width: w, height: Self.rowH)
            ))
            y += Self.rowH
        }

        sepY = y + 3
        y += 7

        built.append(Row(
            title: "选择其他目录保存…",
            subtitle: "选择文件夹后直接下载保存",
            symbol: "folder.badge.plus",
            tint: MSnipUITheme.accent,
            choice: .chooseFolder,
            rect: CGRect(x: 5, y: y, width: w, height: Self.rowH)
        ))
        y += Self.rowH

        built.append(Row(
            title: "另存为（自定义文件名）…",
            subtitle: "弹出系统保存对话框 (⌘S)",
            symbol: "square.and.arrow.down",
            tint: MSnipUITheme.inkSecondary,
            choice: .saveAsPanel,
            rect: CGRect(x: 5, y: y, width: w, height: Self.rowH)
        ))
        y += Self.rowH + 6

        rows = built
        hoveredIdx = nil
        setFrameSize(NSSize(width: Self.menuWidth, height: y))
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = rows.firstIndex(where: { $0.rect.contains(p) })
        if idx != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        hoveredIdx = idx
        toolTip = idx.flatMap { rows[$0].subtitle }
    }

    override func mouseExited(with event: NSEvent) { hoveredIdx = nil }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = rows.first(where: { $0.rect.contains(p) }) else { return }
        onChoice?(hit.choice)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        MSnipUITheme.drawPorcelainBar(ctx: ctx, bounds: bounds, radius: 9.5)

        ctx.saveGState()
        ctx.setFillColor(MSnipUITheme.borderHairline.cgColor)
        ctx.fill(CGRect(x: 10, y: sepY, width: bounds.width - 20, height: 1))
        ctx.restoreGState()

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        for (i, row) in rows.enumerated() {
            let hov = (hoveredIdx == i)
            if hov {
                ToolbarView.drawButtonBg(ctx: ctx, rect: row.rect, active: false, hovered: true)
            }
            let iconRect = CGRect(x: row.rect.minX + 7, y: row.rect.minY, width: 16, height: row.rect.height)
            ToolbarView.drawSymbol(row.symbol, in: iconRect, alpha: 0.94, tint: hov ? MSnipUITheme.accent : row.tint)

            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12.0, weight: hov ? .semibold : .medium),
                .foregroundColor: hov ? MSnipUITheme.accent : MSnipUITheme.inkPrimary,
                .paragraphStyle: para
            ]
            let ns = row.title as NSString
            let sz = ns.size(withAttributes: attrs)
            ns.draw(
                in: CGRect(
                    x: round(iconRect.maxX + 6),
                    y: round(row.rect.midY - sz.height * 0.5),
                    width: row.rect.maxX - iconRect.maxX - 14,
                    height: sz.height + 2
                ),
                withAttributes: attrs
            )
        }
    }
}
