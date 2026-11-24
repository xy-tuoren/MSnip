import AppKit
import CoreGraphics
import CoreVideo
import Darwin
import Foundation
import MSnipCore
import ScreenCaptureKit

/// 单块显示器的冻结快照数据（线程安全惰性解包采样器，窗口瞬时冻结后再后台预热）
final class ScreenSnapshot: @unchecked Sendable {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let cgImage: CGImage
    let scaleFactor: CGFloat

    private let samplerLock = NSLock()
    private var _sampler: PixelSampler?

    var isSamplerReady: Bool {
        samplerLock.lock()
        defer { samplerLock.unlock() }
        return _sampler != nil
    }

    var sampler: PixelSampler {
        samplerLock.lock()
        if let existing = _sampler {
            samplerLock.unlock()
            return existing
        }
        samplerLock.unlock()
        let created = PixelSampler(cgImage: cgImage)
        samplerLock.lock()
        if let existing = _sampler {
            samplerLock.unlock()
            return existing
        }
        _sampler = created
        samplerLock.unlock()
        return created
    }

    func preheatSamplerInBackground(completion: @escaping @MainActor () -> Void) {
        if isSamplerReady {
            Task { @MainActor in completion() }
            return
        }
        Task.detached(priority: .high) { [weak self] in
            guard let self else { return }
            _ = self.sampler
            await MainActor.run { completion() }
        }
    }

    init(screen: NSScreen, displayID: CGDirectDisplayID, cgImage: CGImage) {
        self.screen = screen
        self.displayID = displayID
        self.cgImage = cgImage
        let screenWidthPt = max(1.0, screen.frame.width)
        self.scaleFactor = CGFloat(cgImage.width) / screenWidthPt
    }
}

/// 跨 macOS 版本极速零色差屏幕抓取引擎：
/// - 缓存显示器 `SCContentFilter` 免除每次热键枚举窗口 IPC（延迟立降 50%），保留显示器原生 ICC 色彩空间实现 100% 原图零色差；
/// - 显示器热插拔或分辨率变化时自动失效重建缓存。
enum ScreenCapturer {
    @MainActor static var runtimeVerifiedAccess = false
    @MainActor private static var cachedDisplayFilters: [CGDirectDisplayID: AnyObject] = [:]
    @MainActor private static var screenObserverRegistered = false

    @MainActor
    private static func registerScreenObserverIfNeeded() {
        guard !screenObserverRegistered else { return }
        screenObserverRegistered = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { cachedDisplayFilters.removeAll() }
        }
    }

    @MainActor
    static func hasScreenCapturePermission() async -> Bool {
        if runtimeVerifiedAccess || CGPreflightScreenCaptureAccess() {
            runtimeVerifiedAccess = true
            return true
        }
        if #available(macOS 14.0, *) {
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
               !content.displays.isEmpty {
                runtimeVerifiedAccess = true
                for d in content.displays {
                    cachedDisplayFilters[d.displayID] = SCContentFilter(display: d, excludingWindows: [])
                }
                return true
            }
        }
        return false
    }

    @MainActor
    static func ensurePermission() -> Bool {
        if runtimeVerifiedAccess || CGPreflightScreenCaptureAccess() {
            runtimeVerifiedAccess = true
            return true
        }
        _ = CGRequestScreenCaptureAccess()
        return CGPreflightScreenCaptureAccess()
    }

    @MainActor
    static func captureAllScreens() async -> [ScreenSnapshot] {
        registerScreenObserverIfNeeded()
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return [] }
        return await captureScreens(screens)
    }

    /// 仅抓取指定单块显示器（供「重截上次区域」直通使用，跳过副屏抓拍与整屏位图解包）
    @MainActor
    static func captureScreen(displayID: CGDirectDisplayID) async -> ScreenSnapshot? {
        registerScreenObserverIfNeeded()
        let screens = NSScreen.screens
        guard let target = screens.first(where: { screenDisplayID($0) == displayID }) ?? screens.first else {
            return nil
        }
        return await captureScreens([target]).first
    }

    @MainActor
    private static func captureScreens(_ screens: [NSScreen]) async -> [ScreenSnapshot] {
        if #available(macOS 14.0, *) {
            if let sck = await captureViaScreenCaptureKit(screens: screens), !sck.isEmpty {
                runtimeVerifiedAccess = true
                return sck
            }
        }
        let legacy = captureViaLegacyCoreGraphics(screens: screens)
        if !legacy.isEmpty { runtimeVerifiedAccess = true }
        return legacy
    }

    @available(macOS 14.0, *)
    @MainActor
    private static func ensureDisplayFilters(for screens: [NSScreen]) async -> [CGDirectDisplayID: SCContentFilter]? {
        let neededIDs = screens.compactMap(screenDisplayID)
        var out: [CGDirectDisplayID: SCContentFilter] = [:]
        for id in neededIDs {
            if let hit = cachedDisplayFilters[id] as? SCContentFilter { out[id] = hit }
        }
        if out.count == neededIDs.count && !out.isEmpty { return out }

        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return nil
        }
        cachedDisplayFilters.removeAll()
        out.removeAll()
        for d in content.displays {
            let f = SCContentFilter(display: d, excludingWindows: [])
            cachedDisplayFilters[d.displayID] = f
            out[d.displayID] = f
        }
        return out
    }

    @available(macOS 14.0, *)
    @MainActor
    private static func captureViaScreenCaptureKit(screens: [NSScreen]) async -> [ScreenSnapshot]? {
        guard let filterMap = await ensureDisplayFilters(for: screens) else { return nil }

        struct CaptureSpec: @unchecked Sendable {
            let index: Int
            let displayID: CGDirectDisplayID
            let filter: SCContentFilter
            let cfg: SCStreamConfiguration
        }

        var specs: [CaptureSpec] = []
        for (idx, screen) in screens.enumerated() {
            guard let id = screenDisplayID(screen), let filter = filterMap[id] else { continue }
            let cfg = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            cfg.width = Int((screen.frame.width * scale).rounded())
            cfg.height = Int((screen.frame.height * scale).rounded())
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.showsCursor = false
            cfg.capturesAudio = false
            specs.append(CaptureSpec(index: idx, displayID: id, filter: filter, cfg: cfg))
        }
        guard !specs.isEmpty else { return nil }

        if specs.count == 1 {
            let s = specs[0]
            if let img = try? await SCScreenshotManager.captureImage(contentFilter: s.filter, configuration: s.cfg) {
                return [ScreenSnapshot(screen: screens[s.index], displayID: s.displayID, cgImage: img)]
            }
            // 若旧缓存 filter 因显示器状态变更失效，清理重试一次
            cachedDisplayFilters.removeAll()
            guard let fresh = await ensureDisplayFilters(for: screens), let f2 = fresh[s.displayID],
                  let img2 = try? await SCScreenshotManager.captureImage(contentFilter: f2, configuration: s.cfg) else {
                return nil
            }
            return [ScreenSnapshot(screen: screens[s.index], displayID: s.displayID, cgImage: img2)]
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
            for await item in group { if let item { out.append(item) } }
            return out
        }
        return capturedPairs.sorted { $0.0 < $1.0 }.map { ScreenSnapshot(screen: screens[$0.0], displayID: $0.1, cgImage: $0.2) }
    }

    @MainActor
    private static func captureViaLegacyCoreGraphics(screens: [NSScreen]) -> [ScreenSnapshot] {
        typealias LegacyCaptureFn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGDisplayCreateImage") else { return [] }
        let createImage = unsafeBitCast(sym, to: LegacyCaptureFn.self)
        return screens.compactMap { screen in
            guard let id = screenDisplayID(screen), let img = createImage(id)?.takeRetainedValue() else { return nil }
            return ScreenSnapshot(screen: screen, displayID: id, cgImage: img)
        }
    }

    private static func screenDisplayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID($0.uint32Value) }
    }

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
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
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

        typealias LegacyWinCaptureFn = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
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
