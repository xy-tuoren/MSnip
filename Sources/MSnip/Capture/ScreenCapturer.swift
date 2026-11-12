import AppKit
import CoreGraphics
import Darwin
import Foundation
import MSnipCore
import ScreenCaptureKit

/// 单块显示器的冻结快照数据
final class ScreenSnapshot {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let cgImage: CGImage
    let sampler: PixelSampler
    let scaleFactor: CGFloat

    init(screen: NSScreen, displayID: CGDirectDisplayID, cgImage: CGImage) {
        self.screen = screen
        self.displayID = displayID
        self.cgImage = cgImage
        self.sampler = PixelSampler(cgImage: cgImage)
        let screenWidthPt = max(1.0, screen.frame.width)
        self.scaleFactor = CGFloat(cgImage.width) / screenWidthPt
    }
}

/// 跨 macOS 版本屏幕抓取引擎：
/// - macOS 14.0+ 使用官方 `ScreenCaptureKit` (`SCScreenshotManager`)，原生支持 Retina 与 HDR 色调映射；
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

        var results: [ScreenSnapshot] = []
        for screen in screens {
            guard let id = screenDisplayID(screen), let scDisplay = displayMap[id] else { continue }
            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            cfg.width = Int((screen.frame.width * scale).rounded())
            cfg.height = Int((screen.frame.height * scale).rounded())
            cfg.showsCursor = false
            cfg.capturesAudio = false

            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) {
                results.append(ScreenSnapshot(screen: screen, displayID: id, cgImage: image))
            }
        }
        return results
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
}
