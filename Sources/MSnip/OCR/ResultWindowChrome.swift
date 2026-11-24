import AppKit
import Foundation

/// OCR 与 LaTeX 双栏窗口自适应深浅色调色板（浅色 Daylight Porcelain / 深色 Carbon Dark）
enum ResultTheme {
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { app in
            app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static let canvasBg       = dynamic(light: MSnipUITheme.canvasBg, dark: NSColor(srgbRed: 0.075, green: 0.086, blue: 0.106, alpha: 1.0))
    static let sidebarBg      = dynamic(light: MSnipUITheme.sidebarBg, dark: NSColor(srgbRed: 0.125, green: 0.145, blue: 0.180, alpha: 1.0))
    static let cardSolid      = dynamic(light: MSnipUITheme.cardSolid, dark: NSColor(srgbRed: 0.106, green: 0.122, blue: 0.153, alpha: 1.0))
    static let subtleFill     = dynamic(light: MSnipUITheme.subtleFill, dark: NSColor(srgbRed: 0.137, green: 0.157, blue: 0.196, alpha: 1.0))
    static let transWellFill  = dynamic(light: MSnipUITheme.transWellFill, dark: NSColor(srgbRed: 0.094, green: 0.125, blue: 0.180, alpha: 1.0))
    static let activeSoftFill = dynamic(light: MSnipUITheme.activeSoftFill, dark: NSColor(srgbRed: 0.140, green: 0.480, blue: 0.980, alpha: 0.22))
    static let borderHairline = dynamic(light: MSnipUITheme.borderHairline, dark: NSColor.white.withAlphaComponent(0.09))
    static let borderStrong   = dynamic(light: MSnipUITheme.borderStrong, dark: NSColor.white.withAlphaComponent(0.16))
    static let inkPrimary     = dynamic(light: MSnipUITheme.inkPrimary, dark: NSColor(srgbRed: 0.933, green: 0.949, blue: 0.973, alpha: 1.0))
    static let inkSecondary   = dynamic(light: MSnipUITheme.inkSecondary, dark: NSColor(srgbRed: 0.650, green: 0.695, blue: 0.765, alpha: 1.0))
    static let inkMuted       = dynamic(light: MSnipUITheme.inkMuted, dark: NSColor(srgbRed: 0.490, green: 0.540, blue: 0.615, alpha: 1.0))
    static let inkTrans       = dynamic(light: MSnipUITheme.inkTrans, dark: NSColor(srgbRed: 0.815, green: 0.895, blue: 1.000, alpha: 1.0))
    static let accent         = dynamic(light: MSnipUITheme.accent, dark: NSColor(srgbRed: 0.290, green: 0.610, blue: 1.000, alpha: 1.0))

    static func cgColor(_ color: NSColor, dark: Bool) -> CGColor {
        let app = NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        var resolved: CGColor = color.cgColor
        app.performAsCurrentDrawingAppearance { resolved = color.cgColor }
        return resolved
    }
}

/// OCR 与 LaTeX 双栏对照窗口的持久化外观配置（默认常规层级不强占前景，可一键切换置顶与深浅外观，并记忆窗口位置与尺寸）
enum ResultWindowKind: String {
    case ocr
    case latex

    private var frameKey: String { "MSnip.ResultWindow.frame.\(rawValue)" }
    private var pinKey: String { "MSnip.ResultWindow.alwaysOnTop.\(rawValue)" }

    var isAlwaysOnTop: Bool {
        get { UserDefaults.standard.bool(forKey: pinKey) }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: pinKey) }
    }

    @MainActor
    func resolveInitialFrame(defaultSize: NSSize, minSize: NSSize, on screen: NSScreen) -> NSRect {
        if let raw = UserDefaults.standard.string(forKey: frameKey) {
            var saved = NSRectFromString(raw)
            if saved.width >= minSize.width, saved.height >= minSize.height {
                if let host = NSScreen.screens.first(where: {
                    let inter = $0.visibleFrame.intersection(saved)
                    return !inter.isNull && inter.width >= 120 && inter.height >= 80
                }) {
                    let vf = host.visibleFrame
                    saved.size.width = min(saved.width, vf.width)
                    saved.size.height = min(saved.height, vf.height)
                    saved.origin.x = min(max(vf.minX, saved.origin.x), vf.maxX - saved.width)
                    saved.origin.y = min(max(vf.minY, saved.origin.y), vf.maxY - saved.height)
                    return saved.integral
                }
            }
        }
        let vf = screen.visibleFrame
        let w = min(defaultSize.width, vf.width)
        let h = min(defaultSize.height, vf.height)
        return NSRect(x: round(vf.midX - w * 0.5), y: round(vf.midY - h * 0.5), width: w, height: h)
    }

    func saveFrame(_ frame: NSRect) {
        guard frame.width >= 300, frame.height >= 200 else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: frameKey)
    }
}

/// OCR / LaTeX 对照窗口共用标题栏置顶按钮、深浅色外观切换、窗口层级控制与卡片工厂
enum ResultWindowChrome {
    private static let appearanceKey = "MSnip.ResultWindow.appearanceMode"

    @MainActor
    static var prefersDarkAppearance: Bool {
        get {
            if let raw = UserDefaults.standard.string(forKey: appearanceKey) {
                return raw == "dark"
            }
            return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        set {
            UserDefaults.standard.set(newValue ? "dark" : "light", forKey: appearanceKey)
        }
    }

    @MainActor
    static func applyAppearance(to window: NSWindow, dark: Bool) {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = ResultTheme.canvasBg
        window.contentView?.layer?.backgroundColor = ResultTheme.cgColor(ResultTheme.canvasBg, dark: dark)
    }

    @MainActor
    static func applyWindowLevel(to window: NSWindow, alwaysOnTop: Bool) {
        if alwaysOnTop {
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        } else {
            window.level = .normal
            window.collectionBehavior = [.moveToActiveSpace]
        }
    }

    @MainActor
    static func syncPinButton(_ button: OCRPillButton, alwaysOnTop: Bool) {
        button.isToggledOn = alwaysOnTop
        button.symbolName = alwaysOnTop ? "pin.fill" : "pin"
        button.toolTip = alwaysOnTop
            ? "当前已置顶浮于其他窗口上方（点击取消置顶）"
            : "置顶此窗口（默认常规层级，允许切换其他应用自然覆盖）"
    }

    @MainActor
    static func syncThemeButton(_ button: OCRPillButton, dark: Bool) {
        button.symbolName = dark ? "sun.max" : "moon"
        button.toolTip = dark ? "当前深色外观（点击切换为浅色瓷白外观）" : "当前浅色外观（点击切换为深色极客外观）"
        button.needsDisplay = true
    }

    @MainActor
    static func makePinButton(kind: ResultWindowKind, windowProvider: @escaping () -> NSWindow?) -> OCRPillButton {
        let initial = kind.isAlwaysOnTop
        let btn = OCRPillButton(title: "", symbol: initial ? "pin.fill" : "pin")
        syncPinButton(btn, alwaysOnTop: initial)
        btn.onClick = { [weak btn] in
            let next = !kind.isAlwaysOnTop
            kind.isAlwaysOnTop = next
            if let btn { syncPinButton(btn, alwaysOnTop: next) }
            if let win = windowProvider() { applyWindowLevel(to: win, alwaysOnTop: next) }
        }
        return btn
    }

    @MainActor
    static func makeThemeButton(onToggle: @escaping (Bool) -> Void) -> OCRPillButton {
        let initial = prefersDarkAppearance
        let btn = OCRPillButton(title: "", symbol: initial ? "sun.max" : "moon")
        syncThemeButton(btn, dark: initial)
        btn.onClick = { [weak btn] in
            let next = !prefersDarkAppearance
            prefersDarkAppearance = next
            if let btn { syncThemeButton(btn, dark: next) }
            onToggle(next)
        }
        return btn
    }

    static func makeLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let lbl = NSTextField(labelWithString: text)
        lbl.font = NSFont.systemFont(ofSize: size, weight: weight)
        lbl.textColor = color
        return lbl
    }

    static func makeCardContainer(cornerRadius: CGFloat = 11) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = cornerRadius
        v.layer?.borderWidth = 1.0
        return v
    }

    static func styleCardLayer(_ view: NSView?, dark: Bool) {
        view?.layer?.backgroundColor = ResultTheme.cgColor(ResultTheme.cardSolid, dark: dark)
        view?.layer?.borderColor = ResultTheme.cgColor(ResultTheme.borderHairline, dark: dark)
    }

    static func invalidateSubtree(_ view: NSView) {
        view.needsDisplay = true
        for sub in view.subviews { invalidateSubtree(sub) }
    }
}
