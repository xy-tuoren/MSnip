import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 覆盖层的智能矩阵移动探测、吸管取色、鼠标绘制与滚轮交互扩展
extension OverlayView {
    // MARK: - Mouse & Auto-Snap Interaction

    private func applyCursor(_ kind: OverlayCursorKind) {
        if appliedCursorKind != kind { appliedCursorKind = kind; kind.apply() }
    }

    override func mouseMoved(with event: NSEvent) {
        if isOverlayVSyncActive { return }
        let p = convert(event.locationInWindow, from: nil)
        processLiveHoverPoint(p)
    }

    /// 统一 VSync / 悬停入口：优先零延迟同步 GPU 放大镜位置与切片，再做光标去重与自动吸附
    func processLiveHoverPoint(_ p: CGPoint) {
        let prevPt = lastMousePoint
        lastMousePoint = p
        let onChrome = (!toolbar.isHidden && toolbar.frame.contains(p))
            || (!subbar.isHidden && subbar.frame.contains(p))
            || (!sidePills.isHidden && sidePills.frame.contains(p))
            || (!cornerSlider.isHidden && cornerSlider.frame.contains(p))
            || (!saveMenu.isHidden && saveMenu.frame.contains(p))
        if onChrome { applyCursor(.arrow); invalidateMagnifierMove(from: prevPt, to: p); return }
        if toolbar.inPlaceOCRActive, let sel = selection, sel.contains(p) { invalidateMagnifierMove(from: prevPt, to: p); return }
        if eyedropperActive { applyCursor(.crosshair); invalidateMagnifierMove(from: prevPt, to: p); return }
        if let sel = selection {
            if Geometry.hitHandle(at: p, in: sel) != nil { applyCursor(.crosshair) }
            else if spacePressed || (activeTool == nil && sel.contains(p) && !optionPressed) { applyCursor(.openHand) }
            else { applyCursor(.crosshair) }
            invalidateMagnifierMove(from: prevPt, to: p)
            return
        }

        // 多屏下若其他显示器已锁定选区，副屏被动悬停绝不抢焦点或清空主屏标注
        if let allowHover = onHoverFocusRequest, !allowHover(self) {
            if lastMousePoint != nil { lastMousePoint = nil; syncMagnifierView(); syncGPUChromeLayers() }
            return
        }
        // 优先于 autoSnap 更新纯 GPU 放大镜，确保小面板 1:1 紧贴硬件光标零拖尾
        invalidateMagnifierMove(from: prevPt, to: p)
        applyCursor(.crosshair)
        updateAutoSnap(at: p, previousPoint: prevPt)
    }

    override func mouseDown(with event: NSEvent) {
        if let win = window, !win.isKeyWindow { NSApp.activate(ignoringOtherApps: true); win.makeKeyAndOrderFront(nil) }
        window?.makeFirstResponder(self)
        if selection == nil { onSelectionActivated?(self) }
        let p = convert(event.locationInWindow, from: nil)
        lastMousePoint = p

        if isSaveMenuVisible {
            isSaveMenuVisible = false
            updateToolbarLayout()
            return
        }
        if isEditingText {
            commitTextEditing()
            return
        }

        // 吸管模式或已锁定选区按住 ⌥ 单击：吸取屏幕任意像素作为标注颜色
        if eyedropperActive || (selection != nil && event.modifierFlags.contains(.option)) {
            if let sample = samplePixelAtCursor() {
                customPickedColor = sample.color
                eyedropperActive = false
                if let selIdx = selectedObjectIndex {
                    doc.modifyWithHistory(at: selIdx) { $0.style.color = sample.color }
                }
                needsDisplay = true
            }
            return
        }

        // 双击正式选区内部：录屏模式下直接开始倒计时录屏；否则双击文字重编辑或一键复制退出
        if event.clickCount == 2, let sel = selection, sel.contains(p), !toolbar.inPlaceOCRActive {
            if isRecordingMode {
                confirmBeginRegionRecording()
                return
            }
            if let hitIdx = doc.hitIndex(at: p), case .text = doc.objects[hitIdx].payload {
                beginTextEditing(at: p, existingIndex: hitIdx)
                return
            }
            if activeTool != .text && activeTool != .step && activeTool != .eraser {
                exportAndFinish(mode: .copy)
                return
            }
        }

        onSelectionActivated?(self)

        guard let sel = selection else {
            selectedObjectIndex = nil
            var snapTarget = hoveredAutoRect
            if caliperActive, let m = caliperView.measurement {
                let s = max(1.0, snapshot.scaleFactor)
                let r = CGRect(x: CGFloat(m.leftPx) / s, y: CGFloat(m.topPx) / s, width: CGFloat(m.widthPx) / s, height: CGFloat(m.heightPx) / s)
                if r.width >= 8, r.height >= 8 { snapTarget = r }
            }
            if snapTarget == nil && autoSnap.stack.isEmpty { updateAutoSnap(at: p) }
            dragOp = .pendingSnapOrCreate(anchor: p, snapRect: snapTarget ?? hoveredAutoRect)
            return
        }

        if let handle = Geometry.hitHandle(at: p, in: sel) {
            deactivateInPlaceOCR()
            deactivateInPlaceTranslate()
            selectedObjectIndex = nil
            dragOp = .resizingSelection(handle: handle, initialRect: sel, mouseStart: p)
            return
        }

        if (toolbar.inPlaceOCRActive || toolbar.inPlaceTranslateActive) && sel.contains(p) {
            return
        }

        if spacePressed && sel.contains(p) {
            dragOp = .movingSelection(initialRect: sel, mouseStart: p); return
        }
        if let selIdx = selectedObjectIndex, doc.objects.indices.contains(selIdx),
           let handle = doc.objects[selIdx].hitEditableHandle(at: p) {
            doc.beginTransaction()
            dragOp = .resizingAnnotation(index: selIdx, handle: handle, initialPayload: doc.objects[selIdx].payload, moved: false)
            return
        }
        if sel.contains(p), activeTool != .eraser, let hitIdx = doc.hitIndex(at: p) {
            let directStepHit: Bool = {
                guard case .step(let c, _, _) = doc.objects[hitIdx].payload else { return false }
                return hypot(p.x - c.x, p.y - c.y) <= doc.objects[hitIdx].style.stepBadgeRadius
            }()
            if activeTool == nil || event.modifierFlags.contains(.command) || selectedObjectIndex == hitIdx || directStepHit {
                selectedObjectIndex = hitIdx
                doc.beginTransaction()
                dragOp = .movingAnnotation(index: hitIdx, lastPoint: p, moved: false)
                return
            }
        }

        if sel.contains(p) {
            selectedObjectIndex = nil
            if let tool = activeTool {
                if tool == .text { beginTextEditing(at: p) }
                else if tool == .eraser { beginEraserDrag(at: p) }
                else {
                    dragOp = .drawingAnnotation(tool: tool, start: p)
                    draftAnnotation = makeDraft(tool: tool, from: p, to: p, shift: false)
                }
            } else {
                dragOp = .movingSelection(initialRect: sel, mouseStart: p)
            }
        } else if activeTool == nil, (doc.isEmpty || isRecordingMode) {
            selection = nil
            updateAutoSnap(at: p)
            dragOp = .pendingSnapOrCreate(anchor: p, snapRect: hoveredAutoRect)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let op = dragOp else { return }
        let prevPt = lastMousePoint ?? convert(event.locationInWindow, from: nil)
        let p = convert(event.locationInWindow, from: nil)
        lastMousePoint = p
        shiftTapCandidate = false
        let shift = event.modifierFlags.contains(.shift)

        switch op {
        case .pendingSnapOrCreate(let anchor, _):
            if hypot(p.x - anchor.x, p.y - anchor.y) >= 4.0 {
                if caliperActive { caliperActive = false }
                dragOp = .creatingSelection(anchor: anchor)
                let end = shift ? Geometry.squareConstrainedEnd(from: anchor, to: p) : p
                selection = Geometry.normalizedRect(from: anchor, to: end).intersection(bounds)
            }

        case .creatingSelection(var anchor):
            if spacePressed {
                anchor = CGPoint(x: anchor.x + (p.x - prevPt.x), y: anchor.y + (p.y - prevPt.y))
                dragOp = .creatingSelection(anchor: anchor)
            }
            let end = shift ? Geometry.squareConstrainedEnd(from: anchor, to: p) : p
            selection = Geometry.normalizedRect(from: anchor, to: end).intersection(bounds)

        case .movingSelection(let initial, let start):
            let moved = initial.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            let clamped = Geometry.clampRect(moved, within: bounds)
            let actualDx = clamped.minX - (selection?.minX ?? initial.minX)
            let actualDy = clamped.minY - (selection?.minY ?? initial.minY)
            if abs(actualDx) > 0.01 || abs(actualDy) > 0.01 {
                for i in doc.objects.indices {
                    doc.updateWithoutHistory(at: i) { $0.translate(dx: actualDx, dy: actualDy) }
                }
            }
            selection = clamped

        case .resizingSelection(let handle, let initial, let start):
            let delta = CGPoint(x: p.x - start.x, y: p.y - start.y)
            selection = handle.resizedRect(from: initial, delta: delta, minSize: 8, preserveAspect: shift).intersection(bounds)

        case .drawingAnnotation(let tool, let start):
            let clampedP = selection.map {
                CGPoint(x: min(max(p.x, $0.minX), $0.maxX), y: min(max(p.y, $0.minY), $0.maxY))
            } ?? p
            if tool == .pen, var existing = draftAnnotation, case .pen(var pts) = existing.payload {
                if let last = pts.last, hypot(clampedP.x - last.x, clampedP.y - last.y) >= 2.0 {
                    pts.append(clampedP)
                    existing.payload = .pen(points: pts)
                    draftAnnotation = existing
                }
            } else if tool == .highlighter, var existing = draftAnnotation, case .highlighter(var pts) = existing.payload {
                if shift {
                    existing.payload = .highlighter(points: [start, Geometry.angleSnappedEnd(from: start, to: clampedP)])
                    draftAnnotation = existing
                } else if let last = pts.last, hypot(clampedP.x - last.x, clampedP.y - last.y) >= 2.0 {
                    pts.append(clampedP)
                    existing.payload = .highlighter(points: pts)
                    draftAnnotation = existing
                }
            } else {
                draftAnnotation = makeDraft(tool: tool, from: start, to: clampedP, shift: shift)
            }
            invalidateMagnifierMove(from: prevPt, to: p)

        case .erasing(let lastPt, let erased):
            continueEraserDrag(from: lastPt, to: p, erased: erased)

        case .movingAnnotation(let index, let lastPoint, let moved):
            let dx = p.x - lastPoint.x, dy = p.y - lastPoint.y
            let oldB = doc.objects[index].bounds.insetBy(dx: -14, dy: -14)
            doc.updateWithoutHistory(at: index) { $0.translate(dx: dx, dy: dy) }
            dragOp = .movingAnnotation(index: index, lastPoint: p, moved: moved || hypot(dx, dy) > 0.5)
            setNeedsDisplay(oldB); setNeedsDisplay(doc.objects[index].bounds.insetBy(dx: -14, dy: -14))
            invalidateMagnifierMove(from: prevPt, to: p)

        case .resizingAnnotation(let index, let handle, let initial, _):
            let clamped = selection.map { CGPoint(x: min(max(p.x, $0.minX), $0.maxX), y: min(max(p.y, $0.minY), $0.maxY)) } ?? p
            let oldB = doc.objects[index].bounds.insetBy(dx: -16, dy: -16)
            doc.updateWithoutHistory(at: index) {
                $0.payload = Annotation.resizedPayload(from: initial, handle: handle, to: clamped, shift: shift)
            }
            dragOp = .resizingAnnotation(index: index, handle: handle, initialPayload: initial, moved: true)
            setNeedsDisplay(oldB); setNeedsDisplay(doc.objects[index].bounds.insetBy(dx: -16, dy: -16))
            invalidateMagnifierMove(from: prevPt, to: p)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let op = dragOp else { return }
        dragOp = nil

        switch op {
        case .pendingSnapOrCreate(_, let snapRect):
            if caliperActive { caliperActive = false }
            if let snap = snapRect, snap.width >= 6, snap.height >= 6 { selection = snap; triggerQuickLaunchIfNeeded(); scheduleSilentBarcodeScan(for: snap) }
        case .creatingSelection:
            if let sel = selection, (sel.width < 6 || sel.height < 6) {
                selection = nil; updateAutoSnap(at: convert(event.locationInWindow, from: nil), immediate: true)
            } else if let sel = selection { updateToolbarLayout(); triggerQuickLaunchIfNeeded(); scheduleSilentBarcodeScan(for: sel) }
        case .movingSelection, .resizingSelection:
            updateToolbarLayout(); syncMagnifierView(); if let sel = selection { scheduleSilentBarcodeScan(for: sel) }
        case .drawingAnnotation(_, let start):
            let end = convert(event.locationInWindow, from: nil)
            if let draft = draftAnnotation, !draft.isTrivial { doc.append(draft); updateToolbarLayout() }
            else if hypot(end.x - start.x, end.y - start.y) < 3.5, let hitIdx = doc.hitIndex(at: end) { selectedObjectIndex = hitIdx }
            draftAnnotation = nil
        case .erasing(_, let erased):
            doc.commitTransaction(changed: erased); updateToolbarLayout(); if erased { needsDisplay = true }
        case .movingAnnotation(_, _, let moved), .resizingAnnotation(_, _, _, let moved):
            doc.commitTransaction(changed: moved); updateToolbarLayout()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if selection == nil {
            guard autoSnap.stack.count > 1 else { return }
            if event.hasPreciseScrollingDeltas {
                autoSnap.scrollAccumulator += event.scrollingDeltaY
                if abs(autoSnap.scrollAccumulator) >= 16.0 {
                    let step = autoSnap.scrollAccumulator > 0 ? 1 : -1
                    autoSnap.scrollAccumulator = 0
                    stepAutoSnapTier(by: step)
                }
            } else if abs(event.scrollingDeltaY) > 0.01 {
                stepAutoSnapTier(by: event.scrollingDeltaY > 0 ? 1 : -1)
            }
            return
        }

        adjustAnnotationSize(by: event.scrollingDeltaY > 0 ? 1.0 : -1.0)
    }
}

// MARK: - 标注文字内联编辑与输入法处理

private final class CapsuleAwareTextField: NSTextField {
    var onToggleCapsule: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "b" {
            onToggleCapsule?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// 覆盖层原位文本标注输入扩展（支持中文输入法、二次双击重编辑及 `⌘B` 一键切换圆角胶囊底色字）
extension OverlayView {
    var isEditingText: Bool { textField != nil }

    func beginTextEditing(at point: CGPoint, existingIndex: Int? = nil) {
        commitTextEditing()
        editingExistingIndex = existingIndex

        let initialText: String
        let origin: CGPoint
        if let idx = existingIndex, case .text(let o, let s, _) = doc.objects[idx].payload {
            origin = o
            initialText = s
            style.textCapsule = doc.objects[idx].style.textCapsule
            toolbar.textCapsule = style.textCapsule
        } else {
            origin = point
            initialText = ""
        }
        editingTextOrigin = origin

        let field = CapsuleAwareTextField(
            frame: NSRect(
                x: origin.x - 2,
                y: origin.y - 2,
                width: 240,
                height: max(30, style.fontSize * 1.65)
            )
        )
        field.stringValue = initialText
        field.placeholderString = style.textCapsule ? "输入胶囊标签文字（⌘B 切换纯字）" : "输入文字（⌘B 切胶囊底色）"
        field.drawsBackground = true
        field.isBordered = true
        field.focusRingType = .exterior
        field.wantsLayer = true
        field.delegate = self
        field.onToggleCapsule = { [weak self] in
            self?.toggleTextCapsuleMode()
        }
        textField = field
        applyTextFieldVisualStyle()
        addSubview(field)
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeFirstResponder(field)
        syncMagnifierView()
        syncShortcutTipsView()
        needsDisplay = true
    }

    func applyTextFieldVisualStyle() {
        guard let field = textField else { return }
        field.font = NSFont.systemFont(ofSize: style.fontSize, weight: .semibold)
        if style.textCapsule {
            let luma = 0.299 * Double(style.color.r) + 0.587 * Double(style.color.g) + 0.114 * Double(style.color.b)
            field.backgroundColor = NSColor(cgColor: style.color.cgColor) ?? .systemRed
            field.textColor = luma > 195.0 ? .black : .white
            field.layer?.cornerRadius = 7
        } else {
            field.backgroundColor = NSColor.black.withAlphaComponent(0.48)
            field.textColor = NSColor(cgColor: style.color.cgColor) ?? .systemRed
            field.layer?.cornerRadius = 4
        }
    }

    func commitTextEditing() {
        guard let field = textField, let origin = editingTextOrigin else { return }
        let content = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = editingExistingIndex
        field.removeFromSuperview()
        textField = nil
        editingTextOrigin = nil
        editingExistingIndex = nil
        window?.makeFirstResponder(self)

        if !content.isEmpty {
            let measured = AnnotationRenderer.measureText(
                content,
                fontSize: style.fontSize,
                capsule: style.textCapsule
            )
            if let idx = existing {
                doc.modifyWithHistory(at: idx) { obj in
                    obj.style.textCapsule = style.textCapsule
                    obj.payload = .text(origin: origin, content: content, measuredSize: measured)
                }
            } else {
                let item = Annotation(
                    payload: .text(origin: origin, content: content, measuredSize: measured),
                    style: style
                )
                doc.append(item)
            }
        } else if let idx = existing {
            doc.remove(at: idx)
        }
        updateToolbarLayout()
        syncShortcutTipsView()
        needsDisplay = true
    }

    func cancelTextEditing() {
        textField?.removeFromSuperview()
        textField = nil
        editingTextOrigin = nil
        editingExistingIndex = nil
        window?.makeFirstResponder(self)
        syncShortcutTipsView()
        needsDisplay = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(insertNewline(_:)) {
            commitTextEditing()
            return true
        }
        if commandSelector == #selector(cancelOperation(_:)) {
            cancelTextEditing()
            return true
        }
        return false
    }
}
