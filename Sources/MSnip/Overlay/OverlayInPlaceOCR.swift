import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 选区右侧悬浮三联快捷圆钮（复刻参考图选区右缘圆钮：停留在当前页面实时切换圆角、渐变衬底与整窗对齐）
final class OverlaySidePillsView: NSView {
    enum PillAction {
        case cycleCorner
        case cycleBackdrop
        case snapWindow(optionHeld: Bool)
    }

    var onAction: ((PillAction) -> Void)?
    var hasCorner: Bool = false { didSet { needsDisplay = true } }
    var hasBackdrop: Bool = false { didSet { needsDisplay = true } }
    private var hoveredIdx: Int?

    override var isFlipped: Bool { true }
    static let pillSize: CGFloat = 30
    static let gap: CGFloat = 8
    static let viewSize = NSSize(width: 32, height: 30 * 3 + 8 * 2)

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.viewSize))
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor(srgbRed: 0.04, green: 0.08, blue: 0.16, alpha: 1.0).cgColor
        layer?.shadowOpacity = 0.16
        layer?.shadowRadius = 7
        layer?.shadowOffset = CGSize(width: 0, height: 2)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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

    private func rectForSlot(_ idx: Int) -> CGRect {
        CGRect(x: 1, y: CGFloat(idx) * (Self.pillSize + Self.gap), width: Self.pillSize, height: Self.pillSize)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let hit = (0..<3).first(where: { rectForSlot($0).contains(p) })
        if hit != nil { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        if hit != hoveredIdx {
            hoveredIdx = hit
            switch hit {
            case 0: toolTip = "切换圆角裁切预览 (B)"
            case 1: toolTip = "切换渐变美化衬底实时预览 (P)"
            case 2: toolTip = "对齐底层应用窗口（⌥+点击导出独立透明阴影窗口）"
            default: toolTip = nil
            }
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) { hoveredIdx = nil; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let idx = (0..<3).first(where: { rectForSlot($0).contains(p) }) else { return }
        switch idx {
        case 0: onAction?(.cycleCorner)
        case 1: onAction?(.cycleBackdrop)
        case 2: onAction?(.snapWindow(optionHeld: event.modifierFlags.contains(.option)))
        default: break
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let specs: [(String, Bool)] = [
            ("rectangle.roundedtop", hasCorner),
            ("sparkles.rectangle.stack", hasBackdrop),
            ("macwindow", false)
        ]
        for (i, (sym, active)) in specs.enumerated() {
            let r = rectForSlot(i)
            let hov = (hoveredIdx == i)
            ctx.saveGState()
            let fill = active
                ? MSnipUITheme.accent
                : (hov ? MSnipUITheme.subtleFill : MSnipUITheme.cardBg)
            ctx.setFillColor(fill.cgColor)
            ctx.fillEllipse(in: r)
            let border = active ? MSnipUITheme.accent : MSnipUITheme.borderStrong
            ctx.setStrokeColor(border.cgColor)
            ctx.setLineWidth(1.0)
            ctx.strokeEllipse(in: r.insetBy(dx: 0.5, dy: 0.5))
            ctx.restoreGState()
            ToolbarView.drawSymbol(sym, in: r, alpha: 0.96, tint: active ? .white : MSnipUITheme.inkPrimary)
        }
    }
}

/// 覆盖层页内实况文字识别 (`[A]`) 管理扩展：不退出当前截图页即可直接在选区内高亮划词复制
@MainActor
extension OverlayView {
    func toggleInPlaceOCR() {
        if toolbar.inPlaceOCRActive {
            deactivateInPlaceOCR()
        } else {
            activateInPlaceOCR()
        }
    }

    func activateInPlaceOCR() {
        commitTextEditing()
        deactivateInPlaceTranslate()
        if selection == nil, let snap = hoveredAutoRect {
            selection = snap
        }
        guard let sel = selection, sel.width >= 8, sel.height >= 8 else {
            ToastHUD.show(message: "请先框选需要识别文字的区域")
            return
        }
        guard let baked = AnnotationRenderer.bakeExportImage(
            sampler: snapshot.sampler,
            selection: sel,
            imageScale: snapshot.scaleFactor,
            annotations: doc.objects
        ) else { return }

        activeTool = nil
        eyedropperActive = false
        selectedObjectIndex = nil
        toolbar.inPlaceOCRActive = true

        let liveView = inPlaceOCRView ?? {
            let v = LiveTextImageView(scaling: .scaleAxesIndependently)
            addSubview(v, positioned: .below, relativeTo: toolbar)
            inPlaceOCRView = v
            return v
        }()
        liveView.frame = sel
        liveView.isHidden = false
        liveView.setPreviewImageOnly(cgImage: baked, logicalSize: sel.size, highlightBlocks: true)

        VisionTextExtractor.recognizeAsync(from: baked) { [weak self, weak liveView] output in
            guard let self, let liveView, self.toolbar.inPlaceOCRActive else { return }
            liveView.applyPrecomputedAnalysis(output.liveAnalysisObject, highlightBlocks: true)
            let text = output.initialClipboardText
            if !text.isEmpty {
                ClipboardAndSave.copyText(text)
                let count = text.count
                ToastHUD.show(
                    message: "已识别 \(count) 字并复制 · 可直接在框内划词或点工具继续标注",
                    actionTitle: "双栏对照窗 ›",
                    onAction: { [weak self] in
                        self?.exportAndFinish(mode: .extractText)
                    }
                )
            } else {
                ToastHUD.show(message: "选区内未检测到可识别文字或二维码")
            }
        }
        updateToolbarLayout()
        needsDisplay = true
    }

    func deactivateInPlaceOCR() {
        guard toolbar.inPlaceOCRActive || inPlaceOCRView != nil else { return }
        toolbar.inPlaceOCRActive = false
        inPlaceOCRView?.clearSelection()
        inPlaceOCRView?.removeFromSuperview()
        inPlaceOCRView = nil
        updateToolbarLayout()
        needsDisplay = true
    }

    /// 将当前选区直接贴合到底层独立窗口边界，停留在截图页继续标注或识字
    func snapSelectionToUnderlyingWindow() {
        let probe = selection.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? lastMousePoint
            ?? CGPoint(x: bounds.midX, y: bounds.midY)
        guard let hit = regionDetector.topWindow(at: probe, in: snapshot) else {
            ToastHUD.show(message: "当前位置下方未检测到独立应用窗口")
            return
        }
        deactivateInPlaceOCR()
        deactivateInPlaceTranslate()
        selection = hit.localRect
        ToastHUD.show(message: "已对齐窗口：\(hit.ownerName.isEmpty ? "当前窗口" : hit.ownerName)（⌥+点击可直出透明阴影图）")
    }
}
