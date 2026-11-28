import AppKit
import Foundation
import MSnipCore

// 单实例快传：若 MSnip 已在菜单栏运行，带参数执行对应动作，无参数直接点击应用图标则呼出设置面板并 0.01s 退出
let myPID = ProcessInfo.processInfo.processIdentifier
let bundleID = Bundle.main.bundleIdentifier ?? "top.xy.msnip"
let alreadyRunning = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .contains { $0.processIdentifier != myPID }
if alreadyRunning {
    let cmd = MSnipLaunchCommand.parse(arguments: CommandLine.arguments) ?? .settings
    if cmd != .tray {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(MSnipLaunchCommand.ipcNotificationName),
            object: cmd.rawValue,
            userInfo: nil,
            deliverImmediately: true
        )
    }
    exit(0)
}

// 仅主实例挂载本地诊断日志（转发命令的第二实例 0.01s 即退出，不写日志）
DiagnosticLogging.bootstrap()

// 入口：菜单栏无主窗口常驻模式（不占用 Dock 栏，无轮询待机 0% CPU）
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = MainActor.assumeIsolated { AppController() }
app.delegate = controller
app.run()
