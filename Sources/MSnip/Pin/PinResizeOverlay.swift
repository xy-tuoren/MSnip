import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 贴图窗口边角拖拽缩放状态盒
@MainActor
struct PinResizeDragState {
    var activeEdge: PinResizeEdge?
    var hoveredEdge: PinResizeEdge?
    var mouseStart: NSPoint = .zero
    var frameStart: NSRect = .zero
    weak var chromeView: PinResizeChromeView?
}

/// 零私有 API、全 macOS 12+ 兼容的 8 向缩放光标工厂（高清矢量绘制斜向双箭头光标并全局缓存）
@MainActor
enum PinResizeCursorFactory {
    private static let nwseCursor: NSCursor = makeDiagonalCursor(nwToSe: true)
    private static let neswCursor: NSCursor = makeDiagonalCursor(nwToSe: false)

    static func cursor(for edge: PinResizeEdge) -> NSCursor {
        switch edge {
        case .left, .right:             return .resizeLeftRight
        case .top, .bottom:             return .resizeUpDown
        case .topLeft, .bottomRight:    return nwseCursor
        case .topRight, .bottomLeft:    return neswCursor
        }
    }

    private static func makeDiagonalCursor(nwToSe: Bool) -> NSCursor {
        let sz = NSSize(width: 18, height: 18)
        let img = NSImage(size: sz, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.rotate(by: nwToSe ? (-.pi / 4.0) : (.pi / 4.0))

            let path = CGMutablePath()
            path.move(to: CGPoint(x: -7.2, y: 0))
            path.addLine(to: CGPoint(x: -3.4, y: 3.6))
            path.addLine(to: CGPoint(x: -3.4, y: 1.3))
            path.addLine(to: CGPoint(x: 3.4, y: 1.3))
            path.addLine(to: CGPoint(x: 3.4, y: 3.6))
            path.addLine(to: CGPoint(x: 7.2, y: 0))
            path.addLine(to: CGPoint(x: 3.4, y: -3.6))
            path.addLine(to: CGPoint(x: 3.4, y: -1.3))
            path.addLine(to: CGPoint(x: -3.4, y: -1.3))
            path.addLine(to: CGPoint(x: -3.4, y: -3.6))
            path.closeSubpath()

            ctx.setShadow(offset: CGSize(width: 0, height: -0.8), blur: 1.5, color: NSColor.black.withAlphaComponent(0.42).cgColor)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(2.1)
            ctx.setLineJoin(.round)
            ctx.addPath(path); ctx.strokePath()
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(path); ctx.fillPath()
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: 9, y: 9))
    }
}

/// 贴图边角悬停微指示与实时缩放胶囊视图（默认完全隐藏，仅鼠标移至边角或拖拽缩放时显现，完全鼠标穿透）
final class PinResizeChromeView: NSView {
    var hoveredEdge: PinResizeEdge? { didSet { if oldValue != hoveredEdge { needsDisplay = true } } }
    var activeResizeBadge: String? { didSet { if oldValue != activeResizeBadge { needsDisplay = true } } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard hoveredEdge != nil || activeResizeBadge != nil,
              let ctx = NSGraphicsContext.current?.cgContext else { return }

        if let edge = hoveredEdge {
            drawEdgeIndicator(edge, in: ctx)
        }

        if let badge = activeResizeBadge, bounds.width >= 96, bounds.height >= 44 {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let ns = badge as NSString
            let sz = ns.size(withAttributes: attrs)
            let pillW = ceil(sz.width + 16), pillH: CGFloat = 22
            let pill = CGRect(x: round(bounds.midX - pillW * 0.5), y: 10, width: pillW, height: pillH)
            let path = CGPath(roundedRect: pill, cornerWidth: 11, cornerHeight: 11, transform: nil)
            ctx.setFillColor(NSColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 0.80).cgColor)
            ctx.addPath(path); ctx.fillPath()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
            ctx.setLineWidth(0.8); ctx.addPath(path); ctx.strokePath()
            ns.draw(at: CGPoint(x: round(pill.midX - sz.width * 0.5), y: round(pill.midY - sz.height * 0.5 - 0.5)), withAttributes: attrs)
        }
    }

    private func drawEdgeIndicator(_ edge: PinResizeEdge, in ctx: CGContext) {
        let inset: CGFloat = 2.0
        let arm: CGFloat = min(10.0, max(5.0, min(bounds.width, bounds.height) * 0.16))
        let p = CGMutablePath()
        switch edge {
        case .topLeft:
            let pt = CGPoint(x: inset, y: bounds.height - inset)
            p.move(to: CGPoint(x: pt.x + arm, y: pt.y)); p.addLine(to: pt); p.addLine(to: CGPoint(x: pt.x, y: pt.y - arm))
        case .topRight:
            let pt = CGPoint(x: bounds.width - inset, y: bounds.height - inset)
            p.move(to: CGPoint(x: pt.x - arm, y: pt.y)); p.addLine(to: pt); p.addLine(to: CGPoint(x: pt.x, y: pt.y - arm))
        case .bottomLeft:
            let pt = CGPoint(x: inset, y: inset)
            p.move(to: CGPoint(x: pt.x + arm, y: pt.y)); p.addLine(to: pt); p.addLine(to: CGPoint(x: pt.x, y: pt.y + arm))
        case .bottomRight:
            let pt = CGPoint(x: bounds.width - inset, y: inset)
            p.move(to: CGPoint(x: pt.x - arm, y: pt.y)); p.addLine(to: pt); p.addLine(to: CGPoint(x: pt.x, y: pt.y + arm))
        case .top, .bottom:
            let half = min(18.0, max(8.0, bounds.width * 0.12))
            let y = (edge == .top) ? (bounds.height - inset) : inset
            p.move(to: CGPoint(x: bounds.midX - half, y: y)); p.addLine(to: CGPoint(x: bounds.midX + half, y: y))
        case .left, .right:
            let half = min(18.0, max(8.0, bounds.height * 0.12))
            let x = (edge == .right) ? (bounds.width - inset) : inset
            p.move(to: CGPoint(x: x, y: bounds.midY - half)); p.addLine(to: CGPoint(x: x, y: bounds.midY + half))
        }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(3.8)
        ctx.addPath(p); ctx.strokePath()
        ctx.setStrokeColor(MSnipUITheme.accent.cgColor)
        ctx.setLineWidth(2.2)
        ctx.addPath(p); ctx.strokePath()
    }
}

/// 贴图窗口 8 向边角缩放与自适应屏幕尺寸交互扩展
extension PinWindow {
    var minAllowedZoom: CGFloat {
        min(0.25, max(0.05, 80.0 / max(1.0, max(baseSize.width, baseSize.height))))
    }

    var maxAllowedZoom: CGFloat { 4.0 }

    func attachResizeChrome() {
        let chrome = PinResizeChromeView(frame: pinContentView.bounds)
        chrome.autoresizingMask = [.width, .height]
        pinContentView.addSubview(chrome)
        resizeState.chromeView = chrome
        pinContentView.onMouseMoved = { [weak self] winPt in
            _ = self?.handleResizeHover(windowPoint: winPt)
        }
        pinContentView.onVisualStateChanged = { [weak self] in
            self?.syncResizeChromeVisibility()
        }
        syncResizeChromeVisibility()
    }

    func syncResizeChromeVisibility() {
        let allow = !isClickThrough && editorCanvas == nil && cropOverlay == nil
        if !allow {
            resizeState.hoveredEdge = nil
            resizeState.chromeView?.hoveredEdge = nil
            resizeState.chromeView?.activeResizeBadge = nil
        }
    }

    @discardableResult
    func handleResizeHover(windowPoint: NSPoint) -> Bool {
        guard !isClickThrough, editorCanvas == nil, cropOverlay == nil else { return false }
        if let active = resizeState.activeEdge {
            PinResizeCursorFactory.cursor(for: active).set()
            return true
        }
        let edge = PinResizeEdge.hitTest(point: windowPoint, in: pinContentView.bounds)
        let prev = resizeState.hoveredEdge
        resizeState.hoveredEdge = edge
        resizeState.chromeView?.hoveredEdge = edge
        if let edge {
            PinResizeCursorFactory.cursor(for: edge).set()
            return true
        }
        if prev != nil { NSCursor.arrow.set() }
        return false
    }

    func clearResizeHoverCursorIfNeeded() {
        guard resizeState.activeEdge == nil else { return }
        if resizeState.hoveredEdge != nil {
            resizeState.hoveredEdge = nil
            resizeState.chromeView?.hoveredEdge = nil
            NSCursor.arrow.set()
        }
    }

    func beginResizeDrag(edge: PinResizeEdge) {
        pinContentView.liveTextView.clearSelection()
        resizeState.activeEdge = edge
        resizeState.hoveredEdge = edge
        resizeState.mouseStart = NSEvent.mouseLocation
        resizeState.frameStart = frame
        resizeState.chromeView?.hoveredEdge = edge
        updateResizeBadge()
        PinResizeCursorFactory.cursor(for: edge).set()
        syncResizeChromeVisibility()
    }

    func updateResizeDrag() {
        guard let edge = resizeState.activeEdge else { return }
        let now = NSEvent.mouseLocation
        let delta = CGPoint(x: now.x - resizeState.mouseStart.x, y: now.y - resizeState.mouseStart.y)
        let res = ImageTransform.resizedPinFrame(
            edge: edge,
            initialFrame: resizeState.frameStart,
            baseSize: baseSize,
            delta: delta,
            minZoom: minAllowedZoom,
            maxZoom: maxAllowedZoom
        )
        let s = imageScale
        let snapped = NSRect(
            x: (res.frame.origin.x * s).rounded() / s,
            y: (res.frame.origin.y * s).rounded() / s,
            width: res.frame.width,
            height: res.frame.height
        )
        zoomFactor = res.zoom
        setFrame(snapped, display: true)
        updateResizeBadge()
        PinResizeCursorFactory.cursor(for: edge).set()
        if hoverBarPanel.isVisible { hoverBarPanel.reposition(anchoringTo: frame, on: screen) }
    }

    func endResizeDrag() {
        guard resizeState.activeEdge != nil else { return }
        resizeState.activeEdge = nil
        resizeState.chromeView?.activeResizeBadge = nil
        if let winPt = currentWindowMousePoint() {
            _ = handleResizeHover(windowPoint: winPt)
        } else {
            resizeState.hoveredEdge = nil
            resizeState.chromeView?.hoveredEdge = nil
            NSCursor.arrow.set()
        }
        syncResizeChromeVisibility()
        if hoverBarPanel.isVisible { hoverBarPanel.reposition(anchoringTo: frame, on: screen) }
    }

    /// 一键将当前贴图等比自适应至所在屏幕可视区域内（防止大图或拼图超出屏幕边界）
    @objc func fitToScreen() {
        let scr = screen ?? NSScreen.main ?? NSScreen.screens.first
        let vf = scr?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let fit = ImageTransform.fittedPinRect(baseSize: baseSize, visibleBounds: vf, preferredOrigin: nil)
        let s = imageScale
        zoomFactor = fit.zoom
        let snapped = NSRect(
            x: (fit.frame.origin.x * s).rounded() / s,
            y: (fit.frame.origin.y * s).rounded() / s,
            width: fit.frame.width,
            height: fit.frame.height
        )
        setFrame(snapped, display: true)
        toolbarPanel?.reposition(anchoringTo: frame, on: screen)
        if hoverBarPanel.isVisible { hoverBarPanel.reposition(anchoringTo: frame, on: screen) }
    }

    private func updateResizeBadge() {
        let w = Int(frame.width.rounded()), h = Int(frame.height.rounded())
        let pct = max(1, Int((zoomFactor * 100.0).rounded()))
        resizeState.chromeView?.activeResizeBadge = "\(w) × \(h) · \(pct)%"
    }

    private func currentWindowMousePoint() -> NSPoint? {
        let pt = convertPoint(fromScreen: NSEvent.mouseLocation)
        return pinContentView.bounds.contains(pt) ? pt : nil
    }
}
