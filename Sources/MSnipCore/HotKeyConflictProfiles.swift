import Carbon
import Foundation

/// 常见运行中第三方软件默认热键档案与标准配置解析器（`KeyboardShortcuts` / `Raycast` 等，100% 可单测）
public enum HotKeyConflictProfiles {
    private static let cmd = UInt32(cmdKey)
    private static let opt = UInt32(optionKey)
    private static let shift = UInt32(shiftKey)
    private static let ctrl = UInt32(controlKey)

    /// 常见第三方常驻工具默认热键档案（已校准真实 macOS Bundle ID，仅在对应 App 实际运行时触发）
    public static let knownApps: [KnownAppHotKeyProfile] = [
        .init(bundleIDPrefixes: ["com.depthpicture.PixPin", "com.pixpin"], appName: "PixPin", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_ANSI_1), carbonModifiers: opt), "截图"),
            (KeyCombo(keyCode: UInt32(kVK_ANSI_2), carbonModifiers: opt), "贴图")
        ]),
        .init(bundleIDPrefixes: ["com.tencent.xinWeChat"], appName: "微信", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: ctrl | cmd), "截图")
        ]),
        .init(bundleIDPrefixes: ["com.tencent.WeWorkMac"], appName: "企业微信", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: opt), "截图")
        ]),
        .init(bundleIDPrefixes: ["com.tencent.qq"], appName: "QQ", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: ctrl | cmd), "截图")
        ]),
        .init(bundleIDPrefixes: ["com.alibaba.DingTalkMac"], appName: "钉钉", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: shift | cmd), "截图")
        ]),
        .init(bundleIDPrefixes: ["com.electron.lark", "com.bytedance.feishu"], appName: "飞书", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: shift | cmd), "截图")
        ]),
        .init(bundleIDPrefixes: ["com.1password.1password"], appName: "1Password", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: shift | cmd), "快速访问"),
            (KeyCombo(keyCode: UInt32(kVK_ANSI_Backslash), carbonModifiers: cmd), "自动填充")
        ]),
        .init(bundleIDPrefixes: ["com.openai.chat", "com.openai.codex"], appName: "ChatGPT", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: opt), "唤起对话")
        ]),
        .init(bundleIDPrefixes: ["com.ripperhe.Bob", "com.hezongyidev.Bob"], appName: "Bob", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: opt), "划词翻译"),
            (KeyCombo(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: opt), "截图翻译"),
            (KeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: opt), "输入翻译")
        ]),
        .init(bundleIDPrefixes: ["com.izual.Easydict"], appName: "Easydict", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: opt), "划词翻译"),
            (KeyCombo(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: opt), "截图翻译"),
            (KeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: opt), "输入翻译")
        ]),
        .init(bundleIDPrefixes: ["com.Snipaste"], appName: "Snipaste", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_F1), carbonModifiers: 0), "截图"),
            (KeyCombo(keyCode: UInt32(kVK_F3), carbonModifiers: 0), "贴图")
        ]),
        .init(bundleIDPrefixes: ["cc.ffitch.shottr"], appName: "Shottr", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_ANSI_2), carbonModifiers: shift | cmd), "区域截图")
        ]),
        .init(bundleIDPrefixes: ["cn.better365.ishot"], appName: "iShot", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: opt), "截图")
        ]),
        .init(bundleIDPrefixes: ["com.xnipapp.xnip"], appName: "Xnip", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_ANSI_X), carbonModifiers: shift | cmd), "截图")
        ]),
        .init(bundleIDPrefixes: ["pl.maketheweb.cleanshotx"], appName: "CleanShot X", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_ANSI_4), carbonModifiers: shift | cmd), "区域截图"),
            (KeyCombo(keyCode: UInt32(kVK_ANSI_5), carbonModifiers: shift | cmd), "录屏菜单")
        ]),
        .init(bundleIDPrefixes: ["com.raycast.macos"], appName: "Raycast", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: opt), "呼出")
        ]),
        .init(bundleIDPrefixes: ["com.runningwithcrayons.Alfred"], appName: "Alfred", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: opt), "呼出")
        ]),
        .init(bundleIDPrefixes: ["org.p0deje.Maccy"], appName: "Maccy", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: shift | cmd), "剪贴板历史")
        ]),
        .init(bundleIDPrefixes: ["com.wiheads.paste"], appName: "Paste", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: shift | cmd), "剪贴板历史")
        ])
    ]

    /// 解析 macOS 开源社区通用的 `KeyboardShortcuts` UserDefaults JSON（`{"carbonKeyCode":1,"carbonModifiers":2048}`）
    public static func parseKeyboardShortcutsJSON(_ raw: String) -> KeyCombo? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = obj["carbonKeyCode"] as? Int,
              let mods = obj["carbonModifiers"] as? Int,
              KeyCombo.isDisplayableKeyCode(code) else { return nil }
        let mask = UInt32(mods) & (cmd | opt | shift | ctrl)
        guard mask != 0 || KeyCombo.isFunctionOrNavKey(code) else { return nil }
        return KeyCombo(keyCode: UInt32(code), carbonModifiers: mask)
    }

    /// 解析 Raycast 等应用的 `raycastGlobalHotkey` 字符串（如 `"Option-49"`、`"Command-Shift-0"`）
    public static func parseRaycastHotkeyString(_ raw: String) -> KeyCombo? {
        let parts = raw.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, let code = Int(last), KeyCombo.isDisplayableKeyCode(code) else { return nil }
        var mask: UInt32 = 0
        for p in parts.dropLast() {
            switch p.lowercased() {
            case "command", "cmd": mask |= cmd
            case "option", "opt", "alt": mask |= opt
            case "shift": mask |= shift
            case "control", "ctrl": mask |= ctrl
            default: break
            }
        }
        guard mask != 0 || KeyCombo.isFunctionOrNavKey(code) else { return nil }
        return KeyCombo(keyCode: UInt32(code), carbonModifiers: mask)
    }

    /// 所有 macOS 应用通用的高频菜单快捷键（设为全局热键会拦截前台所有应用）
    public static func commonAppShortcut(for combo: KeyCombo) -> (short: String, detail: String, requiresConfirm: Bool)? {
        let code = Int(combo.keyCode)
        if combo.carbonModifiers == cmd {
            let map: [Int: (String, String, Bool)] = [
                kVK_ANSI_C: ("拦截复制", "通用「复制 (⌘C)」", true),
                kVK_ANSI_V: ("拦截粘贴", "通用「粘贴 (⌘V)」", true),
                kVK_ANSI_X: ("拦截剪切", "通用「剪切 (⌘X)」", true),
                kVK_ANSI_Z: ("拦截撤销", "通用「撤销 (⌘Z)」", true),
                kVK_ANSI_A: ("拦截全选", "通用「全选 (⌘A)」", true),
                kVK_ANSI_S: ("拦截保存", "通用「保存 (⌘S)」", true),
                kVK_ANSI_W: ("拦截关闭", "通用「关闭窗口 (⌘W)」", true),
                kVK_ANSI_Q: ("拦截退出", "通用「退出应用 (⌘Q)」", true),
                kVK_ANSI_H: ("拦截隐藏", "通用「隐藏应用 (⌘H)」", true),
                kVK_ANSI_M: ("拦截最小化", "通用「最小化 (⌘M)」", true),
                kVK_ANSI_N: ("拦截新建", "通用「新建 (⌘N)」", false),
                kVK_ANSI_T: ("拦截新标签", "通用「新标签页 (⌘T)」", false),
                kVK_ANSI_R: ("拦截刷新", "通用「刷新 (⌘R)」", false),
                kVK_ANSI_F: ("拦截查找", "通用「查找 (⌘F)」", false),
                kVK_ANSI_P: ("拦截打印", "通用「打印 (⌘P)」", false),
                kVK_ANSI_Comma: ("拦截偏好", "通用「应用设置 (⌘,)」", false),
                kVK_ANSI_1: ("拦截标签 1", "浏览器/编辑器「标签 1 (⌘1)」", false),
                kVK_ANSI_2: ("拦截标签 2", "浏览器/编辑器「标签 2 (⌘2)」", false),
                kVK_ANSI_3: ("拦截标签 3", "浏览器/编辑器「标签 3 (⌘3)」", false)
            ]
            if let hit = map[code] { return hit }
        }
        if combo.carbonModifiers == (cmd | shift) {
            if code == kVK_ANSI_Z { return ("拦截重做", "通用「重做 (⇧⌘Z)」", false) }
            if code == kVK_ANSI_P { return ("拦截命令板", "编辑器「命令面板 (⇧⌘P)」", false) }
        }
        return nil
    }

    /// 将 `KeyboardShortcuts_<feature>` 键名清洗为可读标签
    public static func humanizeShortcutKeyName(_ key: String) -> String {
        let trimmed = key.hasPrefix("KeyboardShortcuts_")
            ? String(key.dropFirst("KeyboardShortcuts_".count))
            : key
        return trimmed.isEmpty ? "自定义热键" : trimmed
    }
}
