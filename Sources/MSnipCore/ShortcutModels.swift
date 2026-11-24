import AppKit
import Carbon
import Foundation

/// 全局可配置的 11 项系统级热键动作
public enum GlobalHotKeyAction: String, CaseIterable, Codable, Sendable {
    case capture           = "capture"
    case pin               = "pin"
    case ocr               = "ocr"
    case translate         = "translate"
    case longShot          = "longShot"
    case record            = "record"
    case delayedCapture    = "delayedCapture"
    case fullScreenCapture = "fullScreenCapture"
    case latex             = "latex"
    case togglePins        = "togglePins"
    case repeatCapture     = "repeatCapture"

    public var title: String {
        switch self {
        case .capture:           return "区域截图"
        case .pin:               return "桌面贴图"
        case .ocr:               return "快捷识字 (OCR)"
        case .translate:         return "截图翻译"
        case .longShot:          return "滚动长截图"
        case .record:            return "区域录屏 (GIF/MP4)"
        case .delayedCapture:    return "延时截图"
        case .fullScreenCapture: return "截取当前全屏"
        case .latex:             return "公式识别 (LaTeX)"
        case .togglePins:        return "显隐全部贴图"
        case .repeatCapture:     return "重截上次选区"
        }
    }

    public var subtitle: String {
        switch self {
        case .capture:           return "冻结屏幕框选、圈记标注、取色与独立窗口抓拍"
        case .pin:               return "将剪贴板图片/色值钉在桌面，或在截图中直接贴出"
        case .ocr:               return "框选屏幕任意区域后立即进入实况划词识字"
        case .translate:         return "框选屏幕任意区域后立即原位替换译文"
        case .longShot:          return "框选可滚动区域后直接开始长图自动拼接"
        case .record:            return "直接进入 GIF / MP4 选区录屏准备状态"
        case .delayedCapture:    return "按设定的默认秒数启动悬浮倒计时，适合捕获菜单与悬停态"
        case .fullScreenCapture: return "一键截取鼠标所在显示器整屏，按设定复制或保存到默认目录"
        case .latex:             return "框选数学公式直接识别并弹出 KaTeX 预览"
        case .togglePins:        return "一键暂藏或恢复桌面上所有置顶贴图窗口"
        case .repeatCapture:     return "按上一次截图的选区位置静默重截并复制到剪贴板"
        }
    }

    public var symbol: String {
        switch self {
        case .capture:           return "viewfinder"
        case .pin:               return "pin"
        case .ocr:               return "text.viewfinder"
        case .translate:         return "character.bubble"
        case .longShot:          return "scissors"
        case .record:            return "video"
        case .delayedCapture:    return "timer"
        case .fullScreenCapture: return "rectangle.dashed"
        case .latex:             return "function"
        case .togglePins:        return "eye.slash"
        case .repeatCapture:     return "arrow.clockwise"
        }
    }
}

/// 单项全局快捷键覆盖状态（支持覆盖为自定义组合键，或显式停用某项预设热键）
public enum HotKeyBindingOverride: Codable, Equatable, Sendable {
    case custom(KeyCombo)
    case disabled
}

/// 零冲突、左手顺手优先的全局快捷键预设方案（优先双键/单键，不抢占浏览器 ⌘1 与编辑器 ⌘⇧P）
public enum HotKeyPreset: String, CaseIterable, Codable, Sendable {
    case optASD  = "optASD"
    case ctrl123 = "ctrl123"
    case fnKeys  = "fnKeys"
    case ctrlCmd = "ctrlCmd"

    public init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        switch raw {
        case "optASD", "optAP", "cmd12": self = .optASD
        case "ctrl123", "opt123":        self = .ctrl123
        case "fnKeys", "f1f3":           self = .fnKeys
        case "ctrlCmd", "cmdShiftAP":    self = .ctrlCmd
        default:                         self = .optASD
        }
    }

    public var segmentTitle: String {
        switch self {
        case .optASD:  return "⌥A / ⌥S 左手双键"
        case .ctrl123: return "⌃1 / ⌃2 数字双键"
        case .fnKeys:  return "F1 / F2 单键"
        case .ctrlCmd: return "⌃⌘A 经典三键"
        }
    }

    public func defaultCombo(for action: GlobalHotKeyAction) -> KeyCombo? {
        let opt = UInt32(optionKey)
        let ctrl = UInt32(controlKey)
        let cc = UInt32(controlKey | cmdKey)
        switch (self, action) {
        case (.optASD, .capture):    return KeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: opt)
        case (.optASD, .pin):        return KeyCombo(keyCode: UInt32(kVK_ANSI_T), carbonModifiers: opt)
        case (.optASD, .ocr):        return KeyCombo(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: opt)
        case (.optASD, .translate):  return KeyCombo(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: opt)
        case (.optASD, .longShot):   return KeyCombo(keyCode: UInt32(kVK_ANSI_E), carbonModifiers: opt)
        case (.optASD, .record):     return KeyCombo(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: opt)

        case (.ctrl123, .capture):   return KeyCombo(keyCode: UInt32(kVK_ANSI_1), carbonModifiers: ctrl)
        case (.ctrl123, .pin):       return KeyCombo(keyCode: UInt32(kVK_ANSI_2), carbonModifiers: ctrl)
        case (.ctrl123, .ocr):       return KeyCombo(keyCode: UInt32(kVK_ANSI_3), carbonModifiers: ctrl)
        case (.ctrl123, .translate): return KeyCombo(keyCode: UInt32(kVK_ANSI_4), carbonModifiers: ctrl)
        case (.ctrl123, .longShot):  return KeyCombo(keyCode: UInt32(kVK_ANSI_5), carbonModifiers: ctrl)
        case (.ctrl123, .record):    return KeyCombo(keyCode: UInt32(kVK_ANSI_6), carbonModifiers: ctrl)

        case (.fnKeys, .capture):    return KeyCombo(keyCode: UInt32(kVK_F1), carbonModifiers: 0)
        case (.fnKeys, .pin):        return KeyCombo(keyCode: UInt32(kVK_F2), carbonModifiers: 0)
        case (.fnKeys, .ocr):        return KeyCombo(keyCode: UInt32(kVK_F3), carbonModifiers: 0)
        case (.fnKeys, .translate):  return KeyCombo(keyCode: UInt32(kVK_F4), carbonModifiers: 0)
        case (.fnKeys, .longShot):   return KeyCombo(keyCode: UInt32(kVK_F5), carbonModifiers: 0)
        case (.fnKeys, .record):     return KeyCombo(keyCode: UInt32(kVK_F6), carbonModifiers: 0)

        case (.ctrlCmd, .capture):   return KeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: cc)
        case (.ctrlCmd, .pin):       return KeyCombo(keyCode: UInt32(kVK_ANSI_T), carbonModifiers: cc)
        case (.ctrlCmd, .ocr):       return KeyCombo(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: cc)
        case (.ctrlCmd, .translate): return KeyCombo(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: cc)
        case (.ctrlCmd, .longShot):  return KeyCombo(keyCode: UInt32(kVK_ANSI_E), carbonModifiers: cc)
        case (.ctrlCmd, .record):    return KeyCombo(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: cc)

        default:                     return nil
        }
    }
}

/// 截图覆盖层画布内的单键分组
public enum CanvasActionGroup: Int, CaseIterable, Sendable {
    case outputAndModes = 0
    case annotationTools = 1
    case inspectionAndAppearance = 2

    public var title: String {
        switch self {
        case .outputAndModes:          return "输出与多模态动作"
        case .annotationTools:         return "圈记标注工具"
        case .inspectionAndAppearance: return "美化、窗口对齐与取色测量"
        }
    }
}

/// 截图画布内全部 24 项可自由重绑定的单键动作（中英文输入法通用，冲突自动互换）
public enum CanvasAction: String, CaseIterable, Codable, Sendable {
    case copy, quickSave, pin, ocr, translate, longShot, record, cancel
    case rect, arrow, pen, text, step, mosaic, eraser, textCapsule
    case cornerRadius, backdropOrCoord, snapWindow, caliper, eyedropper, copyCoord, toggleMagnifier, toggleTips

    public var group: CanvasActionGroup {
        switch self {
        case .copy, .quickSave, .pin, .ocr, .translate, .longShot, .record, .cancel:
            return .outputAndModes
        case .rect, .arrow, .pen, .text, .step, .mosaic, .eraser, .textCapsule:
            return .annotationTools
        case .cornerRadius, .backdropOrCoord, .snapWindow, .caliper, .eyedropper, .copyCoord, .toggleMagnifier, .toggleTips:
            return .inspectionAndAppearance
        }
    }

    public var defaultKey: String {
        switch self {
        case .copy: return "c";            case .quickSave: return "s";       case .pin: return "p";          case .ocr: return "t"
        case .translate: return "y";       case .longShot: return "l";        case .record: return "v";       case .cancel: return "q"
        case .rect: return "r";            case .arrow: return "a";           case .pen: return "d";          case .text: return "w"
        case .step: return "n";            case .mosaic: return "m";          case .eraser: return "e";       case .textCapsule: return "k"
        case .cornerRadius: return "b";    case .backdropOrCoord: return "g"; case .snapWindow: return "f";   case .caliper: return "z"
        case .eyedropper: return "i";      case .copyCoord: return "x";       case .toggleMagnifier: return "o"; case .toggleTips: return "h"
        }
    }

    public var title: String {
        switch self {
        case .copy: return "复制截图 / 复制色值"
        case .quickSave: return "一键快存（配 ⇧ 另存为）"
        case .pin: return "贴到桌面"
        case .ocr: return "原位识字（配 ⇧ 公式 / ⌥ 对照窗）"
        case .translate: return "原位翻译（配 ⌥ 双栏流式窗）"
        case .longShot: return "滚动长截图"
        case .record: return "切换录屏模式"
        case .cancel: return "退出截图（Esc 始终可用）"
        case .rect: return "矩形 / 椭圆 (+⇧)"
        case .arrow: return "箭头标注"
        case .pen: return "画笔 / 荧光笔 (+⇧)"
        case .text: return "文字标注"
        case .step: return "步骤序号 ①②③"
        case .mosaic: return "马赛克 / 高斯模糊 (+⇧)"
        case .eraser: return "橡皮擦 / 恢复上次选区"
        case .textCapsule: return "切换文字胶囊底色"
        case .cornerRadius: return "圆角裁切滑块（配 ⌥ 重置）"
        case .backdropOrCoord: return "渐变衬底美化 / 切换相对坐标"
        case .snapWindow: return "对齐底层窗口（配 ⌥ 抓独立窗口）"
        case .caliper: return "像素卡尺四向测距"
        case .eyedropper: return "画笔吸管取色"
        case .copyCoord: return "复制光标坐标"
        case .toggleMagnifier: return "显示 / 隐藏取色放大镜"
        case .toggleTips: return "显示 / 隐藏快捷键提示面板"
        }
    }

    public var symbol: String {
        switch self {
        case .copy: return "doc.on.doc";       case .quickSave: return "square.and.arrow.down"; case .pin: return "pin";             case .ocr: return "text.viewfinder"
        case .translate: return "character.bubble"; case .longShot: return "scissors";          case .record: return "video";        case .cancel: return "xmark.circle"
        case .rect: return "rectangle";        case .arrow: return "arrow.up.right";            case .pen: return "pencil";          case .text: return "character"
        case .step: return "1.circle";         case .mosaic: return "checkerboard.rectangle";   case .eraser: return "eraser";       case .textCapsule: return "capsule"
        case .cornerRadius: return "app";      case .backdropOrCoord: return "sparkles.rectangle.stack"; case .snapWindow: return "macwindow"; case .caliper: return "ruler"
        case .eyedropper: return "eyedropper"; case .copyCoord: return "scope";                 case .toggleMagnifier: return "magnifyingglass"; case .toggleTips: return "questionmark.circle"
        }
    }

    public static var defaultMap: [CanvasAction: String] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.defaultKey) })
    }

    /// 将物理键码解析为合法画布单键（排除数字 1-9、方向键、空格、Tab、回车与增减粗细的 `[` `]` `-` `=`）
    public static func singleKeyToken(for keyCode: UInt16) -> String? {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "a"; case kVK_ANSI_B: return "b"; case kVK_ANSI_C: return "c"; case kVK_ANSI_D: return "d"
        case kVK_ANSI_E: return "e"; case kVK_ANSI_F: return "f"; case kVK_ANSI_G: return "g"; case kVK_ANSI_H: return "h"
        case kVK_ANSI_I: return "i"; case kVK_ANSI_J: return "j"; case kVK_ANSI_K: return "k"; case kVK_ANSI_L: return "l"
        case kVK_ANSI_M: return "m"; case kVK_ANSI_N: return "n"; case kVK_ANSI_O: return "o"; case kVK_ANSI_P: return "p"
        case kVK_ANSI_Q: return "q"; case kVK_ANSI_R: return "r"; case kVK_ANSI_S: return "s"; case kVK_ANSI_T: return "t"
        case kVK_ANSI_U: return "u"; case kVK_ANSI_V: return "v"; case kVK_ANSI_W: return "w"; case kVK_ANSI_X: return "x"
        case kVK_ANSI_Y: return "y"; case kVK_ANSI_Z: return "z"
        case kVK_ANSI_Semicolon: return ";"; case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ",";     case kVK_ANSI_Period: return "."; case kVK_ANSI_Backslash: return "\\"
        default: return nil
        }
    }

    /// 绑定画布单键；若目标键已被其他动作占用则自动互换，返回发生互换的另一动作
    @discardableResult
    public static func bind(key rawKey: String, to target: CanvasAction, in customMap: inout [String: String]) -> CanvasAction? {
        let key = rawKey.lowercased()
        let prevKey = (customMap[target.rawValue] ?? target.defaultKey).lowercased()
        guard key != prevKey else { return nil }
        var swappedOther: CanvasAction?
        for other in allCases where other != target {
            let otherKey = (customMap[other.rawValue] ?? other.defaultKey).lowercased()
            if otherKey == key {
                if prevKey == other.defaultKey { customMap.removeValue(forKey: other.rawValue) }
                else { customMap[other.rawValue] = prevKey }
                swappedOther = other
                break
            }
        }
        if key == target.defaultKey { customMap.removeValue(forKey: target.rawValue) }
        else { customMap[target.rawValue] = key }
        return swappedOther
    }
}
