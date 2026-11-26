import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

/// 编辑器专属按需监听引擎（仅在剪贴板仍归 MSnip 截图所有且前台为编辑器/IDE 时短暂挂载，离开或新复制即刻彻底销毁）：
/// 1. 被动 `AXObserver` 监听编辑器内部焦点切换（代码/AI 聊天框 ↔ 内置终端）；
/// 2. `.listenOnly` 级 `CGEventTap` 感应 `⌘V` 触发时机，供不透明 Electron / GPUI 编辑器执行无感路径回补；
/// 3. 绝不拦截或延迟任何正常按键，不记录任何输入内容。
@MainActor
public final class EditorPasteMonitor {
    /// 合成粘贴事件的唯一签名标记，避免触发自身回调死循环
    public static let syntheticPasteTag: Int64 = 0x4D53_4E50_5041_5354

    public var onFocusChanged: (() -> Void)?
    public var onCommandVPressed: (() -> Void)?
    public var onOtherKeyPressed: (() -> Void)?

    private var observedPID: pid_t = 0
    private var axObserver: AXObserver?
    private var axAppElement: AXUIElement?
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var isTapActive = false

    public init() {}

    deinit {
        if let obs = axObserver {
            if let appEl = axAppElement {
                AXObserverRemoveNotification(obs, appEl, kAXFocusedUIElementChangedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let src = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
    }

    /// 启动对指定编辑器进程的按需焦点监听与 `⌘V` 被动感应（未授权辅助功能时静默跳过）
    public func start(forPID pid: pid_t) {
        guard AXIsProcessTrusted(), pid > 0 else {
            stop()
            return
        }
        if observedPID == pid && (axObserver != nil || isTapActive) {
            return
        }
        stop()
        observedPID = pid
        attachAXObserver(forPID: pid)
        attachListenOnlyKeyTap()
    }

    /// 立即彻底释放 `AXObserver`、`CFMachPort` 与 `CFRunLoopSource`（零残留、零开销）
    public func stop() {
        isTapActive = false
        observedPID = 0

        if let obs = axObserver {
            if let appEl = axAppElement {
                AXObserverRemoveNotification(obs, appEl, kAXFocusedUIElementChangedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
            axObserver = nil
        }
        axAppElement = nil

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        if let src = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            eventTapSource = nil
        }
    }

    /// 使用独立事件源发送一次带标记的 `⌘V`（不受物理修饰键瞬时抬起状态影响）
    public static func postSyntheticCommandV() {
        guard AXIsProcessTrusted() else { return }
        let src = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.eventSourceUserData, value: syntheticPasteTag)
        up.setIntegerValueField(.eventSourceUserData, value: syntheticPasteTag)
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    // MARK: - Private Setup

    private func attachAXObserver(forPID pid: pid_t) {
        var obs: AXObserver?
        guard AXObserverCreate(pid, Self.axObserverCallback, &obs) == .success, let observer = obs else {
            return
        }
        let appEl = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let err = AXObserverAddNotification(observer, appEl, kAXFocusedUIElementChangedNotification as CFString, refcon)
        guard err == .success || err == .notificationAlreadyRegistered else {
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axObserver = observer
        axAppElement = appEl
    }

    private func attachListenOnlyKeyTap() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.keyTapCallback,
            userInfo: refcon
        ) else {
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }
        eventTap = tap
        eventTapSource = source
        isTapActive = true
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private static let axObserverCallback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let monitor = Unmanaged<EditorPasteMonitor>.fromOpaque(refcon).takeUnretainedValue()
        DispatchQueue.main.async { [weak monitor] in
            monitor?.onFocusChanged?()
        }
    }

    private static let keyTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<EditorPasteMonitor>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if monitor.isTapActive, let tap = monitor.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard monitor.isTapActive, type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == EditorPasteMonitor.syntheticPasteTag {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let mods = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if keyCode == kVK_ANSI_V && mods == .maskCommand {
            if !isRepeat {
                DispatchQueue.main.async { [weak monitor] in
                    monitor?.onCommandVPressed?()
                }
            }
        } else if mods.contains(.maskCommand) && !isRepeat {
            // 仅在按下 ⌘ 组合键（如 ⌘C / ⌘X 等可能改写剪贴板的快捷键）时通知复核，普通打字零唤醒、零 IPC
            DispatchQueue.main.async { [weak monitor] in
                monitor?.onOtherKeyPressed?()
            }
        }
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - 当前焦点终端与编辑器识别

/// 编辑器内部当前聚焦控件的语义分类
public enum EditorFocusClassification: Equatable, Sendable {
    /// 明确命中内置终端 / 控制台（应立即提供 PNG + 文件 URL + 临时路径）
    case terminal
    /// 明确命中代码编辑区 / AI 聊天输入框 / Markdown / 搜索框（应保持纯净图像）
    case nonTerminalInput
    /// 无法从辅助功能树判定（例如未授权辅助功能，或 Electron / GPUI 未展开内部控件树）
    case indeterminate
}

/// 单个辅助功能控件节点的纯值快照（便于核心判定逻辑脱离窗口环境 100% 单元测试）
public struct AXNodeSnapshot: Equatable, Sendable {
    public let role: String
    public let subrole: String
    public let roleDescription: String
    public let identifier: String
    public let domIdentifier: String
    public let domClasses: [String]
    public let description: String
    public let title: String

    public init(
        role: String = "",
        subrole: String = "",
        roleDescription: String = "",
        identifier: String = "",
        domIdentifier: String = "",
        domClasses: [String] = [],
        description: String = "",
        title: String = ""
    ) {
        self.role = role
        self.subrole = subrole
        self.roleDescription = roleDescription
        self.identifier = identifier
        self.domIdentifier = domIdentifier
        self.domClasses = domClasses
        self.description = description
        self.title = title
    }

    var hasMetadata: Bool {
        !subrole.isEmpty || !identifier.isEmpty || !domIdentifier.isEmpty
            || !domClasses.isEmpty || !description.isEmpty || !title.isEmpty
    }
}

/// 编辑器内部终端焦点探测器（纯被动只读 AX 查询：绝不写入 AXEnhancedUserInterface，避免触发 VS Code 屏幕阅读器模式）
public enum EditorTerminalFocusDetector {
    private static let strongTerminalClasses: Set<String> = [
        "xterm-helper-textarea", "xterm", "xterm-screen", "xterm-viewport",
        "terminal-wrapper", "terminal-outer-container", "integrated-terminal",
        "terminal-widget", "terminal-instance", "terminal-input", "pty-terminal"
    ]

    private static let strongTerminalIdentifiers: [String] = [
        "workbench.panel.terminal", "terminal.integrated", "jbterminal",
        "terminalpanel", "terminalview", "integratedterminal",
        "ideconsole", "dvtconsole", "debugconsole", "xterm"
    ]

    private static let strongNonTerminalClasses: Set<String> = [
        "monaco-mouse-cursor-text", "monaco-editor", "cm-content",
        "prosemirror", "tiptap", "chat-input", "composer-input",
        "aislash-editor-input", "quick-input-box", "find-part",
        "suggest-input-container", "chat-widget", "interactive-session"
    ]

    private static let strongNonTerminalIdentifiers: [String] = [
        "workbench.parts.editor", "workbench.panel.chat", "dvtsourcetextview"
    ]

    private static let nonTerminalLabelPhrases: [String] = [
        "editor content", "编辑器内容", "chat input", "ask anything",
        "message input", "ask copilot", "composer", "find", "replace",
        "search", "搜索", "查找", "命令面板", "command palette"
    ]

    private static let codeFileExtensions: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "md", "mdx",
        "json", "yml", "yaml", "toml", "xml", "html", "css", "scss", "less",
        "rs", "go", "java", "kt", "kts", "c", "cc", "cpp", "h", "hpp", "m", "mm",
        "rb", "php", "sql", "sh", "zsh", "bash", "txt", "csv", "log", "env", "vue", "svelte"
    ]

    private static let containerRoles: Set<String> = [
        "AXGroup", "AXScrollArea", "AXSplitGroup", "AXTabGroup",
        "AXUnknown", "AXPane", "AXLayoutArea", "AXWebArea"
    ]

    /// 被动读取指定编辑器进程当前的焦点控件及其祖先链（在 AXWindow 之前停止，防止窗口文件名干扰）
    public static func detectFocusedTarget(pid: pid_t) -> EditorFocusClassification {
        guard AXIsProcessTrusted(), pid > 0 else { return .indeterminate }
        let appEl = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard err == .success, let rawFocused = focusedRef else { return .indeterminate }
        guard CFGetTypeID(rawFocused) == AXUIElementGetTypeID() else { return .indeterminate }
        let focusedEl = unsafeBitCast(rawFocused, to: AXUIElement.self)

        var chain: [AXNodeSnapshot] = []
        var current: AXUIElement? = focusedEl
        for _ in 0..<8 {
            guard let el = current else { break }
            let snap = snapshot(of: el)
            if snap.role == "AXWindow" || snap.role == "AXApplication" { break }
            chain.append(snap)
            current = parentElement(of: el)
        }
        return classifyFocusChain(chain)
    }

    /// 纯函数语义判定：根据焦点控件及其祖先快照判断当前是否位于编辑器内置终端
    public static func classifyFocusChain(_ nodes: [AXNodeSnapshot]) -> EditorFocusClassification {
        guard let focused = nodes.first else { return .indeterminate }

        // 1) 焦点自身具备强终端 DOM 类名或开发标识 -> 立即命中终端
        if hasStrongTerminalSignal(focused) { return .terminal }

        // 2) 焦点自身具备强非终端编辑/聊天/搜索/源码文件名特征 -> 立即判定为非终端（绝不误贴路径）
        if hasStrongNonTerminalSignal(focused) { return .nonTerminalInput }

        // 3) 焦点自身标签严格匹配终端词边界（免疫 ClipboardTerminalAdapter.swift 等文件名）
        if matchesTerminalLabel(focused.description)
            || matchesTerminalLabel(focused.title)
            || matchesTerminalLabel(focused.roleDescription)
            || matchesTerminalLabel(focused.subrole) {
            return .terminal
        }

        // 4) 向上回溯容器祖先链（已排除 AXWindow / AXApplication）
        for ancestor in nodes.dropFirst() {
            if hasStrongTerminalSignal(ancestor) { return .terminal }
            if containerRoles.contains(ancestor.role) {
                if matchesTerminalLabel(ancestor.description) || matchesTerminalLabel(ancestor.title) {
                    return .terminal
                }
            }
            if hasStrongNonTerminalContainerSignal(ancestor) { return .nonTerminalInput }
        }

        // 5) 焦点是明确带元数据的普通文本输入控件且整条祖先链均无终端信号 -> 非终端；否则视为不透明（交由 2b 探针兜底）
        if (focused.role == "AXTextField" || focused.role == "AXTextArea") && focused.hasMetadata {
            return .nonTerminalInput
        }
        return .indeterminate
    }

    // MARK: - Signal Matchers

    private static func hasStrongTerminalSignal(_ node: AXNodeSnapshot) -> Bool {
        for cls in node.domClasses {
            if strongTerminalClasses.contains(cls.lowercased()) { return true }
        }
        let idA = node.identifier.lowercased()
        let idB = node.domIdentifier.lowercased()
        for token in strongTerminalIdentifiers {
            if idA.contains(token) || idB.contains(token) { return true }
        }
        return false
    }

    private static func hasStrongNonTerminalSignal(_ node: AXNodeSnapshot) -> Bool {
        if node.role == "AXSearchField" || node.role == "AXComboBox" || node.role == "AXButton" {
            return true
        }
        if hasStrongNonTerminalContainerSignal(node) { return true }
        if looksLikeCodeFilename(node.description) || looksLikeCodeFilename(node.title) {
            return true
        }
        let desc = node.description.lowercased()
        let ttl = node.title.lowercased()
        for phrase in nonTerminalLabelPhrases {
            if desc.contains(phrase) || ttl.contains(phrase) { return true }
        }
        if node.role == "AXTextField" && !matchesTerminalLabel(node.description) && !matchesTerminalLabel(node.title) {
            return true
        }
        return false
    }

    private static func hasStrongNonTerminalContainerSignal(_ node: AXNodeSnapshot) -> Bool {
        for cls in node.domClasses {
            if strongNonTerminalClasses.contains(cls.lowercased()) { return true }
        }
        let idA = node.identifier.lowercased()
        let idB = node.domIdentifier.lowercased()
        for token in strongNonTerminalIdentifiers {
            if idA.contains(token) || idB.contains(token) { return true }
        }
        return false
    }

    static func looksLikeCodeFilename(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let parts = trimmed.split(whereSeparator: { $0.isWhitespace || $0 == "—" || $0 == "-" || $0 == "," })
        for part in parts {
            let token = part.trimmingCharacters(in: CharacterSet(charactersIn: "()[]\"'`:;"))
            guard let dot = token.lastIndex(of: ".") else { continue }
            let ext = token[token.index(after: dot)...].lowercased()
            if codeFileExtensions.contains(ext) { return true }
        }
        return false
    }

    static func matchesTerminalLabel(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !looksLikeCodeFilename(trimmed) else { return false }
        let lower = trimmed.lowercased()

        if hasPrefixWithBoundary(lower, prefix: "terminal") { return true }
        if lower.hasPrefix("终端") || lower.hasPrefix("内置终端") || lower.hasPrefix("集成终端") { return true }

        let exactWords: Set<String> = ["console", "shell", "zsh", "bash", "fish", "tmux", "pty", "控制台", "调试控制台"]
        if exactWords.contains(lower) { return true }

        let phrases = ["integrated terminal", "debug console", "调试控制台", "interactive shell", "lldb"]
        return phrases.contains(where: { lower.contains($0) })
    }

    private static func hasPrefixWithBoundary(_ text: String, prefix: String) -> Bool {
        guard text.hasPrefix(prefix) else { return false }
        if text.count == prefix.count { return true }
        let nextChar = text[text.index(text.startIndex, offsetBy: prefix.count)]
        return nextChar.isWhitespace || nextChar.isNumber || ",:-()/·•".contains(nextChar)
    }

    // MARK: - Passive AX Readers

    private static func snapshot(of el: AXUIElement) -> AXNodeSnapshot {
        AXNodeSnapshot(
            role: stringAttr(el, kAXRoleAttribute),
            subrole: stringAttr(el, kAXSubroleAttribute),
            roleDescription: stringAttr(el, kAXRoleDescriptionAttribute),
            identifier: stringAttr(el, kAXIdentifierAttribute),
            domIdentifier: stringAttr(el, "AXDOMIdentifier"),
            domClasses: stringArrayAttr(el, "AXDOMClassList"),
            description: stringAttr(el, kAXDescriptionAttribute),
            title: stringAttr(el, kAXTitleAttribute)
        )
    }

    private static func stringAttr(_ el: AXUIElement, _ attr: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success,
              let str = value as? String else { return "" }
        return str
    }

    private static func stringArrayAttr(_ el: AXUIElement, _ attr: String) -> [String] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success,
              let arr = value as? [String] else { return [] }
        return arr
    }

    private static func parentElement(of el: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &value) == .success,
              let raw = value,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }
}
