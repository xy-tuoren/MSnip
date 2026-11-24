import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MSnipCore

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
}
