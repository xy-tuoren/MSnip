import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MSnipCore

/// 抓屏瞬间的桌面窗口快照项（Quartz 全局坐标系：主屏幕左上角为 (0,0)，向下为 +Y）
struct WindowSnapshotItem {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let globalBounds: CGRect
    let layer: Int
}

/// 高速精准三层区域探测器（PixPin 级瞬时整窗与内部卡片跟手架构）：
/// 1. 完整覆盖外部窗口与 MSnip 自身可见窗口（设置/拼图/识字/贴图），支持标题栏/底栏/外框边距 0ms 直吸整窗；
/// 2. 0ms 最新优先合并队列（Latest-Wins Coalescing）+ 空间缓存池，自动剔除无边框透明滚动层对整窗的切割；
/// 3. 自适应圆角四边闭合 `VisualDetector` 兜底，杜绝两张内缩卡片之间的空白缝隙误判为幽灵横条。
final class RegionDetector: @unchecked Sendable {
    private let windows: [WindowSnapshotItem]
    private let chrome: SystemChromeSnapshot
    private let primaryScreenHeight: CGFloat
    private let selfPID: pid_t
    private let axTrusted: Bool
    let hasOpenPopupMenu: Bool

    private let detectQueue = DispatchQueue(label: "top.xy.msnip.region.detect", qos: .userInteractive)
    private let stateLock = NSLock()
    private var appElementCache: [pid_t: AXUIElement] = [:]
    private var timeoutStrikes: [pid_t: Int] = [:]
    private var spatialRectsByPID: [pid_t: [CGRect]] = [:]

    private struct PendingQuery {
        let localPoint: CGPoint
        let snapshot: ScreenSnapshot
        let completion: @MainActor ([CGRect], CGRect?) -> Void
    }
    private var isWorkerBusy = false
    private var pendingQuery: PendingQuery?

    init(
        windows: [WindowSnapshotItem],
        chrome: SystemChromeSnapshot,
        primaryScreenHeight: CGFloat,
        hasOpenPopupMenu: Bool = false,
        initialSelfRects: [CGRect] = []
    ) {
        self.windows = windows; self.chrome = chrome
        self.primaryScreenHeight = primaryScreenHeight
        self.selfPID = ProcessInfo.processInfo.processIdentifier
        self.axTrusted = AXIsProcessTrusted()
        self.hasOpenPopupMenu = hasOpenPopupMenu
        if !initialSelfRects.isEmpty { self.spatialRectsByPID[self.selfPID] = initialSelfRects }
    }

    static func captureBeforeOverlay(
        primaryScreenHeight: CGFloat? = nil,
        frontmostPID: pid_t? = nil,
        selfWindows: SelfWindowsSnapshot = .empty
    ) -> RegionDetector {
        let primaryH = primaryScreenHeight ?? (NSScreen.screens.first?.frame.height ?? 0)
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let frontPID = frontmostPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        let rawList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var pidBundleCache: [pid_t: String] = [:]
        let ignoredShellBundles: Set<String> = [
            "com.apple.dock", "com.apple.WindowManager", "com.apple.wallpaper.agent", "com.apple.notificationcenterui"
        ]

        var items: [WindowSnapshotItem] = []
        var menuBarRects: [CGRect] = []
        var hasOpenPopupMenu = false
        for entry in rawList {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let rawWinID = entry[kCGWindowNumber as String] as? UInt32 else { continue }
            let winID = CGWindowID(rawWinID)
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0.05, layer >= 0, layer < 500,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rawRect = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            let rect: CGRect
            if pid == selfPID {
                guard let exactSelfRect = selfWindows.windowBoundsByID[winID] else { continue }
                rect = exactSelfRect
            } else {
                rect = rawRect
            }
            guard rect.width >= 20, rect.height >= 20 else { continue }

            let ownerName = entry[kCGWindowOwnerName as String] as? String ?? ""
            if OverlayMenuFocusGuard.isPopupMenuWindow(layer: layer, rect: rect, ownerName: ownerName) { hasOpenPopupMenu = true }
            if ownerName == "Window Server" {
                if rect.height <= 48 && layer == 24 { menuBarRects.append(rect) }
                continue
            }
            let bundleID = pidBundleCache[pid] ?? {
                let r = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
                pidBundleCache[pid] = r; return r
            }()
            if ignoredShellBundles.contains(bundleID) && rect.width > 400 && rect.height > 400 { continue }
            items.append(WindowSnapshotItem(windowID: winID, ownerPID: pid, ownerName: ownerName, globalBounds: rect, layer: layer))
        }
        let chrome = RegionAXPreindexer.captureSystemChrome(menuBarRects: menuBarRects, frontmostPID: frontPID, skipMenuBarScan: hasOpenPopupMenu)
        return RegionDetector(windows: items, chrome: chrome, primaryScreenHeight: primaryH, hasOpenPopupMenu: hasOpenPopupMenu, initialSelfRects: selfWindows.subviewRects)
    }

    static func checkAccessibilityPermission(prompt: Bool) -> Bool {
        prompt ? AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt" as CFString: true] as CFDictionary) : AXIsProcessTrusted()
    }

    private func resolveScreenMapping(at localPoint: CGPoint, in snapshot: ScreenSnapshot) -> (bounds: CGRect, origin: CGPoint, global: CGPoint)? {
        let sf = snapshot.screen.frame, sb = CGRect(origin: .zero, size: sf.size)
        guard sb.contains(localPoint) else { return nil }
        let origin = CGPoint(x: sf.minX, y: primaryScreenHeight - sf.maxY)
        return (sb, origin, CGPoint(x: origin.x + localPoint.x, y: origin.y + localPoint.y))
    }

    func topWindow(at localPoint: CGPoint, in snapshot: ScreenSnapshot) -> (windowID: CGWindowID, ownerName: String, localRect: CGRect)? {
        guard let map = resolveScreenMapping(at: localPoint, in: snapshot),
              let hit = windows.first(where: { $0.globalBounds.contains(map.global) }) else { return nil }
        let lr = toLocalRect(hit.globalBounds, screenQuartzOrigin: map.origin).intersection(map.bounds)
        guard !lr.isNull, lr.width >= 24, lr.height >= 24 else { return nil }
        return (hit.windowID, hit.ownerName, lr)
    }

    func fastMemoryHierarchy(at localPoint: CGPoint, in snapshot: ScreenSnapshot) -> (stack: [CGRect], isComplete: Bool, winRect: CGRect?) {
        let sbFallback = CGRect(origin: .zero, size: snapshot.screen.frame.size)
        guard let map = resolveScreenMapping(at: localPoint, in: snapshot) else { return ([sbFallback], true, nil) }
        if let chromeStack = chrome.matchLocalStack(at: map.global, screenQuartzOrigin: map.origin, screenBoundsLocal: map.bounds) {
            return (chromeStack, true, chromeStack.count >= 2 ? chromeStack[chromeStack.count - 2] : nil)
        }
        guard let topWin = windows.first(where: { $0.globalBounds.contains(map.global) }) else {
            return ([map.bounds], false, nil)
        }
        let winLocal = toLocalRect(topWin.globalBounds, screenQuartzOrigin: map.origin).intersection(map.bounds)
        guard !winLocal.isNull, winLocal.width >= 24, winLocal.height >= 24 else { return ([map.bounds], false, nil) }

        let nearRim = Self.isNearWindowRim(localPoint, in: winLocal)
        var cands: [CGRect] = [winLocal, map.bounds]
        stateLock.lock(); let pool = spatialRectsByPID[topWin.ownerPID] ?? []; stateLock.unlock()
        for gr in pool where gr.contains(map.global) {
            let lr = toLocalRect(gr, screenQuartzOrigin: map.origin).intersection(winLocal)
            guard !lr.isNull, lr.width >= 16, lr.height >= 16,
                  !Self.isWindowChromeStrip(lr, in: winLocal),
                  !nearRim || (lr.width <= 120 && lr.height <= 50) else { continue }
            cands.append(lr)
        }
        return (VisualDetector.normalizeHierarchy(cands), topWin.ownerPID == selfPID && snapshot.isSamplerReady, winLocal)
    }

    func requestLatestHierarchy(at localPoint: CGPoint, in snapshot: ScreenSnapshot, completion: @escaping @MainActor ([CGRect], CGRect?) -> Void) {
        stateLock.lock()
        pendingQuery = PendingQuery(localPoint: localPoint, snapshot: snapshot, completion: completion)
        if isWorkerBusy { stateLock.unlock(); return }
        isWorkerBusy = true
        stateLock.unlock()
        detectQueue.async { [weak self] in self?.drainPendingQueries() }
    }

    func detectHierarchy(at localPoint: CGPoint, in snapshot: ScreenSnapshot, fastWindowOnly: Bool = false) -> [CGRect] {
        let sbFallback = CGRect(origin: .zero, size: snapshot.screen.frame.size)
        guard let map = resolveScreenMapping(at: localPoint, in: snapshot) else { return [sbFallback] }
        if let chromeStack = chrome.matchLocalStack(at: map.global, screenQuartzOrigin: map.origin, screenBoundsLocal: map.bounds) { return chromeStack }
        if fastWindowOnly {
            if let topWin = windows.first(where: { $0.globalBounds.contains(map.global) }) {
                let wl = toLocalRect(topWin.globalBounds, screenQuartzOrigin: map.origin).intersection(map.bounds)
                if !wl.isNull, wl.width >= 24, wl.height >= 24 { return VisualDetector.normalizeHierarchy([wl, map.bounds]) }
            }
            return [map.bounds]
        }
        return computeFullHierarchy(at: localPoint, in: snapshot).stack
    }

    private func drainPendingQueries() {
        while true {
            stateLock.lock()
            guard let req = pendingQuery else { isWorkerBusy = false; stateLock.unlock(); return }
            pendingQuery = nil; stateLock.unlock()
            let res = computeFullHierarchy(at: req.localPoint, in: req.snapshot)
            Task { @MainActor in req.completion(res.stack, res.winRect) }
        }
    }

    private func computeFullHierarchy(at localPoint: CGPoint, in snapshot: ScreenSnapshot) -> (stack: [CGRect], winRect: CGRect?) {
        let sbFallback = CGRect(origin: .zero, size: snapshot.screen.frame.size)
        guard let map = resolveScreenMapping(at: localPoint, in: snapshot) else { return ([sbFallback], nil) }
        if let chromeStack = chrome.matchLocalStack(at: map.global, screenQuartzOrigin: map.origin, screenBoundsLocal: map.bounds) {
            return (chromeStack, chromeStack.count >= 2 ? chromeStack[chromeStack.count - 2] : nil)
        }

        var cands: [CGRect] = [map.bounds]
        var winLocalOut: CGRect?
        let samplerReady = snapshot.isSamplerReady

        if let topWin = windows.first(where: { $0.globalBounds.contains(map.global) }) {
            let winLocal = toLocalRect(topWin.globalBounds, screenQuartzOrigin: map.origin).intersection(map.bounds)
            if !winLocal.isNull && winLocal.width >= 24 && winLocal.height >= 24 {
                winLocalOut = winLocal; cands.append(winLocal)
                let winArea = winLocal.width * winLocal.height
                let nearRim = Self.isNearWindowRim(localPoint, in: winLocal)
                var smallestInner: CGRect?

                let sourceGlobalRects: [CGRect]
                if topWin.ownerPID == selfPID {
                    stateLock.lock(); sourceGlobalRects = (spatialRectsByPID[selfPID] ?? []).filter { $0.contains(map.global) }; stateLock.unlock()
                } else if axTrusted {
                    sourceGlobalRects = queryAXCached(pid: topWin.ownerPID, at: map.global, clampTo: topWin.globalBounds)
                } else {
                    sourceGlobalRects = []
                }

                for gr in sourceGlobalRects {
                    let lr = toLocalRect(gr, screenQuartzOrigin: map.origin).intersection(winLocal)
                    guard !lr.isNull, !Self.isWindowChromeStrip(lr, in: winLocal),
                          !nearRim || (lr.width <= 120 && lr.height <= 50) else { continue }
                    let area = lr.width * lr.height
                    if samplerReady && area > winArea * 0.40 && area < winArea * 0.96
                        && !VisualDetector.hasVisualBoundary(lr, within: winLocal, sampler: snapshot.sampler, scale: snapshot.scaleFactor) {
                        continue
                    }
                    cands.append(lr)
                    if smallestInner == nil || area < (smallestInner!.width * smallestInner!.height) { smallestInner = lr }
                }

                let needVisual = !nearRim && ((smallestInner == nil) || ((smallestInner!.width * smallestInner!.height) > winArea * 0.40))
                if needVisual, samplerReady {
                    let scope = smallestInner ?? winLocal
                    let vRects = VisualDetector.detectVisualRects(at: localPoint, within: scope, sampler: snapshot.sampler, scale: snapshot.scaleFactor)
                        .filter { !Self.isWindowChromeStrip($0, in: winLocal) }
                    cands.append(contentsOf: vRects)
                }
            }
        } else if samplerReady {
            cands.append(contentsOf: VisualDetector.detectVisualRects(at: localPoint, within: map.bounds, sampler: snapshot.sampler, scale: snapshot.scaleFactor))
        }

        let normalized = VisualDetector.normalizeHierarchy(cands)
        return (normalized.isEmpty ? [map.bounds] : normalized, winLocalOut)
    }

    private static func isNearWindowRim(_ pt: CGPoint, in win: CGRect) -> Bool {
        pt.x - win.minX <= 10 || win.maxX - pt.x <= 10 || pt.y - win.minY <= 10 || win.maxY - pt.y <= 10
    }

    /// 过滤横跨整窗顶/底的空标题栏或底状态条（在标题栏空白处悬停时直接吸附整个窗口，内部独立按钮不受影响）
    private static func isWindowChromeStrip(_ r: CGRect, in win: CGRect) -> Bool {
        guard win.width >= 180, win.height >= 140 else { return false }
        let fullW = r.width >= win.width * 0.90
        let touchesBarEdge = (r.minY - win.minY <= 4.0) || (win.maxY - r.maxY <= 4.0)
        return fullW && touchesBarEdge && r.height <= 64.0
    }

    private func queryAXCached(pid: pid_t, at globalPoint: CGPoint, clampTo windowBounds: CGRect) -> [CGRect] {
        stateLock.lock()
        if (timeoutStrikes[pid] ?? 0) >= 3 { stateLock.unlock(); return [] }
        let appElem: AXUIElement = appElementCache[pid] ?? {
            let el = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(el, 0.018); appElementCache[pid] = el; return el
        }()
        stateLock.unlock()

        var timedOut = false
        let rects = RegionAXPreindexer.queryHierarchy(appElem: appElem, at: globalPoint, clampTo: windowBounds, timedOut: &timedOut)
        stateLock.lock()
        if timedOut {
            timeoutStrikes[pid] = (timeoutStrikes[pid] ?? 0) + 1
        } else if !rects.isEmpty {
            timeoutStrikes[pid] = 0
            var pool = spatialRectsByPID[pid] ?? []
            if pool.count < 160 {
                for r in rects where !pool.contains(where: { abs($0.minX - r.minX) <= 2 && abs($0.minY - r.minY) <= 2 && abs($0.width - r.width) <= 2 && abs($0.height - r.height) <= 2 }) {
                    pool.append(r)
                }
                spatialRectsByPID[pid] = pool
            }
        }
        stateLock.unlock()
        return rects
    }

    private func toLocalRect(_ globalRect: CGRect, screenQuartzOrigin: CGPoint) -> CGRect {
        CGRect(x: globalRect.origin.x - screenQuartzOrigin.x, y: globalRect.origin.y - screenQuartzOrigin.y, width: globalRect.width, height: globalRect.height)
    }
}
