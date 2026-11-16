import AppKit
import CoreGraphics
import Darwin
import Foundation
import MSnipCore
import ScreenCaptureKit

/// 单块显示器的冻结快照数据（像素采样器按需惰性解包，避免副屏白白拷贝数十 MB 位图缓冲）
final class ScreenSnapshot {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let cgImage: CGImage
    lazy var sampler: PixelSampler = PixelSampler(cgImage: cgImage)
    let scaleFactor: CGFloat

    init(screen: NSScreen, displayID: CGDirectDisplayID, cgImage: CGImage) {
        self.screen = screen
        self.displayID = displayID
        self.cgImage = cgImage
        let screenWidthPt = max(1.0, screen.frame.width)
        self.scaleFactor = CGFloat(cgImage.width) / screenWidthPt
    }
}

/// 跨 macOS 版本屏幕抓取引擎：
/// - macOS 14.0+ 使用官方 `ScreenCaptureKit` (`SCScreenshotManager`) 多屏并发抓图，原生支持 Retina 与 HDR 色调映射；
/// - macOS 12–13 自动回退 `CGDisplayCreateImage`（通过符号动态解析避开新 SDK 废弃编译限制）。
enum ScreenCapturer {
    /// 检查屏幕录制权限；若未授权则触发系统授权引导
    static func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        _ = CGRequestScreenCaptureAccess()
        return CGPreflightScreenCaptureAccess()
    }

    /// 抓取当前所有连接的显示器快照
    @MainActor
    static func captureAllScreens() async -> [ScreenSnapshot] {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return [] }

        if #available(macOS 14.0, *) {
            if let snapshots = await captureViaScreenCaptureKit(screens: screens), !snapshots.isEmpty {
                return snapshots
            }
        }
        return captureViaLegacyCoreGraphics(screens: screens)
    }

    @available(macOS 14.0, *)
    @MainActor
    private static func captureViaScreenCaptureKit(screens: [NSScreen]) async -> [ScreenSnapshot]? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return nil
        }
        var displayMap: [CGDirectDisplayID: SCDisplay] = [:]
        for d in content.displays {
            displayMap[d.displayID] = d
        }

        struct CaptureSpec: @unchecked Sendable {
            let index: Int
            let displayID: CGDirectDisplayID
            let filter: SCContentFilter
            let cfg: SCStreamConfiguration
        }

        var specs: [CaptureSpec] = []
        for (idx, screen) in screens.enumerated() {
            guard let id = screenDisplayID(screen), let scDisplay = displayMap[id] else { continue }
            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            cfg.width = Int((screen.frame.width * scale).rounded())
            cfg.height = Int((screen.frame.height * scale).rounded())
            cfg.showsCursor = false
            cfg.capturesAudio = false
            specs.append(CaptureSpec(index: idx, displayID: id, filter: filter, cfg: cfg))
        }
        guard !specs.isEmpty else { return nil }

        // 单显示器走零额外调度直通快径；多显示器使用 TaskGroup 并发抓屏
        if specs.count == 1 {
            let s = specs[0]
            guard let img = try? await SCScreenshotManager.captureImage(contentFilter: s.filter, configuration: s.cfg) else {
                return nil
            }
            return [ScreenSnapshot(screen: screens[s.index], displayID: s.displayID, cgImage: img)]
        }

        let capturedPairs: [(Int, CGDirectDisplayID, CGImage)] = await withTaskGroup(
            of: (Int, CGDirectDisplayID, CGImage)?.self
        ) { group in
            for s in specs {
                group.addTask {
                    guard let img = try? await SCScreenshotManager.captureImage(contentFilter: s.filter, configuration: s.cfg) else {
                        return nil
                    }
                    return (s.index, s.displayID, img)
                }
            }
            var out: [(Int, CGDirectDisplayID, CGImage)] = []
            for await item in group {
                if let item { out.append(item) }
            }
            return out
        }

        return capturedPairs
            .sorted { $0.0 < $1.0 }
            .map { ScreenSnapshot(screen: screens[$0.0], displayID: $0.1, cgImage: $0.2) }
    }

    @MainActor
    private static func captureViaLegacyCoreGraphics(screens: [NSScreen]) -> [ScreenSnapshot] {
        typealias LegacyCaptureFn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGDisplayCreateImage") else {
            return []
        }
        let createImage = unsafeBitCast(sym, to: LegacyCaptureFn.self)

        var results: [ScreenSnapshot] = []
        for screen in screens {
            guard let id = screenDisplayID(screen),
                  let unmanaged = createImage(id) else { continue }
            let img = unmanaged.takeRetainedValue()
            results.append(ScreenSnapshot(screen: screen, displayID: id, cgImage: img))
        }
        return results
    }

    private static func screenDisplayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

    /// 抓取单个独立应用窗口的纯净透明图层（剥离桌面背景与前后遮挡窗口，可选叠加 macOS 原生柔和悬浮阴影或渐变衬底）
    @MainActor
    static func captureIsolatedWindow(
        windowID: CGWindowID,
        scaleFactor: CGFloat,
        backdropStyle: BackdropStyle = .none
    ) async -> CGImage? {
        let scale = max(1.0, scaleFactor)
        if #available(macOS 14.0, *),
           let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
           let scWin = content.windows.first(where: { $0.windowID == windowID }) {
            let filter = SCContentFilter(desktopIndependentWindow: scWin)
            let cfg = SCStreamConfiguration()
            cfg.width = max(16, Int((scWin.frame.width * scale).rounded()))
            cfg.height = max(16, Int((scWin.frame.height * scale).rounded()))
            cfg.showsCursor = false
            cfg.capturesAudio = false
            cfg.shouldBeOpaque = false
            cfg.backgroundColor = .clear
            cfg.ignoreShadowsSingleWindow = true

            if let rawWin = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) {
                if backdropStyle != .none {
                    return BackdropBeautifier.apply(to: rawWin, style: backdropStyle, imageScale: scale, innerCornerRadiusPt: 12)
                }
                return BackdropBeautifier.applyTransparentWindowShadow(to: rawWin, imageScale: scale)
            }
        }

        // 回退路径：通过符号动态解析调用 CGWindowListCreateImage 抓取含原生阴影的独立窗口
        typealias LegacyWinCaptureFn = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            return nil
        }
        let fn = unsafeBitCast(sym, to: LegacyWinCaptureFn.self)
        let listOpt = CGWindowListOption.optionIncludingWindow.rawValue
        let imgOpt: UInt32 = (backdropStyle != .none) ? CGWindowImageOption.boundsIgnoreFraming.rawValue : 0
        guard let raw = fn(.null, listOpt, windowID, imgOpt)?.takeRetainedValue() else { return nil }
        if backdropStyle != .none {
            return BackdropBeautifier.apply(to: raw, style: backdropStyle, imageScale: scale, innerCornerRadiusPt: 12)
        }
        return raw
    }
}
