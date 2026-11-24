import AppKit
import CoreGraphics
import Foundation

/// 长截图底部非抢焦悬浮操作栏（清爽浅色磨砂白底风 + 矢量 SF Symbols + 蓝色主完成胶囊）
final class LongShotControlBarView: NSView {
    enum Action {
        case toggleAutoScroll
        case extractText
        case translateText
        case pin
        case save
        case cancel
        case finishCopy
    }

    var onAction: ((Action) -> Void)?
    var isAutoScrolling = false { didSet { needsDisplay = true } }
    var pinHint: String = "⌘2"

    private struct ButtonSlot {
        let rect: CGRect
        let tip: String
        let action: Action
        let render: (CGContext, CGRect, Bool) -> Void
    }

    private var slots: [ButtonSlot] = []
    private var hoveredIdx: Int?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static let barSize = NSSize(width: 354, height: 40)

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.barSize))
        rebuildSlots()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

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

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = slots.firstIndex(where: { $0.rect.contains(p) })
        if idx != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        if idx != hoveredIdx {
            hoveredIdx = idx
            toolTip = idx.map { slots[$0].tip }
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) { hoveredIdx = nil; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let slot = slots.first(where: { $0.rect.contains(p) }) {
            onAction?(slot.action)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        rebuildSlots()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        MSnipUITheme.drawPorcelainBar(ctx: ctx, bounds: bounds, radius: 9.5)
        for (i, s) in slots.enumerated() {
            s.render(ctx, s.rect, hoveredIdx == i)
        }
    }

    private func rebuildSlots() {
        var list: [ButtonSlot] = []
        let y: CGFloat = 5, h: CGFloat = 30
        var x: CGFloat = 7

        let autoW: CGFloat = 96
        let autoRect = CGRect(x: x, y: y, width: autoW, height: h)
        let running = isAutoScrolling
        list.append(ButtonSlot(
            rect: autoRect,
            tip: running ? "停止自动滚动" : "平滑自动向下滚动（需辅助功能权限）",
            action: .toggleAutoScroll,
            render: { ctx, r, hov in
                ToolbarView.drawButtonBg(ctx: ctx, rect: r, active: running, hovered: hov)
                let sym = running ? "pause.fill" : "play.fill"
                let fg = running ? MSnipUITheme.accent : MSnipUITheme.inkPrimary
                let iconR = CGRect(x: r.minX + 8, y: r.minY, width: 14, height: r.height)
                ToolbarView.drawSymbol(sym, in: iconR, alpha: 0.95, tint: fg)
                let label = (running ? "停止滚动" : "自动滚动") as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: fg
                ]
                let sz = label.size(withAttributes: attrs)
                label.draw(
                    at: CGPoint(x: round(iconR.maxX + 4), y: round(r.minY + (r.height - sz.height) * 0.5)),
                    withAttributes: attrs
                )
            }
        ))
        x += autoW + 8

        let iconDefs: [(String, String, NSColor, Action)] = [
            ("text.viewfinder", "长图识字 (OCR)", MSnipUITheme.inkPrimary, .extractText),
            ("character.bubble", "长图翻译", MSnipUITheme.inkPrimary, .translateText),
            ("pin", "长图贴到屏幕 (\(pinHint))", MSnipUITheme.inkPrimary, .pin),
            ("square.and.arrow.down", "保存长图 PNG", MSnipUITheme.inkPrimary, .save),
            ("xmark", "取消长截图 (Esc)", MSnipUITheme.danger, .cancel)
        ]
        for (sym, tip, tint, act) in iconDefs {
            let r = CGRect(x: x, y: y, width: 28, height: h)
            x += 31
            list.append(ButtonSlot(rect: r, tip: tip, action: act) { ctx, rect, hov in
                ToolbarView.drawButtonBg(ctx: ctx, rect: rect, active: false, hovered: hov)
                ToolbarView.drawSymbol(sym, in: rect, alpha: 0.95, tint: tint)
            })
        }

        let okRect = CGRect(x: x + 2, y: y, width: 76, height: h)
        list.append(ButtonSlot(rect: okRect, tip: "完成并复制长图到剪贴板 (⌘↩ / ↩)", action: .finishCopy) { ctx, r, hov in
            MSnipUITheme.drawPrimaryCTA(ctx: ctx, rect: r, radius: 6.5, hovered: hov)
            let iconR = CGRect(x: r.minX + 10, y: r.minY, width: 14, height: r.height)
            ToolbarView.drawSymbol("checkmark", in: iconR, alpha: 1.0, tint: .white)
            let txt = "完成" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let sz = txt.size(withAttributes: attrs)
            txt.draw(
                at: CGPoint(x: round(iconR.maxX + 4), y: round(r.minY + (r.height - sz.height) * 0.5)),
                withAttributes: attrs
            )
        })
        slots = list
    }
}

// MARK: - LongShotSession Panel Construction & Layout

extension LongShotSession {
    func setupPanels(screen: NSScreen, localRect: CGRect, pinHint: String) {
        let appKitSel = NSRect(
            x: screen.frame.minX + localRect.minX,
            y: screen.frame.maxY - localRect.maxY,
            width: localRect.width,
            height: localRect.height
        )

        let pad = LongShotBorderView.sidePad
        let topSpace = LongShotBorderView.topBadgeSpace
        let borderFrame = NSRect(
            x: appKitSel.minX - pad,
            y: appKitSel.minY - pad,
            width: appKitSel.width + pad * 2,
            height: appKitSel.height + pad + topSpace
        )
        let bp = makeLongShotPanel(frame: borderFrame, ignoresMouse: true)
        let bv = LongShotBorderView(frame: NSRect(origin: .zero, size: borderFrame.size))
        bp.contentView = bv
        self.borderPanel = bp
        self.borderView = bv

        let prevW: CGFloat = 152
        let prevH: CGFloat = min(max(190, appKitSel.height), 380)
        let rightX = appKitSel.maxX + 12
        let leftX = appKitSel.minX - prevW - 12
        let prevX = (rightX + prevW + 8 <= screen.frame.maxX)
            ? rightX
            : (leftX >= screen.frame.minX + 8 ? leftX : screen.frame.maxX - prevW - 10)
        let prevY = min(max(screen.visibleFrame.minY + 10, appKitSel.maxY - prevH), screen.visibleFrame.maxY - prevH - 10)
        let prevFrame = NSRect(x: round(prevX), y: round(prevY), width: prevW, height: round(prevH))

        let pp = makeLongShotPanel(frame: prevFrame, ignoresMouse: true)
        let pv = LongShotPreviewView(frame: NSRect(origin: .zero, size: prevFrame.size))
        pv.baseHeightPx = Int((localRect.height * scaleFactor).rounded())
        pp.contentView = pv
        self.previewPanel = pp
        self.previewView = pv

        let barSz = LongShotControlBarView.barSize
        let barX = min(max(screen.frame.minX + 8, appKitSel.maxX - barSz.width), screen.frame.maxX - barSz.width - 8)
        let belowY = appKitSel.minY - barSz.height - 10
        let aboveY = borderFrame.maxY + 8
        let barY = (belowY >= screen.visibleFrame.minY + 6)
            ? belowY
            : (aboveY + barSz.height <= screen.visibleFrame.maxY ? aboveY : screen.visibleFrame.minY + 12)
        let cp = makeLongShotPanel(frame: NSRect(x: round(barX), y: round(barY), width: barSz.width, height: barSz.height), ignoresMouse: false)
        let cv = LongShotControlBarView()
        cv.pinHint = pinHint
        cv.onAction = { [weak self] act in self?.handleControlAction(act) }
        cp.contentView = cv
        self.controlPanel = cp
        self.controlView = cv

        bp.orderFrontRegardless()
        pp.orderFrontRegardless()
        cp.orderFrontRegardless()
    }

    private func makeLongShotPanel(frame: NSRect, ignoresMouse: Bool) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar; p.animationBehavior = .none
        p.isFloatingPanel = true; p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false; p.backgroundColor = .clear
        p.hasShadow = !ignoresMouse; p.ignoresMouseEvents = ignoresMouse
        return p
    }
}
