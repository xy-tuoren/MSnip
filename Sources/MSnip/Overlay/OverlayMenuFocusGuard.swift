import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import QuartzCore

/// 覆盖层菜单模态防卡死守护器：
/// - 检测抓取瞬间是否存在外部顶栏/右键/控制中心弹出菜单；
/// - 若存在外部菜单，在冻结覆盖层盖屏后激活 MSnip 释放 WindowServer 模态菜单抓取（若系统菜单仍滞留则安全投递带标签 Esc 解除）；
/// - 挂载兜底全局 Esc 监听，确保无论任何系统浮层抢焦点都不会让覆盖层陷入卡死无法退出的状态。
@MainActor
final class OverlayMenuFocusGuard {
    static let syntheticEscMagic: Int64 = 0x4D53_4E50_4553_4301

    private var didActivateForMenu = false
    private var previousFrontmostApp: NSRunningApplication?
    private var globalEscMonitor: Any?
    private var ignoreEscUntil: TimeInterval = 0
    private var pendingWorkItems: [DispatchWorkItem] = []

    nonisolated static func isPopupMenuWindow(layer: Int, rect: CGRect, ownerName: String) -> Bool {
        if layer >= 100 && layer <= 105 { return true } // kCGPopUpMenuWindowLevel = 101
        if layer == 25 && ownerName != "Window Server" && rect.height > 60 { return true } // 控制中心/状态栏大浮层
        return false
    }

    nonisolated static func hasExternalOpenPopupMenu() -> Bool {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let rawList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for entry in rawList {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != selfPID else { continue }
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0.05,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict),
                  rect.width >= 20, rect.height >= 20 else { continue }
            let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
            if isPopupMenuWindow(layer: layer, rect: rect, ownerName: owner) { return true }
        }
        return false
    }

    func activateOverlayIfNeeded(
        hasOpenPopupMenu: Bool,
        keyWindow: OverlayWindow?,
        initialView: OverlayView?,
        onForceCancel: @escaping @MainActor () -> Void
    ) {
        teardown(restorePreviousApp: false)

        globalEscMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard ev.keyCode == 53 else { return }
            if ev.cgEvent?.getIntegerValueField(.eventSourceUserData) == Self.syntheticEscMagic { return }
            Task { @MainActor [weak self] in
                guard let self, CACurrentMediaTime() >= self.ignoreEscUntil else { return }
                onForceCancel()
            }
        }

        guard hasOpenPopupMenu else { return }
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousFrontmostApp = front
        }
        didActivateForMenu = true
        NSApp.activate(ignoringOtherApps: true)
        keyWindow?.makeKeyAndOrderFront(nil)
        if let v = initialView { keyWindow?.makeFirstResponder(v) }

        // 25ms 后复检：若苹果菜单/系统菜单仍滞留在 WindowServer 模态循环中，发单次带标签 Esc 在幕后释放输入焦点
        let checkWork = DispatchWorkItem { [weak self, weak keyWindow, weak initialView] in
            MainActor.assumeIsolated {
                guard let self, let win = keyWindow, win.isVisible else { return }
                if Self.hasExternalOpenPopupMenu() {
                    self.ignoreEscUntil = CACurrentMediaTime() + 0.18
                    Self.postTaggedEscapeToReleaseSystemMenu()
                    let refocus = DispatchWorkItem { [weak win, weak initialView] in
                        MainActor.assumeIsolated {
                            guard let win, win.isVisible else { return }
                            NSApp.activate(ignoringOtherApps: true)
                            win.makeKeyAndOrderFront(nil)
                            if let v = initialView { win.makeFirstResponder(v) }
                        }
                    }
                    self.pendingWorkItems.append(refocus)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: refocus)
                } else if !win.isKeyWindow {
                    NSApp.activate(ignoringOtherApps: true)
                    win.makeKeyAndOrderFront(nil)
                    if let v = initialView { win.makeFirstResponder(v) }
                }
            }
        }
        pendingWorkItems.append(checkWork)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: checkWork)
    }

    func teardown(restorePreviousApp: Bool) {
        for item in pendingWorkItems { item.cancel() }
        pendingWorkItems.removeAll()
        if let m = globalEscMonitor { NSEvent.removeMonitor(m); globalEscMonitor = nil }
        if restorePreviousApp && didActivateForMenu {
            previousFrontmostApp?.activate(options: [])
        }
        didActivateForMenu = false
        previousFrontmostApp = nil
    }

    private static func postTaggedEscapeToReleaseSystemMenu() {
        guard AXIsProcessTrusted(),
              let down = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false) else { return }
        down.setIntegerValueField(.eventSourceUserData, value: syntheticEscMagic)
        up.setIntegerValueField(.eventSourceUserData, value: syntheticEscMagic)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
