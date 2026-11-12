import AppKit

// 入口：菜单栏无主窗口常驻模式（不占用 Dock 栏，无轮询待机 0% CPU）
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = MainActor.assumeIsolated { AppController() }
app.delegate = controller
app.run()
