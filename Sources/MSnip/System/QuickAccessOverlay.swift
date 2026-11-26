import AppKit
import CoreGraphics
import Foundation
import MSnipCore
import QuartzCore

/// 截后 / 录后左下角悬浮速览卡控制器：
/// - 仅持有一张 ≤ 480px 缩略图与历史条目 ID / 文件路径，绝不驻留 5K 原图；
/// - 支持鼠标悬停暂停倒计时、直接拖拽 PNG/GIF/MP4 文件投递，以及一键二次标注 / 贴图 / OCR / 访达定位。
@MainActor
final class QuickAccessOverlayController {
    private enum Payload {
        case screenshot(entryID: UUID, scale: CGFloat, savedURL: URL?)
        case mediaFile(url: URL, format: RecordingFormat)
    }

    var onResolveHistoryCGImage: ((UUID) -> (CGImage, CGFloat)?)?
    var onResolveHistoryFileURL: ((UUID) -> URL?)?
    var onAnnotateImage: ((CGImage, CGFloat) -> Void)?
    var onPinImage: ((CGImage, CGFloat) -> Void)?
    var onOCRImage: ((CGImage, CGFloat) -> Void)?
    var onQuickSaveImage: ((CGImage, CGFloat) -> Void)?

    private var activePanel: ToastPanel?
    private var activeCard: QuickAccessCardView?
    private var activePayload: Payload?
    private var activeTargetFrame: NSRect = .zero
    private var isHovering = false
    private var isDragging = false
    private var dismissWork: DispatchWorkItem?
    nonisolated(unsafe) private var appearanceObserver: NSObjectProtocol?

    init() {
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: .msnipAppearanceDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.activeCard?.needsDisplay = true }
        }
    }

    deinit {
        if let obs = appearanceObserver { NotificationCenter.default.removeObserver(obs) }
    }

    func presentScreenshot(
        entryID: UUID,
        sourceImage: CGImage,
        scale: CGFloat,
        savedURL: URL? = nil,
        statusPrefix: String = "已复制"
    ) {
        let thumb = makeThumbCG(from: sourceImage, maxSide: 480)
        let badge = "\(statusPrefix) · \(sourceImage.width)×\(sourceImage.height)"
        let payload = Payload.screenshot(entryID: entryID, scale: scale, savedURL: savedURL)
        showCard(thumbnail: thumb, badge: badge, isMediaFile: false, hasSavedURL: savedURL != nil, payload: payload)
    }

    func presentMediaFile(url: URL, format: RecordingFormat, statusPrefix: String = "已完成") {
        let kb = max(1, ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) / 1024)
        let sizeText = kb >= 1024 ? String(format: "%.1f MB", Double(kb) / 1024.0) : "\(kb) KB"
        let badge = "\(format.badgeTitle) \(statusPrefix) · \(sizeText)"
        let payload = Payload.mediaFile(url: url, format: format)
        let cached = MediaThumbnailLoader.cachedThumbnail(for: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        showCard(thumbnail: cached, badge: badge, isMediaFile: true, hasSavedURL: true, payload: payload)
        if cached == nil {
            MediaThumbnailLoader.loadThumbnail(for: url) { [weak self] img in
                guard let self, case .mediaFile(let curURL, _) = self.activePayload, curURL == url,
                      let cg = img?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                self.activeCard?.updateThumbnail(cg)
            }
        }
    }

    func dismissImmediate() {
        dismissWork?.cancel(); dismissWork = nil
        isHovering = false; isDragging = false
        activePanel?.orderOut(nil)
        activePanel?.contentView = nil
        activePanel = nil; activeCard = nil; activePayload = nil
    }

    private func showCard(thumbnail: CGImage?, badge: String, isMediaFile: Bool, hasSavedURL: Bool, payload: Payload) {
        dismissImmediate()
        activePayload = payload

        let card = QuickAccessCardView(thumbnail: thumbnail, badgeText: badge, isMediaFile: isMediaFile, hasSavedURL: hasSavedURL)
        card.onClose = { [weak self] in self?.dismissImmediate() }
        card.onHoverChanged = { [weak self] hovering in self?.handleHoverChanged(hovering) }
        card.onDraggingChanged = { [weak self] dragging in self?.handleDraggingChanged(dragging) }
        card.onClickThumb = { [weak self] in self?.handleThumbClick() }
        card.onAction = { [weak self] act in self?.handleAction(act) }
        card.dragFileURLProvider = { [weak self] in self?.resolveDragURL() }

        let probe = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(probe) }) ?? NSScreen.main ?? NSScreen.screens.first
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let sz = QuickAccessCardView.panelSize
        let target = NSRect(x: round(vf.minX + 14), y: round(vf.minY + 14), width: sz.width, height: sz.height)
        activeTargetFrame = target

        let panel = ToastPanel(frame: target.offsetBy(dx: -24, dy: 0), interactive: true)
        panel.contentView = card
        panel.alphaValue = 0.0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.30, 1.0)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1.0
        }
        activePanel = panel
        activeCard = card
        scheduleAutoDismiss(seconds: 6.0, for: panel, card: card)
    }

    private func handleHoverChanged(_ hovering: Bool) {
        isHovering = hovering
        syncCountdownForInteraction()
    }

    private func handleDraggingChanged(_ dragging: Bool) {
        isDragging = dragging
        syncCountdownForInteraction()
    }

    private func syncCountdownForInteraction() {
        guard let panel = activePanel, let card = activeCard else { return }
        if isHovering || isDragging {
            dismissWork?.cancel(); dismissWork = nil
            panel.setFrame(activeTargetFrame, display: true)
            panel.alphaValue = 1.0
            card.resetProgressFull()
        } else {
            scheduleAutoDismiss(seconds: 3.2, for: panel, card: card)
        }
    }

    private func scheduleAutoDismiss(seconds: TimeInterval, for panel: ToastPanel, card: QuickAccessCardView) {
        dismissWork?.cancel(); dismissWork = nil
        guard !isHovering, !isDragging else { card.resetProgressFull(); return }
        card.startProgressAnimation(duration: seconds)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let current = self.activePanel, current === panel,
                      !self.isHovering, !self.isDragging else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.20
                    current.animator().alphaValue = 0.0
                    current.animator().setFrame(self.activeTargetFrame.offsetBy(dx: -16, dy: 0), display: true)
                }, completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.activePanel === panel, !self.isHovering, !self.isDragging else { return }
                        self.dismissImmediate()
                    }
                })
            }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func handleThumbClick() {
        guard let payload = activePayload else { return }
        switch payload {
        case .screenshot(let id, _, _):
            guard let (img, scale) = onResolveHistoryCGImage?(id) else { return }
            ClipboardAndSave.copyToClipboard(cgImage: img, scaleFactor: scale)
            ToastHUD.show(message: "✓ 已再次复制截图到剪贴板")
        case .mediaFile(let url, let fmt):
            let pb = NSPasteboard.general; pb.clearContents(); pb.writeObjects([url as NSURL])
            ToastHUD.show(message: "✓ 已复制 \(fmt.badgeTitle) 文件到剪贴板")
        }
    }

    private func resolveDragURL() -> URL? {
        guard let payload = activePayload else { return nil }
        switch payload {
        case .screenshot(let id, _, let savedURL):
            if let savedURL, FileManager.default.fileExists(atPath: savedURL.path) { return savedURL }
            return onResolveHistoryFileURL?(id)
        case .mediaFile(let url, _):
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    private func handleAction(_ action: QuickAccessCardView.Action) {
        guard let payload = activePayload else { return }
        dismissImmediate()
        switch payload {
        case .screenshot(let id, let fallbackScale, let savedURL):
            if action == .saveOrReveal, let savedURL {
                ClipboardAndSave.revealInFinder(savedURL); return
            }
            guard let (img, scale) = onResolveHistoryCGImage?(id) else { NSSound.beep(); return }
            let s = max(1.0, scale > 0 ? scale : fallbackScale)
            switch action {
            case .annotate:     onAnnotateImage?(img, s)
            case .pin:          onPinImage?(img, s)
            case .ocr:          onOCRImage?(img, s)
            case .saveOrReveal: onQuickSaveImage?(img, s)
            case .copyFile, .revealFile: break
            }
        case .mediaFile(let url, let fmt):
            switch action {
            case .revealFile: ClipboardAndSave.revealInFinder(url)
            case .copyFile:
                let pb = NSPasteboard.general; pb.clearContents(); pb.writeObjects([url as NSURL])
                ToastHUD.show(message: "✓ 已复制 \(fmt.badgeTitle) 文件")
            default: break
            }
        }
    }

    private func makeThumbCG(from src: CGImage, maxSide: Int) -> CGImage {
        let w = src.width, h = src.height
        let longest = max(w, h)
        guard longest > maxSide else { return ImageTransform.detachedCopy(src) }
        let ratio = CGFloat(maxSide) / CGFloat(longest)
        let nw = max(2, Int(round(CGFloat(w) * ratio))), nh = max(2, Int(round(CGFloat(h) * ratio)))
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: nw * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return ImageTransform.detachedCopy(src)
        }
        ctx.interpolationQuality = .high
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage() ?? ImageTransform.detachedCopy(src)
    }
}

// MARK: - 悬浮速览卡片自绘与拖拽视图

/// 截后 / 录后左下角悬浮速览卡视图（支持直接拖拽文件到聊天窗/桌面、悬停暂停倒计时、GPU 零 CPU 进度条与一键标注/贴图/识字/访达）
private final class QuickAccessCardView: NSView, NSDraggingSource {
    enum Action: Int { case annotate = 0, pin = 1, ocr = 2, saveOrReveal = 3, copyFile = 4, revealFile = 5 }

    static let shadowPad: CGFloat = 16
    static let cardSize = NSSize(width: 248, height: 158)
    static let panelSize = NSSize(width: cardSize.width + shadowPad * 2, height: cardSize.height + shadowPad * 2)

    private var thumbnail: CGImage?
    private let badgeText: String
    private let isMediaFile: Bool
    private let hasSavedURL: Bool
    private let actionButtons: [(action: Action, title: String, symbol: String)]

    var onAction: ((Action) -> Void)?
    var onClickThumb: (() -> Void)?
    var onClose: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onDraggingChanged: ((Bool) -> Void)?
    var dragFileURLProvider: (() -> URL?)?

    private var hoveringCard = false
    private var hoveredActionIdx: Int? { didSet { if oldValue != hoveredActionIdx { needsDisplay = true } } }
    private var hoveredClose = false { didSet { if oldValue != hoveredClose { needsDisplay = true } } }
    private var hoveredThumb = false { didSet { if oldValue != hoveredThumb { needsDisplay = true } } }
    private var dragStartPoint: NSPoint?

    private let progressTrack = CALayer()
    private let progressFill = CALayer()

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(thumbnail: CGImage?, badgeText: String, isMediaFile: Bool, hasSavedURL: Bool) {
        self.thumbnail = thumbnail
        self.badgeText = badgeText
        self.isMediaFile = isMediaFile
        self.hasSavedURL = hasSavedURL
        if isMediaFile {
            self.actionButtons = [
                (.revealFile, "在访达中显示", "folder"),
                (.copyFile, "复制文件", "doc.on.doc")
            ]
        } else {
            self.actionButtons = [
                (.annotate, "标注", "pencil"),
                (.pin, "贴图", "pin"),
                (.ocr, "识字", "text.viewfinder"),
                (.saveOrReveal, hasSavedURL ? "访达" : "保存", hasSavedURL ? "folder" : "square.and.arrow.down")
            ]
        }
        super.init(frame: NSRect(origin: .zero, size: Self.panelSize))
        wantsLayer = true
        toolTip = isMediaFile ? "拖拽缩略图直接发送录屏文件" : "拖拽缩略图直接发送图片 · 点击复制"
        setupProgressLayers()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func updateThumbnail(_ cg: CGImage?) {
        self.thumbnail = cg
        needsDisplay = true
    }

    private func cardRect() -> CGRect {
        CGRect(x: Self.shadowPad, y: Self.shadowPad, width: Self.cardSize.width, height: Self.cardSize.height)
    }

    private func thumbRect() -> CGRect {
        let c = cardRect()
        return CGRect(x: c.minX + 7, y: c.minY + 7, width: c.width - 14, height: 102)
    }

    private func closeRect() -> CGRect {
        let t = thumbRect()
        return CGRect(x: t.maxX - 24, y: t.minY + 5, width: 19, height: 19)
    }

    private func actionRects() -> [CGRect] {
        let c = cardRect()
        let gap: CGFloat = 5
        let count = CGFloat(actionButtons.count)
        let totalW = c.width - 14
        let btnW = floor((totalW - gap * max(0, count - 1)) / max(1, count))
        let y = c.maxY - 40
        return (0..<actionButtons.count).map { i in
            CGRect(x: c.minX + 7 + CGFloat(i) * (btnW + gap), y: y, width: btnW, height: 30)
        }
    }

    private func setupProgressLayers() {
        let c = cardRect()
        progressTrack.frame = CGRect(x: c.minX + 10, y: c.maxY - 4.5, width: c.width - 20, height: 2.5)
        progressTrack.cornerRadius = 1.25; progressTrack.masksToBounds = true
        progressFill.anchorPoint = CGPoint(x: 0, y: 0.5)
        progressFill.frame = CGRect(x: 0, y: 0, width: progressTrack.bounds.width, height: 2.5)
        progressFill.cornerRadius = 1.25
        progressTrack.addSublayer(progressFill)
        layer?.addSublayer(progressTrack)
        syncProgressColors()
    }

    func syncProgressColors() {
        let isDark = GeekTheme.isDark
        progressTrack.backgroundColor = (isDark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.08)).cgColor
        progressFill.backgroundColor = GeekTheme.accent.withAlphaComponent(0.85).cgColor
    }

    func startProgressAnimation(duration: TimeInterval) {
        progressFill.removeAllAnimations()
        let anim = CABasicAnimation(keyPath: "transform.scale.x")
        anim.fromValue = 1.0; anim.toValue = 0.0; anim.duration = duration
        anim.fillMode = .forwards; anim.isRemovedOnCompletion = false
        progressFill.add(anim, forKey: "countdown")
    }

    func resetProgressFull() {
        progressFill.removeAllAnimations()
        progressFill.transform = CATransform3DIdentity
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: cardRect(), options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hoveringCard = true; onHoverChanged?(true)
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoveringCard = false; hoveredActionIdx = nil; hoveredClose = false; hoveredThumb = false
        onHoverChanged?(false)
    }

    private func updateHover(at p: NSPoint) {
        hoveredClose = closeRect().contains(p)
        hoveredActionIdx = hoveredClose ? nil : actionRects().firstIndex(where: { $0.contains(p) })
        hoveredThumb = !hoveredClose && hoveredActionIdx == nil && thumbRect().contains(p)
    }

    override func resetCursorRects() {
        let tr = thumbRect(), cr = closeRect()
        let leftBand = CGRect(x: tr.minX, y: tr.minY, width: max(0, cr.minX - tr.minX), height: tr.height)
        let bottomBand = CGRect(x: cr.minX, y: cr.maxY, width: max(0, tr.maxX - cr.minX), height: max(0, tr.maxY - cr.maxY))
        addCursorRect(leftBand, cursor: .openHand)
        addCursorRect(bottomBand, cursor: .openHand)
        addCursorRect(cr, cursor: .pointingHand)
        for r in actionRects() { addCursorRect(r, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if closeRect().contains(p) { onClose?(); return }
        if let idx = actionRects().firstIndex(where: { $0.contains(p) }) {
            onAction?(actionButtons[idx].action); return
        }
        if thumbRect().contains(p) { dragStartPoint = p }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartPoint else { return }
        let cur = convert(event.locationInWindow, from: nil)
        guard hypot(cur.x - start.x, cur.y - start.y) >= 5.0 else { return }
        dragStartPoint = nil
        guard let url = dragFileURLProvider?() else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let dragNS: NSImage = thumbnail.map { NSImage(cgImage: $0, size: NSSize(width: 96, height: 64)) } ?? NSImage(size: NSSize(width: 96, height: 64))
        item.setDraggingFrame(NSRect(x: cur.x - 48, y: cur.y - 32, width: 96, height: 64), contents: dragNS)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartPoint != nil else { return }
        dragStartPoint = nil
        if thumbRect().contains(convert(event.locationInWindow, from: nil)) { onClickThumb?() }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        onDraggingChanged?(true)
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDraggingChanged?(false)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let isDark = GeekTheme.isDark
        syncProgressColors()
        let c = cardRect(), path = CGPath(roundedRect: c, cornerWidth: 12.5, cornerHeight: 12.5, transform: nil)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 14, color: NSColor.black.withAlphaComponent(isDark ? 0.45 : 0.18).cgColor)
        ctx.setFillColor((isDark ? NSColor(srgbRed: 0.115, green: 0.125, blue: 0.155, alpha: 0.96) : NSColor(srgbRed: 0.985, green: 0.988, blue: 0.996, alpha: 0.97)).cgColor)
        ctx.addPath(path); ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor((isDark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.10)).cgColor)
        ctx.setLineWidth(0.9); ctx.addPath(path); ctx.strokePath()
        ctx.restoreGState()

        drawThumbnailStage(in: ctx, isDark: isDark)
        drawActionButtons(in: ctx, isDark: isDark)
    }

    private func drawThumbnailStage(in ctx: CGContext, isDark: Bool) {
        let tr = thumbRect(), clip = CGPath(roundedRect: tr, cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.saveGState()
        ctx.addPath(clip); ctx.clip()
        ctx.setFillColor((isDark ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 0.92, alpha: 1)).cgColor)
        ctx.fill(tr)
        if let cg = thumbnail {
            let iw = max(1, CGFloat(cg.width)), ih = max(1, CGFloat(cg.height))
            let sc = min(tr.width / iw, tr.height / ih)
            let dw = iw * sc, dh = ih * sc
            let dst = CGRect(x: tr.midX - dw * 0.5, y: tr.midY - dh * 0.5, width: dw, height: dh)
            ctx.saveGState()
            ctx.translateBy(x: 0, y: dst.minY + dst.maxY); ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high; ctx.draw(cg, in: dst)
            ctx.restoreGState()
        } else {
            GeekTheme.drawSymbol(isMediaFile ? "film" : "photo", pointSize: 22, weight: .light, in: tr, alpha: 0.65, tint: GeekTheme.inkMuted)
        }
        if hoveredThumb {
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.24).cgColor); ctx.fill(tr)
            let dragPill = CGRect(x: tr.midX - 48, y: tr.midY - 11, width: 96, height: 22)
            let dp = CGPath(roundedRect: dragPill, cornerWidth: 11, cornerHeight: 11, transform: nil)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor); ctx.addPath(dp); ctx.fillPath()
            GeekTheme.drawText("拖拽即可发送", in: dragPill, font: .systemFont(ofSize: 10.2, weight: .semibold), color: .white, align: .center)
        }
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor((isDark ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.08)).cgColor)
        ctx.setLineWidth(0.7); ctx.addPath(clip); ctx.strokePath()
        ctx.restoreGState()

        let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 9.8, weight: .semibold)
        let bw = min(tr.width - 36, ceil(GeekTheme.measureTextWidth(badgeText, font: badgeFont)) + 14)
        let br = CGRect(x: tr.minX + 6, y: tr.minY + 5, width: bw, height: 18)
        let bp = CGPath(roundedRect: br, cornerWidth: 9, cornerHeight: 9, transform: nil)
        ctx.saveGState()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.62).cgColor); ctx.addPath(bp); ctx.fillPath()
        GeekTheme.drawText(badgeText, in: br, font: badgeFont, color: .white, align: .center)
        let cr = closeRect()
        ctx.setFillColor(NSColor.black.withAlphaComponent(hoveredClose ? 0.80 : 0.52).cgColor); ctx.fillEllipse(in: cr)
        GeekTheme.drawSymbol("xmark", pointSize: 8.8, weight: .bold, in: cr, alpha: 0.96, tint: .white)
        ctx.restoreGState()
    }

    private func drawActionButtons(in ctx: CGContext, isDark: Bool) {
        let rects = actionRects()
        for (idx, def) in actionButtons.enumerated() {
            let r = rects[idx], hov = (hoveredActionIdx == idx)
            let p = CGPath(roundedRect: r, cornerWidth: 7, cornerHeight: 7, transform: nil)
            ctx.saveGState()
            let bg: NSColor = hov
                ? GeekTheme.accent
                : (isDark ? NSColor.white.withAlphaComponent(0.09) : NSColor.black.withAlphaComponent(0.055))
            ctx.setFillColor(bg.cgColor); ctx.addPath(p); ctx.fillPath()
            let fg: NSColor = hov ? .white : GeekTheme.inkPrimary
            let font = NSFont.systemFont(ofSize: 10.6, weight: .medium)
            let tw = GeekTheme.measureTextWidth(def.title, font: font), symW: CGFloat = 12, gap: CGFloat = 3
            let startX = r.midX - (symW + gap + tw) * 0.5
            GeekTheme.drawSymbol(def.symbol, pointSize: 10.5, weight: .semibold, in: CGRect(x: startX, y: r.minY, width: symW, height: r.height), alpha: 0.96, tint: fg)
            GeekTheme.drawText(def.title, in: CGRect(x: startX + symW + gap, y: r.minY, width: tw + 2, height: r.height), font: font, color: fg)
            ctx.restoreGState()
        }
    }
}
