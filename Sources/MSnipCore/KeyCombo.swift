import AppKit
import Carbon
import Foundation

/// 跨模块可序列化的全局快捷键组合（封装虚拟键码与 Carbon 修饰键掩码）
public struct KeyCombo: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32

    public init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// 从 Cocoa `NSEvent` 构造有效全局热键（普通按键必须至少包含 `⌘ / ⌥ / ⌃` 之一；`F1-F19` 可单独使用）
    public static func from(event: NSEvent) -> KeyCombo? {
        let code = UInt32(event.keyCode)
        // 忽略纯修饰键与 Esc / Delete / Return
        let pureModifiers: Set<UInt32> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        guard !pureModifiers.contains(code), code != 53, code != 51, code != 117, code != 36, code != 76 else {
            return nil
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.option)  { carbon |= UInt32(optionKey) }
        if flags.contains(.shift)   { carbon |= UInt32(shiftKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }

        let hasPrimaryMod = flags.contains(.command) || flags.contains(.option) || flags.contains(.control)
        let isFunctionKey = Self.functionKeyMap[Int(code)] != nil
        guard hasPrimaryMod || isFunctionKey else { return nil }
        guard Self.keyDisplayTable[Int(code)] != nil || isFunctionKey else { return nil }
        return KeyCombo(keyCode: code, carbonModifiers: carbon)
    }

    /// 用于工具栏提示、HUD 与录制按钮展示的紧凑文案（如 `⌘1`、`⌘⇧A`、`⌃⌥S`、`F3`）
    public var displayString: String {
        var out = ""
        if (carbonModifiers & UInt32(controlKey)) != 0 { out += "⌃" }
        if (carbonModifiers & UInt32(optionKey)) != 0  { out += "⌥" }
        if (carbonModifiers & UInt32(shiftKey)) != 0   { out += "⇧" }
        if (carbonModifiers & UInt32(cmdKey)) != 0     { out += "⌘" }
        out += Self.keyLabel(for: Int(keyCode))
        return out
    }

    /// 供 `NSMenuItem.keyEquivalent` 使用的字符
    public var menuKeyEquivalent: String {
        if let f = Self.functionKeyMap[Int(keyCode)] {
            return String(UnicodeScalar(f.scalar)!)
        }
        if Int(keyCode) == kVK_Space { return " " }
        if Int(keyCode) == kVK_Tab   { return "\t" }
        return Self.keyDisplayTable[Int(keyCode)]?.lowercased() ?? ""
    }

    /// 供 `NSMenuItem.keyEquivalentModifierMask` 使用的 Cocoa 修饰位掩码
    public var cocoaModifierMask: NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if (carbonModifiers & UInt32(controlKey)) != 0 { mask.insert(.control) }
        if (carbonModifiers & UInt32(optionKey)) != 0  { mask.insert(.option) }
        if (carbonModifiers & UInt32(shiftKey)) != 0   { mask.insert(.shift) }
        if (carbonModifiers & UInt32(cmdKey)) != 0     { mask.insert(.command) }
        return mask
    }

    /// 判断虚拟键码是否为可展示的常规/功能/方向键（供系统热键扫描过滤未知媒体键）
    public static func isDisplayableKeyCode(_ code: Int) -> Bool {
        functionKeyMap[code] != nil || keyDisplayTable[code] != nil || navDisplayTable[code] != nil
    }

    /// 判断是否为功能键或方向键（macOS `CopySymbolicHotKeys` 对这两类键会附带 Fn 位掩码）
    public static func isFunctionOrNavKey(_ code: Int) -> Bool {
        functionKeyMap[code] != nil || navDisplayTable[code] != nil
    }

    private static func keyLabel(for code: Int) -> String {
        if let f = functionKeyMap[code] { return f.label }
        if let n = navDisplayTable[code] { return n }
        return keyDisplayTable[code] ?? "Key\(code)"
    }

    private static let navDisplayTable: [Int: String] = [
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_Escape: "⎋"
    ]

    private static let functionKeyMap: [Int: (label: String, scalar: Int)] = [
        kVK_F1: ("F1", NSF1FunctionKey), kVK_F2: ("F2", NSF2FunctionKey),
        kVK_F3: ("F3", NSF3FunctionKey), kVK_F4: ("F4", NSF4FunctionKey),
        kVK_F5: ("F5", NSF5FunctionKey), kVK_F6: ("F6", NSF6FunctionKey),
        kVK_F7: ("F7", NSF7FunctionKey), kVK_F8: ("F8", NSF8FunctionKey),
        kVK_F9: ("F9", NSF9FunctionKey), kVK_F10: ("F10", NSF10FunctionKey),
        kVK_F11: ("F11", NSF11FunctionKey), kVK_F12: ("F12", NSF12FunctionKey),
        kVK_F13: ("F13", NSF13FunctionKey), kVK_F14: ("F14", NSF14FunctionKey),
        kVK_F15: ("F15", NSF15FunctionKey), kVK_F16: ("F16", NSF16FunctionKey),
        kVK_F17: ("F17", NSF17FunctionKey), kVK_F18: ("F18", NSF18FunctionKey),
        kVK_F19: ("F19", NSF19FunctionKey)
    ]

    private static let keyDisplayTable: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\",
        kVK_ANSI_Grave: "`", kVK_Space: "␣", kVK_Tab: "⇥"
    ]
}
