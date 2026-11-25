import AppKit
import Foundation
import MSnipCore

// 命令行单实例快传：若 MSnip 已在菜单栏常驻运行，则通过分布式通知即时转发动作并 0.01s 退出，杜绝重复图标
if let cmd = MSnipLaunchCommand.parse(arguments: CommandLine.arguments) {
    let myPID = ProcessInfo.processInfo.processIdentifier
    let bundleID = Bundle.main.bundleIdentifier ?? "top.xy.msnip"
    let alreadyRunning = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .contains { $0.processIdentifier != myPID }
    if alreadyRunning {
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
}

// 入口：菜单栏无主窗口常驻模式（不占用 Dock 栏，无轮询待机 0% CPU）
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = MainActor.assumeIsolated { AppController() }
app.delegate = controller
app.run()
