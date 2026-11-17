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

/// 三层融合智能区域探测器：
/// 1. 窗口层：`CGWindowListCopyWindowInfo` 按真实 Z 序瞬时命中顶层窗口（零额外权限）；
/// 2. 控件层：若已开启辅助功能权限，通过窗口 `ownerPID` 穿透我方全屏覆盖层直查 `AXUIElement` 父子矩阵链；
/// 3. 视觉层：`VisualDetector` 基于冻结像素射线识别卡片/按钮/图片边界（无权限或自绘界面兜底）。
final class RegionDetector {
    private let windows: [WindowSnapshotItem]
    private let primaryScreenHeight: CGFloat
    private let axTrusted: Bool

    // 4pt 网格缓存，避免鼠标在同一微小区域高频重算
    private var lastGridKey: (Int, Int, CGDirectDisplayID)?
    private var cachedHierarchy: [CGRect] = []
    private var appElementCache: [pid_t: AXUIElement] = [:]
    private var unresponsivePIDs: Set<pid_t> = []

    init(windows: [WindowSnapshotItem], primaryScreenHeight: CGFloat) {
        self.windows = windows
        self.primaryScreenHeight = primaryScreenHeight
        self.axTrusted = AXIsProcessTrusted()
    }

    /// 在覆盖层窗口创建之前调用，拍下当前所有可见窗口的 Z 序几何快照
    static func captureBeforeOverlay() -> RegionDetector {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let selfPID = ProcessInfo.processInfo.processIdentifier

        let rawList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var pidBundleCache: [pid_t: String] = [:]
        let ignoredShellBundles: Set<String> = [
            "com.apple.dock", "com.apple.WindowManager", "com.apple.wallpaper.agent", "com.apple.notificationcenterui"
        ]

        var items: [WindowSnapshotItem] = []
        for entry in rawList {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != selfPID,
                  let rawWinID = entry[kCGWindowNumber as String] as? UInt32 else { continue }
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1.0
            // 仅保留正常应用窗口、悬浮面板、菜单栏与弹窗（过滤透明遮罩与桌面底层背景）
            guard alpha > 0.05, layer >= 0, layer < 500 else { continue }
            guard let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict),
                  rect.width >= 20, rect.height >= 20 else { continue }

            let ownerName = entry[kCGWindowOwnerName as String] as? String ?? ""
            if ownerName == "Window Server" && rect.height > 80 { continue }
            let bundleID: String = {
                if let cached = pidBundleCache[pid] { return cached }
                let resolved = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
                pidBundleCache[pid] = resolved
                return resolved
            }()
            // 过滤程序坞 (Dock) 与台前调度 (WindowManager) 覆盖全屏的透明容器层，避免遮挡真实应用窗口
            if ignoredShellBundles.contains(bundleID) && rect.width > 400 && rect.height > 400 { continue }

            items.append(WindowSnapshotItem(
                windowID: CGWindowID(rawWinID), ownerPID: pid, ownerName: ownerName, globalBounds: rect, layer: layer
            ))
        }
        return RegionDetector(windows: items, primaryScreenHeight: primaryH)
    }

    /// 检查辅助功能权限状态；`prompt=true` 时触发系统辅助功能授权引导框
    static func checkAccessibilityPermission(prompt: Bool) -> Bool {
        if prompt {
            let key = "AXTrustedCheckOptionPrompt" as CFString
            let opts = [key: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(opts)
        }
        return AXIsProcessTrusted()
    }

    /// 查询鼠标局部点正下方命中的最顶层独立应用窗口（供纯净透明阴影窗口截图使用）
    func topWindow(at localPoint: CGPoint, in snapshot: ScreenSnapshot) -> (windowID: CGWindowID, ownerName: String, localRect: CGRect)? {
        let screenFrame = snapshot.screen.frame
        let screenBoundsLocal = CGRect(origin: .zero, size: screenFrame.size)
        guard screenBoundsLocal.contains(localPoint) else { return nil }
        let screenQuartzOrigin = CGPoint(x: screenFrame.minX, y: primaryScreenHeight - screenFrame.maxY)
        let globalPoint = CGPoint(x: screenQuartzOrigin.x + localPoint.x, y: screenQuartzOrigin.y + localPoint.y)
        guard let hit = windows.first(where: { $0.globalBounds.contains(globalPoint) }) else { return nil }
        let localRect = toLocalRect(hit.globalBounds, screenQuartzOrigin: screenQuartzOrigin).intersection(screenBoundsLocal)
        guard !localRect.isNull, localRect.width >= 24, localRect.height >= 24 else { return nil }
        return (hit.windowID, hit.ownerName, localRect)
    }

    /// 查询指定显示器 `snapshot` 上局部点 `localPoint`（左上角原点）处的嵌套矩阵层级（从小到大排序）
    /// `fastWindowOnly = true` 时（高速扫过鼠标期间）仅执行 0.001ms 窗口 Z 序命中，完全跳过跨进程 AX IPC 阻塞
    func detectHierarchy(at localPoint: CGPoint, in snapshot: ScreenSnapshot, fastWindowOnly: Bool = false) -> [CGRect] {
        let screenFrame = snapshot.screen.frame
        let screenBoundsLocal = CGRect(origin: .zero, size: screenFrame.size)
        guard screenBoundsLocal.contains(localPoint) else { return [screenBoundsLocal] }

        if !fastWindowOnly {
            let gx = Int((localPoint.x / 6.0).rounded())
            let gy = Int((localPoint.y / 6.0).rounded())
            let key = (gx, gy, snapshot.displayID)
            if let last = lastGridKey, last == key, !cachedHierarchy.isEmpty {
                return cachedHierarchy
            }
        }

        // 将当前显示器的覆盖层局部坐标换算为 Quartz 全局坐标（主屏左上角为原点）
        let screenQuartzOrigin = CGPoint(
            x: screenFrame.minX,
            y: primaryScreenHeight - screenFrame.maxY
        )
        let globalPoint = CGPoint(
            x: screenQuartzOrigin.x + localPoint.x,
            y: screenQuartzOrigin.y + localPoint.y
        )

        if fastWindowOnly {
            if let topWin = windows.first(where: { $0.globalBounds.contains(globalPoint) }) {
                let winLocal = toLocalRect(topWin.globalBounds, screenQuartzOrigin: screenQuartzOrigin).intersection(screenBoundsLocal)
                if !winLocal.isNull, winLocal.width >= 24, winLocal.height >= 24 {
                    return VisualDetector.normalizeHierarchy([winLocal, screenBoundsLocal])
                }
            }
            return [screenBoundsLocal]
        }

        let gx = Int((localPoint.x / 6.0).rounded())
        let gy = Int((localPoint.y / 6.0).rounded())
        let key = (gx, gy, snapshot.displayID)

        var candidatesLocal: [CGRect] = [screenBoundsLocal]

        // 1) Z 序命中鼠标正下方最顶层的可见窗口（自动屏蔽被遮挡的下层窗口）
        if let topWindow = windows.first(where: { $0.globalBounds.contains(globalPoint) }) {
            let winLocal = toLocalRect(topWindow.globalBounds, screenQuartzOrigin: screenQuartzOrigin)
                .intersection(screenBoundsLocal)
            if !winLocal.isNull && winLocal.width >= 24 && winLocal.height >= 24 {
                candidatesLocal.append(winLocal)
                var smallestAXRect: CGRect?

                // 2) 辅助功能语义容器树：过滤文字碎片与小图标，仅保留按钮/输入框/卡片/分栏等有意义容器
                if axTrusted {
                    let axGlobalRects = queryAXHierarchy(
                        pid: topWindow.ownerPID,
                        at: globalPoint,
                        clampTo: topWindow.globalBounds
                    )
                    for gr in axGlobalRects {
                        let lr = toLocalRect(gr, screenQuartzOrigin: screenQuartzOrigin).intersection(winLocal)
                        guard !lr.isNull else { continue }
                        candidatesLocal.append(lr)
                        if smallestAXRect == nil || (lr.width * lr.height) < (smallestAXRect!.width * smallestAXRect!.height) {
                            smallestAXRect = lr
                        }
                    }
                }

                // 3) 闭合视觉框探测：仅在未开 AX 或 AX 仅命中大面积画布（如终端/画布/网页内嵌图）时补充探测
                let winArea = winLocal.width * winLocal.height
                let needVisual = (smallestAXRect == nil) || ((smallestAXRect!.width * smallestAXRect!.height) > winArea * 0.45)
                if needVisual {
                    let searchScope = smallestAXRect ?? winLocal
                    let visualRects = VisualDetector.detectVisualRects(
                        at: localPoint,
                        within: searchScope,
                        sampler: snapshot.sampler,
                        scale: snapshot.scaleFactor
                    )
                    candidatesLocal.append(contentsOf: visualRects)
                }
            }
        } else {
            let visualRects = VisualDetector.detectVisualRects(
                at: localPoint,
                within: screenBoundsLocal,
                sampler: snapshot.sampler,
                scale: snapshot.scaleFactor
            )
            candidatesLocal.append(contentsOf: visualRects)
        }

        let normalized = VisualDetector.normalizeHierarchy(candidatesLocal)
        lastGridKey = key
        cachedHierarchy = normalized.isEmpty ? [screenBoundsLocal] : normalized
        return cachedHierarchy
    }

    // MARK: - Accessibility Tree Query

    private static let ignoredAXRoles: Set<String> = [
        "AXStaticText", "AXInlineText", "AXLink", "AXHeading",
        "AXScrollBar", "AXValueIndicator", "AXSplitter", "AXMenuItemMarkChar"
    ]

    private static let batchedAXAttrs: CFArray = [
        kAXRoleAttribute as CFString,
        kAXPositionAttribute as CFString,
        kAXSizeAttribute as CFString,
        kAXParentAttribute as CFString
    ] as CFArray

    private func queryAXHierarchy(pid: pid_t, at globalPoint: CGPoint, clampTo windowBounds: CGRect) -> [CGRect] {
        guard !unresponsivePIDs.contains(pid) else { return [] }
        let appElem: AXUIElement = {
            if let cached = appElementCache[pid] { return cached }
            let created = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(created, 0.006) // 6ms 超紧上限，杜绝 Electron/浏览器深 DOM 树拖拽卡顿
            appElementCache[pid] = created
            return created
        }()

        let t0 = CFAbsoluteTimeGetCurrent()
        var hitRef: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(
            appElem,
            Float(globalPoint.x),
            Float(globalPoint.y),
            &hitRef
        )
        if status == .cannotComplete, (CFAbsoluteTimeGetCurrent() - t0) >= 0.005 {
            unresponsivePIDs.insert(pid)
            return []
        }
        guard status == .success, var current = hitRef else { return [] }

        var rects: [CGRect] = []
        for _ in 0..<10 {
            var valuesRef: CFArray?
            let err = AXUIElementCopyMultipleAttributeValues(
                current,
                Self.batchedAXAttrs,
                AXCopyMultipleAttributeOptions(rawValue: 0),
                &valuesRef
            )
            guard err == .success, let arr = valuesRef as? [AnyObject], arr.count == 4 else {
                break
            }

            let role = (arr[0] as? String) ?? ""
            if !Self.ignoredAXRoles.contains(role),
               let r = unpackAXBounds(posObj: arr[1], sizeObj: arr[2]) {
                let clamped = r.intersection(windowBounds)
                let minSizeOK = (role == "AXImage")
                    ? (clamped.width >= 48 && clamped.height >= 48)
                    : (clamped.width >= 36 && clamped.height >= 24)
                if !clamped.isNull, clamped.contains(globalPoint), minSizeOK {
                    rects.append(clamped)
                }
            }

            let parentObj = arr[3]
            guard CFGetTypeID(parentObj) == AXUIElementGetTypeID() else { break }
            current = (parentObj as! AXUIElement)
        }
        return rects
    }

    private func unpackAXBounds(posObj: AnyObject, sizeObj: AnyObject) -> CGRect? {
        guard CFGetTypeID(posObj) == AXValueGetTypeID(),
              CFGetTypeID(sizeObj) == AXValueGetTypeID() else {
            return nil
        }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        guard AXValueGetValue(posObj as! AXValue, .cgPoint, &pt),
              AXValueGetValue(sizeObj as! AXValue, .cgSize, &sz) else {
            return nil
        }
        return CGRect(origin: pt, size: sz)
    }

    private func toLocalRect(_ globalRect: CGRect, screenQuartzOrigin: CGPoint) -> CGRect {
        CGRect(
            x: globalRect.origin.x - screenQuartzOrigin.x,
            y: globalRect.origin.y - screenQuartzOrigin.y,
            width: globalRect.width,
            height: globalRect.height
        )
    }
}
