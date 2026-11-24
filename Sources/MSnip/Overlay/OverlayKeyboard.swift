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

        if event.keyCode == 49 { // Space：拖拽中按住平移选框
            if dragOp != nil { spacePressed = true }
            return
        }
        if event.keyCode == 53 {
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == OverlayMenuFocusGuard.syntheticEscMagic { return }
            handleEscapeStepBack(); return
        } // Esc
        if event.keyCode == 48 { cycleColorFormat(); return } // Tab
        if event.keyCode == 36 || event.keyCode == 76 { // Return / Enter
            if isRecordingMode { confirmBeginRegionRecording() }
            else if shift && !cmd && !ctrl { captureCurrentWindowAndFinish(pin: opt) }
            else if opt && !cmd && !ctrl { exportAndFinish(mode: .copyWithPath) }
            else { exportAndFinish(mode: .copy) }
            return
        }

        if let pCombo = activePinCombo, KeyCombo.from(event: event) == pCombo {
            exportAndFinish(mode: .pin)
            return
        }

        // 兼容系统通用 ⌘ 组合键（⌘C / ⌘S / ⌘Z / ⌘A / ⌘O / ⌘B）
        if cmd {
            switch letter {
            case "c":
                if toolbar.inPlaceOCRActive, let liveV = inPlaceOCRView, liveV.copySelectionIfActive() {
                    ToastHUD.show(message: "已复制划选文字")
                } else {
                    exportAndFinish(mode: shift ? .copyWithPath : .copy)
                }
                return
            case "s":
                if shift { exportAndFinish(mode: .save) } else { quickSaveInPlace() }
                return
            case "b": toggleTextCapsuleMode(); return
            case "a": selection = bounds; return
            case "o": exportAndFinish(mode: .extractText); return
            case "z", "y":
                performUndoRedo(isRedo: (letter == "y") || shift); return
            default: break
            }
        }

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
            if handleSingleKeyShortcut(letter, shift: shift, opt: opt, isRepeat: event.isARepeat) { return }
            if !isRecordingMode, let raw = event.charactersIgnoringModifiers, let n = Int(raw), let tool = ToolKind(rawValue: n) {
                toggleToolShortcut(tool)
            }
        }
    }

    private func matchedCanvasAction(for key: String) -> CanvasAction? {
        let lower = key.lowercased()
        return CanvasAction.allCases.first { (canvasKeyMap[$0] ?? $0.defaultKey).lowercased() == lower }
    }

    private func handleSingleKeyShortcut(_ key: String, shift: Bool, opt: Bool, isRepeat: Bool) -> Bool {
        if isRecordingMode {
            if key == "`" || key == "~" {
                if !shift && !opt && !isRepeat { magnifierVisibilityOverride = magnifierView.isHidden }; return true
            }
            if key == "/" || key == "?" {
                showShortcutTips.toggle(); onPrefsChanged?(colorCopyFormat, showShortcutTips); return true
            }
            guard let act = matchedCanvasAction(for: key) else { return false }
            switch act {
            case .record:          if !isRepeat { toggleRecordingMode() }
            case .cancel:          onCancel?()
            case .snapWindow:      snapSelectionToUnderlyingWindow()
            case .eraser:          if let prev = lastHistorySelection { selection = Geometry.clampRect(prev, within: bounds) }
            case .caliper:         if !shift && !opt && !isRepeat { caliperActive.toggle() }
            case .toggleMagnifier: if !shift && !opt && !isRepeat { magnifierVisibilityOverride = magnifierView.isHidden }
            case .backdropOrCoord: useRelativeCoordinates.toggle()
            case .toggleTips:      showShortcutTips.toggle(); onPrefsChanged?(colorCopyFormat, showShortcutTips)
            default:               return false
            }
            return true
        }

        if key == "[" || key == "-" {
            if selection != nil { adjustAnnotationSize(by: shift ? -3.0 : -1.0) }
            else { stepAutoSnapTier(by: -1) }
            return true
        }
        if key == "]" || key == "=" || key == "+" {
            if selection != nil { adjustAnnotationSize(by: shift ? 3.0 : 1.0) }
            else { stepAutoSnapTier(by: 1) }
            return true
        }
        if key == "`" || key == "~" {
            if !shift && !opt && !isRepeat { magnifierVisibilityOverride = magnifierView.isHidden }; return true
        }
        if key == "/" || key == "?" {
            showShortcutTips.toggle(); onPrefsChanged?(colorCopyFormat, showShortcutTips); return true
        }

        guard let act = matchedCanvasAction(for: key) else { return false }
        switch act {
        case .copy:
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
        case .quickSave:
            if shift { exportAndFinish(mode: .save) } else { quickSaveInPlace() }
        case .pin:
            exportAndFinish(mode: .pin)
        case .cancel:
            onCancel?()
        case .rect:       toggleToolShortcut(shift ? .ellipse : .rect)
        case .arrow:      toggleToolShortcut(.arrow)
        case .pen:        toggleToolShortcut(shift ? .highlighter : .pen)
        case .text:       toggleToolShortcut(.text)
        case .mosaic:     toggleToolShortcut(shift ? .gaussianBlur : .mosaic)
        case .step:       toggleToolShortcut(.step)
        case .caliper:    if !shift && !opt && !isRepeat { caliperActive.toggle() }
        case .ocr:
            if shift { exportAndFinish(mode: .recognizeLatex) }
            else if opt != ocrAutoOpenDualPane { exportAndFinish(mode: .extractText) }
            else { toggleInPlaceOCR() }
        case .translate:
            if opt != translateAutoOpenDualPane { exportAndFinish(mode: .translateWindow) } else { toggleInPlaceTranslate() }
        case .longShot:   beginLongShot()
        case .record:     if !isRepeat { toggleRecordingMode() }
        case .cornerRadius: toggleCornerRadiusSlider(resetOnly: opt)
        case .snapWindow:
            if opt { captureCurrentWindowAndFinish(pin: false) } else { snapSelectionToUnderlyingWindow() }
        case .eraser:
            if selection != nil { toggleToolShortcut(.eraser) }
            else if let prev = lastHistorySelection { selection = Geometry.clampRect(prev, within: bounds) }
        case .backdropOrCoord:
            if selection == nil || shouldShowMagnifier { useRelativeCoordinates.toggle() } else { cycleBackdropStyle() }
        case .textCapsule: toggleTextCapsuleMode()
        case .eyedropper:
            if selection == nil, let snap = hoveredAutoRect { selection = snap }
            eyedropperActive.toggle()
        case .copyCoord:
            if shift { useRelativeCoordinates.toggle() }
            else if selection != nil, let sample = samplePixelAtCursor() {
                let coord = formattedCoordinateAtCursor(px: sample.px, py: sample.py)
                ClipboardAndSave.copyText(coord.copyValue)
                ToastHUD.show(message: "坐标 \(coord.copyValue) 已复制")
            } else {
                copyCoordinatesAtCursorAndFinish()
            }
        case .toggleMagnifier:
            if !shift && !opt && !isRepeat { magnifierVisibilityOverride = magnifierView.isHidden }
        case .toggleTips:
            showShortcutTips.toggle()
            onPrefsChanged?(colorCopyFormat, showShortcutTips)
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
        if isSaveMenuVisible { isSaveMenuVisible = false; updateToolbarLayout() }
        else if caliperActive { caliperActive = false }
        else if eyedropperActive { eyedropperActive = false }
        else if isCornerSliderVisible { isCornerSliderVisible = false; updateToolbarLayout() }
        else if toolbar.inPlaceTranslateActive { deactivateInPlaceTranslate() }
        else if toolbar.inPlaceOCRActive { deactivateInPlaceOCR() }
        else if selectedObjectIndex != nil { selectedObjectIndex = nil }
        else if activeTool != nil { activeTool = nil; updateToolbarLayout() }
        else if selection != nil && (doc.isEmpty || isRecordingMode) {
            selection = nil; cornerRadiusRatio = 0; backdropStyle = .none
            refreshAutoSnapAtCurrentMouse()
        } else {
            onCancel?()
        }
    }

    /// 物理 ANSI 键码映射到标准小写字母或符号（免疫中文输入法与 CapsLock）
    private func ansiLetter(for keyCode: UInt16) -> String? {
        if let token = CanvasAction.singleKeyToken(for: keyCode) { return token }
        switch Int(keyCode) {
        case kVK_ANSI_LeftBracket: return "["; case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Minus: return "-";       case kVK_ANSI_Equal: return "="
        case kVK_ANSI_Grave: return "`";       case kVK_ANSI_Slash: return "/"
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
        if isSaveMenuVisible { isSaveMenuVisible = false; updateToolbarLayout(); return }
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
