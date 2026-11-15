import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 贴图内容容器：承载实况文本图层、右上角悬停微操作胶囊（二次标注 / 拖出 PNG）与 `NSDraggingSource` 外部文件直投
final class PinContentView: NSView, NSDraggingSource {
    let liveTextView = LiveTextImageView(scaling: .scaleAxesIndependently)
    var onRequestAnnotate: (() -> Void)?
    var onRequestFileDrag: ((NSEvent) -> Void)?

    var isGhostMode: Bool = false {
        didSet { updateChromeState() }
    }
    var isAnnotating: Bool = false {
        didSet { updateChromeState() }
    }

    private var isMouseInside = false {
        didSet { updateChromeState() }
    }
    private let hoverBar = NSView()
    private let annotatePill = PinMicroButton(symbol: "pencil.tip", tip: "二次圈记标注贴图 (E)")
    private let dragOutPill = PinMicroButton(symbol: "arrow.up.forward.square", tip: "按住拖出为 PNG 文件 (或按住 ⌘ 拖拽贴图)")

    init(cgImage: CGImage, baseSize: NSSize) {
        super.init(frame: NSRect(origin: .zero, size: baseSize))
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.masksToBounds = true
        layer?.borderWidth = 1.0
        layer?.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor

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
        hoverBar.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.84).cgColor
        hoverBar.layer?.cornerRadius = 6
        hoverBar.layer?.borderWidth = 0.8
        hoverBar.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        hoverBar.isHidden = true

        annotatePill.frame = NSRect(x: 3, y: 2, width: 22, height: 22)
        dragOutPill.frame = NSRect(x: 27, y: 2, width: 22, height: 22)
        annotatePill.onMouseDown = { [weak self] _ in
            self?.onRequestAnnotate?()
        }
        dragOutPill.onMouseDown = { [weak self] event in
            self?.onRequestFileDrag?(event)
        }
        hoverBar.addSubview(annotatePill)
        hoverBar.addSubview(dragOutPill)
        addSubview(hoverBar)
        layoutHoverBar()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutHoverBar()
    }

    private func layoutHoverBar() {
        let w: CGFloat = 52
        let h: CGFloat = 26
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
        hoverBar.isHidden = !isMouseInside || isGhostMode || isAnnotating || bounds.width < 64 || bounds.height < 42
        if isAnnotating {
            layer?.borderWidth = 1.8
            layer?.borderColor = NSColor.controlAccentColor.cgColor
        } else if isGhostMode {
            layer?.borderWidth = 1.2
            layer?.borderColor = NSColor.systemCyan.withAlphaComponent(0.65).cgColor
        } else if isMouseInside {
            layer?.borderWidth = 1.2
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        } else {
            layer?.borderWidth = 1.0
            layer?.borderColor = NSColor.white.withAlphaComponent(0.45).cgColor
        }
    }

    // MARK: - NSDraggingSource (Direct PNG File Drop to WeChat / Feishu / Browser / Finder)

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

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }
}

/// 贴图右上角悬停微操作图标按钮
private final class PinMicroButton: NSView {
    let symbol: String
    var onMouseDown: ((NSEvent) -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }

    init(symbol: String, tip: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        self.toolTip = tip
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
        if hovered, let ctx = NSGraphicsContext.current?.cgContext {
            let p = CGPath(roundedRect: bounds, cornerWidth: 4, cornerHeight: 4, transform: nil)
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.18).cgColor)
            ctx.addPath(p)
            ctx.fillPath()
        }
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11.5, weight: .semibold)) else { return }
        let sz = img.size
        let r = NSRect(x: (bounds.width - sz.width) * 0.5, y: (bounds.height - sz.height) * 0.5, width: sz.width, height: sz.height)
        img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 0.95)
    }
}
