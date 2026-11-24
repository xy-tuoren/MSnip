import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 贴图画面纯净化容器（画面内部 100% 零悬浮按钮遮挡，直接支持原图划词复制与 `⌘+拖拽` 导出文件）
final class PinContentView: NSView, NSDraggingSource {
    let liveTextView = LiveTextImageView(scaling: .scaleAxesIndependently)
    var onHoverChanged: ((Bool) -> Void)?

    var isGhostMode: Bool = false { didSet { updateBorderStyle() } }
    var isAnnotating: Bool = false { didSet { updateBorderStyle() } }
    var isSelectedKey: Bool = false { didSet { updateBorderStyle() } }
    private var isMouseInside = false { didSet { updateBorderStyle() } }

    init(cgImage: CGImage, baseSize: NSSize) {
        super.init(frame: NSRect(origin: .zero, size: baseSize))
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.masksToBounds = false
        layer?.borderWidth = 0

        liveTextView.frame = bounds
        liveTextView.autoresizingMask = [.width, .height]
        liveTextView.configure(cgImage: cgImage, logicalSize: baseSize)
        addSubview(liveTextView)
        updateTrackingAreas()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

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

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        onHoverChanged?(false)
    }

    private func updateBorderStyle() {
        if isAnnotating {
            layer?.borderWidth = 1.8
            layer?.borderColor = MSnipUITheme.accent.cgColor
        } else if isGhostMode {
            layer?.borderWidth = 1.2
            layer?.borderColor = MSnipUITheme.accent.withAlphaComponent(0.55).cgColor
        } else if isSelectedKey || isMouseInside {
            layer?.borderWidth = 1.0
            layer?.borderColor = MSnipUITheme.accent.withAlphaComponent(isSelectedKey ? 0.90 : 0.72).cgColor
        } else {
            layer?.borderWidth = 0
            layer?.borderColor = nil
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

/// 贴图外侧顶部独立悬浮控制条窗口（零遮挡贴图内部文字，贴顶时自动翻至贴图下方）
final class PinHoverBarPanel: NSPanel {
    enum Action {
        case annotate
        case ocr
        case translate
        case copy
        case close
    }

    let barView = PinHoverBarView()

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: PinHoverBarView.barSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.animationBehavior = .none
        self.isFloatingPanel = true
        self.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        self.becomesKeyOnlyIfNeeded = true
        self.hidesOnDeactivate = false
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.contentView = barView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func reposition(anchoringTo pinFrame: NSRect, on screen: NSScreen?) {
        let scr = screen ?? NSScreen.main ?? NSScreen.screens.first
        let vf = scr?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let sz = PinHoverBarView.barSize
        let x = min(max(vf.minX + 4, round(pinFrame.maxX - sz.width)), vf.maxX - sz.width - 4)
        let aboveY = round(pinFrame.maxY + 5)
        let belowY = round(pinFrame.minY - sz.height - 5)
        let y = (aboveY + sz.height <= vf.maxY - 2) ? aboveY : max(vf.minY + 4, belowY)
        setFrame(NSRect(x: x, y: y, width: sz.width, height: sz.height), display: true)
    }
}

/// 贴图外侧悬浮微操作胶囊视图：`[ ✥ 拖动 | ✎ 标注 | 识字 | 翻译 | 复制 | ✕ 关闭 ]`
final class PinHoverBarView: NSView {
    static let barSize = NSSize(width: 170, height: 28)

    var onAction: ((PinHoverBarPanel.Action) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onDragStart: (() -> Void)?
    var onDragMove: (() -> Void)?
    var onDragEnd: (() -> Void)?

    private struct ActionSlot {
        let rect: CGRect
        let symbol: String
        let tip: String
        let tint: NSColor
        let action: PinHoverBarPanel.Action?
    }

    private let slots: [ActionSlot] = [
        ActionSlot(
            rect: CGRect(x: 4, y: 2, width: 28, height: 24),
            symbol: "arrow.up.and.down.and.arrow.left.and.right",
            tip: "按住拖动整张贴图（满屏文字无空白处时可直接拖这里）",
            tint: MSnipUITheme.accent,
            action: nil
        ),
        ActionSlot(
            rect: CGRect(x: 38, y: 2, width: 25, height: 24),
            symbol: "pencil.tip",
            tip: "二次圈记标注贴图 (E)",
            tint: MSnipUITheme.inkPrimary,
            action: .annotate
        ),
        ActionSlot(
            rect: CGRect(x: 64, y: 2, width: 25, height: 24),
            symbol: "text.viewfinder",
            tip: "提取图中文字 (T)",
            tint: MSnipUITheme.inkPrimary,
            action: .ocr
        ),
        ActionSlot(
            rect: CGRect(x: 90, y: 2, width: 25, height: 24),
            symbol: "character.bubble",
            tip: "翻译图中文字 (Y)",
            tint: MSnipUITheme.inkPrimary,
            action: .translate
        ),
        ActionSlot(
            rect: CGRect(x: 116, y: 2, width: 25, height: 24),
            symbol: "doc.on.doc",
            tip: "复制贴图图像 (⌘C)",
            tint: MSnipUITheme.inkPrimary,
            action: .copy
        ),
        ActionSlot(
            rect: CGRect(x: 142, y: 2, width: 24, height: 24),
            symbol: "xmark",
            tip: "关闭贴图 (Esc / 双击空白处)",
            tint: MSnipUITheme.danger,
            action: .close
        )
    ]

    private var hoveredIdx: Int? { didSet { if oldValue != hoveredIdx { needsDisplay = true } } }
    private var isDraggingPin = false { didSet { if oldValue != isDraggingPin { needsDisplay = true } } }
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect = NSRect(origin: .zero, size: PinHoverBarView.barSize)) {
        super.init(frame: frameRect)
        updateTrackingAreas()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
        syncHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        syncHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIdx = nil
        toolTip = nil
        if !isDraggingPin { NSCursor.arrow.set() }
        onHoverChanged?(false)
    }

    private func syncHover(at pt: CGPoint) {
        let idx = slots.firstIndex(where: { $0.rect.contains(pt) })
        hoveredIdx = idx
        toolTip = idx.map { slots[$0].tip }
        if idx == 0 {
            NSCursor.openHand.set()
        } else if idx != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.openHand.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let hit = slots.first(where: { $0.rect.contains(pt) }), let action = hit.action {
            onAction?(action)
            return
        }
        isDraggingPin = true
        NSCursor.closedHand.set()
        onDragStart?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingPin else { return }
        onDragMove?()
    }

    override func mouseUp(with event: NSEvent) {
        guard isDraggingPin else { return }
        isDraggingPin = false
        NSCursor.openHand.set()
        onDragEnd?()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        MSnipUITheme.drawPorcelainBar(ctx: ctx, bounds: bounds, radius: 8.5)
        ctx.setFillColor(MSnipUITheme.borderHairline.cgColor)
        ctx.fill(CGRect(x: 34.5, y: 6, width: 1, height: bounds.height - 12))

        for (i, s) in slots.enumerated() {
            let hov = (hoveredIdx == i) || (i == 0 && isDraggingPin)
            ToolbarView.drawButtonBg(ctx: ctx, rect: s.rect, active: i == 0 && isDraggingPin, hovered: hov)
            ToolbarView.drawSymbol(s.symbol, in: s.rect, alpha: 0.94, tint: s.tint)
        }
    }
}
