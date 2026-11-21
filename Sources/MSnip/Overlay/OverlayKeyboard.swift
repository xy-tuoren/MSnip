import AppKit
import Carbon
import CoreGraphics
import Foundation
import MSnipCore

/// 覆盖层极速单字母快捷键与鼠标右键取消路由（物理键码优先，中文输入法与大写锁定下同样零延迟生效）
extension OverlayView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "c",
           toolbar.inPlaceOCRActive, let liveV = inPlaceOCRView, liveV.copySelectionIfActive() {
            ToastHUD.show(message: "已复制划选文字")
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

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
        let opt = flags.contains(.option)
        let letter = ansiLetter(for: event.keyCode) ?? (event.charactersIgnoringModifiers?.lowercased() ?? "")

        if event.keyCode == 49 { // Space：拖拽中按住平移选框；静止时轻按开关四向像素卡尺测距
            if dragOp != nil {
                spacePressed = true
            } else if !event.isARepeat {
                caliperActive.toggle()
            }
            return
        }
        if event.keyCode == 53 { handleEscapeStepBack(); return } // Esc
        if event.keyCode == 48 { cycleColorFormat(); return } // Tab
        if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
            if shift && !cmd && !ctrl { captureCurrentWindowAndFinish(pin: opt) }
            else { exportAndFinish(mode: .copy) }
            return
        }

        // 兼容系统通用 ⌘ 组合键（⌘C / ⌘S / ⌘Z / ⌘A / ⌘2 / ⌘O / ⌘B）
        if cmd {
            switch letter {
            case "c":
                if toolbar.inPlaceOCRActive, let liveV = inPlaceOCRView, liveV.copySelectionIfActive() {
                    ToastHUD.show(message: "已复制划选文字")
                } else {
                    exportAndFinish(mode: .copy)
                }
                return
            case "s":
                if shift { quickSaveInPlace() } else { exportAndFinish(mode: .save) }
                return
            case "b": toggleTextCapsuleMode(); return
            case "2": exportAndFinish(mode: .pin); return
            case "a": selection = bounds; return
            case "o": exportAndFinish(mode: .extractText); return
            case "z", "y":
                performUndoRedo(isRedo: (letter == "y") || shift); return
            default: break
            }
        }
        if event.keyCode == 99 { exportAndFinish(mode: .pin); return } // F3

        if event.keyCode == 51 || event.keyCode == 117 { // Delete / ForwardDelete
            if cmd && shift {
                doc.clearAll(); selectedObjectIndex = nil; updateToolbarLayout(); needsDisplay = true
            } else if let idx = selectedObjectIndex {
                doc.remove(at: idx); selectedObjectIndex = nil; updateToolbarLayout(); needsDisplay = true
            }
            return
        }

        // 方向键：未选区时 1px 移动光标（⇧ 5px）；已选区时 1px 平移 / ⌃扩边 / ⇧缩边
        switch event.keyCode {
        case 123: handleArrowKey(dx: -1, dy: 0, ctrl: ctrl, shift: shift); return
        case 124: handleArrowKey(dx: 1, dy: 0, ctrl: ctrl, shift: shift); return
        case 125: handleArrowKey(dx: 0, dy: 1, ctrl: ctrl, shift: shift); return
        case 126: handleArrowKey(dx: 0, dy: -1, ctrl: ctrl, shift: shift); return
        default: break
        }

        // 左手高频优先单字母快捷键（无 ⌘ / ⌃ 修饰，中英文输入法下均零延迟响应）
        if !cmd, !ctrl {
            if handleSingleKeyShortcut(letter, shift: shift, opt: opt) { return }
            if let raw = event.charactersIgnoringModifiers, let n = Int(raw), let tool = ToolKind(rawValue: n) {
                toggleToolShortcut(tool)
            }
        }
    }

    private func handleSingleKeyShortcut(_ key: String, shift: Bool, opt: Bool) -> Bool {
        switch key {
        // 1) 高频结束 / 输出动作
        case "c":
            if selection != nil && !opt && !eyedropperActive {
                if toolbar.inPlaceOCRActive, let liveV = inPlaceOCRView, liveV.copySelectionIfActive() {
                    ToastHUD.show(message: "已复制划选文字")
                } else {
                    exportAndFinish(mode: .copy)
                }
            } else if selection != nil {
                if let sample = samplePixelAtCursor() {
                    let txt = sample.color.formatted(as: colorCopyFormat)
                    ClipboardAndSave.copyText(txt)
                    ToastHUD.show(message: "色值 \(txt) 已复制", swatch: sample.color)
                }
            } else {
                copyColorAtCursorAndFinish()
            }
        case "s":
            if shift { exportAndFinish(mode: .save) } else { quickSaveInPlace() }
        case "p":
            exportAndFinish(mode: .pin)
        case "q":
            onCancel?()

        // 2) 左手高频标注工具 + 单键撤销/重做
        case "r": toggleToolShortcut(shift ? .ellipse : .rect)
        case "a": toggleToolShortcut(.arrow)
        case "d": toggleToolShortcut(shift ? .highlighter : .pen)
        case "w": toggleToolShortcut(.text)
        case "m": toggleToolShortcut(shift ? .gaussianBlur : .mosaic)
        case "n": toggleToolShortcut(.step)
        case "z": performUndoRedo(isRedo: shift)

        // 3) 多模态扩展：识字 / 翻译 / 长截图 / 录屏
        case "t":
            if opt { exportAndFinish(mode: .extractText) } else { toggleInPlaceOCR() }
        case "y":
            if opt { exportAndFinish(mode: .translateWindow) } else { toggleInPlaceTranslate() }
        case "l": beginLongShot()
        case "v": beginRegionRecording()

        // 4) 外观、窗口对齐与辅助微调
        case "b": toggleCornerRadiusSlider(resetOnly: opt)
        case "f":
            if opt { captureCurrentWindowAndFinish(pin: false) } else { snapSelectionToUnderlyingWindow() }
        case "e":
            if let prev = lastHistorySelection { selection = Geometry.clampRect(prev, within: bounds) }
        case "g": cycleBackdropStyle()
        case "k": toggleTextCapsuleMode()
        case "i":
            if selection == nil, let snap = hoveredAutoRect { selection = snap }
            eyedropperActive.toggle()
        case "x":
            if shift {
                useRelativeCoordinates.toggle()
            } else if selection != nil, let sample = samplePixelAtCursor() {
                let coord = formattedCoordinateAtCursor(px: sample.px, py: sample.py)
                ClipboardAndSave.copyText(coord.copyValue)
                ToastHUD.show(message: "坐标 \(coord.copyValue) 已复制")
            } else {
                copyCoordinatesAtCursorAndFinish()
            }
        case "`", "~": magnifierPinned.toggle()
        case "[", "-":
            if selection != nil { adjustAnnotationSize(by: shift ? -3.0 : -1.0) }
        case "]", "=", "+":
            if selection != nil { adjustAnnotationSize(by: shift ? 3.0 : 1.0) }
        case "h", "/", "?":
            showShortcutTips.toggle()
            onPrefsChanged?(colorCopyFormat, showShortcutTips)
        default:
            return false
        }
        return true
    }

    private func toggleToolShortcut(_ tool: ToolKind) {
        eyedropperActive = false
        deactivateInPlaceOCR()
        deactivateInPlaceTranslate()
        if selection == nil, let snap = hoveredAutoRect { selection = snap }
        activeTool = (activeTool == tool) ? nil : tool
        updateToolbarLayout()
    }

    private func performUndoRedo(isRedo: Bool) {
        selectedObjectIndex = nil
        _ = isRedo ? doc.redo() : doc.undo()
        updateToolbarLayout()
        needsDisplay = true
    }

    private func handleEscapeStepBack() {
        if caliperActive { caliperActive = false }
        else if eyedropperActive { eyedropperActive = false }
        else if isCornerSliderVisible { isCornerSliderVisible = false; updateToolbarLayout() }
        else if toolbar.inPlaceTranslateActive { deactivateInPlaceTranslate() }
        else if toolbar.inPlaceOCRActive { deactivateInPlaceOCR() }
        else if selectedObjectIndex != nil { selectedObjectIndex = nil }
        else if activeTool != nil { activeTool = nil; updateToolbarLayout() }
        else if selection != nil && doc.isEmpty {
            selection = nil; cornerRadiusRatio = 0; backdropStyle = .none
            refreshAutoSnapAtCurrentMouse()
        } else {
            onCancel?()
        }
    }

    /// 物理 ANSI 键码映射到标准小写字母（免疫中文输入法与 CapsLock）
    private func ansiLetter(for keyCode: UInt16) -> String? {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "a"; case kVK_ANSI_B: return "b"; case kVK_ANSI_C: return "c"
        case kVK_ANSI_D: return "d"; case kVK_ANSI_E: return "e"; case kVK_ANSI_F: return "f"
        case kVK_ANSI_G: return "g"; case kVK_ANSI_H: return "h"; case kVK_ANSI_I: return "i"
        case kVK_ANSI_K: return "k"; case kVK_ANSI_L: return "l"; case kVK_ANSI_M: return "m"
        case kVK_ANSI_N: return "n"; case kVK_ANSI_O: return "o"; case kVK_ANSI_P: return "p"
        case kVK_ANSI_Q: return "q"; case kVK_ANSI_R: return "r"; case kVK_ANSI_S: return "s"
        case kVK_ANSI_T: return "t"; case kVK_ANSI_V: return "v"; case kVK_ANSI_W: return "w"
        case kVK_ANSI_X: return "x"; case kVK_ANSI_Y: return "y"; case kVK_ANSI_Z: return "z"
        case kVK_ANSI_LeftBracket: return "["; case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Minus: return "-"; case kVK_ANSI_Equal: return "="
        case kVK_ANSI_Grave: return "`"
        default: return nil
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spacePressed = false }
    }

    /// 鼠标右键快捷取消：已有选框时一键取消当前选框回到自动吸附重新框选；无选框时直接退出截图
    override func rightMouseDown(with event: NSEvent) {
        shiftTapCandidate = false
        if isEditingText { cancelTextEditing(); return }
        if caliperActive { caliperActive = false; return }
        if eyedropperActive { eyedropperActive = false; return }
        if selection != nil || dragOp != nil {
            dragOp = nil; draftAnnotation = nil; activeTool = nil; selectedObjectIndex = nil
            deactivateInPlaceOCR(); deactivateInPlaceTranslate()
            isCornerSliderVisible = false; cornerRadiusRatio = 0; backdropStyle = .none
            doc = AnnotationDocument(); selection = nil
            lastMousePoint = convert(event.locationInWindow, from: nil)
            refreshAutoSnapAtCurrentMouse(); syncMagnifierView()
            return
        }
        onCancel?()
    }
}
