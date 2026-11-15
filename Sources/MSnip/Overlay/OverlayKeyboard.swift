import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 覆盖层的 PixPin 风格全键盘快捷键路由扩展
extension OverlayView {
    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        optionPressed = flags.contains(.option)

        // 轻按并松开单独 Shift 键：循环切换放大镜色值格式（HEX / RGB / HSL / HSV）
        if event.keyCode == 56 || event.keyCode == 60 {
            if flags == .shift {
                shiftTapCandidate = true
            } else if !flags.contains(.shift), shiftTapCandidate {
                shiftTapCandidate = false
                if !isEditingText { cycleColorFormat() }
            } else {
                shiftTapCandidate = false
            }
        } else {
            shiftTapCandidate = false
        }
    }

    override func keyDown(with event: NSEvent) {
        shiftTapCandidate = false
        if isEditingText { return }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let ctrl = flags.contains(.control)
        let shift = flags.contains(.shift)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if event.keyCode == 49 { // Space
            spacePressed = true
            return
        }
        if event.keyCode == 53 { // Esc 分层回退
            if eyedropperActive {
                eyedropperActive = false
            } else if selectedObjectIndex != nil {
                selectedObjectIndex = nil
            } else if selection != nil && doc.isEmpty {
                selection = nil
                activeTool = nil
                cornerRadiusPt = 0
                backdropStyle = .none
                refreshAutoSnapAtCurrentMouse()
            } else {
                onCancel?()
            }
            return
        }
        if event.keyCode == 48 { // Tab 切换色值格式
            cycleColorFormat()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 || (cmd && chars == "c") { // Return / Enter / ⌘C
            exportAndFinish(mode: .copy)
            return
        }
        if cmd && chars == "s" {
            exportAndFinish(mode: .save)
            return
        }
        if (cmd && chars == "2") || event.keyCode == 99 { // ⌘2 或 F3 贴图
            exportAndFinish(mode: .pin)
            return
        }
        if cmd && chars == "a" { // ⌘A 全选当前屏幕
            selection = bounds
            return
        }
        if cmd && chars == "o" { // ⌘O 识别文字
            exportAndFinish(mode: .extractText)
            return
        }
        if cmd && (chars == "z" || chars == "y") {
            selectedObjectIndex = nil
            let isRedo = (chars == "y") || shift
            _ = isRedo ? doc.redo() : doc.undo()
            updateToolbarLayout()
            needsDisplay = true
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 { // Delete / ForwardDelete
            if cmd && shift {
                doc.clearAll()
                selectedObjectIndex = nil
                updateToolbarLayout()
                needsDisplay = true
            } else if let idx = selectedObjectIndex {
                doc.remove(at: idx)
                selectedObjectIndex = nil
                updateToolbarLayout()
                needsDisplay = true
            }
            return
        }

        // 方向键：未选定时 1px 移动光标；已选定时 平移 / ⌃扩展边缘 / ⇧收缩边缘
        switch event.keyCode {
        case 123: handleArrowKey(dx: -1, dy: 0, ctrl: ctrl, shift: shift); return // ←
        case 124: handleArrowKey(dx: 1, dy: 0, ctrl: ctrl, shift: shift); return  // →
        case 125: handleArrowKey(dx: 0, dy: 1, ctrl: ctrl, shift: shift); return  // ↓
        case 126: handleArrowKey(dx: 0, dy: -1, ctrl: ctrl, shift: shift); return // ↑
        default: break
        }

        // 单字母 PixPin 快捷操作（无 ⌘ / ⌃ 修饰）
        if !cmd, !ctrl {
            switch chars {
            case "c":
                copyColorAtCursorAndFinish()
                return
            case "x":
                copyCoordinatesAtCursorAndFinish()
                return
            case "g":
                useRelativeCoordinates.toggle()
                return
            case "t":
                exportAndFinish(mode: .extractText)
                return
            case "l":
                beginLongShot()
                return
            case "v":
                beginRegionRecording()
                return
            case "p":
                cycleBackdropStyle()
                return
            case "r":
                if let prev = lastHistorySelection {
                    selection = Geometry.clampRect(prev, within: bounds)
                }
                return
            case "b":
                cycleCornerRadius()
                return
            case "i":
                if selection == nil, let snap = hoveredAutoRect { selection = snap }
                eyedropperActive.toggle()
                return
            case "m", "`", "~":
                magnifierPinned.toggle()
                return
            case "h", "/", "?":
                showShortcutTips.toggle()
                onPrefsChanged?(colorCopyFormat, showShortcutTips)
                return
            case "w":
                warpCursorByPixels(dx: 0, dy: shift ? -5 : -1); return
            case "s":
                warpCursorByPixels(dx: 0, dy: shift ? 5 : 1); return
            case "a":
                warpCursorByPixels(dx: shift ? -5 : -1, dy: 0); return
            case "d":
                warpCursorByPixels(dx: shift ? 5 : 1, dy: 0); return
            default:
                break
            }

            if let n = Int(chars), let tool = ToolKind(rawValue: n) {
                eyedropperActive = false
                if selection == nil, let snap = hoveredAutoRect {
                    selection = snap
                }
                activeTool = (activeTool == tool) ? nil : tool
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spacePressed = false }
    }
}
