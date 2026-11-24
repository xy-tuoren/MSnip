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
            case .systemLive:        return "系统实测"
            case .appConfigLive:     return "配置实测"
            case .runningAppDefault: return "默认参考"
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
        case 7:  return "键盘聚焦菜单栏"
        case 8:  return "键盘聚焦程序坞"
        case 9:  return "键盘聚焦活动窗口"
        case 27: return "切换同应用窗口"
        case 28: return "系统全屏截图"
        case 29: return "全屏截图到剪贴板"
        case 30: return "系统区域截图"
        case 31: return "区域截图到剪贴板"
        case 32, 34: return "调度中心 (Mission Control)"
        case 33, 35: return "应用程序窗口"
        case 36, 37: return "显示桌面"
        case 52: return "隐藏/显示程序坞 (Dock)"
        case 60: return "切换上一个输入法"
        case 61: return "切换下一个输入法"
        case 64: return "聚焦搜索 (Spotlight)"
        case 65: return "访达搜索窗口"
        case 70: return "查询词典"
        case 79, 80: return "向左切换桌面空间"
        case 81, 82: return "向右切换桌面空间"
        case 98: return "聚焦帮助菜单"
        case 118...126: return "切换到桌面 \(id - 117)"
        case 160: return "启动台 (Launchpad)"
        case 184: return "系统截屏与录屏"
        case 190: return "快速备忘录"
        default: return nil
        }
    }

    /// 按默认按键签名匹配 macOS 内置系统热键中文名称（供 `CopySymbolicHotKeys` 实时条目补全名称）
    public static func systemSignatureName(for combo: KeyCombo) -> String? {
        switch (Int(combo.keyCode), combo.carbonModifiers) {
        case (kVK_Space, cmd):               return "聚焦搜索 (Spotlight)"
        case (kVK_Space, cmd | opt):         return "访达搜索窗口"
        case (kVK_Space, ctrl):              return "切换上一个输入法"
        case (kVK_Space, ctrl | opt):        return "切换下一个输入法"
        case (kVK_Space, ctrl | cmd):        return "表情与符号"
        case (kVK_ANSI_3, shift | cmd):      return "系统全屏截图"
        case (kVK_ANSI_3, ctrl | shift | cmd): return "全屏截图到剪贴板"
        case (kVK_ANSI_4, shift | cmd):      return "系统区域截图"
        case (kVK_ANSI_4, ctrl | shift | cmd): return "区域截图到剪贴板"
        case (kVK_ANSI_5, shift | cmd):      return "系统截屏与录屏"
        case (kVK_ANSI_D, opt | cmd):        return "隐藏/显示程序坞"
        case (kVK_ANSI_D, ctrl | cmd):       return "查询词典"
        case (kVK_ANSI_Q, ctrl | cmd):       return "锁定屏幕"
        case (kVK_Tab, cmd):                 return "应用切换器"
        case (kVK_Tab, shift | cmd):         return "反向切换应用"
        case (kVK_ANSI_Grave, cmd):          return "切换同应用窗口"
        case (kVK_Escape, opt | cmd):        return "强制退出应用"
        case (kVK_ANSI_Slash, shift | cmd):  return "帮助菜单搜索"
        case (kVK_UpArrow, ctrl):            return "调度中心"
        case (kVK_DownArrow, ctrl):          return "应用程序窗口"
        case (kVK_LeftArrow, ctrl):          return "切换左侧桌面"
        case (kVK_RightArrow, ctrl):         return "切换右侧桌面"
        case (kVK_F11, 0):                   return "显示桌面"
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
                shortBadge: "同「\(action.title)」冲突",
                detailMessage: "\(combo.displayString) 已被 MSnip「\(action.title)」占用",
                requiresDoublePressConfirm: false
            ))
        }

        if let sys = systemEntries.first(where: { $0.combo == combo }) {
            let short = sys.feature.count <= 7 ? sys.feature : "系统热键"
            results.append(HotKeyConflict(
                severity: .blocking,
                owner: "macOS",
                shortBadge: short,
                detailMessage: "\(combo.displayString) 已被 macOS 系统「\(sys.feature)」占用",
                requiresDoublePressConfirm: true
            ))
        } else if carbonExclusiveOccupied {
            results.append(HotKeyConflict(
                severity: .blocking,
                owner: "系统/常驻应用",
                shortBadge: "已被独占",
                detailMessage: "\(combo.displayString) 已被系统或其他常驻应用独占注册",
                requiresDoublePressConfirm: true
            ))
        }

        for app in runningAppEntries where app.combo == combo {
            let isLiveCfg = (app.sourceKind == .appConfigLive)
            let msg = isLiveCfg
                ? "「\(app.owner)」已配置热键（\(app.feature)），会直接冲突"
                : "「\(app.owner)」运行中 · \(app.feature)默认热键，可能冲突"
            results.append(HotKeyConflict(
                severity: isLiveCfg ? .blocking : .warning,
                owner: app.owner,
                shortBadge: isLiveCfg ? "\(app.owner)已占用" : "\(app.owner)运行中",
                detailMessage: msg,
                requiresDoublePressConfirm: isLiveCfg
            ))
        }

        if let common = commonAppShortcut(for: combo) {
            results.append(HotKeyConflict(
                severity: .warning,
                owner: "通用快捷键",
                shortBadge: common.short,
                detailMessage: "\(combo.displayString) 会拦截前台应用的\(common.detail)",
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
