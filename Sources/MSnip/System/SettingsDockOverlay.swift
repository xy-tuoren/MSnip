import AppKit
import CoreGraphics
import Foundation

/// 吸附在 macOS「系统设置」权限列表正下方的高亮拖拽条视图：
/// 整条高亮卡片任意位置均可按住直接向上拖入列表（支持 `acceptsFirstMouse` 免点活拖拽）。
final class SettingsDockBarView: NSView, NSDraggingSource {
    var onCloseClicked: (() -> Void)?
    var onDragStateChanged: ((Bool) -> Void)?

    private var isHovered = false { didSet { if oldValue != isHovered { needsDisplay = true } } }
    private var isPressing = false { didSet { if oldValue != isPressing { needsDisplay = true } } }
    private var mouseDownEvent: NSEvent?

    private var closeRect: NSRect {
        NSRect(x: bounds.width - 28, y: (bounds.height - 18) * 0.5, width: 18, height: 18)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

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

    override func mouseEntered(with event: NSEvent) { isHovered = true; updateCursor(for: event) }
    override func mouseMoved(with event: NSEvent) { updateCursor(for: event) }
    override func mouseExited(with event: NSEvent) {
        isHovered = false; isPressing = false; NSCursor.arrow.set()
    }

    private func updateCursor(for event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if closeRect.insetBy(dx: -4, dy: -4).contains(pt) {
            NSCursor.arrow.set()
        } else {
            (isPressing ? NSCursor.closedHand : NSCursor.openHand).set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if closeRect.insetBy(dx: -4, dy: -4).contains(pt) { onCloseClicked?(); return }
        isPressing = true
        mouseDownEvent = event
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startEvent = mouseDownEvent else { return }
        let p0 = convert(startEvent.locationInWindow, from: nil)
        let p1 = convert(event.locationInWindow, from: nil)
        guard hypot(p1.x - p0.x, p1.y - p0.y) >= 2.0 else { return }

        mouseDownEvent = nil
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        let sz = NSSize(width: 54, height: 54)
        item.setDraggingFrame(
            NSRect(x: p1.x - sz.width * 0.5, y: p1.y - sz.height * 0.5, width: sz.width, height: sz.height),
            contents: appIcon(size: sz)
        )
        onDragStateChanged?(true)
        let session = beginDraggingSession(with: [item], event: startEvent, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        isPressing = false; mouseDownEvent = nil; updateCursor(for: event)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isPressing = false
        onDragStateChanged?(false)
    }

    override func draw(_ dirtyRect: NSRect) {
        let cardRect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: cardRect, xRadius: 12, yRadius: 12)

        let bg = isHovered
            ? NSColor(srgbRed: 0.12, green: 0.20, blue: 0.32, alpha: 0.96)
            : NSColor(srgbRed: 0.11, green: 0.16, blue: 0.25, alpha: 0.95)
        bg.setFill()
        path.fill()

        let glow = NSColor(srgbRed: 0.22, green: 0.74, blue: 0.98, alpha: isHovered ? 1.0 : 0.85)
        glow.setStroke()
        path.lineWidth = isHovered ? 2.0 : 1.5
        path.stroke()

        let iconSide: CGFloat = 38
        let iconRect = NSRect(x: 14, y: (bounds.height - iconSide) * 0.5, width: iconSide, height: iconSide)
        appIcon(size: iconRect.size).draw(in: iconRect)

        let textX = iconRect.maxX + 12
        let title = "按住此处向上拖入列表即可添加 MSnip" as NSString
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let tSz = title.size(withAttributes: titleAttrs)

        let sub = "直接拖到上方权限框内松手 · 自动勾选开启" as NSString
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(srgbRed: 0.68, green: 0.84, blue: 0.96, alpha: 0.92)
        ]
        let sSz = sub.size(withAttributes: subAttrs)

        let baseY = (bounds.height - (tSz.height + 2 + sSz.height)) * 0.5
        sub.draw(at: NSPoint(x: textX, y: round(baseY)), withAttributes: subAttrs)
        title.draw(at: NSPoint(x: textX, y: round(baseY + sSz.height + 2)), withAttributes: titleAttrs)

        let pillW: CGFloat = 58, pillH: CGFloat = 24
        let pillRect = NSRect(x: bounds.width - pillW - 36, y: (bounds.height - pillH) * 0.5, width: pillW, height: pillH)
        glow.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: pillRect, xRadius: 6.5, yRadius: 6.5).fill()

        let badge = "↑ 拖入" as NSString
        let bAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: glow]
        let bSz = badge.size(withAttributes: bAttrs)
        badge.draw(at: NSPoint(x: pillRect.minX + (pillW - bSz.width) * 0.5, y: pillRect.minY + (pillH - bSz.height) * 0.5), withAttributes: bAttrs)

        let xStr = "✕" as NSString
        let xAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.45)]
        let xSz = xStr.size(withAttributes: xAttrs)
        xStr.draw(at: NSPoint(x: closeRect.midX - xSz.width * 0.5, y: closeRect.midY - xSz.height * 0.5), withAttributes: xAttrs)
    }

    private func appIcon(size: NSSize) -> NSImage {
        let icon = (NSApp.applicationIconImage?.copy() as? NSImage) ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        icon.size = size
        return icon
    }
}

/// 实时追踪「系统设置」窗口几何，将高亮拖拽条精准悬浮吸附在权限列表正下方
@MainActor
final class SettingsDockOverlay {
    private var panel: NSPanel?
    private var trackTimer: Timer?
    private var manuallyDismissed = false

    func startTracking() {
        manuallyDismissed = false
        ensurePanel()
        syncPosition()
        guard trackTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncPosition() }
        }
        RunLoop.main.add(timer, forMode: .common)
        trackTimer = timer
    }

    func stopAndHide() {
        trackTimer?.invalidate()
        trackTimer = nil
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let size = NSSize(width: 444, height: 58)
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true

        let bar = SettingsDockBarView(frame: NSRect(origin: .zero, size: size))
        bar.onCloseClicked = { [weak self] in
            self?.manuallyDismissed = true
            self?.panel?.orderOut(nil)
        }
        bar.onDragStateChanged = { [weak p] dragging in p?.alphaValue = dragging ? 0.28 : 1.0 }
        p.contentView = bar
        panel = p
    }

    private func syncPosition() {
        guard !manuallyDismissed, let panel else { return }
        guard let origin = locateSystemSettingsDockOrigin(barSize: panel.frame.size) else {
            panel.orderOut(nil)
            return
        }
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func locateSystemSettingsDockOrigin(barSize: NSSize) -> NSPoint? {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        guard primaryH > 0 else { return nil }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let rawList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

        var occludersAbove: [CGRect] = []
        for entry in rawList {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != selfPID,
                  (entry[kCGWindowLayer as String] as? Int ?? -1) == 0,
                  let dict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let cgBounds = CGRect(dictionaryRepresentation: dict),
                  cgBounds.width >= 200, cgBounds.height >= 150 else { continue }

            let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
            if (owner == "系统设置" || owner == "System Settings" || owner == "System Preferences"),
               cgBounds.width >= 440, cgBounds.height >= 360 {
                let barX = cgBounds.width >= 680 ? (cgBounds.maxX - barSize.width - 38) : (cgBounds.midX - barSize.width * 0.5)
                let barQuartzRect = CGRect(x: barX, y: cgBounds.maxY - 89 - barSize.height, width: barSize.width, height: barSize.height)
                if occludersAbove.contains(where: { !$0.intersection(barQuartzRect).isNull }) { return nil }
                return NSPoint(x: round(barX), y: round(primaryH - barQuartzRect.maxY))
            }
            occludersAbove.append(cgBounds)
        }
        return nil
    }
}
