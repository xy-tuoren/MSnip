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
