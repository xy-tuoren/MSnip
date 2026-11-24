import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 选区右侧悬浮三联快捷圆钮（复刻参考图选区右缘圆钮：停留在当前页面实时切换圆角、渐变衬底与整窗对齐）
final class OverlaySidePillsView: NSView {
    enum PillAction {
        case cycleCorner(optionHeld: Bool)
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
            case 0: toolTip = "调节圆角比例进度条（B · ⌥+点击归零）"
            case 1: toolTip = "切换渐变美化衬底实时预览 (G)"
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
        case 0: onAction?(.cycleCorner(optionHeld: event.modifierFlags.contains(.option)))
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
            v.hidesImageContent = true
            addSubview(v, positioned: .below, relativeTo: toolbar)
            inPlaceOCRView = v
            return v
        }()
        liveView.hidesImageContent = true
        liveView.frame = sel
        liveView.isHidden = false
        liveView.setPreviewImageOnly(cgImage: baked, logicalSize: sel.size, highlightBlocks: false)

        VisionTextExtractor.recognizeAsync(from: baked) { [weak self, weak liveView] output in
            guard let self, let liveView, self.toolbar.inPlaceOCRActive else { return }
            liveView.applyPrecomputedAnalysis(output.liveAnalysisObject, highlightBlocks: false)
            if let qr = output.qrPayloads.first, output.preservedText.isEmpty {
                Self.presentBarcodeToast(qr)
                return
            }
            let text = output.initialClipboardText
            if !text.isEmpty {
                let count = text.count
                let msg: String
                if self.ocrAutoCopy {
                    ClipboardAndSave.copyText(text)
                    msg = "已识别 \(count) 字并复制 · 可直接在框内划词或点工具继续标注"
                } else {
                    msg = "已识别 \(count) 字 · 可直接在框内划词或按 ⌘C 复制"
                }
                ToastHUD.show(
                    message: msg,
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

    /// 选区锁定后静默探测二维码/条码，命中即弹出一键打开链接/复制码值提示（未命中零干扰）
    func scheduleSilentBarcodeScan(for rect: CGRect) {
        barcodeScanTask?.cancel()
        barcodeScanTask = nil
        guard !isRecordingMode, quickLaunchMode == .standard,
              rect.width >= 36, rect.height >= 36, rect.width <= 1400, rect.height <= 1400 else { return }
        let s = max(1.0, snapshot.scaleFactor)
        let pxRect = CGRect(
            x: max(0, round(rect.minX * s)),
            y: max(0, round(rect.minY * s)),
            width: max(1, round(rect.width * s)),
            height: max(1, round(rect.height * s))
        )
        guard let cropped = snapshot.cgImage.cropping(to: pxRect) else { return }
        barcodeScanTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self, !Task.isCancelled, self.selection == rect, !self.isDraggingSelectionBox else { return }
            let codes = await VisionTextExtractor.detectBarcodesOffMain(cgImage: cropped)
            guard !Task.isCancelled, self.selection == rect, let first = codes.first else { return }
            Self.presentBarcodeToast(first)
        }
    }

    static func presentBarcodeToast(_ payload: String) {
        let lower = payload.lowercased()
        let isURL = (lower.hasPrefix("http://") || lower.hasPrefix("https://")), url = isURL ? URL(string: payload) : nil
        let preview = payload.count > 44 ? String(payload.prefix(44)) + "…" : payload
        if let url {
            ToastHUD.show(message: "识别到二维码链接：\(preview)", actionTitle: "打开链接 ›") {
                ClipboardAndSave.copyText(payload)
                NSWorkspace.shared.open(url)
            }
        } else {
            ToastHUD.show(message: "识别到二维码/条码：\(preview)", actionTitle: "复制码值 ›") {
                ClipboardAndSave.copyText(payload)
                ToastHUD.show(message: "✓ 已复制二维码/条码内容")
            }
        }
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
