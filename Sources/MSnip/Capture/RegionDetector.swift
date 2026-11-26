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

// MARK: - 窗口与辅助功能元素异步预索引

/// MSnip 自身可见窗口与内部卡片/控件的零 IPC 预快照（Quartz 全局坐标）
struct SelfWindowsSnapshot: Sendable {
    let windowBoundsByID: [CGWindowID: CGRect]
    let subviewRects: [CGRect]
    static let empty = SelfWindowsSnapshot(windowBoundsByID: [:], subviewRects: [])
}

/// 系统程序坞（Dock）与顶部菜单栏的预索引几何快照（Quartz 全局坐标）
struct SystemChromeSnapshot {
    let dockBarRect: CGRect?
    let dockItemRects: [CGRect]
    let menuBarRects: [CGRect]
    let menuBarItemRects: [CGRect]

    static let empty = SystemChromeSnapshot(dockBarRect: nil, dockItemRects: [], menuBarRects: [], menuBarItemRects: [])

    /// 在 0.005ms 内匹配程序坞（Dock 胶囊 / 单个 App 图标）或顶部菜单栏（菜单项 / 状态栏图标）
    func matchLocalStack(at globalPoint: CGPoint, screenQuartzOrigin origin: CGPoint, screenBoundsLocal: CGRect) -> [CGRect]? {
        let toLocal: (CGRect) -> CGRect = { r in
            CGRect(x: r.minX - origin.x, y: r.minY - origin.y, width: r.width, height: r.height).intersection(screenBoundsLocal)
        }
        let hitDockItem = dockItemRects.first(where: { $0.contains(globalPoint) })
        let hitDockBar = dockBarRect.flatMap { $0.contains(globalPoint) ? $0 : nil }
        if hitDockItem != nil || hitDockBar != nil {
            var cands: [CGRect] = [screenBoundsLocal]
            if let bar = dockBarRect { let lr = toLocal(bar); if !lr.isNull { cands.append(lr) } }
            if let item = hitDockItem { let lr = toLocal(item); if !lr.isNull { cands.append(lr) } }
            return VisualDetector.normalizeHierarchy(cands)
        }
        let hitMenuBar = menuBarRects.first(where: { $0.contains(globalPoint) })
        let hitMenuItem = menuBarItemRects.first(where: { $0.contains(globalPoint) })
        if hitMenuBar != nil || hitMenuItem != nil {
            var cands: [CGRect] = [screenBoundsLocal]
            if let bar = hitMenuBar { let lr = toLocal(bar); if !lr.isNull { cands.append(lr) } }
            if let item = hitMenuItem { let lr = toLocal(item); if !lr.isNull { cands.append(lr) } }
            return VisualDetector.normalizeHierarchy(cands)
        }
        return nil
    }
}

/// 辅助功能（AX）预索引与精准控件树查询引擎：
/// 1. 抓屏前 2~4ms 一次性预取程序坞 `AXList` + 全部 `AXDockItem`、顶部菜单栏与控制中心状态栏图标；
/// 2. 完整信任 macOS 原生控件边界（含 16×16 小图标、按钮、卡片、分栏与滚动区），像 PixPin 一样精准吸附。
enum RegionAXPreindexer {
    private static let ignoredAXRoles: Set<String> = [
        "AXStaticText", "AXInlineText", "AXLink", "AXHeading",
        "AXScrollBar", "AXValueIndicator", "AXSplitter", "AXMenuItemMarkChar", "AXMenuBar"
    ]

    private static let fineLeafRoles: Set<String> = [
        "AXButton", "AXDockItem", "AXMenuBarItem", "AXImage", "AXCheckBox",
        "AXRadioButton", "AXPopUpButton", "AXTextField", "AXSearchField",
        "AXTabButton", "AXDisclosureTriangle", "AXColorWell", "AXSlider", "AXMenuButton"
    ]

    private static let batchedAttrs: CFArray = [
        kAXRoleAttribute as CFString,
        kAXPositionAttribute as CFString,
        kAXSizeAttribute as CFString,
        kAXParentAttribute as CFString
    ] as CFArray

    private static let boundsAttrs: CFArray = [
        kAXPositionAttribute as CFString,
        kAXSizeAttribute as CFString
    ] as CFArray

    /// 在冻结抓屏并行阶段预扫描程序坞与顶部状态栏（全量缓存 + 严格 45ms 总预算 + 逐元素 15ms 超时，绝不因外部菜单阻塞）
    static func captureSystemChrome(
        menuBarRects: [CGRect],
        frontmostPID: pid_t?,
        skipMenuBarScan: Bool = false
    ) -> SystemChromeSnapshot {
        guard AXIsProcessTrusted() else {
            return SystemChromeSnapshot(dockBarRect: nil, dockItemRects: [], menuBarRects: menuBarRects, menuBarItemRects: [])
        }
        let deadline = CFAbsoluteTimeGetCurrent() + 0.045
        let (dockBar, dockItems) = scanDock(deadline: deadline)
        let menuItems = skipMenuBarScan ? [] : scanMenuBarItems(frontmostPID: frontmostPID, deadline: deadline)
        return SystemChromeSnapshot(
            dockBarRect: dockBar,
            dockItemRects: dockItems,
            menuBarRects: menuBarRects,
            menuBarItemRects: menuItems
        )
    }

    /// 按单点位置查询目标应用窗口内的完整 AX 控件层级链（返回全局坐标矩形数组）
    static func queryHierarchy(
        appElem: AXUIElement,
        at globalPoint: CGPoint,
        clampTo windowBounds: CGRect,
        timedOut: inout Bool
    ) -> [CGRect] {
        let t0 = CFAbsoluteTimeGetCurrent()
        var hitRef: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(appElem, Float(globalPoint.x), Float(globalPoint.y), &hitRef)
        if status == .cannotComplete, (CFAbsoluteTimeGetCurrent() - t0) >= 0.014 {
            timedOut = true
            return []
        }
        guard status == .success, var current = hitRef else { return [] }

        var rects: [CGRect] = []
        let deadline = t0 + 0.035
        for _ in 0..<12 {
            if CFAbsoluteTimeGetCurrent() >= deadline { timedOut = true; break }
            setFastTimeout(current, 0.015)
            var valuesRef: CFArray?
            let err = AXUIElementCopyMultipleAttributeValues(current, batchedAttrs, AXCopyMultipleAttributeOptions(rawValue: 0), &valuesRef)
            if err == .cannotComplete, CFAbsoluteTimeGetCurrent() >= deadline { timedOut = true; break }
            guard err == .success, let arr = valuesRef as? [AnyObject], arr.count == 4 else { break }

            let role = (arr[0] as? String) ?? ""
            if !ignoredAXRoles.contains(role), let rawRect = unpackBounds(posObj: arr[1], sizeObj: arr[2]) {
                let clamped = rawRect.intersection(windowBounds)
                let minW: CGFloat = fineLeafRoles.contains(role) ? 16 : 28
                let minH: CGFloat = fineLeafRoles.contains(role) ? 16 : 20
                let aspectOK = clamped.width <= clamped.height * 32 && clamped.height <= clamped.width * 24
                if !clamped.isNull, clamped.contains(globalPoint), clamped.width >= minW, clamped.height >= minH, aspectOK {
                    rects.append(clamped)
                }
            }

            let parentObj = arr[3]
            guard CFGetTypeID(parentObj) == AXUIElementGetTypeID() else { break }
            current = (parentObj as! AXUIElement)
        }
        return rects
    }

    // MARK: - Dock & Menu Bar Pre-Scan

    private static func scanDock(deadline: CFAbsoluteTime) -> (CGRect?, [CGRect]) {
        guard CFAbsoluteTimeGetCurrent() < deadline,
              let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return (nil, [])
        }
        let appEl = AXUIElementCreateApplication(dockApp.processIdentifier)
        setFastTimeout(appEl, 0.020)

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return (nil, [])
        }

        for child in children {
            if CFAbsoluteTimeGetCurrent() >= deadline { break }
            setFastTimeout(child, 0.015)
            var roleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef) == .success,
                  (roleRef as? String) == "AXList" else { continue }
            let barRect = readBounds(of: child)
            var itemRefs: CFTypeRef?
            var itemRects: [CGRect] = []
            if CFAbsoluteTimeGetCurrent() < deadline,
               AXUIElementCopyAttributeValue(child, kAXChildrenAttribute as CFString, &itemRefs) == .success,
               let items = itemRefs as? [AXUIElement] {
                itemRects.reserveCapacity(items.count)
                for item in items {
                    if CFAbsoluteTimeGetCurrent() >= deadline { break }
                    if let r = readBounds(of: item), r.width >= 16, r.height >= 16 {
                        itemRects.append(r)
                    }
                }
            }
            let resolvedBar: CGRect? = {
                if let b = barRect, b.width >= 60, b.height >= 24, b.width < 4000, b.height < 260 { return b }
                guard let first = itemRects.first else { return nil }
                let union = itemRects.dropFirst().reduce(first) { $0.union($1) }
                return union.insetBy(dx: -8, dy: -6)
            }()
            return (resolvedBar, itemRects)
        }
        return (nil, [])
    }

    private static func scanMenuBarItems(frontmostPID: pid_t?, deadline: CFAbsoluteTime) -> [CGRect] {
        var rects: [CGRect] = []
        let selfPID = ProcessInfo.processInfo.processIdentifier
        if CFAbsoluteTimeGetCurrent() < deadline, let pid = frontmostPID, pid > 0, pid != selfPID {
            let appEl = AXUIElementCreateApplication(pid)
            setFastTimeout(appEl, 0.015)
            appendMenuBarChildren(from: appEl, attr: kAXMenuBarAttribute, deadline: deadline, into: &rects)
        }
        let statusBundles = ["com.apple.controlcenter", "com.apple.systemuiserver"]
        for bid in statusBundles {
            if CFAbsoluteTimeGetCurrent() >= deadline { break }
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bid) {
                if CFAbsoluteTimeGetCurrent() >= deadline { break }
                let el = AXUIElementCreateApplication(app.processIdentifier)
                setFastTimeout(el, 0.015)
                appendMenuBarChildren(from: el, attr: "AXExtrasMenuBar", deadline: deadline, into: &rects)
                appendMenuBarChildren(from: el, attr: kAXMenuBarAttribute, deadline: deadline, into: &rects)
            }
        }
        return rects
    }

    private static func appendMenuBarChildren(
        from appEl: AXUIElement,
        attr: String,
        deadline: CFAbsoluteTime,
        into out: inout [CGRect]
    ) {
        guard CFAbsoluteTimeGetCurrent() < deadline else { return }
        var barRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, attr as CFString, &barRef) == .success,
              let rawBar = barRef, CFGetTypeID(rawBar) == AXUIElementGetTypeID() else { return }
        let barEl = unsafeBitCast(rawBar, to: AXUIElement.self)
        setFastTimeout(barEl, 0.015)
        var kidsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(barEl, kAXChildrenAttribute as CFString, &kidsRef) == .success,
              let kids = kidsRef as? [AXUIElement] else { return }
        for kid in kids {
            if CFAbsoluteTimeGetCurrent() >= deadline { break }
            if let r = readBounds(of: kid), r.width >= 14, r.height >= 14, r.height <= 48 {
                out.append(r)
            }
        }
    }

    private static func setFastTimeout(_ el: AXUIElement, _ seconds: Float = 0.015) {
        AXUIElementSetMessagingTimeout(el, seconds)
    }

    private static func readBounds(of el: AXUIElement) -> CGRect? {
        setFastTimeout(el, 0.015)
        var valuesRef: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, boundsAttrs, AXCopyMultipleAttributeOptions(rawValue: 0), &valuesRef) == .success,
              let arr = valuesRef as? [AnyObject], arr.count == 2 else { return nil }
        return unpackBounds(posObj: arr[0], sizeObj: arr[1])
    }

    private static func unpackBounds(posObj: AnyObject, sizeObj: AnyObject) -> CGRect? {
        guard CFGetTypeID(posObj) == AXValueGetTypeID(), CFGetTypeID(sizeObj) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(posObj as! AXValue, .cgPoint, &pt), AXValueGetValue(sizeObj as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }

    /// 在 `@MainActor` 抓屏瞬间直接提取 MSnip 自身可见窗口（如设置窗、拼图窗、OCR 窗、贴图窗）及内部有界控件（0.02ms 纯内存，免自进程 AX 死锁）
    @MainActor
    static func captureSelfWindows(primaryScreenHeight: CGFloat) -> SelfWindowsSnapshot {
        var winMap: [CGWindowID: CGRect] = [:]
        var rects: [CGRect] = []
        func toQuartz(_ sr: NSRect) -> CGRect {
            CGRect(x: sr.minX, y: primaryScreenHeight - sr.maxY, width: sr.width, height: sr.height)
        }
        for win in NSApp.windows where win.isVisible && win.alphaValue > 0.05 {
            guard win.windowNumber > 0, let winID = CGWindowID(exactly: win.windowNumber) else { continue }
            if win is OverlayWindow || win.level.rawValue >= NSWindow.Level.statusBar.rawValue { continue }
            let screenWinFrame = (win as? PinWindow)?.imageScreenFrame ?? win.frame
            guard screenWinFrame.width >= 24, screenWinFrame.height >= 24 else { continue }
            let qWin = toQuartz(screenWinFrame)
            winMap[winID] = qWin
            guard !(win is PinWindow), let root = win.contentView else { continue }
            collectVisualSubviewRects(in: root, window: win, windowQuartz: qWin, toQuartz: toQuartz, into: &rects)
        }
        return SelfWindowsSnapshot(windowBoundsByID: winMap, subviewRects: rects)
    }

    @MainActor
    private static func collectVisualSubviewRects(
        in view: NSView, window: NSWindow, windowQuartz: CGRect,
        toQuartz: (NSRect) -> CGRect, into out: inout [CGRect]
    ) {
        guard !view.isHidden, view.alphaValue > 0.05, out.count < 200 else { return }
        let isPureLayoutWrapper = (view is NSScrollView) || (view is NSClipView) || (view is NSTextField)
            || (view is GeekFlippedView) || (view === window.contentView)
        if !isPureLayoutWrapper && view.bounds.width >= 18 && view.bounds.height >= 16 {
            let inWin = view.convert(view.bounds, to: nil).intersection(window.contentView?.bounds ?? .zero)
            if !inWin.isNull && inWin.width >= 18 && inWin.height >= 16 {
                let q = toQuartz(window.convertToScreen(inWin)).intersection(windowQuartz)
                let areaRatio = (q.width * q.height) / max(1, windowQuartz.width * windowQuartz.height)
                if !q.isNull && areaRatio < 0.94 { out.append(q) }
            }
        }
        for sub in view.subviews {
            collectVisualSubviewRects(in: sub, window: window, windowQuartz: windowQuartz, toQuartz: toQuartz, into: &out)
        }
    }
}
