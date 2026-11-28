import Carbon
import Foundation

/// 全局热键冲突严重程度
public enum HotKeyConflictSeverity: Int, Comparable, Sendable {
    case warning = 1
    case blocking = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 单条热键冲突详情
public struct HotKeyConflict: Equatable, Sendable {
    public let severity: HotKeyConflictSeverity
    public let owner: String
    public let shortBadge: String
    public let detailMessage: String
    public let requiresDoublePressConfirm: Bool

    public init(
        severity: HotKeyConflictSeverity,
        owner: String,
        shortBadge: String,
        detailMessage: String,
        requiresDoublePressConfirm: Bool
    ) {
        self.severity = severity
        self.owner = owner
        self.shortBadge = shortBadge
        self.detailMessage = detailMessage
        self.requiresDoublePressConfirm = requiresDoublePressConfirm
    }
}

/// 已占用热键条目（用于设置页「冲突体检与已占热键一览」展示，明确区分实测与默认参考）
public struct OccupiedHotKeyEntry: Equatable, Sendable {
    public enum Category: Sendable { case system, runningApp }
    public enum SourceKind: Sendable {
        case systemLive
        case appConfigLive
        case runningAppDefault

        public var badgeTitle: String {
            switch self {
            case .systemLive:        return L("系统实测")
            case .appConfigLive:     return L("配置实测")
            case .runningAppDefault: return L("默认参考")
            }
        }
    }

    public let combo: KeyCombo
    public let owner: String
    public let feature: String
    public let category: Category
    public let sourceKind: SourceKind

    public init(
        combo: KeyCombo,
        owner: String,
        feature: String,
        category: Category,
        sourceKind: SourceKind? = nil
    ) {
        self.combo = combo
        self.owner = owner
        self.feature = feature
        self.category = category
        self.sourceKind = sourceKind ?? (category == .system ? .systemLive : .runningAppDefault)
    }
}

/// 常见运行中第三方软件默认热键定义
public struct KnownAppHotKeyProfile: Sendable {
    public let bundleIDPrefixes: [String]
    public let appName: String
    public let bindings: [(combo: KeyCombo, feature: String)]

    public init(bundleIDPrefixes: [String], appName: String, bindings: [(combo: KeyCombo, feature: String)]) {
        self.bundleIDPrefixes = bundleIDPrefixes
        self.appName = appName
        self.bindings = bindings
    }
}

/// 零依赖纯逻辑热键冲突识别与零冲突组合推荐引擎（100% 可单测）
public enum HotKeyConflictCatalog {
    private static let cmd = UInt32(cmdKey)
    private static let opt = UInt32(optionKey)
    private static let shift = UInt32(shiftKey)
    private static let ctrl = UInt32(controlKey)

    /// Apple Symbolic HotKey ID (`com.apple.symbolichotkeys`) 语义名称映射
    public static func symbolicHotKeyIDName(_ id: Int) -> String? {
        switch id {
        case 7:  return L("键盘聚焦菜单栏")
        case 8:  return L("键盘聚焦程序坞")
        case 9:  return L("键盘聚焦活动窗口")
        case 27: return L("切换同应用窗口")
        case 28: return L("系统全屏截图")
        case 29: return L("全屏截图到剪贴板")
        case 30: return L("系统区域截图")
        case 31: return L("区域截图到剪贴板")
        case 32, 34: return L("调度中心 (Mission Control)")
        case 33, 35: return L("应用程序窗口")
        case 36, 37: return L("显示桌面")
        case 52: return L("隐藏/显示程序坞 (Dock)")
        case 60: return L("切换上一个输入法")
        case 61: return L("切换下一个输入法")
        case 64: return L("聚焦搜索 (Spotlight)")
        case 65: return L("访达搜索窗口")
        case 70: return L("查询词典")
        case 79, 80: return L("向左切换桌面空间")
        case 81, 82: return L("向右切换桌面空间")
        case 98: return L("聚焦帮助菜单")
        case 118...126: return L("切换到桌面 %@", id - 117)
        case 160: return L("启动台 (Launchpad)")
        case 184: return L("系统截屏与录屏")
        case 190: return L("快速备忘录")
        default: return nil
        }
    }

    /// 按默认按键签名匹配 macOS 内置系统热键中文名称（供 `CopySymbolicHotKeys` 实时条目补全名称）
    public static func systemSignatureName(for combo: KeyCombo) -> String? {
        switch (Int(combo.keyCode), combo.carbonModifiers) {
        case (kVK_Space, cmd):               return L("聚焦搜索 (Spotlight)")
        case (kVK_Space, cmd | opt):         return L("访达搜索窗口")
        case (kVK_Space, ctrl):              return L("切换上一个输入法")
        case (kVK_Space, ctrl | opt):        return L("切换下一个输入法")
        case (kVK_Space, ctrl | cmd):        return L("表情与符号")
        case (kVK_ANSI_3, shift | cmd):      return L("系统全屏截图")
        case (kVK_ANSI_3, ctrl | shift | cmd): return L("全屏截图到剪贴板")
        case (kVK_ANSI_4, shift | cmd):      return L("系统区域截图")
        case (kVK_ANSI_4, ctrl | shift | cmd): return L("区域截图到剪贴板")
        case (kVK_ANSI_5, shift | cmd):      return L("系统截屏与录屏")
        case (kVK_ANSI_D, opt | cmd):        return L("隐藏/显示程序坞")
        case (kVK_ANSI_D, ctrl | cmd):       return L("查询词典")
        case (kVK_ANSI_Q, ctrl | cmd):       return L("锁定屏幕")
        case (kVK_Tab, cmd):                 return L("应用切换器")
        case (kVK_Tab, shift | cmd):         return L("反向切换应用")
        case (kVK_ANSI_Grave, cmd):          return L("切换同应用窗口")
        case (kVK_Escape, opt | cmd):        return L("强制退出应用")
        case (kVK_ANSI_Slash, shift | cmd):  return L("帮助菜单搜索")
        case (kVK_UpArrow, ctrl):            return L("调度中心")
        case (kVK_DownArrow, ctrl):          return L("应用程序窗口")
        case (kVK_LeftArrow, ctrl):          return L("切换左侧桌面")
        case (kVK_RightArrow, ctrl):         return L("切换右侧桌面")
        case (kVK_F11, 0):                   return L("显示桌面")
        default:                             return nil
        }
    }

    /// 所有 macOS 应用通用的高频菜单快捷键（委托至 `HotKeyConflictProfiles` 档案库）
    public static func commonAppShortcut(for combo: KeyCombo) -> (short: String, detail: String, requiresConfirm: Bool)? {
        HotKeyConflictProfiles.commonAppShortcut(for: combo)
    }

    /// 根据正在运行的 Bundle ID 集合生成第三方应用默认热键参考列表
    public static func runningAppEntries(for runningBundleIDs: Set<String>) -> [OccupiedHotKeyEntry] {
        var out: [OccupiedHotKeyEntry] = []
        for profile in HotKeyConflictProfiles.knownApps {
            let active = runningBundleIDs.contains { bid in
                profile.bundleIDPrefixes.contains { bid.lowercased().hasPrefix($0.lowercased()) }
            }
            guard active else { continue }
            for b in profile.bindings {
                out.append(OccupiedHotKeyEntry(
                    combo: b.combo,
                    owner: profile.appName,
                    feature: b.feature,
                    category: .runningApp,
                    sourceKind: .runningAppDefault
                ))
            }
        }
        return out
    }

    /// 综合评估单个热键的 4 类冲突来源（MSnip 内部 / macOS 系统 / Carbon 独占 / 运行中应用与通用快捷键）
    public static func evaluate(
        combo: KeyCombo,
        excluding slot: GlobalHotKeyAction?,
        ownBindings: [GlobalHotKeyAction: KeyCombo],
        systemEntries: [OccupiedHotKeyEntry],
        runningAppEntries: [OccupiedHotKeyEntry],
        carbonExclusiveOccupied: Bool
    ) -> [HotKeyConflict] {
        var results: [HotKeyConflict] = []

        for (action, bound) in ownBindings where action != slot && bound == combo {
            results.append(HotKeyConflict(
                severity: .blocking,
                owner: "MSnip",
                shortBadge: L("同「%@」冲突", action.title),
                detailMessage: L("%@ 已被 MSnip「%@」占用", combo.displayString, action.title),
                requiresDoublePressConfirm: false
            ))
        }

        if let sys = systemEntries.first(where: { $0.combo == combo }) {
            let short = sys.feature.count <= (MSnipL10n.usesEnglish ? 16 : 7) ? sys.feature : L("系统热键")
            results.append(HotKeyConflict(
                severity: .blocking,
                owner: "macOS",
                shortBadge: short,
                detailMessage: L("%@ 已被 macOS 系统「%@」占用", combo.displayString, sys.feature),
                requiresDoublePressConfirm: true
            ))
        } else if carbonExclusiveOccupied {
            results.append(HotKeyConflict(
                severity: .blocking,
                owner: L("系统/常驻应用"),
                shortBadge: L("已被独占"),
                detailMessage: L("%@ 已被系统或其他常驻应用独占注册", combo.displayString),
                requiresDoublePressConfirm: true
            ))
        }

        for app in runningAppEntries where app.combo == combo {
            let isLiveCfg = (app.sourceKind == .appConfigLive)
            let msg = isLiveCfg
                ? L("「%@」已配置热键（%@），会直接冲突", app.owner, app.feature)
                : L("「%@」运行中 · %@默认热键，可能冲突", app.owner, app.feature)
            results.append(HotKeyConflict(
                severity: isLiveCfg ? .blocking : .warning,
                owner: app.owner,
                shortBadge: isLiveCfg ? L("%@已占用", app.owner) : L("%@运行中", app.owner),
                detailMessage: msg,
                requiresDoublePressConfirm: isLiveCfg
            ))
        }

        if let common = commonAppShortcut(for: combo) {
            results.append(HotKeyConflict(
                severity: .warning,
                owner: L("通用快捷键"),
                shortBadge: common.short,
                detailMessage: L("%@ 会拦截前台应用的%@", combo.displayString, common.detail),
                requiresDoublePressConfirm: common.requiresConfirm
            ))
        }

        return results.sorted { $0.severity > $1.severity }
    }

    /// 为指定动作推荐一个当前完全零冲突的左手顺手组合键
    public static func suggestConflictFreeCombo(
        for slot: GlobalHotKeyAction,
        ownBindings: [GlobalHotKeyAction: KeyCombo],
        occupied: Set<KeyCombo>
    ) -> KeyCombo? {
        var blocked = occupied
        for (a, c) in ownBindings where a != slot { blocked.insert(c) }
        let optKeys: [Int] = [
            kVK_ANSI_A, kVK_ANSI_S, kVK_ANSI_D, kVK_ANSI_T, kVK_ANSI_E, kVK_ANSI_R,
            kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_Z, kVK_ANSI_X,
            kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
            kVK_ANSI_5, kVK_ANSI_6
        ]
        for code in optKeys {
            let c = KeyCombo(keyCode: UInt32(code), carbonModifiers: opt)
            if !blocked.contains(c) { return c }
        }
        for code in [kVK_ANSI_A, kVK_ANSI_S, kVK_ANSI_D, kVK_ANSI_T, kVK_ANSI_E, kVK_ANSI_R, kVK_ANSI_1, kVK_ANSI_2] {
            let c = KeyCombo(keyCode: UInt32(code), carbonModifiers: ctrl | opt)
            if !blocked.contains(c) { return c }
        }
        return nil
    }
}

// MARK: - 常见应用冲突热键知识库

/// 常见运行中第三方软件默认热键档案与标准配置解析器（`KeyboardShortcuts` / `Raycast` 等，100% 可单测）
public enum HotKeyConflictProfiles {
    private static let cmd = UInt32(cmdKey)
    private static let opt = UInt32(optionKey)
    private static let shift = UInt32(shiftKey)
    private static let ctrl = UInt32(controlKey)

    /// 常见第三方常驻工具默认热键档案（已校准真实 macOS Bundle ID，仅在对应 App 实际运行时触发）
    public static let knownApps: [KnownAppHotKeyProfile] = [
        .init(bundleIDPrefixes: ["com.depthpicture.PixPin", "com.pixpin"], appName: "PixPin", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_ANSI_1), carbonModifiers: opt), L("截图")),
            (KeyCombo(keyCode: UInt32(kVK_ANSI_2), carbonModifiers: opt), L("贴图"))
        ]),
        .init(bundleIDPrefixes: ["com.tencent.xinWeChat"], appName: L("微信"), bindings: [
            (KeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: ctrl | cmd), L("截图"))
        ]),
        .init(bundleIDPrefixes: ["com.tencent.WeWorkMac"], appName: L("企业微信"), bindings: [
            (KeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: opt), L("截图"))
        ]),
        .init(bundleIDPrefixes: ["com.tencent.qq"], appName: "QQ", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: ctrl | cmd), L("截图"))
        ]),
        .init(bundleIDPrefixes: ["com.alibaba.DingTalkMac"], appName: L("钉钉"), bindings: [
            (KeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: shift | cmd), L("截图"))
        ]),
        .init(bundleIDPrefixes: ["com.electron.lark", "com.bytedance.feishu"], appName: L("飞书"), bindings: [
            (KeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: shift | cmd), L("截图"))
        ]),
        .init(bundleIDPrefixes: ["com.1password.1password"], appName: "1Password", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: shift | cmd), L("快速访问")),
            (KeyCombo(keyCode: UInt32(kVK_ANSI_Backslash), carbonModifiers: cmd), L("自动填充"))
        ]),
        .init(bundleIDPrefixes: ["com.openai.chat", "com.openai.codex"], appName: "ChatGPT", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: opt), L("唤起对话"))
        ]),
        .init(bundleIDPrefixes: ["com.ripperhe.Bob", "com.hezongyidev.Bob"], appName: "Bob", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: opt), L("划词翻译")),
            (KeyCombo(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: opt), L("截图翻译")),
            (KeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: opt), L("输入翻译"))
        ]),
        .init(bundleIDPrefixes: ["com.izual.Easydict"], appName: "Easydict", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: opt), L("划词翻译")),
            (KeyCombo(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: opt), L("截图翻译")),
            (KeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: opt), L("输入翻译"))
        ]),
        .init(bundleIDPrefixes: ["com.Snipaste"], appName: "Snipaste", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_F1), carbonModifiers: 0), L("截图")),
            (KeyCombo(keyCode: UInt32(kVK_F3), carbonModifiers: 0), L("贴图"))
        ]),
        .init(bundleIDPrefixes: ["cc.ffitch.shottr"], appName: "Shottr", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_ANSI_2), carbonModifiers: shift | cmd), L("区域截图"))
        ]),
        .init(bundleIDPrefixes: ["cn.better365.ishot"], appName: "iShot", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: opt), L("截图"))
        ]),
        .init(bundleIDPrefixes: ["com.xnipapp.xnip"], appName: "Xnip", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_ANSI_X), carbonModifiers: shift | cmd), L("截图"))
        ]),
        .init(bundleIDPrefixes: ["pl.maketheweb.cleanshotx"], appName: "CleanShot X", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_ANSI_4), carbonModifiers: shift | cmd), L("区域截图")),
            (KeyCombo(keyCode: UInt32(kVK_ANSI_5), carbonModifiers: shift | cmd), L("录屏菜单"))
        ]),
        .init(bundleIDPrefixes: ["com.raycast.macos"], appName: "Raycast", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: opt), L("呼出"))
        ]),
        .init(bundleIDPrefixes: ["com.runningwithcrayons.Alfred"], appName: "Alfred", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_Space), carbonModifiers: opt), L("呼出"))
        ]),
        .init(bundleIDPrefixes: ["org.p0deje.Maccy"], appName: "Maccy", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: shift | cmd), L("剪贴板历史"))
        ]),
        .init(bundleIDPrefixes: ["com.wiheads.paste"], appName: "Paste", bindings: [
            (KeyCombo(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: shift | cmd), L("剪贴板历史"))
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
                kVK_ANSI_C: (L("拦截复制"), L("通用「复制 (⌘C)」"), true),
                kVK_ANSI_V: (L("拦截粘贴"), L("通用「粘贴 (⌘V)」"), true),
                kVK_ANSI_X: (L("拦截剪切"), L("通用「剪切 (⌘X)」"), true),
                kVK_ANSI_Z: (L("拦截撤销"), L("通用「撤销 (⌘Z)」"), true),
                kVK_ANSI_A: (L("拦截全选"), L("通用「全选 (⌘A)」"), true),
                kVK_ANSI_S: (L("拦截保存"), L("通用「保存 (⌘S)」"), true),
                kVK_ANSI_W: (L("拦截关闭"), L("通用「关闭窗口 (⌘W)」"), true),
                kVK_ANSI_Q: (L("拦截退出"), L("通用「退出应用 (⌘Q)」"), true),
                kVK_ANSI_H: (L("拦截隐藏"), L("通用「隐藏应用 (⌘H)」"), true),
                kVK_ANSI_M: (L("拦截最小化"), L("通用「最小化 (⌘M)」"), true),
                kVK_ANSI_N: (L("拦截新建"), L("通用「新建 (⌘N)」"), false),
                kVK_ANSI_T: (L("拦截新标签"), L("通用「新标签页 (⌘T)」"), false),
                kVK_ANSI_R: (L("拦截刷新"), L("通用「刷新 (⌘R)」"), false),
                kVK_ANSI_F: (L("拦截查找"), L("通用「查找 (⌘F)」"), false),
                kVK_ANSI_P: (L("拦截打印"), L("通用「打印 (⌘P)」"), false),
                kVK_ANSI_Comma: (L("拦截偏好"), L("通用「应用设置 (⌘,)」"), false),
                kVK_ANSI_1: (L("拦截标签 1"), L("浏览器/编辑器「标签 1 (⌘1)」"), false),
                kVK_ANSI_2: (L("拦截标签 2"), L("浏览器/编辑器「标签 2 (⌘2)」"), false),
                kVK_ANSI_3: (L("拦截标签 3"), L("浏览器/编辑器「标签 3 (⌘3)」"), false)
            ]
            if let hit = map[code] { return hit }
        }
        if combo.carbonModifiers == (cmd | shift) {
            if code == kVK_ANSI_Z { return (L("拦截重做"), L("通用「重做 (⇧⌘Z)」"), false) }
            if code == kVK_ANSI_P { return (L("拦截命令板"), L("编辑器「命令面板 (⇧⌘P)」"), false) }
        }
        return nil
    }

    /// 将 `KeyboardShortcuts_<feature>` 键名清洗为可读标签
    public static func humanizeShortcutKeyName(_ key: String) -> String {
        let trimmed = key.hasPrefix("KeyboardShortcuts_")
            ? String(key.dropFirst("KeyboardShortcuts_".count))
            : key
        return trimmed.isEmpty ? L("自定义热键") : trimmed
    }
}
