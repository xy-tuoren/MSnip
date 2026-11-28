import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 拼图工作室高清大图查看器（支持滚轮自由缩放 25%–400%、放大拖拽平移、双击切换 1:1 原图、←/→ 翻页、Esc / 空白单击关闭）
@MainActor
final class CollageImageLightbox: NSObject, NSWindowDelegate {
    struct Entry {
        let title: String
        let cgImage: CGImage
        let scaleFactor: CGFloat
    }

    var onCopyImage: ((CGImage, CGFloat) -> Void)?

    private var panel: CollageLightboxWindow?
    private var contentView: CollageLightboxContentView?
    private var entries: [Entry] = []
    private var currentIndex: Int = 0

    func show(entries: [Entry], startIndex: Int = 0, showsCheckerboard: Bool = false) {
        guard !entries.isEmpty else { return }
        self.entries = entries
        self.currentIndex = min(max(0, startIndex), entries.count - 1)
        ensurePanelBuilt()
        guard let panel, let contentView else { return }

        let mouse = NSEvent.mouseLocation
        guard let scr = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let vf = scr.visibleFrame
        let w = round(min(1380, vf.width * 0.88))
        let h = round(min(900, vf.height * 0.86))
        panel.setFrame(NSRect(x: round(vf.midX - w * 0.5), y: round(vf.midY - h * 0.5), width: w, height: h), display: false)

        contentView.showsCheckerboard = showsCheckerboard
        loadCurrentEntry()
        panel.makeKeyAndOrderFront(nil)
    }

    func refreshAppearance() { contentView?.needsDisplay = true }

    func dismiss() {
        panel?.orderOut(nil)
        entries.removeAll()
        contentView?.clearImage()
    }

    func windowWillClose(_ notification: Notification) {
        entries.removeAll()
        contentView?.clearImage()
    }

    private func ensurePanelBuilt() {
        guard panel == nil else { return }
        let p = CollageLightboxWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        p.delegate = self
        p.onKeyAction = { [weak self] key in self?.handleKey(key) }

        let cv = CollageLightboxContentView(frame: p.contentLayoutRect)
        cv.autoresizingMask = [.width, .height]
        cv.onClose = { [weak self] in self?.dismiss() }
        cv.onPrev = { [weak self] in self?.step(-1) }
        cv.onNext = { [weak self] in self?.step(1) }
        cv.onCopy = { [weak self] in
            guard let self, self.entries.indices.contains(self.currentIndex) else { return }
            let cur = self.entries[self.currentIndex]
            self.onCopyImage?(cur.cgImage, cur.scaleFactor)
        }
        p.contentView = cv
        panel = p
        contentView = cv
    }

    private func loadCurrentEntry() {
        guard entries.indices.contains(currentIndex), let contentView else { return }
        let e = entries[currentIndex]
        let prefix = entries.count > 1 ? "[\(currentIndex + 1)/\(entries.count)] " : ""
        contentView.configure(
            cgImage: e.cgImage,
            title: "\(prefix)\(e.title) · \(e.cgImage.width) × \(e.cgImage.height) px",
            canStepPrev: currentIndex > 0,
            canStepNext: currentIndex < entries.count - 1
        )
    }

    private func step(_ delta: Int) {
        let next = currentIndex + delta
        guard entries.indices.contains(next) else { return }
        currentIndex = next
        loadCurrentEntry()
    }

    private func handleKey(_ action: CollageLightboxWindow.KeyAction) {
        switch action {
        case .close:     dismiss()
        case .prev:      step(-1)
        case .next:      step(1)
        case .fit:       contentView?.resetToFit()
        case .actual100: contentView?.zoomToActualPixels()
        case .copy:
            guard entries.indices.contains(currentIndex) else { return }
            let cur = entries[currentIndex]
            onCopyImage?(cur.cgImage, cur.scaleFactor)
        }
    }
}

private final class CollageLightboxContentView: NSView {
    var showsCheckerboard = false { didSet { needsDisplay = true } }
    var onClose: (() -> Void)?
    var onPrev: (() -> Void)?
    var onNext: (() -> Void)?
    var onCopy: (() -> Void)?

    private var cgImage: CGImage?
    private var titleText: String = ""
    private var canStepPrev = false
    private var canStepNext = false

    private var zoom: CGFloat = 1.0
    private var isFitMode = true
    private var panOffset: CGPoint = .zero
    private var dragStart: CGPoint?
    private var panStart: CGPoint = .zero
    private var hoveredTag: Int? { didSet { if oldValue != hoveredTag { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    func configure(cgImage: CGImage, title: String, canStepPrev: Bool, canStepNext: Bool) {
        self.cgImage = cgImage
        self.titleText = title
        self.canStepPrev = canStepPrev
        self.canStepNext = canStepNext
        resetToFit()
    }

    func clearImage() { cgImage = nil; needsDisplay = true }

    func resetToFit() {
        isFitMode = true
        panOffset = .zero
        zoom = fitScale()
        needsDisplay = true
    }

    func zoomToActualPixels() {
        isFitMode = false
        let scrScale = max(1.0, window?.backingScaleFactor ?? 2.0)
        zoom = 1.0 / scrScale
        panOffset = .zero
        needsDisplay = true
    }

    private func fitScale() -> CGFloat {
        guard let cg = cgImage else { return 1.0 }
        let availW = max(80, bounds.width - 110)
        let availH = max(80, bounds.height - 116)
        return min(1.0, min(availW / max(1, CGFloat(cg.width)), availH / max(1, CGFloat(cg.height))))
    }

    private func imageDrawRect() -> CGRect {
        guard let cg = cgImage else { return .zero }
        let s = isFitMode ? fitScale() : zoom
        let dw = round(CGFloat(cg.width) * s), dh = round(CGFloat(cg.height) * s)
        return CGRect(x: round(bounds.midX - dw * 0.5 + panOffset.x), y: round(bounds.midY + 14 - dh * 0.5 + panOffset.y), width: dw, height: dh)
    }

    private func actionButtons() -> [(tag: Int, rect: CGRect, title: String)] {
        let y: CGFloat = 14, h: CGFloat = 26
        var list: [(Int, CGRect, String)] = [
            (1, CGRect(x: bounds.width - 216, y: y, width: 52, height: h), L("适应")),
            (2, CGRect(x: bounds.width - 158, y: y, width: 42, height: h), "1:1"),
            (3, CGRect(x: bounds.width - 110, y: y, width: 52, height: h), L("复制")),
            (4, CGRect(x: bounds.width - 52,  y: y, width: 34, height: h), "✕")
        ]
        if canStepPrev { list.append((5, CGRect(x: 16, y: round(bounds.midY - 22), width: 34, height: 44), "‹")) }
        if canStepNext { list.append((6, CGRect(x: bounds.width - 50, y: round(bounds.midY - 22), width: 34, height: 44), "›")) }
        return list
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hoveredTag = actionButtons().first(where: { $0.rect.contains(p) })?.tag
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = actionButtons().first(where: { $0.rect.contains(p) }) {
            switch hit.tag {
            case 1: resetToFit()
            case 2: zoomToActualPixels()
            case 3: onCopy?()
            case 4: onClose?()
            case 5: onPrev?()
            case 6: onNext?()
            default: break
            }
            return
        }
        let imgR = imageDrawRect()
        if !imgR.contains(p) { onClose?(); return }
        if event.clickCount == 2 {
            if isFitMode { zoomToActualPixels() } else { resetToFit() }
            return
        }
        dragStart = p; panStart = panOffset
    }

    override func mouseDragged(with event: NSEvent) {
        guard let st = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        panOffset = CGPoint(x: panStart.x + (p.x - st.x), y: panStart.y + (p.y - st.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) { dragStart = nil }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY
        guard abs(dy) > 0.01 else { return }
        let base = isFitMode ? fitScale() : zoom
        isFitMode = false
        let step: CGFloat = event.hasPreciseScrollingDeltas ? dy * 0.006 : (dy > 0 ? 0.12 : -0.12)
        zoom = min(4.0, max(0.08, base * (1.0 + step)))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let isDark = GeekTheme.isDark
        let shell = CGPath(roundedRect: bounds, cornerWidth: 16, cornerHeight: 16, transform: nil)
        let shellFill = isDark ? NSColor(srgbRed: 0.07, green: 0.08, blue: 0.10, alpha: 0.94) : NSColor(srgbRed: 0.96, green: 0.965, blue: 0.98, alpha: 0.96)
        let shellStroke = isDark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.12)
        let fgColor = isDark ? NSColor.white.withAlphaComponent(0.88) : NSColor(srgbRed: 0.10, green: 0.13, blue: 0.18, alpha: 0.92)
        ctx.saveGState()
        ctx.setFillColor(shellFill.cgColor); ctx.addPath(shell); ctx.fillPath()
        ctx.setStrokeColor(shellStroke.cgColor); ctx.setLineWidth(1.0); ctx.addPath(shell); ctx.strokePath()
        ctx.restoreGState()

        if let cg = cgImage {
            let dst = imageDrawRect()
            ctx.saveGState()
            let clip = CGPath(roundedRect: dst, cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 24, color: NSColor.black.withAlphaComponent(isDark ? 0.55 : 0.18).cgColor)
            ctx.setFillColor(NSColor.white.cgColor); ctx.addPath(clip); ctx.fillPath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(clip); ctx.clip()
            if showsCheckerboard {
                let c1 = (isDark ? NSColor(white: 0.24, alpha: 1) : NSColor(white: 0.96, alpha: 1)).cgColor
                let c2 = (isDark ? NSColor(white: 0.18, alpha: 1) : NSColor(white: 0.87, alpha: 1)).cgColor
                ctx.setFillColor(c1); ctx.fill(dst); ctx.setFillColor(c2)
                var y = dst.minY, r = 0
                while y < dst.maxY {
                    var x = dst.minX + (r % 2 == 0 ? 0 : 12)
                    while x < dst.maxX { ctx.fill(CGRect(x: x, y: y, width: 12, height: 12)); x += 24 }
                    y += 12; r += 1
                }
            }
            NSImage(cgImage: cg, size: dst.size).draw(in: dst, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
            ctx.restoreGState()
        }

        // 顶部标题与缩放比例
        let pct = Int(((isFitMode ? fitScale() : zoom) * max(1.0, window?.backingScaleFactor ?? 2.0) * 100.0).rounded())
        let header = L("%@  ·  %@%（滚轮缩放 · 拖拽平移 · 双击 1:1 · Esc 关闭）", titleText, pct)
        GeekTheme.drawText(header, in: CGRect(x: 18, y: 14, width: max(120, bounds.width - 246), height: 26),
                           font: .monospacedDigitSystemFont(ofSize: 12.0, weight: .medium), color: fgColor)

        for b in actionButtons() {
            let hov = (hoveredTag == b.tag)
            let p = CGPath(roundedRect: b.rect, cornerWidth: 7, cornerHeight: 7, transform: nil)
            let btnFill = isDark ? NSColor.white.withAlphaComponent(hov ? 0.24 : 0.12) : NSColor.black.withAlphaComponent(hov ? 0.12 : 0.06)
            ctx.setFillColor(btnFill.cgColor); ctx.addPath(p); ctx.fillPath()
            GeekTheme.drawText(b.title, in: b.rect, font: .systemFont(ofSize: b.tag >= 5 ? 18 : 11.5, weight: .semibold), color: fgColor, align: .center)
        }
    }
}
