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

    private struct CachedRegion: Sendable {
        let globalRect: CGRect
        let isLeaf: Bool
    }

    private let detectQueue = DispatchQueue(label: "top.xy.msnip.region.detect", qos: .userInteractive)
    private let stateLock = NSLock()
    private var appElementCache: [pid_t: AXUIElement] = [:]
    private var timeoutStrikes: [pid_t: Int] = [:]
    /// 按独立窗口 ID 隔离的已校验区域缓存（只存已通过角色/视觉闭合校验的真实矩形，杜绝跨窗口污染与隐形 div 回跳）
    private var spatialRectsByWindow: [CGWindowID: [CachedRegion]] = [:]
    private var selfSubviewCandidatesByWindow: [CGWindowID: [AXCandidate]] = [:]

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
        initialSelfCandidatesByWindow: [CGWindowID: [AXCandidate]] = [:]
    ) {
        self.windows = windows; self.chrome = chrome
        self.primaryScreenHeight = primaryScreenHeight
        self.selfPID = ProcessInfo.processInfo.processIdentifier
        self.axTrusted = AXIsProcessTrusted()
        self.hasOpenPopupMenu = hasOpenPopupMenu
        self.selfSubviewCandidatesByWindow = initialSelfCandidatesByWindow
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
        return RegionDetector(
            windows: items,
            chrome: chrome,
            primaryScreenHeight: primaryH,
            hasOpenPopupMenu: hasOpenPopupMenu,
            initialSelfCandidatesByWindow: selfWindows.subviewCandidatesByWindowID
        )
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

    func fastMemoryHierarchy(at localPoint: CGPoint, in snapshot: ScreenSnapshot, windowOnly: Bool = false) -> (stack: [CGRect], isComplete: Bool, hasFineHit: Bool, winRect: CGRect?) {
        let sbFallback = CGRect(origin: .zero, size: snapshot.screen.frame.size)
        guard let map = resolveScreenMapping(at: localPoint, in: snapshot) else { return ([sbFallback], true, false, nil) }
        if let chromeStack = chrome.matchLocalStack(at: map.global, screenQuartzOrigin: map.origin, screenBoundsLocal: map.bounds) {
            return (chromeStack, true, true, chromeStack.count >= 2 ? chromeStack[chromeStack.count - 2] : nil)
        }
        guard let topWin = windows.first(where: { $0.globalBounds.contains(map.global) }) else {
            return ([map.bounds], false, false, nil)
        }
        let winLocal = toLocalRect(topWin.globalBounds, screenQuartzOrigin: map.origin).intersection(map.bounds)
        guard !winLocal.isNull, winLocal.width >= 24, winLocal.height >= 24 else { return ([map.bounds], false, false, nil) }

        var cands: [CGRect] = [winLocal, map.bounds]
        if windowOnly {
            return (VisualDetector.normalizeHierarchy(cands), false, false, winLocal)
        }
        let nearRim = Self.isNearWindowRim(localPoint, in: winLocal)
        var hasFineHit = false
        stateLock.lock(); let pool = spatialRectsByWindow[topWin.windowID] ?? []; stateLock.unlock()
        for item in pool where item.globalRect.contains(map.global) {
            let lr = toLocalRect(item.globalRect, screenQuartzOrigin: map.origin).intersection(winLocal)
            guard !lr.isNull, lr.contains(localPoint), lr.width >= 16, lr.height >= 16,
                  item.isLeaf || !Self.isWindowChromeStrip(lr, in: winLocal),
                  !nearRim || (item.isLeaf && lr.width <= 120 && lr.height <= 48) else { continue }
            cands.append(lr)
            hasFineHit = true
        }
        return (VisualDetector.normalizeHierarchy(cands), false, hasFineHit, winLocal)
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
        let sampler = snapshot.sampler

        if let topWin = windows.first(where: { $0.globalBounds.contains(map.global) }) {
            let winLocal = toLocalRect(topWin.globalBounds, screenQuartzOrigin: map.origin).intersection(map.bounds)
            if !winLocal.isNull && winLocal.width >= 24 && winLocal.height >= 24 {
                winLocalOut = winLocal; cands.append(winLocal)
                let winArea = winLocal.width * winLocal.height
                let nearRim = Self.isNearWindowRim(localPoint, in: winLocal)
                var smallestInner: CGRect?
                var hasCompactLeafHit = false
                var verifiedCacheEntries: [CachedRegion] = []

                let sourceCandidates: [AXCandidate]
                if topWin.ownerPID == selfPID {
                    sourceCandidates = (selfSubviewCandidatesByWindow[topWin.windowID] ?? []).filter { $0.rect.contains(map.global) }
                } else if axTrusted {
                    sourceCandidates = queryAXRaw(pid: topWin.ownerPID, at: map.global, clampTo: topWin.globalBounds)
                } else {
                    sourceCandidates = []
                }

                for cand in sourceCandidates {
                    let lr = toLocalRect(cand.rect, screenQuartzOrigin: map.origin).intersection(winLocal)
                    guard !lr.isNull, lr.contains(localPoint) else { continue }
                    if !cand.isLeafControl && Self.isWindowChromeStrip(lr, in: winLocal) { continue }
                    if nearRim && !(cand.isLeafControl && lr.width <= 120 && lr.height <= 48) { continue }

                    let area = lr.width * lr.height
                    let areaRatio = area / max(1, winArea)
                    if areaRatio >= 0.96 { continue }

                    // 真实紧凑交互控件（图标按钮/标签/输入框）与中小图片直接信任；所有结构容器（AXGroup/AXScrollArea/AXWebArea/AXRow 等）无论大小一律校验可见像素边界
                    let isCompactControl = cand.isLeafControl
                        && ((lr.width <= 240 && lr.height <= 64) || (lr.width <= 480 && lr.height <= 44))
                    let isCompactMedia = cand.isMediaLeaf && lr.width >= 18 && lr.height >= 18 && areaRatio < 0.35
                    if !isCompactControl && !isCompactMedia {
                        guard lr.width >= 32, lr.height >= 24,
                              VisualDetector.hasVisualBoundary(lr, within: winLocal, sampler: sampler, scale: snapshot.scaleFactor) else {
                            continue
                        }
                    } else {
                        hasCompactLeafHit = true
                    }

                    cands.append(lr)
                    let verifiedGlobal = CGRect(x: lr.minX + map.origin.x, y: lr.minY + map.origin.y, width: lr.width, height: lr.height)
                    verifiedCacheEntries.append(CachedRegion(globalRect: verifiedGlobal, isLeaf: isCompactControl || isCompactMedia))
                    if smallestInner == nil || area < (smallestInner!.width * smallestInner!.height) { smallestInner = lr }
                }

                let smallestArea = smallestInner.map { $0.width * $0.height } ?? winArea
                let needVisual = !nearRim && !hasCompactLeafHit && (smallestInner == nil || smallestArea > winArea * 0.15)
                if needVisual {
                    let scope = smallestInner ?? winLocal
                    let vRects = VisualDetector.detectVisualRects(at: localPoint, within: scope, sampler: sampler, scale: snapshot.scaleFactor)
                        .filter { !Self.isWindowChromeStrip($0, in: winLocal) }
                    cands.append(contentsOf: vRects)
                    for vr in vRects {
                        let vg = CGRect(x: vr.minX + map.origin.x, y: vr.minY + map.origin.y, width: vr.width, height: vr.height)
                        verifiedCacheEntries.append(CachedRegion(globalRect: vg, isLeaf: false))
                    }
                }

                if !verifiedCacheEntries.isEmpty {
                    storeVerifiedCache(verifiedCacheEntries, for: topWin.windowID)
                }
            }
        } else {
            cands.append(contentsOf: VisualDetector.detectVisualRects(at: localPoint, within: map.bounds, sampler: sampler, scale: snapshot.scaleFactor))
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
        return fullW && touchesBarEdge && r.height <= 72.0
    }

    private func queryAXRaw(pid: pid_t, at globalPoint: CGPoint, clampTo windowBounds: CGRect) -> [AXCandidate] {
        stateLock.lock()
        if (timeoutStrikes[pid] ?? 0) >= 3 { stateLock.unlock(); return [] }
        let appElem: AXUIElement = appElementCache[pid] ?? {
            let el = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(el, 0.024); appElementCache[pid] = el; return el
        }()
        stateLock.unlock()

        var timedOut = false
        let cands = RegionAXPreindexer.queryHierarchy(appElem: appElem, at: globalPoint, clampTo: windowBounds, timedOut: &timedOut)
        stateLock.lock()
        if timedOut {
            timeoutStrikes[pid] = (timeoutStrikes[pid] ?? 0) + 1
        } else {
            timeoutStrikes[pid] = 0
        }
        stateLock.unlock()
        return cands
    }

    private func storeVerifiedCache(_ entries: [CachedRegion], for windowID: CGWindowID) {
        stateLock.lock()
        var pool = spatialRectsByWindow[windowID] ?? []
        if pool.count < 120 {
            for item in entries {
                let r = item.globalRect
                if !pool.contains(where: {
                    abs($0.globalRect.minX - r.minX) <= 2 && abs($0.globalRect.minY - r.minY) <= 2
                        && abs($0.globalRect.width - r.width) <= 2 && abs($0.globalRect.height - r.height) <= 2
                }) {
                    pool.append(item)
                    if pool.count >= 120 { break }
                }
            }
            spatialRectsByWindow[windowID] = pool
        }
        stateLock.unlock()
    }

    private func toLocalRect(_ globalRect: CGRect, screenQuartzOrigin: CGPoint) -> CGRect {
        CGRect(x: globalRect.origin.x - screenQuartzOrigin.x, y: globalRect.origin.y - screenQuartzOrigin.y, width: globalRect.width, height: globalRect.height)
    }
}

// MARK: - 窗口与辅助功能元素异步预索引

/// 辅助功能层级候选（携带控件语义角色，供视觉边界校验精准区分真实交互控件与隐形布局容器）
struct AXCandidate: Sendable {
    let rect: CGRect
    let isLeafControl: Bool
    let isMediaLeaf: Bool
}

/// MSnip 自身可见窗口与内部卡片/控件的零 IPC 预快照（Quartz 全局坐标）
struct SelfWindowsSnapshot: Sendable {
    let windowBoundsByID: [CGWindowID: CGRect]
    let subviewCandidatesByWindowID: [CGWindowID: [AXCandidate]]
    static let empty = SelfWindowsSnapshot(windowBoundsByID: [:], subviewCandidatesByWindowID: [:])
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
        "AXStaticText", "AXInlineText", "AXLink", "AXHeading", "AXParagraph",
        "AXScrollBar", "AXValueIndicator", "AXSplitter", "AXMenuItemMarkChar",
        "AXMenuBar", "AXListMarker", "AXTextMarkerRange", "AXRuler", "AXRulerMarker",
        "AXGrowArea", "AXBusyIndicator", "AXProgressIndicator",
        "AXWindow", "AXApplication"
    ]

    private static let fineLeafRoles: Set<String> = [
        "AXButton", "AXDockItem", "AXMenuBarItem", "AXCheckBox",
        "AXRadioButton", "AXPopUpButton", "AXTextField", "AXSearchField",
        "AXTabButton", "AXDisclosureTriangle", "AXColorWell", "AXSlider",
        "AXMenuButton", "AXSegmentedControl", "AXIncrementor", "AXComboBox"
    ]

    private static let mediaLeafRoles: Set<String> = ["AXImage"]

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

    /// 按单点位置查询目标应用窗口内的带语义 AX 控件层级链（返回全局坐标候选数组）
    static func queryHierarchy(
        appElem: AXUIElement,
        at globalPoint: CGPoint,
        clampTo windowBounds: CGRect,
        timedOut: inout Bool
    ) -> [AXCandidate] {
        let t0 = CFAbsoluteTimeGetCurrent()
        var hitRef: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(appElem, Float(globalPoint.x), Float(globalPoint.y), &hitRef)
        if status == .cannotComplete, (CFAbsoluteTimeGetCurrent() - t0) >= 0.018 {
            timedOut = true
            return []
        }
        guard status == .success, var current = hitRef else { return [] }

        var candidates: [AXCandidate] = []
        let deadline = t0 + 0.045
        for _ in 0..<10 {
            // 已经成功命中真实节点后的父链遍历超时仅提前收敛，不误判为整进程卡死封禁（避免 Chrome/Electron 误触发 timeoutStrikes）
            if CFAbsoluteTimeGetCurrent() >= deadline { break }
            setFastTimeout(current, 0.015)
            var valuesRef: CFArray?
            let err = AXUIElementCopyMultipleAttributeValues(current, batchedAttrs, AXCopyMultipleAttributeOptions(rawValue: 0), &valuesRef)
            guard err == .success, let arr = valuesRef as? [AnyObject], arr.count == 4 else { break }

            let role = (arr[0] as? String) ?? ""
            if role == "AXWindow" || role == "AXApplication" { break }
            if !ignoredAXRoles.contains(role), let rawRect = unpackBounds(posObj: arr[1], sizeObj: arr[2]) {
                let clamped = rawRect.intersection(windowBounds)
                let isLeaf = fineLeafRoles.contains(role)
                let isMedia = mediaLeafRoles.contains(role)
                let minW: CGFloat = (isLeaf || isMedia) ? 16 : 36
                let minH: CGFloat = (isLeaf || isMedia) ? 16 : 26
                let maxAspectH: CGFloat = (isLeaf || isMedia) ? 20 : 18
                let maxAspectV: CGFloat = (isLeaf || isMedia) ? 14 : 12
                let aspectOK = clamped.width <= clamped.height * maxAspectH && clamped.height <= clamped.width * maxAspectV
                if !clamped.isNull, clamped.contains(globalPoint), clamped.width >= minW, clamped.height >= minH, aspectOK {
                    candidates.append(AXCandidate(rect: clamped, isLeafControl: isLeaf, isMediaLeaf: isMedia))
                }
            }

            let parentObj = arr[3]
            guard CFGetTypeID(parentObj) == AXUIElementGetTypeID() else { break }
            current = (parentObj as! AXUIElement)
        }
        return candidates
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
        var candsByWin: [CGWindowID: [AXCandidate]] = [:]
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
            var cands: [AXCandidate] = []
            collectVisualSubviewRects(in: root, window: win, windowQuartz: qWin, toQuartz: toQuartz, into: &cands)
            if !cands.isEmpty { candsByWin[winID] = cands }
        }
        return SelfWindowsSnapshot(windowBoundsByID: winMap, subviewCandidatesByWindowID: candsByWin)
    }

    @MainActor
    private static func collectVisualSubviewRects(
        in view: NSView, window: NSWindow, windowQuartz: CGRect,
        toQuartz: (NSRect) -> CGRect, into out: inout [AXCandidate]
    ) {
        guard !view.isHidden, view.alphaValue > 0.05, out.count < 200 else { return }
        let isPureLayoutWrapper = (view is NSScrollView) || (view is NSClipView) || (view is NSTextField)
            || (view is GeekFlippedView) || (view === window.contentView)
        if !isPureLayoutWrapper && view.bounds.width >= 18 && view.bounds.height >= 16 {
            let inWin = view.convert(view.bounds, to: nil).intersection(window.contentView?.bounds ?? .zero)
            if !inWin.isNull && inWin.width >= 18 && inWin.height >= 16 {
                let q = toQuartz(window.convertToScreen(inWin)).intersection(windowQuartz)
                let areaRatio = (q.width * q.height) / max(1, windowQuartz.width * windowQuartz.height)
                if !q.isNull && areaRatio < 0.94 {
                    let isLeaf = (view is NSControl)
                    out.append(AXCandidate(rect: q, isLeafControl: isLeaf, isMediaLeaf: view is NSImageView))
                }
            }
        }
        for sub in view.subviews {
            collectVisualSubviewRects(in: sub, window: window, windowQuartz: windowQuartz, toQuartz: toQuartz, into: &out)
        }
    }
}
