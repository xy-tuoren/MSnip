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

/// 全 macOS 12+ 兼容的 8 向缩放光标工厂（macOS 15+ 优先调用原生系统 `frameResize`，低版本回退矢量斜向双箭头）
@MainActor
enum PinResizeCursorFactory {
    private static let nwseFallback: NSCursor = makeDiagonalCursor(nwToSe: true)
    private static let neswFallback: NSCursor = makeDiagonalCursor(nwToSe: false)

    static func cursor(for edge: PinResizeEdge) -> NSCursor {
        if #available(macOS 15.0, *) {
            switch edge {
            case .topLeft:     return .frameResize(position: .topLeft, directions: .all)
            case .topRight:    return .frameResize(position: .topRight, directions: .all)
            case .bottomLeft:  return .frameResize(position: .bottomLeft, directions: .all)
            case .bottomRight: return .frameResize(position: .bottomRight, directions: .all)
            case .left:        return .frameResize(position: .left, directions: .all)
            case .right:       return .frameResize(position: .right, directions: .all)
            case .top:         return .frameResize(position: .top, directions: .all)
            case .bottom:      return .frameResize(position: .bottom, directions: .all)
            }
        }
        switch edge {
        case .left, .right:          return .resizeLeftRight
        case .top, .bottom:          return .resizeUpDown
        case .topLeft, .bottomRight: return nwseFallback
        case .topRight, .bottomLeft: return neswFallback
        }
    }

    private static func makeDiagonalCursor(nwToSe: Bool) -> NSCursor {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.rotate(by: nwToSe ? (-.pi / 4.0) : (.pi / 4.0))
            let p = CGMutablePath()
            p.move(to: CGPoint(x: -7.2, y: 0)); p.addLine(to: CGPoint(x: -3.4, y: 3.6)); p.addLine(to: CGPoint(x: -3.4, y: 1.3))
            p.addLine(to: CGPoint(x: 3.4, y: 1.3)); p.addLine(to: CGPoint(x: 3.4, y: 3.6)); p.addLine(to: CGPoint(x: 7.2, y: 0))
            p.addLine(to: CGPoint(x: 3.4, y: -3.6)); p.addLine(to: CGPoint(x: 3.4, y: -1.3)); p.addLine(to: CGPoint(x: -3.4, y: -1.3))
            p.addLine(to: CGPoint(x: -3.4, y: -3.6)); p.closeSubpath()
            ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(2.1); ctx.setLineJoin(.round); ctx.addPath(p); ctx.strokePath()
            ctx.setFillColor(NSColor.black.cgColor); ctx.addPath(p); ctx.fillPath()
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: 9, y: 9))
    }
}

/// 贴图边角悬停微指示与原生光标热区视图（仅在 8 条边角窄带接管 hitTest 与 CursorRect，中心 100% 穿透给实况文本）
final class PinResizeChromeView: NSView {
    var isInteractive: Bool = true {
        didSet {
            guard oldValue != isInteractive else { return }
            updateTrackingAreas()
            window?.invalidateCursorRects(for: self)
        }
    }
    var hoveredEdge: PinResizeEdge? { didSet { if oldValue != hoveredEdge { needsDisplay = true } } }
    var activeResizeBadge: String? { didSet { if oldValue != activeResizeBadge { needsDisplay = true } } }
    var onBorderHoverChanged: ((PinResizeEdge?) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractive else { return nil }
        return PinResizeEdge.hitTest(point: convert(point, from: superview), in: bounds) != nil ? self : nil
    }
    override func menu(for event: NSEvent) -> NSMenu? { superview?.menu }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); window?.invalidateCursorRects(for: self) }

    override func resetCursorRects() {
        discardCursorRects()
        guard isInteractive else { return }
        for (edge, rect) in borderZones() where !rect.isEmpty { addCursorRect(rect, cursor: PinResizeCursorFactory.cursor(for: edge)) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        guard isInteractive else { return }
        for (edge, rect) in borderZones() where !rect.isEmpty {
            addTrackingArea(NSTrackingArea(rect: rect, options: [.cursorUpdate, .mouseEnteredAndExited, .activeAlways], owner: self, userInfo: ["edge": edge]))
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        guard isInteractive else { super.cursorUpdate(with: event); return }
        if let edge = (event.trackingArea?.userInfo?["edge"] as? PinResizeEdge) ?? PinResizeEdge.hitTest(point: convert(event.locationInWindow, from: nil), in: bounds) {
            PinResizeCursorFactory.cursor(for: edge).set()
        } else { super.cursorUpdate(with: event) }
    }

    override func mouseEntered(with event: NSEvent) {
        guard isInteractive, let edge = event.trackingArea?.userInfo?["edge"] as? PinResizeEdge else { return }
        hoveredEdge = edge; onBorderHoverChanged?(edge); PinResizeCursorFactory.cursor(for: edge).set()
    }

    override func mouseExited(with event: NSEvent) {
        guard let exited = event.trackingArea?.userInfo?["edge"] as? PinResizeEdge, hoveredEdge == exited else { return }
        let next = isInteractive ? PinResizeEdge.hitTest(point: convert(event.locationInWindow, from: nil), in: bounds) : nil
        hoveredEdge = next; onBorderHoverChanged?(next)
        if let next { PinResizeCursorFactory.cursor(for: next).set() } else { NSCursor.arrow.set() }
    }

    private func borderZones() -> [(PinResizeEdge, NSRect)] {
        guard bounds.width >= 32, bounds.height >= 32 else { return [] }
        let minDim = min(bounds.width, bounds.height)
        let c = min(14, max(6, minDim * 0.28))
        let e = min(7, max(4, minDim * 0.18))
        let w = bounds.width, h = bounds.height
        return [
            (.topLeft,     NSRect(x: 0, y: h - c, width: c, height: c)),
            (.topRight,    NSRect(x: w - c, y: h - c, width: c, height: c)),
            (.bottomLeft,  NSRect(x: 0, y: 0, width: c, height: c)),
            (.bottomRight, NSRect(x: w - c, y: 0, width: c, height: c)),
            (.top,         NSRect(x: c, y: h - e, width: max(0, w - c * 2), height: e)),
            (.bottom,      NSRect(x: c, y: 0, width: max(0, w - c * 2), height: e)),
            (.left,        NSRect(x: 0, y: c, width: e, height: max(0, h - c * 2))),
            (.right,       NSRect(x: w - e, y: c, width: e, height: max(0, h - c * 2)))
        ]
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hoveredEdge != nil || activeResizeBadge != nil,
              let ctx = NSGraphicsContext.current?.cgContext else { return }
        if let edge = hoveredEdge { drawEdgeIndicator(edge, in: ctx) }
        if let badge = activeResizeBadge, bounds.width >= 96, bounds.height >= 44 {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let ns = badge as NSString, sz = ns.size(withAttributes: attrs)
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
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor); ctx.setLineWidth(3.8); ctx.addPath(p); ctx.strokePath()
        ctx.setStrokeColor(MSnipUITheme.accent.cgColor); ctx.setLineWidth(2.2); ctx.addPath(p); ctx.strokePath()
    }
}

/// 贴图窗口 8 向边角缩放与自适应屏幕尺寸交互扩展
extension PinWindow {
    var minAllowedZoom: CGFloat { min(0.25, max(0.05, 80.0 / max(1.0, max(baseSize.width, baseSize.height)))) }
    var maxAllowedZoom: CGFloat { 4.0 }

    func attachResizeChrome() {
        let chrome = PinResizeChromeView(frame: pinContentView.bounds)
        chrome.autoresizingMask = [.width, .height]
        chrome.onBorderHoverChanged = { [weak self] edge in self?.resizeState.hoveredEdge = edge }
        pinContentView.addSubview(chrome)
        resizeState.chromeView = chrome
        pinContentView.onMouseMoved = { [weak self] pt in _ = self?.handleResizeHover(contentPoint: pt) }
        pinContentView.onVisualStateChanged = { [weak self] in self?.syncGlowState(); self?.syncResizeChromeVisibility() }
        syncResizeChromeVisibility()
    }

    func syncResizeChromeVisibility() {
        let allow = !isClickThrough && editorCanvas == nil && cropOverlay == nil
        resizeState.chromeView?.isInteractive = allow
        if !allow {
            resizeState.hoveredEdge = nil
            resizeState.chromeView?.hoveredEdge = nil
            resizeState.chromeView?.activeResizeBadge = nil
        }
    }

    @discardableResult
    func handleResizeHover(contentPoint: NSPoint) -> Bool {
        guard !isClickThrough, editorCanvas == nil, cropOverlay == nil else { return false }
        if let active = resizeState.activeEdge { PinResizeCursorFactory.cursor(for: active).set(); return true }
        let edge = PinResizeEdge.hitTest(point: contentPoint, in: pinContentView.bounds)
        let prev = resizeState.hoveredEdge
        resizeState.hoveredEdge = edge
        resizeState.chromeView?.hoveredEdge = edge
        if let edge { PinResizeCursorFactory.cursor(for: edge).set(); return true }
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
        resizeState.activeEdge = edge; resizeState.hoveredEdge = edge
        resizeState.mouseStart = NSEvent.mouseLocation; resizeState.frameStart = imageScreenFrame
        resizeState.chromeView?.hoveredEdge = edge
        updateResizeBadge(); PinResizeCursorFactory.cursor(for: edge).set(); syncGlowState()
    }

    func updateResizeDrag() {
        guard let edge = resizeState.activeEdge else { return }
        let now = NSEvent.mouseLocation
        let res = ImageTransform.resizedPinFrame(
            edge: edge, initialFrame: resizeState.frameStart, baseSize: baseSize,
            delta: CGPoint(x: now.x - resizeState.mouseStart.x, y: now.y - resizeState.mouseStart.y),
            minZoom: minAllowedZoom, maxZoom: maxAllowedZoom
        )
        let s = imageScale
        zoomFactor = res.zoom
        setImageScreenFrame(NSRect(x: (res.frame.origin.x * s).rounded() / s, y: (res.frame.origin.y * s).rounded() / s, width: res.frame.width, height: res.frame.height))
        updateResizeBadge(); PinResizeCursorFactory.cursor(for: edge).set()
        if hoverBarPanel.isVisible { hoverBarPanel.reposition(anchoringTo: imageScreenFrame, on: screen) }
    }

    func endResizeDrag() {
        guard resizeState.activeEdge != nil else { return }
        resizeState.activeEdge = nil; resizeState.chromeView?.activeResizeBadge = nil
        if let cp = currentContentMousePoint() { _ = handleResizeHover(contentPoint: cp) }
        else { resizeState.hoveredEdge = nil; resizeState.chromeView?.hoveredEdge = nil; NSCursor.arrow.set() }
        if let chrome = resizeState.chromeView { invalidateCursorRects(for: chrome) }
        syncGlowState()
        if hoverBarPanel.isVisible { hoverBarPanel.reposition(anchoringTo: imageScreenFrame, on: screen) }
    }

    @objc func fitToScreen() {
        let vf = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let fit = ImageTransform.fittedPinRect(baseSize: baseSize, visibleBounds: vf, preferredOrigin: nil)
        let s = imageScale
        zoomFactor = fit.zoom
        setImageScreenFrame(NSRect(x: (fit.frame.origin.x * s).rounded() / s, y: (fit.frame.origin.y * s).rounded() / s, width: fit.frame.width, height: fit.frame.height))
        toolbarPanel?.reposition(anchoringTo: imageScreenFrame, on: screen)
        if hoverBarPanel.isVisible { hoverBarPanel.reposition(anchoringTo: imageScreenFrame, on: screen) }
    }

    private func updateResizeBadge() {
        let sz = imageScreenFrame.size
        resizeState.chromeView?.activeResizeBadge = "\(Int(sz.width.rounded())) × \(Int(sz.height.rounded())) · \(max(1, Int((zoomFactor * 100.0).rounded())))%"
    }

    private func currentContentMousePoint() -> NSPoint? {
        let winPt = convertPoint(fromScreen: NSEvent.mouseLocation)
        let pt = pinContentView.convert(winPt, from: nil)
        return pinContentView.bounds.contains(pt) ? pt : nil
    }
}
