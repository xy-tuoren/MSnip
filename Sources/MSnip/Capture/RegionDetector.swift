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

/// 高速精准三层区域探测器（PixPin 级瞬时跟手架构）：
/// 1. 系统顶层预索引：程序坞（Dock 胶囊 + 全部 App 图标）与顶部菜单栏项 0.005ms 内存直出，凌驾于最大化窗口之上；
/// 2. 0ms 最新优先合并队列（Latest-Wins Coalescing）+ 空间缓存池：移动鼠标期间永不“防抖冻住”，同时自动丢弃过期中间点；
/// 3. 完整信任 macOS AX 控件边界 + 像素零偏移 `VisualDetector` 兜底（Electron / 自绘界面 / 无权限时无缝接管）。
final class RegionDetector: @unchecked Sendable {
    private let windows: [WindowSnapshotItem]
    private let chrome: SystemChromeSnapshot
    private let primaryScreenHeight: CGFloat
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

    init(windows: [WindowSnapshotItem], chrome: SystemChromeSnapshot, primaryScreenHeight: CGFloat, hasOpenPopupMenu: Bool = false) {
        self.windows = windows; self.chrome = chrome
        self.primaryScreenHeight = primaryScreenHeight; self.axTrusted = AXIsProcessTrusted()
        self.hasOpenPopupMenu = hasOpenPopupMenu
    }

    /// 在覆盖层窗口创建之前调用，并行采集可见窗口 Z 序 + 程序坞/菜单栏预索引
    static func captureBeforeOverlay(primaryScreenHeight: CGFloat? = nil, frontmostPID: pid_t? = nil) -> RegionDetector {
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
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != selfPID,
                  let rawWinID = entry[kCGWindowNumber as String] as? UInt32 else { continue }
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0.05, layer >= 0, layer < 500 else { continue }
            guard let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict),
                  rect.width >= 20, rect.height >= 20 else { continue }

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
            items.append(WindowSnapshotItem(windowID: CGWindowID(rawWinID), ownerPID: pid, ownerName: ownerName, globalBounds: rect, layer: layer))
        }
        let chrome = RegionAXPreindexer.captureSystemChrome(menuBarRects: menuBarRects, frontmostPID: frontPID, skipMenuBarScan: hasOpenPopupMenu)
        return RegionDetector(windows: items, chrome: chrome, primaryScreenHeight: primaryH, hasOpenPopupMenu: hasOpenPopupMenu)
    }

    static func checkAccessibilityPermission(prompt: Bool) -> Bool {
        if prompt {
            let key = "AXTrustedCheckOptionPrompt" as CFString
            return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        return AXIsProcessTrusted()
    }

    /// 查询鼠标局部点正下方命中的最顶层独立应用窗口（供独立窗口透明阴影抓拍与窗口标识使用）
    func topWindow(at localPoint: CGPoint, in snapshot: ScreenSnapshot) -> (windowID: CGWindowID, ownerName: String, localRect: CGRect)? {
        let screenFrame = snapshot.screen.frame
        let screenBoundsLocal = CGRect(origin: .zero, size: screenFrame.size)
        guard screenBoundsLocal.contains(localPoint) else { return nil }
        let origin = CGPoint(x: screenFrame.minX, y: primaryScreenHeight - screenFrame.maxY)
        let globalPoint = CGPoint(x: origin.x + localPoint.x, y: origin.y + localPoint.y)
        guard let hit = windows.first(where: { $0.globalBounds.contains(globalPoint) }) else { return nil }
        let localRect = toLocalRect(hit.globalBounds, screenQuartzOrigin: origin).intersection(screenBoundsLocal)
        guard !localRect.isNull, localRect.width >= 24, localRect.height >= 24 else { return nil }
        return (hit.windowID, hit.ownerName, localRect)
    }

    /// 0.005ms 纯内存快查：优先命中预索引的程序坞/菜单栏，其次命中空间缓存池或窗口几何（永不阻塞主线程）
    func fastMemoryHierarchy(at localPoint: CGPoint, in snapshot: ScreenSnapshot) -> (stack: [CGRect], isComplete: Bool, winRect: CGRect?) {
        let screenFrame = snapshot.screen.frame
        let screenBoundsLocal = CGRect(origin: .zero, size: screenFrame.size)
        guard screenBoundsLocal.contains(localPoint) else { return ([screenBoundsLocal], true, nil) }

        let origin = CGPoint(x: screenFrame.minX, y: primaryScreenHeight - screenFrame.maxY)
        let globalPoint = CGPoint(x: origin.x + localPoint.x, y: origin.y + localPoint.y)

        // 1) 顶层系统壳优先（Dock 胶囊/图标 与 顶部菜单栏/状态栏图标，凌驾于最大化应用窗口之上）
        if let chromeStack = chrome.matchLocalStack(at: globalPoint, screenQuartzOrigin: origin, screenBoundsLocal: screenBoundsLocal) {
            return (chromeStack, true, chromeStack.count >= 2 ? chromeStack[chromeStack.count - 2] : nil)
        }

        // 2) 应用窗口 + 空间缓存池快查
        guard let topWin = windows.first(where: { $0.globalBounds.contains(globalPoint) }) else {
            return ([screenBoundsLocal], false, nil)
        }
        let winLocal = toLocalRect(topWin.globalBounds, screenQuartzOrigin: origin).intersection(screenBoundsLocal)
        guard !winLocal.isNull, winLocal.width >= 24, winLocal.height >= 24 else {
            return ([screenBoundsLocal], false, nil)
        }

        var cands: [CGRect] = [winLocal, screenBoundsLocal]
        stateLock.lock()
        let pool = spatialRectsByPID[topWin.ownerPID] ?? []
        stateLock.unlock()
        for gr in pool where gr.contains(globalPoint) {
            let lr = toLocalRect(gr, screenQuartzOrigin: origin).intersection(winLocal)
            if !lr.isNull, lr.width >= 16, lr.height >= 16 { cands.append(lr) }
        }
        return (VisualDetector.normalizeHierarchy(cands), false, winLocal)
    }

    /// 0ms 最新优先合并后台查询：鼠标连续移动期间持续实时输出，自动丢弃过时中间点，彻底消除迟钝与积压
    func requestLatestHierarchy(
        at localPoint: CGPoint,
        in snapshot: ScreenSnapshot,
        completion: @escaping @MainActor ([CGRect], CGRect?) -> Void
    ) {
        let req = PendingQuery(localPoint: localPoint, snapshot: snapshot, completion: completion)
        stateLock.lock()
        pendingQuery = req
        if isWorkerBusy {
            stateLock.unlock()
            return
        }
        isWorkerBusy = true
        stateLock.unlock()

        detectQueue.async { [weak self] in
            self?.drainPendingQueries()
        }
    }

    /// 同步查询入口（供首帧快速窗口定位或点击兜底调用）
    func detectHierarchy(at localPoint: CGPoint, in snapshot: ScreenSnapshot, fastWindowOnly: Bool = false) -> [CGRect] {
        let screenFrame = snapshot.screen.frame
        let screenBoundsLocal = CGRect(origin: .zero, size: screenFrame.size)
        guard screenBoundsLocal.contains(localPoint) else { return [screenBoundsLocal] }
        let origin = CGPoint(x: screenFrame.minX, y: primaryScreenHeight - screenFrame.maxY)
        let globalPoint = CGPoint(x: origin.x + localPoint.x, y: origin.y + localPoint.y)

        if let chromeStack = chrome.matchLocalStack(at: globalPoint, screenQuartzOrigin: origin, screenBoundsLocal: screenBoundsLocal) {
            return chromeStack
        }
        if fastWindowOnly {
            if let topWin = windows.first(where: { $0.globalBounds.contains(globalPoint) }) {
                let winLocal = toLocalRect(topWin.globalBounds, screenQuartzOrigin: origin).intersection(screenBoundsLocal)
                if !winLocal.isNull, winLocal.width >= 24, winLocal.height >= 24 {
                    return VisualDetector.normalizeHierarchy([winLocal, screenBoundsLocal])
                }
            }
            return [screenBoundsLocal]
        }
        return computeFullHierarchy(at: localPoint, in: snapshot).stack
    }

    // MARK: - Private Worker & Core Detection

    private func drainPendingQueries() {
        while true {
            stateLock.lock()
            guard let req = pendingQuery else {
                isWorkerBusy = false
                stateLock.unlock()
                return
            }
            pendingQuery = nil
            stateLock.unlock()

            let res = computeFullHierarchy(at: req.localPoint, in: req.snapshot)
            Task { @MainActor in req.completion(res.stack, res.winRect) }
        }
    }

    private func computeFullHierarchy(at localPoint: CGPoint, in snapshot: ScreenSnapshot) -> (stack: [CGRect], winRect: CGRect?) {
        let screenFrame = snapshot.screen.frame
        let screenBoundsLocal = CGRect(origin: .zero, size: screenFrame.size)
        guard screenBoundsLocal.contains(localPoint) else { return ([screenBoundsLocal], nil) }

        let origin = CGPoint(x: screenFrame.minX, y: primaryScreenHeight - screenFrame.maxY)
        let globalPoint = CGPoint(x: origin.x + localPoint.x, y: origin.y + localPoint.y)

        if let chromeStack = chrome.matchLocalStack(at: globalPoint, screenQuartzOrigin: origin, screenBoundsLocal: screenBoundsLocal) {
            return (chromeStack, chromeStack.count >= 2 ? chromeStack[chromeStack.count - 2] : nil)
        }

        var candidatesLocal: [CGRect] = [screenBoundsLocal]
        var winLocalOut: CGRect?
        let samplerReady = snapshot.isSamplerReady

        if let topWin = windows.first(where: { $0.globalBounds.contains(globalPoint) }) {
            let winLocal = toLocalRect(topWin.globalBounds, screenQuartzOrigin: origin).intersection(screenBoundsLocal)
            if !winLocal.isNull && winLocal.width >= 24 && winLocal.height >= 24 {
                winLocalOut = winLocal
                candidatesLocal.append(winLocal)
                var smallestAX: CGRect?

                if axTrusted {
                    let axGlobalRects = queryAXCached(pid: topWin.ownerPID, at: globalPoint, clampTo: topWin.globalBounds)
                    for gr in axGlobalRects {
                        let lr = toLocalRect(gr, screenQuartzOrigin: origin).intersection(winLocal)
                        guard !lr.isNull else { continue }
                        candidatesLocal.append(lr)
                        if smallestAX == nil || (lr.width * lr.height) < (smallestAX!.width * smallestAX!.height) {
                            smallestAX = lr
                        }
                    }
                }

                // 仅当未命中精细 AX 控件（无权限、Electron 未开无障碍或命中大片画布 >40%）时启用像素视觉闭合框
                let winArea = winLocal.width * winLocal.height
                let needVisual = (smallestAX == nil) || ((smallestAX!.width * smallestAX!.height) > winArea * 0.40)
                if needVisual, samplerReady {
                    let scope = smallestAX ?? winLocal
                    let visualRects = VisualDetector.detectVisualRects(
                        at: localPoint, within: scope, sampler: snapshot.sampler, scale: snapshot.scaleFactor
                    )
                    candidatesLocal.append(contentsOf: visualRects)
                }
            }
        } else if samplerReady {
            candidatesLocal.append(contentsOf: VisualDetector.detectVisualRects(
                at: localPoint, within: screenBoundsLocal, sampler: snapshot.sampler, scale: snapshot.scaleFactor
            ))
        }

        let normalized = VisualDetector.normalizeHierarchy(candidatesLocal)
        return (normalized.isEmpty ? [screenBoundsLocal] : normalized, winLocalOut)
    }

    private func queryAXCached(pid: pid_t, at globalPoint: CGPoint, clampTo windowBounds: CGRect) -> [CGRect] {
        stateLock.lock()
        if (timeoutStrikes[pid] ?? 0) >= 3 { stateLock.unlock(); return [] }
        let appElem: AXUIElement = {
            if let cached = appElementCache[pid] { return cached }
            let created = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(created, 0.018)
            appElementCache[pid] = created
            return created
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
