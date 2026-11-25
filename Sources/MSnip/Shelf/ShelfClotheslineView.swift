import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 顶部轻盈「晾衣绳」根容器：
/// - 取消笨重实心矩形底框，绘制一条两端自然淡出的悬链弧形细绳；
/// - 空白缝隙 100% 透明且 `hitTest` 返回 `nil` 穿透给底层应用，常驻或展开时完全不遮挡工作区；
/// - 拖入文件/文本经过绳子时即时点亮柔和接纳光带，松手即挂上晾衣架。
final class ShelfClotheslineView: NSView {
    static let ropeMarginX: CGFloat = 18.0
    static let ropeBaseY: CGFloat = 28.0
    static let ropeSag: CGFloat = 7.0

    var onDropFiles: (([URL]) -> Void)?
    var onDropText: ((String) -> Void)?
    var utilityPillRect: CGRect = .zero { didSet { if oldValue != utilityPillRect { needsDisplay = true } } }
    var hitTestTargetsProvider: (() -> [NSView])?

    private var isDragTargeted = false { didSet { if oldValue != isDragTargeted { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .string])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// 精确透明穿透：仅卡片本体、右上微型胶囊与左右翻页键接管鼠标，卡片间透明缝隙彻底穿透给底层窗口
    override func hitTest(_ point: NSPoint) -> NSView? {
        if isDragTargeted { return self }
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        if utilityPillRect.contains(local) {
            return super.hitTest(point) ?? self
        }
        if let targets = hitTestTargetsProvider?() {
            for target in targets where !target.isHidden {
                let ptInTarget = target.convert(local, from: self)
                if target.bounds.contains(ptInTarget) {
                    return target.hitTest(target.convert(point, from: superview)) ?? target
                }
            }
        }
        return nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isDragTargeted = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { isDragTargeted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDragTargeted = false
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onDropFiles?(urls)
            return true
        }
        if let txt = pb.string(forType: .string), !txt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onDropText?(txt)
            return true
        }
        return false
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let isDark = GeekTheme.isDark

        // 1) 拖入文件/文字时的柔光接纳区提示
        if isDragTargeted {
            let dropR = CGRect(x: 20, y: 12, width: bounds.width - 40, height: bounds.height - 22)
            let path = CGPath(roundedRect: dropR, cornerWidth: 16, cornerHeight: 16, transform: nil)
            ctx.saveGState()
            ctx.setFillColor(GeekTheme.accent.withAlphaComponent(isDark ? 0.18 : 0.12).cgColor)
            ctx.addPath(path); ctx.fillPath()
            ctx.setStrokeColor(GeekTheme.accent.withAlphaComponent(0.92).cgColor)
            ctx.setLineWidth(1.8); ctx.setLineDash(phase: 0, lengths: [6, 4])
            ctx.addPath(path); ctx.strokePath()
            ctx.restoreGState()
        }

        // 2) 悬链晾衣绳（两端 8% 渐隐淡出，柔和阴影 + 金属/亚麻双层质感）
        drawCatenaryRope(in: ctx, isDark: isDark)

        // 3) 右上角精简悬浮操作微胶囊底衬
        if !utilityPillRect.isEmpty {
            ctx.saveGState()
            let r = utilityPillRect
            let path = CGPath(roundedRect: r, cornerWidth: r.height * 0.5, cornerHeight: r.height * 0.5, transform: nil)
            ctx.setShadow(
                offset: CGSize(width: 0, height: -2),
                blur: 8,
                color: NSColor.black.withAlphaComponent(isDark ? 0.38 : 0.14).cgColor
            )
            let bg = isDark
                ? NSColor(srgbRed: 0.13, green: 0.14, blue: 0.17, alpha: 0.90)
                : NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 0.94)
            ctx.setFillColor(bg.cgColor)
            ctx.addPath(path); ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor((isDark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.10)).cgColor)
            ctx.setLineWidth(0.8)
            ctx.addPath(path); ctx.strokePath()
            ctx.restoreGState()
        }
    }

    private func drawCatenaryRope(in ctx: CGContext, isDark: Bool) {
        let x0 = Self.ropeMarginX
        let x1 = bounds.width - Self.ropeMarginX
        guard x1 > x0 + 40 else { return }
        let baseY = Self.ropeBaseY
        let ctrlY = baseY + Self.ropeSag * 2.0

        let ropePath = CGMutablePath()
        ropePath.move(to: CGPoint(x: x0, y: baseY))
        ropePath.addQuadCurve(to: CGPoint(x: x1, y: baseY), control: CGPoint(x: (x0 + x1) * 0.5, y: ctrlY))

        let mainColor = isDark
            ? NSColor(srgbRed: 0.72, green: 0.76, blue: 0.82, alpha: 0.85)
            : NSColor(srgbRed: 0.42, green: 0.46, blue: 0.53, alpha: 0.78)
        let hiColor = isDark
            ? NSColor.white.withAlphaComponent(0.36)
            : NSColor.white.withAlphaComponent(0.75)

        // 柔和底影
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 3.5, color: NSColor.black.withAlphaComponent(isDark ? 0.50 : 0.22).cgColor)
        ctx.addPath(ropePath)
        ctx.setLineWidth(2.0); ctx.setLineCap(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        drawFadeGradient(in: ctx, x0: x0, x1: x1, color: mainColor)
        ctx.restoreGState()

        // 顶缘微高光
        ctx.saveGState()
        ctx.translateBy(x: 0, y: -0.6)
        ctx.addPath(ropePath)
        ctx.setLineWidth(0.8); ctx.setLineCap(.round)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        drawFadeGradient(in: ctx, x0: x0, x1: x1, color: hiColor)
        ctx.restoreGState()
    }

    private func drawFadeGradient(in ctx: CGContext, x0: CGFloat, x1: CGFloat, color: NSColor) {
        let cs = CGColorSpaceCreateDeviceRGB()
        let clear = color.withAlphaComponent(0).cgColor
        let solid = color.cgColor
        guard let grad = CGGradient(colorsSpace: cs, colors: [clear, solid, solid, clear] as CFArray, locations: [0, 0.08, 0.92, 1]) else { return }
        ctx.drawLinearGradient(grad, start: CGPoint(x: x0, y: 0), end: CGPoint(x: x1, y: 0), options: [])
    }
}
