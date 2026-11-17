import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 覆盖层局部脏矩形失效（Partial Dirty-Rect Invalidation）与零拷贝底图切片绘制支持
extension OverlayView {
    func autoSnapDirtyBounds(for rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - 8,
            y: rect.minY - 34,
            width: max(rect.width + 16, 280),
            height: rect.height + 42
        ).intersection(bounds)
    }

    func invalidateAutoSnapTransition(from oldRect: CGRect?, to newRect: CGRect?) {
        if let o = oldRect { setNeedsDisplay(autoSnapDirtyBounds(for: o)) }
        if let n = newRect { setNeedsDisplay(autoSnapDirtyBounds(for: n)) }
    }

    func invalidateMagnifierAtCurrentMouse() {
        if let pt = lastMousePoint {
            setNeedsDisplay(magnifierCardFrame(at: pt).insetBy(dx: -22, dy: -24))
        }
    }

    func invalidateMagnifierMove(from oldPt: CGPoint?, to newPt: CGPoint?) {
        if showShortcutTips {
            let zone = shortcutTipsBottomTriggerZone()
            let wasIn = oldPt.map { zone.contains($0) } ?? false
            let nowIn = newPt.map { zone.contains($0) } ?? false
            if wasIn != nowIn {
                needsDisplay = true
                return
            }
        }
        if let r = magnifierDirtyRectIfVisible(at: oldPt) { setNeedsDisplay(r) }
        if let r = magnifierDirtyRectIfVisible(at: newPt) { setNeedsDisplay(r) }
    }

    func updateToolbarLayout() {
        toolbar.canUndo = doc.canUndo
        toolbar.canRedo = doc.canRedo
        toolbar.nextStepNumber = doc.nextStepNumber()
        toolbar.textCapsule = style.textCapsule
        toolbar.refreshState()

        subbar.activeTool = activeTool
        subbar.lineWidth = style.lineWidth
        subbar.colorIndex = colorIndex
        subbar.customColor = customPickedColor
        subbar.eyedropperActive = eyedropperActive
        subbar.textCapsule = style.textCapsule

        sidePills.hasCorner = cornerRadiusPt > 0.5
        sidePills.hasBackdrop = backdropStyle != .none

        guard let sel = selection, sel.width >= 6, sel.height >= 6 else {
            toolbar.isHidden = true
            subbar.isHidden = true
            sidePills.isHidden = true
            return
        }
        toolbar.isHidden = false
        let barSize = toolbar.frame.size
        if let manual = manualToolbarOrigin {
            let cx = min(max(6, manual.x), bounds.width - barSize.width - 6)
            let cy = min(max(6, manual.y), bounds.height - barSize.height - 6)
            toolbar.setFrameOrigin(NSPoint(x: round(cx), y: round(cy)))
        } else {
            let dockBottom = max(12, snapshot.screen.visibleFrame.minY - snapshot.screen.frame.minY + 12)
            let x = min(max(16, sel.maxX - barSize.width), bounds.width - barSize.width - 16)
            let belowY = sel.maxY + 10
            let aboveY = sel.minY - barSize.height - 10
            let y = (belowY + barSize.height + 44 <= bounds.height - dockBottom)
                ? belowY
                : (aboveY >= 16 ? aboveY : max(16, sel.maxY - barSize.height - 10))
            toolbar.setFrameOrigin(NSPoint(x: round(x), y: round(y)))
        }
        repositionSubbar()

        sidePills.isHidden = false
        let pillSz = OverlaySidePillsView.viewSize
        let rightX = sel.maxX + 10
        let leftX = sel.minX - pillSz.width - 10
        let px = (rightX + pillSz.width + 6 <= bounds.width) ? rightX : max(6, leftX)
        let py = min(max(8, sel.minY + 2), bounds.height - pillSz.height - 8)
        sidePills.setFrameOrigin(NSPoint(x: round(px), y: round(py)))

        if let ocrV = inPlaceOCRView { ocrV.frame = sel }
        if let trV = inPlaceTranslateView { trV.frame = sel }
    }

    func clearSelectionFromSibling() {
        cancelTextEditing()
        deactivateInPlaceOCR()
        deactivateInPlaceTranslate()
        stopSnapGlide()
        selection = nil
        lastMousePoint = nil
        eyedropperActive = false
        autoSnapStack = []
        displayedAutoRect = nil
        preferredSnapArea = nil
        selectedObjectIndex = nil
        draftAnnotation = nil
        doc = AnnotationDocument()
    }

    func repositionSubbar() {
        let shouldShow = !toolbar.isHidden && !toolbar.inPlaceOCRActive && !toolbar.inPlaceTranslateActive && (activeTool != nil || selectedObjectIndex != nil)
        guard shouldShow else {
            subbar.isHidden = true
            return
        }
        subbar.refresh()
        subbar.isHidden = false
        let tf = toolbar.frame
        let sz = subbar.frame.size
        let sx = min(max(6, tf.minX), bounds.width - sz.width - 6)
        let belowY = tf.maxY + 6
        let sy = (belowY + sz.height + 6 <= bounds.height) ? belowY : max(6, tf.minY - sz.height - 6)
        subbar.setFrameOrigin(NSPoint(x: round(sx), y: round(sy)))
    }

    /// 停留在页面实时预览渐变美化衬底外框
    func drawLiveBackdropFrameIfNeeded(ctx: CGContext, sel: CGRect, cornerRadius: CGFloat) {
        guard backdropStyle != .none else { return }
        let stops = backdropStyle.gradientStops
        guard stops.count >= 2 else { return }
        let pad: CGFloat = 18
        let outer = sel.insetBy(dx: -pad, dy: -pad)
        let innerR = cornerRadius > 0.5 ? cornerRadius : 10
        let outerPath = CGPath(roundedRect: outer, cornerWidth: innerR + 8, cornerHeight: innerR + 8, transform: nil)
        let innerPath = CGPath(roundedRect: sel, cornerWidth: innerR, cornerHeight: innerR, transform: nil)

        ctx.saveGState()
        ctx.addPath(outerPath)
        ctx.addPath(innerPath)
        ctx.clip(using: .evenOdd)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let cgColors = stops.map(\.cgColor) as CFArray
        let locs: [CGFloat] = stops.enumerated().map { CGFloat($0.offset) / CGFloat(max(1, stops.count - 1)) }
        if let grad = CGGradient(colorsSpace: cs, colors: cgColors, locations: locs) {
            ctx.drawLinearGradient(
                grad,
                start: CGPoint(x: outer.minX, y: outer.minY),
                end: CGPoint(x: outer.maxX, y: outer.maxY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        ctx.restoreGState()
    }

    /// 仅裁剪并绘制 `dirtyRect` 对应的物理像素子图（`CGImage.cropping` 零拷贝，大幅降低 4K/5K 带宽）
    func drawFrozenBackgroundSlice(in ctx: CGContext, dirtyRect: CGRect) {
        let scale = snapshot.scaleFactor
        let imgW = snapshot.cgImage.width
        let imgH = snapshot.cgImage.height
        let pxX0 = max(0, Int(floor(dirtyRect.minX * scale)))
        let pxY0 = max(0, Int(floor(dirtyRect.minY * scale)))
        let pxX1 = min(imgW, Int(ceil(dirtyRect.maxX * scale)))
        let pxY1 = min(imgH, Int(ceil(dirtyRect.maxY * scale)))
        guard pxX1 > pxX0, pxY1 > pxY0 else { return }

        let pxCrop = CGRect(x: pxX0, y: pxY0, width: pxX1 - pxX0, height: pxY1 - pxY0)
        guard let sliceCG = snapshot.cgImage.cropping(to: pxCrop) else { return }
        let dst = CGRect(
            x: CGFloat(pxX0) / scale,
            y: CGFloat(pxY0) / scale,
            width: CGFloat(pxX1 - pxX0) / scale,
            height: CGFloat(pxY1 - pxY0) / scale
        )
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.translateBy(x: 0, y: dst.minY + dst.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(sliceCG, in: dst)
        ctx.restoreGState()
    }
}
