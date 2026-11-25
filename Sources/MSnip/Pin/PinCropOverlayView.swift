import AppKit
import CoreGraphics
import Foundation
import MSnipCore

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

            let tip = "拖选裁剪区域 · ↩ 确认 · Esc 取消" as NSString
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
        guard let cropped = img.cropping(to: CGRect(x: pxX, y: pxY, width: pxW, height: pxH)) else {
            endCropEditing(); return
        }
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
        ToastHUD.show(message: "已裁剪贴图 · \(cropped.width) × \(cropped.height) px")
    }
}
