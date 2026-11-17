import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 贴图内容容器：承载实况文本图层、右上角清爽白底四联悬停微操作胶囊（圈记 / 识字翻译 / 拖出 PNG / 关闭）
final class PinContentView: NSView, NSDraggingSource {
    let liveTextView = LiveTextImageView(scaling: .scaleAxesIndependently)
    var onRequestAnnotate: (() -> Void)?
    var onRequestOCR: (() -> Void)?
    var onRequestClose: (() -> Void)?
    var onRequestFileDrag: ((NSEvent) -> Void)?

    var isGhostMode: Bool = false { didSet { updateChromeState() } }
    var isAnnotating: Bool = false { didSet { updateChromeState() } }
    private var isMouseInside = false { didSet { updateChromeState() } }

    private let hoverBar = NSView()
    private let annotatePill = PinMicroButton(symbol: "pencil.tip", tip: "二次圈记标注贴图 (E)")
    private let ocrPill = PinMicroButton(symbol: "text.viewfinder", tip: "提取文字与对照翻译 (T)")
    private let dragOutPill = PinMicroButton(symbol: "arrow.up.forward.square", tip: "按住直拖 PNG 文件到微信/飞书 (⌘+拖拽)")
    private let closePill = PinMicroButton(symbol: "xmark", tip: "关闭贴图 (Esc / 双击)", tint: MSnipUITheme.danger)

    init(cgImage: CGImage, baseSize: NSSize) {
        super.init(frame: NSRect(origin: .zero, size: baseSize))
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1.0
        layer?.borderColor = MSnipUITheme.borderStrong.cgColor

        liveTextView.frame = bounds
        liveTextView.autoresizingMask = [.width, .height]
        liveTextView.configure(cgImage: cgImage, logicalSize: baseSize)
        addSubview(liveTextView)

        setupHoverBar()
        updateTrackingAreas()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupHoverBar() {
        hoverBar.wantsLayer = true
        hoverBar.layer?.backgroundColor = MSnipUITheme.cardBg.cgColor
        hoverBar.layer?.cornerRadius = 7.5
        hoverBar.layer?.borderWidth = 1.0
        hoverBar.layer?.borderColor = MSnipUITheme.borderStrong.cgColor
        hoverBar.layer?.shadowColor = NSColor.black.cgColor
        hoverBar.layer?.shadowOpacity = 0.14
        hoverBar.layer?.shadowRadius = 6
        hoverBar.layer?.shadowOffset = CGSize(width: 0, height: -1)
        hoverBar.isHidden = true

        let buttons = [annotatePill, ocrPill, dragOutPill, closePill]
        for (i, b) in buttons.enumerated() {
            b.frame = NSRect(x: 4 + CGFloat(i) * 25, y: 3, width: 23, height: 22)
            hoverBar.addSubview(b)
        }
        annotatePill.onMouseDown = { [weak self] _ in self?.onRequestAnnotate?() }
        ocrPill.onMouseDown = { [weak self] _ in self?.onRequestOCR?() }
        dragOutPill.onMouseDown = { [weak self] ev in self?.onRequestFileDrag?(ev) }
        closePill.onMouseDown = { [weak self] _ in self?.onRequestClose?() }

        addSubview(hoverBar)
        layoutHoverBar()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutHoverBar()
    }

    private func layoutHoverBar() {
        let w: CGFloat = 106
        let h: CGFloat = 28
        hoverBar.frame = NSRect(x: max(4, bounds.width - w - 6), y: max(4, bounds.height - h - 6), width: w, height: h)
    }

    func hitHoverControl(atWindowPoint windowPt: NSPoint) -> Bool {
        guard !hoverBar.isHidden else { return false }
        let local = convert(windowPt, from: nil)
        return hoverBar.frame.contains(local)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { isMouseInside = true }
    override func mouseExited(with event: NSEvent) { isMouseInside = false }

    private func updateChromeState() {
        hoverBar.isHidden = !isMouseInside || isGhostMode || isAnnotating || bounds.width < 116 || bounds.height < 44
        if isAnnotating {
            layer?.borderWidth = 1.8
            layer?.borderColor = MSnipUITheme.accent.cgColor
        } else if isGhostMode {
            layer?.borderWidth = 1.2
            layer?.borderColor = MSnipUITheme.accent.withAlphaComponent(0.55).cgColor
        } else if isMouseInside {
            layer?.borderWidth = 1.4
            layer?.borderColor = MSnipUITheme.accent.withAlphaComponent(0.85).cgColor
        } else {
            layer?.borderWidth = 1.0
            layer?.borderColor = MSnipUITheme.borderStrong.cgColor
        }
    }

    func startPNGFileDrag(with event: NSEvent, cgImage: CGImage, scaleFactor: CGFloat) {
        guard let fileURL = ClipboardAndSave.writeTempPNGFile(cgImage: cgImage, scaleFactor: scaleFactor) else {
            NSSound.beep()
            return
        }
        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        let aspect = CGFloat(cgImage.width) / max(1.0, CGFloat(cgImage.height))
        let maxSide: CGFloat = 150
        let thumbSize = aspect >= 1.0
            ? NSSize(width: maxSide, height: max(32, maxSide / aspect))
            : NSSize(width: max(32, maxSide * aspect), height: maxSide)
        let preview = NSImage(cgImage: cgImage, size: thumbSize)
        let localPt = convert(event.locationInWindow, from: nil)
        let dragRect = NSRect(
            x: localPt.x - thumbSize.width * 0.5,
            y: localPt.y - thumbSize.height * 0.5,
            width: thumbSize.width,
            height: thumbSize.height
        )
        item.setDraggingFrame(dragRect, contents: preview)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}

/// 贴图右上角清爽浅色微操作图标按钮
private final class PinMicroButton: NSView {
    let symbol: String
    let tint: NSColor
    var onMouseDown: ((NSEvent) -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    init(symbol: String, tip: String, tint: NSColor = MSnipUITheme.inkPrimary) {
        self.symbol = symbol
        self.tint = tint
        super.init(frame: .zero)
        self.toolTip = tip
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { onMouseDown?(event) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if hovered {
            ToolbarView.drawButtonBg(ctx: ctx, rect: bounds, active: false, hovered: true)
        }
        ToolbarView.drawSymbol(symbol, in: bounds, alpha: 0.94, tint: tint)
    }
}
