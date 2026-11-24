import AppKit
import CoreGraphics
import Foundation

/// 剪贴板图像按前台应用与编辑器焦点动态投影策略
public enum ClipboardProjectionMode: Equatable, Sendable {
    /// 普通应用与编辑器编辑区/AI 聊天框：纯净 `[.png, .tiff]`，零路径干扰
    case imageOnly
    /// 访达（Finder）：`[.png, .tiff, .fileURL]`，支持文件夹内直接 `⌘V` 落盘 PNG
    case imageAndFileURL
    /// 独立终端或编辑器内置终端：
    /// 同时提供 `[.png, .tiff, .fileURL, .string]`，让 `⌘V` 粘贴无空格临时 PNG 路径且 `⌃V`/CLI 仍可直接读取 PNG 二进制
    case terminalImageAndPath
}

/// 线程安全惰性临时 PNG 路径盒（仅当终端或访达实际请求路径/文件时才落盘一次，并自动清理 2 小时前的旧临时文件）
public final class ClipboardFileBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedURL: URL?

    public init() {}

    public func materializeURL(cgImage: CGImage, scaleFactor: CGFloat) -> URL? {
        lock.lock()
        if let existing = cachedURL, FileManager.default.fileExists(atPath: existing.path) {
            lock.unlock()
            return existing
        }
        lock.unlock()

        guard let pngData = ClipboardImagePromise.encodePNG(cgImage: cgImage, scaleFactor: scaleFactor) else {
            return nil
        }
        let fm = FileManager.default
        // 使用系统临时目录（macOS 下为 /var/folders/.../T/，无论用户名是否含空格均无空格）
        let dir = fm.temporaryDirectory.appendingPathComponent("MSnipClipboard", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        pruneStaleFiles(in: dir)

        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let outURL = dir.appendingPathComponent("MSnip-\(df.string(from: Date())).png")
        do {
            try pngData.write(to: outURL, options: .atomic)
        } catch {
            return nil
        }

        lock.lock()
        cachedURL = outURL
        lock.unlock()
        return outURL
    }

    private func pruneStaleFiles(in dir: URL, maxAgeSeconds: TimeInterval = 7200) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-maxAgeSeconds)
        for u in urls {
            if let mtime = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               mtime < cutoff {
                try? fm.removeItem(at: u)
            }
        }
    }
}

/// 独立终端、代码编辑器/IDE 与访达的 Bundle ID 识别与投影策略判定（纯函数，100% 可单测）
public enum ClipboardTerminalAdapter {
    private static let exactTerminalBundleIDs: Set<String> = [
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.warp-stable",
        "dev.warp.warp-preview",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "io.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "org.tabby",
        "com.raphaelamorim.rio",
        "dev.commandline.waveterm",
        "com.termius-dmg.mac",
        "com.panic.prompt3",
        "org.electerm.electerm",
        "com.vandyke.securecrt",
        "com.kingtoolbox.windterm"
    ]

    private static let exactEditorBundleIDs: Set<String> = [
        "com.microsoft.vscode",
        "com.microsoft.vscodeinsiders",
        "com.microsoft.vscode.insiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.anysphere.cursor",
        "com.exafunction.windsurf",
        "com.codeium.windsurf",
        "com.google.antigravity",
        "com.trae.app",
        "com.bytedance.trae",
        "com.icube.trae",
        "cn.trae.app",
        "dev.kiro.desktop",
        "com.kiro.ide",
        "com.vscodium",
        "com.visualstudio.code.oss",
        "com.posit.positron",
        "com.voideditor.void",
        "dev.zed.zed",
        "dev.zed.zed-preview",
        "dev.zed.zed-nightly",
        "com.apple.dt.xcode",
        "com.google.android.studio",
        "com.panic.nova",
        "app.codeedit.codeedit",
        "austincondiff.codeedit",
        "fleet.app",
        "com.rstudio.desktop",
        "org.rstudio.rstudio",
        "org.gnu.emacs",
        "com.neovide.neovide",
        "com.qvacua.vimr",
        "org.vim.macvim"
    ]

    public static func isTerminalBundleID(_ bundleID: String?) -> Bool {
        guard let lower = normalized(bundleID) else { return false }
        if exactTerminalBundleIDs.contains(lower) { return true }
        let keywords = ["iterm", "ghostty", "wezterm", "alacritty", "kitty", "waveterm", "tabby", "termius", "cmux", "windterm"]
        return keywords.contains(where: { lower.contains($0) })
    }

    public static func isEditorBundleID(_ bundleID: String?) -> Bool {
        guard let lower = normalized(bundleID), !isTerminalBundleID(lower) else { return false }
        if exactEditorBundleIDs.contains(lower) { return true }
        let prefixes = ["com.jetbrains.", "com.sublimetext.", "com.microsoft.vscode", "dev.zed.zed", "com.google.antigravity"]
        if prefixes.contains(where: { lower.hasPrefix($0) }) { return true }
        let keywords = ["vscodium", "windsurf", "antigravity", "codeedit", "positron", "kiro.ide", "trae.app"]
        return keywords.contains(where: { lower.contains($0) })
    }

    public static func projectionMode(
        forBundleID bundleID: String?,
        adaptiveEnabled: Bool,
        editorFocus: EditorFocusClassification = .indeterminate
    ) -> ClipboardProjectionMode {
        guard adaptiveEnabled else { return .imageOnly }
        guard let lower = normalized(bundleID) else { return .imageOnly }
        if lower == "com.apple.finder" { return .imageAndFileURL }
        if isTerminalBundleID(lower) { return .terminalImageAndPath }
        if isEditorBundleID(lower) {
            return (editorFocus == .terminal) ? .terminalImageAndPath : .imageOnly
        }
        return .imageOnly
    }

    private static func normalized(_ bundleID: String?) -> String? {
        guard let raw = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw.lowercased()
    }
}
