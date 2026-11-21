import AppKit
import CoreGraphics
import Foundation
import MSnipCore
import QuartzCore

/// 独立 120Hz 透明 GPU 图层承载的四向像素卡尺视图（零主画布重绘，@1x / @2x 均像素级锐利）
final class OverlayCaliperLayerView: NSView {
    weak var ownerOverlay: OverlayView?
    var measurement: PixelCaliperResult? { didSet { if oldValue != measurement { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let owner = ownerOverlay,
              let m = measurement else { return }

        let s = max(1.0, owner.snapshot.scaleFactor)
        let cx = (CGFloat(m.originX) + 0.5) / s
        let cy = (CGFloat(m.originY) + 0.5) / s
        let leftX = CGFloat(m.leftPx) / s
        let rightX = CGFloat(m.rightPx + 1) / s
        let topY = CGFloat(m.topPx) / s
        let bottomY = CGFloat(m.bottomPx + 1) / s

        let coral = NSColor(srgbRed: 0.965, green: 0.255, blue: 0.376, alpha: 1.0) // #F64160
        let halo = NSColor.black.withAlphaComponent(0.55)

        // 1) 淡珊瑚色测距区间微提示框（仅四边均命中有效 UI 边界且非整屏时轻柔描出轮廓）
        let rectW = rightX - leftX
        let rectH = bottomY - topY
        if m.hitLeft && m.hitRight && m.hitTop && m.hitBottom,
           rectW >= 4, rectH >= 4,
           rectW < bounds.width * 0.95 || rectH < bounds.height * 0.95 {
            let box = CGRect(x: leftX, y: topY, width: rectW, height: rectH)
            ctx.saveGState()
            ctx.setFillColor(coral.withAlphaComponent(0.06).cgColor)
            ctx.fill(box)
            ctx.setStrokeColor(coral.withAlphaComponent(0.32).cgColor)
            ctx.setLineWidth(1.0)
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.stroke(box.insetBy(dx: 0.5, dy: 0.5))
            ctx.restoreGState()
        }

        // 2) 四向 1px 清晰珊瑚红测距射线 + 端帽（双层暗描边保底，亮/暗背景均高对比）
        let capHalf: CGFloat = 4.5
        let drawRays: (CGColor, CGFloat) -> Void = { color, width in
            ctx.saveGState()
            ctx.setStrokeColor(color)
            ctx.setLineWidth(width)
            // 水平射线 + 左右端帽
            ctx.move(to: CGPoint(x: leftX, y: cy)); ctx.addLine(to: CGPoint(x: rightX, y: cy))
            if m.hitLeft {
                ctx.move(to: CGPoint(x: leftX + 0.5, y: cy - capHalf)); ctx.addLine(to: CGPoint(x: leftX + 0.5, y: cy + capHalf))
            }
            if m.hitRight {
                ctx.move(to: CGPoint(x: rightX - 0.5, y: cy - capHalf)); ctx.addLine(to: CGPoint(x: rightX - 0.5, y: cy + capHalf))
            }
            // 垂直射线 + 上下端帽
            ctx.move(to: CGPoint(x: cx, y: topY)); ctx.addLine(to: CGPoint(x: cx, y: bottomY))
            if m.hitTop {
                ctx.move(to: CGPoint(x: cx - capHalf, y: topY + 0.5)); ctx.addLine(to: CGPoint(x: cx + capHalf, y: topY + 0.5))
            }
            if m.hitBottom {
                ctx.move(to: CGPoint(x: cx - capHalf, y: bottomY - 0.5)); ctx.addLine(to: CGPoint(x: cx + capHalf, y: bottomY - 0.5))
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
        drawRays(halo.cgColor, 2.5)
        drawRays(coral.cgColor, 1.2)

        // 3) 水平与垂直像素净距读数胶囊（自动避开十字中心与屏幕边界，零重叠）
        let hText = "\(m.widthPx) px"
        let vText = "\(m.heightPx) px"
        let hSz = Self.measureBadge(hText)
        let vSz = Self.measureBadge(vText)

        // 水平读数放在较宽一侧线段中点上方（避开十字中心与放大镜）
        let leftSegW = cx - leftX
        let rightSegW = rightX - cx
        let hAnchorX: CGFloat = (leftSegW >= rightSegW)
            ? (leftSegW >= hSz.width + 12 ? (leftX + leftSegW * 0.5) : (leftX + rectW * 0.5))
            : (rightSegW >= hSz.width + 12 ? (cx + rightSegW * 0.5) : (leftX + rectW * 0.5))
        let hY = (cy - hSz.height - 6 >= 8) ? (cy - hSz.height - 6) : (cy + 7)
        let hRect = CGRect(
            x: round(min(max(8, hAnchorX - hSz.width * 0.5), bounds.width - hSz.width - 8)),
            y: round(hY),
            width: hSz.width,
            height: hSz.height
        )

        // 垂直读数放在较长一侧线段中点右侧（与水平读数防碰撞）
        let topSegH = cy - topY
        let bottomSegH = bottomY - cy
        let vAnchorY: CGFloat = (topSegH >= bottomSegH)
            ? (topSegH >= vSz.height + 12 ? (topY + topSegH * 0.5) : (topY + rectH * 0.5))
            : (bottomSegH >= vSz.height + 12 ? (cy + bottomSegH * 0.5) : (topY + rectH * 0.5))
        let vX = (cx + 8 + vSz.width <= bounds.width - 8) ? (cx + 8) : (cx - vSz.width - 8)
        var vRect = CGRect(
            x: round(min(max(8, vX), bounds.width - vSz.width - 8)),
            y: round(min(max(8, vAnchorY - vSz.height * 0.5), bounds.height - vSz.height - 8)),
            width: vSz.width,
            height: vSz.height
        )
        if vRect.intersects(hRect.insetBy(dx: -4, dy: -4)) {
            let shiftedY = (cy + 10 + vSz.height <= bounds.height - 8) ? (cy + 10) : max(8, hRect.minY - vSz.height - 6)
            vRect.origin.y = round(shiftedY)
        }

        Self.drawBadge(ctx: ctx, rect: hRect, text: hText, bg: coral)
        Self.drawBadge(ctx: ctx, rect: vRect, text: vText, bg: coral)
    }

    private static let badgeAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11.0, weight: .bold),
        .foregroundColor: NSColor.white
    ]

    private static func measureBadge(_ text: String) -> CGSize {
        let sz = (text as NSString).size(withAttributes: badgeAttrs)
        return CGSize(width: ceil(sz.width + 12), height: 19)
    }

    private static func drawBadge(ctx: CGContext, rect: CGRect, text: String, bg: NSColor) {
        let p = CGPath(roundedRect: rect, cornerWidth: 5.0, cornerHeight: 5.0, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 4, color: NSColor.black.withAlphaComponent(0.32).cgColor)
        ctx.setFillColor(bg.cgColor)
        ctx.addPath(p); ctx.fillPath()
        ctx.restoreGState()

        let ns = text as NSString
        let sz = ns.size(withAttributes: badgeAttrs)
        ns.draw(
            at: CGPoint(x: round(rect.midX - sz.width * 0.5), y: round(rect.midY - sz.height * 0.5)),
            withAttributes: badgeAttrs
        )
    }
}

extension OverlayView {
    /// 同步 120Hz 四向像素卡尺图层状态与实时测距结果
    func syncCaliperView() {
        guard caliperActive, !isDraggingSelectionBox, !isEditingText,
              let sample = samplePixelAtCursor(),
              let res = PixelCaliper.measure(atX: sample.px, y: sample.py, in: snapshot.sampler) else {
            if !caliperView.isHidden { caliperView.isHidden = true }
            caliperView.measurement = nil
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if caliperView.frame != bounds { caliperView.frame = bounds }
        if caliperView.isHidden { caliperView.isHidden = false }
        CATransaction.commit()
        caliperView.measurement = res
    }
}
