import AppKit
import Carbon
import CoreGraphics
import Foundation
import MSnipCore

/// 覆盖层极速单字母快捷键与鼠标右键取消路由（物理键码优先，中文输入法与大写锁定下同样零延迟生效）
extension OverlayView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !isEditingText else { return super.performKeyEquivalent(with: event) }
        if let pCombo = activePinCombo, KeyCombo.from(event: event) == pCombo { exportAndFinish(mode: .pin); return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
           handleCommandShortcut(event, shift: flags.contains(.shift)) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func handleCommandShortcut(_ event: NSEvent, shift: Bool) -> Bool {
        let letter = ansiLetter(for: event.keyCode) ?? (event.charactersIgnoringModifiers?.lowercased() ?? "")
        switch letter {
        case "c":
            if toolbar.inPlaceOCRActive, let liveV = inPlaceOCRView, liveV.copySelectionIfActive() { ToastHUD.show(message: L("已复制划选文字")) }
            else if !shift, let idx = selectedObjectIndex, doc.objects.indices.contains(idx) {
                copiedAnnotation = doc.objects[idx]; pasteCascadeCount = 0; ToastHUD.show(message: L("已复制标注图形 · 按 ⌘V 粘贴（⌘D 直接克隆）"))
            } else { exportAndFinish(mode: shift ? .copyWithPath : .copy) }
            return true
        case "v": pasteCopiedAnnotationIfAny(); return true
        case "d": duplicateSelectedAnnotationIfAny(); return true
        case "s": if shift { exportAndFinish(mode: .save) } else { quickSaveInPlace() }; return true
        case "b": toggleTextCapsuleMode(); return true
        case "a": selection = bounds; return true
        case "o": exportAndFinish(mode: ocrPresentation == .silentCopy ? .silentOCR : .extractText); return true
        case "z", "y": performUndoRedo(isRedo: (letter == "y") || shift); return true
        default: return false
        }
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

        if event.keyCode == 49 { if dragOp != nil || selection != nil { spacePressed = true }; return }
        if event.keyCode == 53 {
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == OverlayMenuFocusGuard.syntheticEscMagic { return }
            handleEscapeStepBack(); return
        }
        if event.keyCode == 48 { cycleColorFormat(); return }
        if event.keyCode == 36 || event.keyCode == 76 {
            if isRecordingMode { confirmBeginRegionRecording() }
            else if shift && !cmd && !ctrl { captureCurrentWindowAndFinish(pin: opt) }
            else if opt && !cmd && !ctrl { exportAndFinish(mode: .copyWithPath) }
            else { exportAndFinish(mode: .copy) }
            return
        }
        if let pCombo = activePinCombo, KeyCombo.from(event: event) == pCombo { exportAndFinish(mode: .pin); return }
        if cmd, !ctrl, !opt, handleCommandShortcut(event, shift: shift) { return }

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
                    ToastHUD.show(message: L("已复制划选文字"))
                } else {
                    exportAndFinish(mode: .copy)
                }
            } else if selection != nil {
                if let sample = samplePixelAtCursor() {
                    let txt = sample.color.formatted(as: colorCopyFormat)
                    ClipboardAndSave.copyText(txt)
                    ToastHUD.show(message: L("色值 %@ 已复制", txt), swatch: sample.color)
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
            if shift { exportAndFinish(mode: .recognizeLatex) } else {
                switch ocrPresentation.resolvedTrigger(inPlaceActive: toolbar.inPlaceOCRActive, optionHeld: opt) {
                case .toggleInPlace:      toggleInPlaceOCR()
                case .openDualPane:       exportAndFinish(mode: .extractText)
                case .silentCopyAndClose: exportAndFinish(mode: .silentOCR)
                }
            }
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
            if selection == nil || shouldShowMagnifier { useRelativeCoordinates.toggle() } else { toggleGlowSlider() }
        case .textCapsule: toggleTextCapsuleMode()
        case .eyedropper:
            if selection == nil, let snap = hoveredAutoRect { selection = snap }
            eyedropperActive.toggle()
        case .copyCoord:
            if shift { useRelativeCoordinates.toggle() }
            else if selection != nil, let sample = samplePixelAtCursor() {
                let coord = formattedCoordinateAtCursor(px: sample.px, py: sample.py)
                ClipboardAndSave.copyText(coord.copyValue)
                ToastHUD.show(message: L("坐标 %@ 已复制", coord.copyValue))
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
        else if activeSideSlider != nil { activeSideSlider = nil; updateToolbarLayout() }
        else if toolbar.inPlaceTranslateActive { deactivateInPlaceTranslate() }
        else if toolbar.inPlaceOCRActive { deactivateInPlaceOCR() }
        else if selectedObjectIndex != nil { selectedObjectIndex = nil }
        else if activeTool != nil { activeTool = nil; updateToolbarLayout() }
        else if selection != nil && (doc.isEmpty || isRecordingMode) {
            selection = nil; cornerRadiusRatio = 0; glowStrength = 0; didAdjustGlow = false
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
            activeSideSlider = nil; cornerRadiusRatio = 0; glowStrength = 0; didAdjustGlow = false
            doc = AnnotationDocument(); selection = nil
            lastMousePoint = convert(event.locationInWindow, from: nil)
            refreshAutoSnapAtCurrentMouse(); syncMagnifierView()
            return
        }
        onCancel?()
    }
}

// MARK: - 选区导出、快捷键与像素微调

/// 覆盖层的标注草稿构建、取色/坐标复制、1px 边缘微调与导出烘焙扩展
extension OverlayView {
    enum FinishMode: Equatable { case copy, copyWithPath, save, quickSave, saveToFolder(String), pin, extractText, silentOCR, recognizeLatex, translateWindow }

    func currentExportableImage(for targetRect: CGRect, plainForOCR: Bool, includeGlow: Bool = true) -> CGImage? {
        let baseImg: CGImage?
        if !plainForOCR, let translated = inPlaceTranslateView?.translatedImage {
            if cornerRadiusPt > 0.5 {
                let rPx = min(cornerRadiusPt * snapshot.scaleFactor, CGFloat(min(translated.width, translated.height)) * 0.5)
                let cs = (translated.colorSpace?.model == .rgb && translated.colorSpace?.supportsOutput == true)
                    ? translated.colorSpace!
                    : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
                if let ctx = CGContext(
                    data: nil, width: translated.width, height: translated.height,
                    bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) {
                    let rect = CGRect(x: 0, y: 0, width: translated.width, height: translated.height)
                    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rPx, cornerHeight: rPx, transform: nil))
                    ctx.clip(); ctx.draw(translated, in: rect)
                    baseImg = ctx.makeImage() ?? translated
                } else { baseImg = translated }
            } else { baseImg = translated }
        } else {
            baseImg = AnnotationRenderer.bakeExportImage(
                sampler: snapshot.sampler, selection: targetRect, imageScale: snapshot.scaleFactor,
                annotations: doc.objects, cornerRadiusPt: plainForOCR ? 0 : cornerRadiusPt
            )
        }
        guard let img = baseImg else { return nil }
        if !plainForOCR && includeGlow && glowStrength > 0.005 {
            return BackdropBeautifier.applyLuminousGlow(
                to: img, imageScale: snapshot.scaleFactor, glowIntensity: glowStrength, innerCornerRadiusPt: cornerRadiusPt
            )
        }
        return img
    }

    func cycleColorFormat() {
        colorCopyFormat = colorCopyFormat.next
        onPrefsChanged?(colorCopyFormat, showShortcutTips)
    }

    func copyColorAtCursorAndFinish() {
        guard let sample = samplePixelAtCursor() else { return }
        let formatted = sample.color.formatted(as: colorCopyFormat)
        onFinishCopyColor?(formatted, sample.color, NSEvent.mouseLocation)
    }

    func copyCoordinatesAtCursorAndFinish() {
        guard let sample = samplePixelAtCursor() else { return }
        let coord = formattedCoordinateAtCursor(px: sample.px, py: sample.py)
        onFinishCopyText?(coord.copyValue, NSEvent.mouseLocation)
    }

    func exportAndFinish(mode: FinishMode) {
        commitTextEditing()
        let isPlainOCR = (mode == .extractText || mode == .silentOCR || mode == .recognizeLatex || mode == .translateWindow)
        guard let targetRect = selection ?? hoveredAutoRect,
              targetRect.width >= 2, targetRect.height >= 2,
              let baked = currentExportableImage(for: targetRect, plainForOCR: isPlainOCR, includeGlow: mode != .pin) else { return }

        switch mode {
        case .copy:            onFinishCopy?(baked, snapshot.scaleFactor, targetRect)
        case .copyWithPath:    onFinishCopyWithPath?(baked, snapshot.scaleFactor, targetRect)
        case .save:              onFinishSave?(baked, snapshot.scaleFactor, targetRect)
        case .quickSave:         onQuickSaveInPlace?(baked, snapshot.scaleFactor, targetRect)
        case .saveToFolder(let d): onFinishSaveToFolder?(baked, snapshot.scaleFactor, d, targetRect)
        case .pin:
            let s = max(1.0, snapshot.scaleFactor)
            let snappedOrigin = CGPoint(x: round(targetRect.minX * s) / s, y: round(targetRect.minY * s) / s)
            onFinishPin?(baked, snapshot.scaleFactor, snappedOrigin, snapshot.screen, targetRect, didAdjustGlow ? glowStrength : nil)
        case .extractText:     onFinishExtractText?(baked, snapshot.scaleFactor, snapshot.screen, targetRect)
        case .silentOCR:       onFinishSilentOCR?(baked, snapshot.scaleFactor, snapshot.screen, targetRect)
        case .recognizeLatex:  onFinishRecognizeLatex?(baked, snapshot.scaleFactor, snapshot.screen, targetRect)
        case .translateWindow: onFinishTranslateWindow?(baked, snapshot.scaleFactor, snapshot.screen, targetRect)
        }
    }

    func pasteCopiedAnnotationIfAny() {
        guard let copied = copiedAnnotation else { return }
        pasteCascadeCount += 1
        let off = CGFloat(pasteCascadeCount) * 16.0
        if let newIdx = doc.pasteClone(of: copied, offset: CGPoint(x: off, y: off), within: selection ?? bounds) {
            selectedObjectIndex = newIdx; updateToolbarLayout(); needsDisplay = true
        }
    }

    func duplicateSelectedAnnotationIfAny() {
        guard let idx = selectedObjectIndex, doc.objects.indices.contains(idx) else { return }
        if let newIdx = doc.duplicate(at: idx, offset: CGPoint(x: 16, y: 16), within: selection ?? bounds) {
            selectedObjectIndex = newIdx; copiedAnnotation = doc.objects[newIdx]; pasteCascadeCount = 0
            updateToolbarLayout(); needsDisplay = true
        }
    }

    /// 识别当前光标或选区中心命中的顶层窗口，一键执行独立窗口纯净透明阴影截图
    func captureCurrentWindowAndFinish(pin: Bool) {
        commitTextEditing()
        let probe = selection.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? lastMousePoint
            ?? CGPoint(x: bounds.midX, y: bounds.midY)
        guard let hit = regionDetector.topWindow(at: probe, in: snapshot) else {
            ToastHUD.show(message: L("当前位置未命中独立应用窗口，请将鼠标移至目标窗口上再按 F 或 ⇧↩"))
            return
        }
        onFinishIsolatedWindow?(
            hit.windowID,
            snapshot.scaleFactor,
            backdropStyle,
            pin,
            hit.localRect.origin,
            snapshot.screen
        )
    }

    func makeDraft(tool: ToolKind, from a: CGPoint, to b: CGPoint, shift: Bool) -> Annotation {
        let endForBox = shift ? Geometry.squareConstrainedEnd(from: a, to: b) : b
        let endForLine = shift ? Geometry.angleSnappedEnd(from: a, to: b) : b
        let payload: AnnotationPayload
        switch tool {
        case .rect:
            payload = .rect(Geometry.normalizedRect(from: a, to: endForBox))
        case .ellipse:
            payload = .ellipse(Geometry.normalizedRect(from: a, to: endForBox))
        case .mosaic:
            payload = .mosaic(Geometry.normalizedRect(from: a, to: b))
        case .gaussianBlur:
            payload = .gaussianBlur(Geometry.normalizedRect(from: a, to: b))
        case .spotlight:
            payload = .spotlight(Geometry.normalizedRect(from: a, to: endForBox))
        case .arrow:
            payload = .arrow(from: a, to: endForLine)
        case .line:
            payload = .line(from: a, to: endForLine)
        case .pen:
            payload = .pen(points: [a, b])
        case .highlighter:
            payload = .highlighter(points: [a, endForLine])
        case .step:
            let stepNum: Int
            if let existing = draftAnnotation, case .step(_, _, let n) = existing.payload {
                stepNum = n
            } else {
                stepNum = doc.nextStepNumber()
            }
            let dist = hypot(endForLine.x - a.x, endForLine.y - a.y)
            let tail = dist >= (style.stepBadgeRadius + 6.0) ? endForLine : nil
            payload = .step(center: a, tail: tail, number: stepNum)
        case .text, .eraser:
            payload = .text(origin: a, content: "", measuredSize: .zero)
        }
        return Annotation(payload: payload, style: style)
    }

    // MARK: - Cursor 1px Warp & PixPin Edge Fine-Tuning

    func warpCursorByPixels(dx: Int, dy: Int) {
        let stepPt = 1.0 / max(1.0, snapshot.scaleFactor)
        let curLocal = lastMousePoint ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let nextLocal = CGPoint(
            x: min(max(0, curLocal.x + CGFloat(dx) * stepPt), bounds.width - stepPt),
            y: min(max(0, curLocal.y + CGFloat(dy) * stepPt), bounds.height - stepPt)
        )
        lastMousePoint = nextLocal

        if let primaryH = NSScreen.screens.first?.frame.height {
            let screenOriginTopY = primaryH - snapshot.screen.frame.maxY
            let globalQuartz = CGPoint(x: snapshot.screen.frame.minX + nextLocal.x, y: screenOriginTopY + nextLocal.y)
            CGWarpMouseCursorPosition(globalQuartz)
            CGAssociateMouseAndMouseCursorPosition(1)
        }

        if selection == nil {
            updateAutoSnap(at: nextLocal)
        }
        invalidateMagnifierMove(from: curLocal, to: nextLocal)
    }

    /// 统一同步画笔粗细、文字字号、马赛克/毛玻璃颗粒大小与二级进度条读数
    func applyAnnotationSize(_ rawWidth: CGFloat) {
        let w = min(ToolbarSubbarView.maxStroke, max(ToolbarSubbarView.minStroke, rawWidth.rounded()))
        style.lineWidth = w
        style.fontSize = min(64.0, max(12.0, round(10.0 + w * 3.0)))
        style.mosaicBlockSize = min(36.0, max(5.0, round(4.0 + w * 1.8)))
        toolbar.lineWidth = w
        subbar.lineWidth = w
        applyTextFieldVisualStyle()
        if let selIdx = selectedObjectIndex {
            doc.modifyWithHistory(at: selIdx) {
                $0.style.lineWidth = style.lineWidth
                $0.style.fontSize = style.fontSize
                $0.style.mosaicBlockSize = style.mosaicBlockSize
                if case .text(let origin, let content, _) = $0.payload {
                    let newSz = AnnotationRenderer.measureText(content, fontSize: $0.style.fontSize, capsule: $0.style.textCapsule)
                    $0.payload = .text(origin: origin, content: content, measuredSize: newSz)
                }
            }
        }
        onStyleChanged?(colorIndex, style.lineWidth)
        needsDisplay = true
    }

    func adjustAnnotationSize(by delta: CGFloat) {
        applyAnnotationSize(style.lineWidth + delta)
    }

    func handleArrowKey(dx: CGFloat, dy: CGFloat, ctrl: Bool, shift: Bool) {
        if let idx = selectedObjectIndex {
            let step: CGFloat = shift ? 5.0 : 1.0
            doc.modifyWithHistory(at: idx) { $0.translate(dx: dx * step, dy: dy * step) }
            updateToolbarLayout()
            needsDisplay = true
            return
        }

        // 激活任意标注工具时（画笔/马赛克/毛玻璃/矩形/箭头/文字/序号），方向键 ↑/→ 调大、↓/← 缩小（按住 ⇧ 加速）
        if selection != nil, activeTool != nil, !ctrl {
            let step: CGFloat = shift ? 3.0 : 1.0
            let dir: CGFloat = (dy < 0 || dx > 0) ? 1.0 : -1.0
            adjustAnnotationSize(by: dir * step)
            return
        }

        guard var sel = selection else {
            let mul = shift ? 5 : 1
            warpCursorByPixels(dx: Int(dx) * mul, dy: Int(dy) * mul)
            return
        }

        if ctrl {
            if dx < 0 { sel.origin.x -= 1; sel.size.width += 1 }
            if dx > 0 { sel.size.width += 1 }
            if dy < 0 { sel.origin.y -= 1; sel.size.height += 1 }
            if dy > 0 { sel.size.height += 1 }
            selection = sel.intersection(bounds)
        } else if shift {
            if dx < 0, sel.width > 8 { sel.size.width -= 1 }
            if dx > 0, sel.width > 8 { sel.origin.x += 1; sel.size.width -= 1 }
            if dy < 0, sel.height > 8 { sel.size.height -= 1 }
            if dy > 0, sel.height > 8 { sel.origin.y += 1; sel.size.height -= 1 }
            selection = sel.intersection(bounds)
        } else {
            let clamped = Geometry.clampRect(sel.offsetBy(dx: dx, dy: dy), within: bounds)
            let actualDx = clamped.minX - sel.minX
            let actualDy = clamped.minY - sel.minY
            if abs(actualDx) > 0.01 || abs(actualDy) > 0.01 {
                for i in doc.objects.indices {
                    doc.updateWithoutHistory(at: i) { $0.translate(dx: actualDx, dy: actualDy) }
                }
            }
            selection = clamped
        }
    }

    func drawEraserCursorRingIfNeeded(in ctx: CGContext, sel: CGRect) {
        guard activeTool == .eraser, !isRecordingMode, let pt = lastMousePoint, sel.contains(pt) else { return }
        if (!toolbar.isHidden && toolbar.frame.contains(pt)) || (!subbar.isHidden && subbar.frame.contains(pt)) { return }
        let r = style.eraserRadius
        let circle = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
        ctx.saveGState()
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        ctx.fillEllipse(in: circle)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.setLineWidth(2.0); ctx.strokeEllipse(in: circle)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(1.2); ctx.setLineDash(phase: 0, lengths: [3, 2.5]); ctx.strokeEllipse(in: circle)
        ctx.restoreGState()
    }

    func beginEraserDrag(at p: CGPoint) {
        selectedObjectIndex = nil
        doc.beginTransaction()
        let hit = doc.eraseAlongSegment(from: p, to: p, radius: style.eraserRadius)
        dragOp = .erasing(lastPoint: p, erased: hit)
        if hit { needsDisplay = true }
    }

    func continueEraserDrag(from last: CGPoint, to p: CGPoint, erased: Bool) {
        let hit = doc.eraseAlongSegment(from: last, to: p, radius: style.eraserRadius)
        dragOp = .erasing(lastPoint: p, erased: erased || hit)
        if hit { needsDisplay = true }
        invalidateMagnifierMove(from: last, to: p)
    }
}
