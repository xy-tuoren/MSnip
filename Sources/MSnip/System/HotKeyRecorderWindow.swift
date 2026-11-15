import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 全局快捷键自由录制面板控制器（录制期间自动挂起现有全局热键防拦截，关闭时立即恢复生效）
@MainActor
final class HotKeyRecorderController: NSObject, NSWindowDelegate {
    enum Slot: CaseIterable {
        case capture
        case pin
        case ocr

        var title: String {
            switch self {
            case .capture: return "区域截图 / 长截图 / 录动图"
            case .pin:     return "从剪贴板贴图 / 截图贴出"
            case .ocr:     return "框选提取文字 (Quick OCR)"
            }
        }

        var subtitle: String {
            switch self {
            case .capture: return "冻结屏幕并框选、标注、滚动长截图或录制 GIF/MP4"
            case .pin:     return "将剪贴板图像/色值钉在桌面，或在截图中直接贴出"
            case .ocr:     return "框选任意屏幕区域后直接弹出双栏实况识字对照窗"
            }
        }
    }

    var onBeginRecording: (() -> Void)?
    var onConfigUpdated: ((AppConfig) -> Void)?

    private var window: NSWindow?
    private var configSnapshot = AppConfig()
    private var activeRecordingSlot: Slot?
    private var pills: [Slot: RecorderKeyPill] = [:]
    private let statusLabel = NSTextField(labelWithString: "点击右侧键帽即可录入新组合键（需含 ⌘ / ⌥ / ⌃ 之一，或直接按 F1–F19）")

    func show(with config: AppConfig) {
        self.configSnapshot = config
        if let win = window {
            refreshAllPills()
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }

        let win = KeyInterceptWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "自定义全局快捷键"
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.delegate = self
        win.onKeyDownIntercept = { [weak self] event in
            self?.handleRecordedKeyEvent(event) ?? false
        }

        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 460, height: 300))
        root.material = .windowBackground
        root.blendingMode = .behindWindow
        root.state = .active

        let header = NSTextField(labelWithString: "自定义全局快捷键")
        header.font = .systemFont(ofSize: 16, weight: .bold)
        header.frame = NSRect(x: 24, y: 246, width: 320, height: 24)
        root.addSubview(header)

        statusLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 24, y: 224, width: 412, height: 18)
        root.addSubview(statusLabel)

        var rowY: CGFloat = 166
        for slot in Slot.allCases {
            let row = buildRow(for: slot, y: rowY)
            root.addSubview(row)
            rowY -= 54
        }

        let resetBtn = NSButton(title: "恢复当前预设默认", target: self, action: #selector(resetToPresetDefaults))
        resetBtn.bezelStyle = .rounded
        resetBtn.frame = NSRect(x: 20, y: 16, width: 146, height: 30)
        root.addSubview(resetBtn)

        let doneBtn = NSButton(title: "完成", target: self, action: #selector(closePanel))
        doneBtn.bezelStyle = .rounded
        doneBtn.keyEquivalent = "\r"
        doneBtn.frame = NSRect(x: 356, y: 16, width: 84, height: 30)
        root.addSubview(doneBtn)

        win.contentView = root
        win.center()
        self.window = win
        refreshAllPills()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    private func buildRow(for slot: Slot, y: CGFloat) -> NSView {
        let card = NSView(frame: NSRect(x: 24, y: y, width: 412, height: 46))
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor

        let title = NSTextField(labelWithString: slot.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.frame = NSRect(x: 12, y: 23, width: 258, height: 18)
        card.addSubview(title)

        let sub = NSTextField(labelWithString: slot.subtitle)
        sub.font = .systemFont(ofSize: 10.5)
        sub.textColor = .secondaryLabelColor
        sub.frame = NSRect(x: 12, y: 6, width: 266, height: 15)
        card.addSubview(sub)

        let pill = RecorderKeyPill(frame: NSRect(x: 286, y: 8, width: 114, height: 30))
        pill.onClick = { [weak self] in
            self?.toggleRecording(slot: slot)
        }
        pills[slot] = pill
        card.addSubview(pill)
        return card
    }

    private func toggleRecording(slot: Slot) {
        if activeRecordingSlot == slot {
            activeRecordingSlot = nil
            onConfigUpdated?(configSnapshot)
            statusLabel.stringValue = "已取消录入"
            statusLabel.textColor = .secondaryLabelColor
        } else {
            activeRecordingSlot = slot
            onBeginRecording?()
            statusLabel.stringValue = "正在录入「\(slot.title)」：请按下快捷键（Esc 取消，⌫ 恢复默认）"
            statusLabel.textColor = .controlAccentColor
        }
        refreshAllPills()
    }

    private func handleRecordedKeyEvent(_ event: NSEvent) -> Bool {
        guard let slot = activeRecordingSlot else { return false }
        if event.keyCode == 53 { // Esc 取消录入
            activeRecordingSlot = nil
            onConfigUpdated?(configSnapshot)
            statusLabel.stringValue = "已取消录入"
            statusLabel.textColor = .secondaryLabelColor
            refreshAllPills()
            return true
        }
        if event.keyCode == 51 || event.keyCode == 117 { // Delete 恢复该项默认
            setCombo(nil, for: slot)
            activeRecordingSlot = nil
            onConfigUpdated?(configSnapshot)
            statusLabel.stringValue = "已恢复「\(slot.title)」为默认热键"
            statusLabel.textColor = .secondaryLabelColor
            refreshAllPills()
            return true
        }
        guard let combo = KeyCombo.from(event: event) else {
            NSSound.beep()
            statusLabel.stringValue = "请包含 ⌘ / ⌥ / ⌃ 修饰键（例如 ⌘⇧S、⌥X），或按 F1–F19"
            statusLabel.textColor = .systemOrange
            return true
        }

        // 冲突检测：不能与另外两项热键完全相同
        for other in Slot.allCases where other != slot && currentCombo(for: other) == combo {
            NSSound.beep()
            statusLabel.stringValue = "「\(combo.displayString)」已被「\(other.title)」占用，请换一个组合"
            statusLabel.textColor = .systemRed
            return true
        }

        configSnapshot.hotKeysEnabled = true
        setCombo(combo, for: slot)
        activeRecordingSlot = nil
        onConfigUpdated?(configSnapshot)
        statusLabel.stringValue = "已设置「\(slot.title)」为 \(combo.displayString)"
        statusLabel.textColor = .systemGreen
        refreshAllPills()
        return true
    }

    private func currentCombo(for slot: Slot) -> KeyCombo {
        switch slot {
        case .capture: return configSnapshot.activeCaptureCombo
        case .pin:     return configSnapshot.activePinCombo
        case .ocr:     return configSnapshot.activeOCRCombo
        }
    }

    private func setCombo(_ combo: KeyCombo?, for slot: Slot) {
        switch slot {
        case .capture: configSnapshot.customCaptureCombo = combo
        case .pin:     configSnapshot.customPinCombo = combo
        case .ocr:     configSnapshot.customOCRCombo = combo
        }
    }

    private func refreshAllPills() {
        for slot in Slot.allCases {
            pills[slot]?.configure(
                label: currentCombo(for: slot).displayString,
                recording: activeRecordingSlot == slot
            )
        }
    }

    @objc private func resetToPresetDefaults() {
        activeRecordingSlot = nil
        configSnapshot.clearCustomHotKeys()
        onConfigUpdated?(configSnapshot)
        statusLabel.stringValue = "已恢复全部快捷键为当前预设方案"
        statusLabel.textColor = .secondaryLabelColor
        refreshAllPills()
    }

    @objc private func closePanel() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if activeRecordingSlot != nil {
            activeRecordingSlot = nil
            onConfigUpdated?(configSnapshot)
        }
    }
}

/// 优先拦截快捷键录入事件的定制窗口
private final class KeyInterceptWindow: NSWindow {
    var onKeyDownIntercept: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onKeyDownIntercept?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDownIntercept?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// 可点击进入录制态的键帽胶囊按钮
private final class RecorderKeyPill: NSView {
    var onClick: (() -> Void)?
    private var text: String = ""
    private var isRecording = false

    func configure(label: String, recording: Bool) {
        self.text = recording ? "按下快捷键…" : label
        self.isRecording = recording
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: r, cornerWidth: 7, cornerHeight: 7, transform: nil)
        let fill = isRecording
            ? NSColor.controlAccentColor.withAlphaComponent(0.20)
            : NSColor.labelColor.withAlphaComponent(0.08)
        let stroke = isRecording
            ? NSColor.controlAccentColor
            : NSColor.labelColor.withAlphaComponent(0.22)
        ctx.setFillColor(fill.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setStrokeColor(stroke.cgColor)
        ctx.setLineWidth(isRecording ? 1.5 : 1.0)
        ctx.addPath(path)
        ctx.strokePath()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: isRecording ? 11.5 : 13, weight: .semibold),
            .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor
        ]
        let ns = text as NSString
        let sz = ns.size(withAttributes: attrs)
        ns.draw(at: CGPoint(x: (bounds.width - sz.width) * 0.5, y: (bounds.height - sz.height) * 0.5), withAttributes: attrs)
    }
}
