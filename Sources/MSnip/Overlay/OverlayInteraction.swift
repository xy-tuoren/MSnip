import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 覆盖层的工具栏动作响应、智能矩阵移动探测、鼠标绘制与滚轮交互扩展
extension OverlayView {
    func handleToolbarAction(_ action: ToolbarView.Action) {
        commitTextEditing()
        switch action {
        case .selectTool(let tool):
            activeTool = tool
            if tool != nil { selectedObjectIndex = nil }
        case .selectColor(let idx):
            colorIndex = idx
            if let selIdx = selectedObjectIndex {
                doc.modifyWithHistory(at: selIdx) { $0.style.color = style.color }
            }
            onStyleChanged?(colorIndex, style.lineWidth)
            needsDisplay = true
        case .selectStroke(let w):
            style.lineWidth = w
            style.fontSize = max(14, w * 4.5)
            toolbar.lineWidth = w
            if let selIdx = selectedObjectIndex {
                doc.modifyWithHistory(at: selIdx) {
                    $0.style.lineWidth = w
                    $0.style.fontSize = max(14, w * 4.5)
                }
            }
            onStyleChanged?(colorIndex, style.lineWidth)
            needsDisplay = true
        case .undo:
            selectedObjectIndex = nil
            if doc.undo() { updateToolbarLayout(); needsDisplay = true }
        case .redo:
            selectedObjectIndex = nil
            if doc.redo() { updateToolbarLayout(); needsDisplay = true }
        case .pin:
            exportAndFinish(mode: .pin)
        case .save:
            exportAndFinish(mode: .save)
        case .cancel:
            onCancel?()
        case .confirmCopy:
            exportAndFinish(mode: .copy)
        }
    }

    // MARK: - Mouse & Auto-Snap Interaction

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !toolbar.isHidden && toolbar.frame.contains(p) {
            NSCursor.arrow.set()
            return
        }
        if let sel = selection {
            if Geometry.hitHandle(at: p, in: sel) != nil {
                NSCursor.crosshair.set()
                return
            }
            if spacePressed || (activeTool == nil && sel.contains(p)) {
                NSCursor.openHand.set()
                return
            }
            NSCursor.crosshair.set()
            return
        }

        // 未锁定选区阶段：移动光标实时识别并高亮下方的窗口 / UI 控件矩阵
        onSelectionActivated?(self)
        updateAutoSnap(at: p)
        NSCursor.crosshair.set()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)

        if isEditingText {
            commitTextEditing()
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

        // 尚未产生正式选区：按下时先记录当前自动识别框（单击直接锁定，拖动 >= 4pt 则无缝转手动画框）
        guard let sel = selection else {
            selectedObjectIndex = nil
            if autoSnapStack.isEmpty { updateAutoSnap(at: p) }
            dragOp = .pendingSnapOrCreate(anchor: p, snapRect: hoveredAutoRect)
            return
        }

        // 1) 八向选区控制柄优先
        if let handle = Geometry.hitHandle(at: p, in: sel) {
            selectedObjectIndex = nil
            dragOp = .resizingSelection(handle: handle, initialRect: sel, mouseStart: p)
            return
        }

        // 2) 按住空格拖动整个选区
        if spacePressed && sel.contains(p) {
            dragOp = .movingSelection(initialRect: sel, mouseStart: p)
            return
        }

        // 3) 命中已有标注：在无工具态、按住 ⌘ 键、或点在已选中标注上时直接移动标注
        if sel.contains(p), let hitIdx = doc.hitIndex(at: p) {
            if activeTool == nil || event.modifierFlags.contains(.command) || selectedObjectIndex == hitIdx {
                selectedObjectIndex = hitIdx
                doc.beginTransaction()
                dragOp = .movingAnnotation(index: hitIdx, lastPoint: p, moved: false)
                return
            }
        }

        // 4) 选区内绘制新标注或拖动选区；选区外且无标注时支持重新点击/拖拽选区
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
        let p = convert(event.locationInWindow, from: nil)
        let shift = event.modifierFlags.contains(.shift)

        switch op {
        case .pendingSnapOrCreate(let anchor, _):
            if hypot(p.x - anchor.x, p.y - anchor.y) >= 4.0 {
                dragOp = .creatingSelection(anchor: anchor)
                let end = shift ? Geometry.squareConstrainedEnd(from: anchor, to: p) : p
                selection = Geometry.normalizedRect(from: anchor, to: end).intersection(bounds)
            }

        case .creatingSelection(let anchor):
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
            break
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
        // 1) 未锁定选区时：滚轮在鼠标下方的「内部小控件 <-> 父容器 <-> 整窗口」多级矩阵间切换
        if selection == nil {
            guard autoSnapStack.count > 1 else { return }
            if event.hasPreciseScrollingDeltas {
                scrollSnapAccumulator += event.scrollingDeltaY
                let threshold: CGFloat = 14.0
                if abs(scrollSnapAccumulator) >= threshold {
                    let step = scrollSnapAccumulator > 0 ? 1 : -1
                    scrollSnapAccumulator = 0
                    autoSnapIndex = min(max(0, autoSnapIndex + step), autoSnapStack.count - 1)
                    needsDisplay = true
                }
            } else if abs(event.scrollingDeltaY) > 0.01 {
                let step = event.scrollingDeltaY > 0 ? 1 : -1
                autoSnapIndex = min(max(0, autoSnapIndex + step), autoSnapStack.count - 1)
                needsDisplay = true
            }
            return
        }

        // 2) 已锁定选区时：滚轮微调标注粗细 / 字号 / 马赛克粒度
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
