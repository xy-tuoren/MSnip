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
    fileprivate weak var chromeView: PinResizeChromeView?
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

/// 贴图边角悬停微指示与原生光标热区视图（跨贴图外沿 -4pt ~ 内沿 +7pt 8 条窄带接管 hitTest 与 CursorRect，中心 100% 穿透给实况文本）
private final class PinResizeChromeView: NSView {
    private let outerReach = PinGlowContainerView.outerResizeReach
    private var imageBounds: NSRect { bounds.insetBy(dx: outerReach, dy: outerReach) }

    var isInteractive: Bool = true {
        didSet { guard oldValue != isInteractive else { return }; updateTrackingAreas(); window?.invalidateCursorRects(for: self) }
    }
    var hoveredEdge: PinResizeEdge? { didSet { if oldValue != hoveredEdge { needsDisplay = true } } }
    var activeResizeBadge: String? { didSet { if oldValue != activeResizeBadge { needsDisplay = true } } }
    var onBorderHoverChanged: ((PinResizeEdge?) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isInteractive else { return nil }
        return PinResizeEdge.hitTest(point: convert(point, from: superview), in: imageBounds, outerSlop: outerReach) != nil ? self : nil
    }
    override func menu(for event: NSEvent) -> NSMenu? { superview?.menu ?? (superview as? PinGlowContainerView)?.contentHost.menu }
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
            addTrackingArea(NSTrackingArea(rect: rect, options: [.cursorUpdate, .mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self, userInfo: ["edge": edge]))
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        guard isInteractive else { super.cursorUpdate(with: event); return }
        let local = convert(event.locationInWindow, from: nil)
        if let edge = PinResizeEdge.hitTest(point: local, in: imageBounds, outerSlop: outerReach) ?? (event.trackingArea?.userInfo?["edge"] as? PinResizeEdge) {
            PinResizeCursorFactory.cursor(for: edge).set()
        } else { super.cursorUpdate(with: event) }
    }

    override func mouseEntered(with event: NSEvent) {
        guard isInteractive else { return }
        let local = convert(event.locationInWindow, from: nil)
        guard let edge = PinResizeEdge.hitTest(point: local, in: imageBounds, outerSlop: outerReach) ?? (event.trackingArea?.userInfo?["edge"] as? PinResizeEdge) else { return }
        hoveredEdge = edge; onBorderHoverChanged?(edge); PinResizeCursorFactory.cursor(for: edge).set()
    }

    override func mouseMoved(with event: NSEvent) {
        guard isInteractive else { return }
        let edge = PinResizeEdge.hitTest(point: convert(event.locationInWindow, from: nil), in: imageBounds, outerSlop: outerReach)
        if hoveredEdge != edge { hoveredEdge = edge; onBorderHoverChanged?(edge) }
        if let edge { PinResizeCursorFactory.cursor(for: edge).set() }
    }

    override func mouseExited(with event: NSEvent) {
        guard let exited = event.trackingArea?.userInfo?["edge"] as? PinResizeEdge, hoveredEdge == exited else { return }
        let next = isInteractive ? PinResizeEdge.hitTest(point: convert(event.locationInWindow, from: nil), in: imageBounds, outerSlop: outerReach) : nil
        hoveredEdge = next; onBorderHoverChanged?(next)
        if let next { PinResizeCursorFactory.cursor(for: next).set() } else { NSCursor.arrow.set() }
    }

    private func borderZones() -> [(PinResizeEdge, NSRect)] {
        let img = imageBounds
        guard img.width >= 32, img.height >= 32 else { return [] }
        let minDim = min(img.width, img.height)
        let c = min(14, max(6, minDim * 0.28)) + outerReach
        let e = min(7, max(4, minDim * 0.18)) + outerReach
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
        let img = imageBounds
        if let badge = activeResizeBadge, img.width >= 96, img.height >= 44 {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let ns = badge as NSString, sz = ns.size(withAttributes: attrs)
            let pillW = ceil(sz.width + 16), pillH: CGFloat = 22
            let pill = CGRect(x: round(img.midX - pillW * 0.5), y: img.minY + 10, width: pillW, height: pillH)
            let path = CGPath(roundedRect: pill, cornerWidth: 11, cornerHeight: 11, transform: nil)
            ctx.setFillColor(NSColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 0.80).cgColor)
            ctx.addPath(path); ctx.fillPath()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
            ctx.setLineWidth(0.8); ctx.addPath(path); ctx.strokePath()
            ns.draw(at: CGPoint(x: round(pill.midX - sz.width * 0.5), y: round(pill.midY - sz.height * 0.5 - 0.5)), withAttributes: attrs)
        }
    }

    private func drawEdgeIndicator(_ edge: PinResizeEdge, in ctx: CGContext) {
        let img = imageBounds, inset: CGFloat = 1.5
        let arm: CGFloat = min(10.0, max(5.0, min(img.width, img.height) * 0.16))
        let p = CGMutablePath()
        switch edge {
        case .topLeft:
            let pt = CGPoint(x: img.minX + inset, y: img.maxY - inset)
            p.move(to: CGPoint(x: pt.x + arm, y: pt.y)); p.addLine(to: pt); p.addLine(to: CGPoint(x: pt.x, y: pt.y - arm))
        case .topRight:
            let pt = CGPoint(x: img.maxX - inset, y: img.maxY - inset)
            p.move(to: CGPoint(x: pt.x - arm, y: pt.y)); p.addLine(to: pt); p.addLine(to: CGPoint(x: pt.x, y: pt.y - arm))
        case .bottomLeft:
            let pt = CGPoint(x: img.minX + inset, y: img.minY + inset)
            p.move(to: CGPoint(x: pt.x + arm, y: pt.y)); p.addLine(to: pt); p.addLine(to: CGPoint(x: pt.x, y: pt.y + arm))
        case .bottomRight:
            let pt = CGPoint(x: img.maxX - inset, y: img.minY + inset)
            p.move(to: CGPoint(x: pt.x - arm, y: pt.y)); p.addLine(to: pt); p.addLine(to: CGPoint(x: pt.x, y: pt.y + arm))
        case .top, .bottom:
            let half = min(18.0, max(8.0, img.width * 0.12))
            let y = (edge == .top) ? (img.maxY - inset) : (img.minY + inset)
            p.move(to: CGPoint(x: img.midX - half, y: y)); p.addLine(to: CGPoint(x: img.midX + half, y: y))
        case .left, .right:
            let half = min(18.0, max(8.0, img.height * 0.12))
            let x = (edge == .right) ? (img.maxX - inset) : (img.minX + inset)
            p.move(to: CGPoint(x: x, y: img.midY - half)); p.addLine(to: CGPoint(x: x, y: img.midY + half))
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
        let reach = PinGlowContainerView.outerResizeReach
        let chrome = PinResizeChromeView(frame: pinContentView.frame.insetBy(dx: -reach, dy: -reach))
        chrome.autoresizingMask = [.width, .height]
        chrome.onBorderHoverChanged = { [weak self] edge in
            self?.resizeState.hoveredEdge = edge
            if edge != nil { self?.updatePinHover(true) }
        }
        glowContainer.addSubview(chrome)
        resizeState.chromeView = chrome
        pinContentView.onMouseMoved = { [weak self] pt in _ = self?.handleResizeHover(contentPoint: pt) }
        pinContentView.onVisualStateChanged = { [weak self] in self?.syncGlowState(); self?.syncResizeChromeVisibility() }
        syncResizeChromeVisibility()
    }

    func syncResizeChromeVisibility() {
        let allow = !isClickThrough && editorCanvas == nil && cropOverlay == nil
        resizeState.chromeView?.isInteractive = allow
        if !allow { resizeState.hoveredEdge = nil; resizeState.chromeView?.hoveredEdge = nil; resizeState.chromeView?.activeResizeBadge = nil }
    }

    @discardableResult
    func handleResizeHover(contentPoint: NSPoint) -> Bool {
        guard !isClickThrough, editorCanvas == nil, cropOverlay == nil else { return false }
        if let active = resizeState.activeEdge { PinResizeCursorFactory.cursor(for: active).set(); return true }
        let edge = PinResizeEdge.hitTest(point: contentPoint, in: pinContentView.bounds, outerSlop: PinGlowContainerView.outerResizeReach)
        let prev = resizeState.hoveredEdge
        resizeState.hoveredEdge = edge; resizeState.chromeView?.hoveredEdge = edge
        if let edge { PinResizeCursorFactory.cursor(for: edge).set(); return true }
        if prev != nil { NSCursor.arrow.set() }
        return false
    }

    func clearResizeHoverCursorIfNeeded() {
        guard resizeState.activeEdge == nil, resizeState.hoveredEdge != nil else { return }
        resizeState.hoveredEdge = nil; resizeState.chromeView?.hoveredEdge = nil; NSCursor.arrow.set()
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
        reconcileHoverFromCurrentMouse()
    }

    @objc func fitToScreen() {
        let vf = (screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let fit = ImageTransform.fittedPinRect(baseSize: baseSize, visibleBounds: vf, preferredOrigin: nil)
        let s = imageScale
        zoomFactor = fit.zoom
        setImageScreenFrame(NSRect(x: (fit.frame.origin.x * s).rounded() / s, y: (fit.frame.origin.y * s).rounded() / s, width: fit.frame.width, height: fit.frame.height))
        toolbarPanel?.reposition(anchoringTo: imageScreenFrame, on: screen)
        if hoverBarPanel.isVisible { hoverBarPanel.reposition(anchoringTo: imageScreenFrame, on: screen) }
        reconcileHoverFromCurrentMouse()
    }

    private func updateResizeBadge() {
        let sz = imageScreenFrame.size
        resizeState.chromeView?.activeResizeBadge = "\(Int(sz.width.rounded())) × \(Int(sz.height.rounded())) · \(max(1, Int((zoomFactor * 100.0).rounded())))%"
    }

    private func currentContentMousePoint() -> NSPoint? {
        let winPt = convertPoint(fromScreen: NSEvent.mouseLocation)
        let pt = pinContentView.convert(winPt, from: nil)
        let reach = PinGlowContainerView.outerResizeReach
        return pinContentView.bounds.insetBy(dx: -reach, dy: -reach).contains(pt) ? pt : nil
    }
}

// MARK: - 贴图二次裁剪覆盖层

/// 贴图原位二次裁剪交互视图（在贴图内拖选保留区域，回车/双击确认裁剪，Esc 取消）
final class PinCropOverlayView: NSView {
    var onCommitCrop: ((CGRect) -> Void)? // 归一化坐标 0..1（左上角原点）
    var onCancelCrop: (() -> Void)?

    private var cropRect: CGRect?
    private var anchorPoint: CGPoint?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let inset = min(bounds.width, bounds.height) * 0.1
        if bounds.width > 40, bounds.height > 40 {
            cropRect = bounds.insetBy(dx: round(inset), dy: round(inset))
        } else {
            cropRect = bounds
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = clampedPoint(convert(event.locationInWindow, from: nil))
        if event.clickCount == 2, let r = cropRect, r.contains(p) {
            commitCurrentCrop()
            return
        }
        anchorPoint = p
        cropRect = CGRect(origin: p, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = anchorPoint else { return }
        let p = clampedPoint(convert(event.locationInWindow, from: nil))
        let end = event.modifierFlags.contains(.shift) ? Geometry.squareConstrainedEnd(from: anchor, to: p) : p
        cropRect = Geometry.normalizedRect(from: anchor, to: end).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        anchorPoint = nil
        if let r = cropRect, (r.width < 10 || r.height < 10) {
            cropRect = bounds.insetBy(dx: round(bounds.width * 0.1), dy: round(bounds.height * 0.1))
            needsDisplay = true
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancelCrop?(); return }
        if event.keyCode == 36 || event.keyCode == 76 { commitCurrentCrop(); return }
    }

    private func commitCurrentCrop() {
        guard let r = cropRect, bounds.width > 2, bounds.height > 2, r.width >= 10, r.height >= 10 else {
            onCancelCrop?()
            return
        }
        let norm = CGRect(
            x: max(0, min(1, r.minX / bounds.width)),
            y: max(0, min(1, r.minY / bounds.height)),
            width: max(0.02, min(1, r.width / bounds.width)),
            height: max(0.02, min(1, r.height / bounds.height))
        )
        onCommitCrop?(norm)
    }

    private func clampedPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), bounds.width), y: min(max(0, p.y), bounds.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.54).cgColor)
        if let r = cropRect, r.width >= 2, r.height >= 2 {
            ctx.addRect(bounds)
            ctx.addRect(r)
            ctx.fillPath(using: .evenOdd)

            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.5)
            ctx.stroke(r.insetBy(dx: 0.75, dy: 0.75))

            // 角落短刻度提示
            ctx.setStrokeColor(MSnipUITheme.accent.cgColor)
            ctx.setLineWidth(2.5)
            let cl: CGFloat = min(12, min(r.width, r.height) * 0.3)
            let corners: [(CGPoint, CGPoint, CGPoint)] = [
                (CGPoint(x: r.minX, y: r.minY + cl), CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX + cl, y: r.minY)),
                (CGPoint(x: r.maxX - cl, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.minY + cl)),
                (CGPoint(x: r.minX, y: r.maxY - cl), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX + cl, y: r.maxY)),
                (CGPoint(x: r.maxX - cl, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY - cl))
            ]
            for (p1, p2, p3) in corners {
                ctx.move(to: p1); ctx.addLine(to: p2); ctx.addLine(to: p3)
            }
            ctx.strokePath()

            let tip = L("拖选裁剪区域 · ↩ 确认 · Esc 取消") as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let sz = tip.size(withAttributes: attrs)
            let bw = min(bounds.width - 12, sz.width + 16), bh: CGFloat = 22
            let bx = round((bounds.width - bw) * 0.5)
            let by = r.minY >= bh + 8 ? round(r.minY - bh - 5) : round(min(bounds.height - bh - 6, r.minY + 6))
            let bgR = CGRect(x: bx, y: by, width: bw, height: bh)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.76).cgColor)
            ctx.addPath(CGPath(roundedRect: bgR, cornerWidth: 6, cornerHeight: 6, transform: nil)); ctx.fillPath()
            tip.draw(at: CGPoint(x: round(bgR.midX - sz.width * 0.5), y: round(bgR.midY - sz.height * 0.5)), withAttributes: attrs)
        } else {
            ctx.fill(bounds)
        }
        ctx.restoreGState()
    }
}

/// 贴图窗口二次裁剪生命周期扩展
extension PinWindow {
    @objc func beginCropEditing() {
        guard cropOverlay == nil, editorCanvas == nil, !isClickThrough else { return }
        pinContentView.liveTextView.clearSelection()
        pinContentView.isAnnotating = true
        syncHoverBarVisibility()

        let overlay = PinCropOverlayView(frame: pinContentView.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.onCommitCrop = { [weak self] normRect in self?.commitCrop(normalizedTopLeft: normRect) }
        overlay.onCancelCrop = { [weak self] in self?.endCropEditing() }
        pinContentView.addSubview(overlay)
        self.cropOverlay = overlay
        makeKeyAndOrderFront(nil)
        makeFirstResponder(overlay)
    }

    func endCropEditing() {
        guard let overlay = cropOverlay else { return }
        overlay.removeFromSuperview()
        cropOverlay = nil
        pinContentView.isAnnotating = false
        reconcileHoverFromCurrentMouse()
    }

    private func commitCrop(normalizedTopLeft norm: CGRect) {
        let img = currentCGImage
        let pxX = max(0, Int((norm.minX * CGFloat(img.width)).rounded()))
        let pxY = max(0, Int((norm.minY * CGFloat(img.height)).rounded()))
        let pxW = max(12, min(img.width - pxX, Int((norm.width * CGFloat(img.width)).rounded())))
        let pxH = max(12, min(img.height - pxY, Int((norm.height * CGFloat(img.height)).rounded())))
        guard let rawCropped = img.cropping(to: CGRect(x: pxX, y: pxY, width: pxW, height: pxH)) else {
            endCropEditing(); return
        }
        let cropped = ImageTransform.detachedCopy(rawCropped)
        let oldFrame = imageScreenFrame
        endCropEditing()

        baseCGImage = cropped
        currentCGImage = cropped
        activeBaseSampler = nil
        annotationDoc = AnnotationDocument()
        let nextBase = NSSize(width: max(8, CGFloat(cropped.width) / imageScale), height: max(8, CGFloat(cropped.height) / imageScale))
        baseSize = nextBase

        let newW = round(nextBase.width * zoomFactor), newH = round(nextBase.height * zoomFactor)
        // 保持裁剪区域在屏幕上的原位不动
        let newX = ((oldFrame.minX + norm.minX * oldFrame.width) * imageScale).rounded() / imageScale
        let newY = ((oldFrame.maxY - norm.maxY * oldFrame.height) * imageScale).rounded() / imageScale
        setImageScreenFrame(NSRect(x: newX, y: newY, width: newW, height: newH))
        pinContentView.liveTextView.configure(cgImage: cropped, logicalSize: nextBase)
        if hoverBarPanel.isVisible { hoverBarPanel.reposition(anchoringTo: imageScreenFrame, on: screen) }
        ToastHUD.show(message: L("已裁剪贴图 · %@ × %@ px", cropped.width, cropped.height))
    }
}
