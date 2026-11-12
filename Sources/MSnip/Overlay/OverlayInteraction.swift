import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 覆盖层的智能矩阵移动探测、吸管取色、鼠标绘制与滚轮交互扩展
extension OverlayView {
    // MARK: - Mouse & Auto-Snap Interaction

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        lastMousePoint = p
        if !toolbar.isHidden && toolbar.frame.contains(p) {
            NSCursor.arrow.set()
            needsDisplay = true
            return
        }
        if eyedropperActive {
            NSCursor.crosshair.set()
            needsDisplay = true
            return
        }
        if let sel = selection {
            if Geometry.hitHandle(at: p, in: sel) != nil {
                NSCursor.crosshair.set()
            } else if spacePressed || (activeTool == nil && sel.contains(p) && !optionPressed) {
                NSCursor.openHand.set()
            } else {
                NSCursor.crosshair.set()
            }
            if optionPressed || magnifierPinned || showShortcutTips {
                needsDisplay = true
            }
            return
        }

        onSelectionActivated?(self)
        updateAutoSnap(at: p)
        NSCursor.crosshair.set()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        lastMousePoint = p

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

        // 双击正式选区内部：双击文字重编辑，否则一键复制并退出
        if event.clickCount == 2, let sel = selection, sel.contains(p) {
            if let hitIdx = doc.hitIndex(at: p), case .text = doc.objects[hitIdx].payload {
                beginTextEditing(at: p, existingIndex: hitIdx)
                return
            }
            if activeTool != .text {
                exportAndFinish(mode: .copy)
                return
            }
        }

        onSelectionActivated?(self)

        guard let sel = selection else {
            selectedObjectIndex = nil
            if autoSnapStack.isEmpty { updateAutoSnap(at: p) }
            dragOp = .pendingSnapOrCreate(anchor: p, snapRect: hoveredAutoRect)
            return
        }

        if let handle = Geometry.hitHandle(at: p, in: sel) {
            selectedObjectIndex = nil
            dragOp = .resizingSelection(handle: handle, initialRect: sel, mouseStart: p)
            return
        }

        if spacePressed && sel.contains(p) {
            dragOp = .movingSelection(initialRect: sel, mouseStart: p)
            return
        }

        if sel.contains(p), let hitIdx = doc.hitIndex(at: p) {
            if activeTool == nil || event.modifierFlags.contains(.command) || selectedObjectIndex == hitIdx {
                selectedObjectIndex = hitIdx
                doc.beginTransaction()
                dragOp = .movingAnnotation(index: hitIdx, lastPoint: p, moved: false)
                return
            }
        }

        if sel.contains(p) {
            selectedObjectIndex = nil
            if let tool = activeTool {
                if tool == .text {
                    beginTextEditing(at: p)
                } else {
                    dragOp = .drawingAnnotation(tool: tool, start: p)
                    draftAnnotation = makeDraft(tool: tool, from: p, to: p, shift: false)
                }
            } else {
                dragOp = .movingSelection(initialRect: sel, mouseStart: p)
            }
        } else if activeTool == nil, doc.isEmpty {
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
            selection = handle.resizedRect(from: initial, delta: delta, minSize: 8).intersection(bounds)

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
            } else {
                draftAnnotation = makeDraft(tool: tool, from: start, to: clampedP, shift: shift)
            }

        case .movingAnnotation(let index, let lastPoint, let moved):
            let dx = p.x - lastPoint.x
            let dy = p.y - lastPoint.y
            doc.updateWithoutHistory(at: index) { $0.translate(dx: dx, dy: dy) }
            dragOp = .movingAnnotation(index: index, lastPoint: p, moved: moved || hypot(dx, dy) > 0.5)
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let op = dragOp else { return }
        dragOp = nil

        switch op {
        case .pendingSnapOrCreate(_, let snapRect):
            if let snap = snapRect, snap.width >= 6, snap.height >= 6 {
                selection = snap
            }
        case .creatingSelection:
            if let sel = selection, (sel.width < 6 || sel.height < 6) {
                selection = nil
                updateAutoSnap(at: convert(event.locationInWindow, from: nil))
            }
        case .movingSelection, .resizingSelection:
            needsDisplay = true
        case .drawingAnnotation(_, let start):
            let end = convert(event.locationInWindow, from: nil)
            if let draft = draftAnnotation, !draft.isTrivial {
                doc.append(draft)
                updateToolbarLayout()
            } else if hypot(end.x - start.x, end.y - start.y) < 3.5, let hitIdx = doc.hitIndex(at: end) {
                selectedObjectIndex = hitIdx
            }
            draftAnnotation = nil
        case .movingAnnotation(_, _, let moved):
            doc.commitTransaction(changed: moved)
            updateToolbarLayout()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if selection == nil {
            guard autoSnapStack.count > 1 else { return }
            if event.hasPreciseScrollingDeltas {
                scrollSnapAccumulator += event.scrollingDeltaY
                if abs(scrollSnapAccumulator) >= 16.0 {
                    let step = scrollSnapAccumulator > 0 ? 1 : -1
                    scrollSnapAccumulator = 0
                    stepAutoSnapTier(by: step)
                }
            } else if abs(event.scrollingDeltaY) > 0.01 {
                stepAutoSnapTier(by: event.scrollingDeltaY > 0 ? 1 : -1)
            }
            return
        }

        let delta: CGFloat = event.scrollingDeltaY > 0 ? 0.5 : -0.5
        style.lineWidth = min(18.0, max(1.0, style.lineWidth + delta))
        style.fontSize = min(64.0, max(12.0, style.fontSize + delta * 2.0))
        style.mosaicBlockSize = min(32.0, max(5.0, style.mosaicBlockSize + delta * 1.5))
        toolbar.lineWidth = style.lineWidth
        if let idx = selectedObjectIndex {
            doc.modifyWithHistory(at: idx) {
                $0.style.lineWidth = style.lineWidth
                $0.style.fontSize = style.fontSize
                $0.style.mosaicBlockSize = style.mosaicBlockSize
            }
            needsDisplay = true
        }
    }
}
