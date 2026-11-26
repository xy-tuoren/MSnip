import AppKit
import CoreGraphics
import Foundation
import MSnipCore
import QuartzCore

/// 覆盖层局部脏矩形失效（Partial Dirty-Rect Invalidation）、拖拽期无遮挡隐藏与零拷贝底图切片绘制支持
extension OverlayView {
    var isDraggingSelectionBox: Bool {
        guard let op = dragOp else { return false }
        switch op {
        case .creatingSelection, .movingSelection, .resizingSelection:
            return true
        case .pendingSnapOrCreate, .drawingAnnotation, .erasing, .movingAnnotation, .resizingAnnotation:
            return false
        }
    }

    func autoSnapDirtyBounds(for rect: CGRect) -> CGRect {
        let minX = min(rect.minX - 10, max(0, bounds.width - 390))
        return CGRect(
            x: minX,
            y: rect.minY - 38,
            width: max(rect.maxX - minX + 12, 380),
            height: rect.height + 48
        ).intersection(bounds)
    }

    func selectionDirtyBounds(for rect: CGRect) -> CGRect {
        let pad: CGFloat = (glowStrength > 0.005) ? ceil(14.0 + 22.0 * glowStrength) : 14.0
        return CGRect(
            x: rect.minX - pad,
            y: rect.minY - 40 - pad,
            width: max(rect.width + pad * 2, 340),
            height: rect.height + 50 + pad * 2
        ).intersection(bounds)
    }

    /// 纯 GPU 刷新暗化遮罩四边图层、自动吸附边框、尺寸胶囊与快捷键提示卡（零 CPU 全屏位图重绘）
    func syncGPUChromeLayers() {
        let hideAllForCaliper = (selection == nil && caliperActive)
        let activeRadius = (selection != nil && cornerRadiusPt > 0.5)
            ? min(cornerRadiusPt, min(selection!.width, selection!.height) * 0.5)
            : 0
        let highlightRect = selection ?? autoSnap.displayedRect ?? hoveredAutoRect
        let showGPUDim = !hideAllForCaliper && activeRadius <= 0.5
        let showSnapBorder = !hideAllForCaliper && (selection == nil) && (hoveredAutoRect != nil)
        let borderCol = (isRecordingMode ? MSnipUITheme.danger : MSnipUITheme.accent).withAlphaComponent(0.95).cgColor
        dimSnapView.update(highlightRect: highlightRect, showDim: showGPUDim, showSnapBorder: showSnapBorder, borderColor: borderCol)

        if hideAllForCaliper {
            hudPillView.update(text: nil, anchorRect: nil, containerBounds: bounds)
        } else if let sel = selection, sel.width >= 1, sel.height >= 1 {
            hudPillView.update(text: selectionHudText(for: sel, cornerRadius: activeRadius), anchorRect: sel, containerBounds: bounds)
        } else if let target = hoveredAutoRect {
            let disp = autoSnap.displayedRect ?? target
            hudPillView.update(text: autoSnapHudText(for: target), anchorRect: disp, containerBounds: bounds)
        } else {
            hudPillView.update(text: nil, anchorRect: nil, containerBounds: bounds)
        }
        syncShortcutTipsView()
    }

    func invalidateAutoSnapTransition(from oldRect: CGRect?, to newRect: CGRect?) {
        syncGPUChromeLayers()
    }

    func invalidateSelectionTransition(from oldSel: CGRect?, to newSel: CGRect?) {
        syncGPUChromeLayers()
        if (oldSel == nil) != (newSel == nil) {
            needsDisplay = true
            return
        }
        if let o = oldSel { setNeedsDisplay(selectionDirtyBounds(for: o)) }
        if let n = newSel { setNeedsDisplay(selectionDirtyBounds(for: n)) }
    }

    func invalidateMagnifierMove(from oldPt: CGPoint?, to newPt: CGPoint?) {
        syncMagnifierView()
        syncCaliperView()
        if activeTool == .eraser, selection != nil {
            let pad = style.eraserRadius + 6
            if let o = oldPt { setNeedsDisplay(CGRect(x: o.x - pad, y: o.y - pad, width: pad * 2, height: pad * 2)) }
            if let n = newPt { setNeedsDisplay(CGRect(x: n.x - pad, y: n.y - pad, width: pad * 2, height: pad * 2)) }
        }
        if showShortcutTips, !cachedTipsTriggerZone.isEmpty {
            let wasIn = oldPt.map { cachedTipsTriggerZone.contains($0) } ?? false
            let nowIn = newPt.map { cachedTipsTriggerZone.contains($0) } ?? false
            if wasIn != nowIn {
                syncShortcutTipsView()
            }
        }
    }

    func updateToolbarLayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // PixPin 丝滑交互：拖拽拉框、平移或缩放选区期间暂时隐藏悬浮栏，松手瞬间一步到位呈现，零遮挡零阴影重算卡顿
        if isDraggingSelectionBox {
            toolbar.isHidden = true
            subbar.isHidden = true
            sidePills.isHidden = true
            cornerSlider.isHidden = true
            saveMenu.isHidden = true
            caliperView.isHidden = true
            if let ocrV = inPlaceOCRView, let sel = selection { ocrV.frame = sel }
            if let trV = inPlaceTranslateView, let sel = selection { trV.frame = sel }
            return
        }

        toolbar.canUndo = doc.canUndo
        toolbar.canRedo = doc.canRedo
        toolbar.nextStepNumber = doc.nextStepNumber()
        toolbar.textCapsule = style.textCapsule
        toolbar.refreshState()

        subbar.activeTool = activeTool
        subbar.lineWidth = style.lineWidth
        subbar.colorIndex = colorIndex
        subbar.customColor = customPickedColor
        subbar.eyedropperActive = eyedropperActive
        subbar.textCapsule = style.textCapsule

        sidePills.hasCorner = (cornerRadiusRatio > 0.005 || activeSideSlider == .corner)
        sidePills.hasGlow = (glowStrength > 0.005 || activeSideSlider == .glow)

        guard let sel = selection, sel.width >= 6, sel.height >= 6 else {
            toolbar.isHidden = true
            subbar.isHidden = true
            sidePills.isHidden = true
            activeSideSlider = nil
            cornerSlider.isHidden = true
            isSaveMenuVisible = false
            saveMenu.isHidden = true
            return
        }
        toolbar.isHidden = false
        let barSize = toolbar.frame.size
        if let manual = manualToolbarOrigin {
            let cx = min(max(6, manual.x), bounds.width - barSize.width - 6)
            let cy = min(max(6, manual.y), bounds.height - barSize.height - 6)
            toolbar.setFrameOrigin(NSPoint(x: round(cx), y: round(cy)))
        } else {
            let dockBottom = max(12, snapshot.screen.visibleFrame.minY - snapshot.screen.frame.minY + 12)
            let x = min(max(16, sel.maxX - barSize.width), bounds.width - barSize.width - 16)
            let belowY = sel.maxY + 10
            let aboveY = sel.minY - barSize.height - 10
            let y = (belowY + barSize.height + 44 <= bounds.height - dockBottom)
                ? belowY
                : (aboveY >= 16 ? aboveY : max(16, sel.maxY - barSize.height - 10))
            toolbar.setFrameOrigin(NSPoint(x: round(x), y: round(y)))
        }
        repositionSubbar()

        if isRecordingMode {
            sidePills.isHidden = true
            activeSideSlider = nil; cornerSlider.isHidden = true
            isSaveMenuVisible = false; saveMenu.isHidden = true
            return
        }

        sidePills.isHidden = false
        let pillSz = OverlaySidePillsView.viewSize
        let rightX = sel.maxX + 10
        let leftX = sel.minX - pillSz.width - 10
        let px = (rightX + pillSz.width + 6 <= bounds.width) ? rightX : max(6, leftX)
        let py = min(max(8, sel.minY + 2), bounds.height - pillSz.height - 8)
        sidePills.setFrameOrigin(NSPoint(x: round(px), y: round(py)))

        if let sliderMode = activeSideSlider {
            cornerSlider.mode = sliderMode
            cornerSlider.ratio = (sliderMode == .glow) ? glowStrength : cornerRadiusRatio
            cornerSlider.isHidden = false
            let sSz = OverlayCornerSliderView.barSize
            let preferRightX = sidePills.frame.maxX + 8
            let altLeftX = sidePills.frame.minX - sSz.width - 8
            let sx = (preferRightX + sSz.width + 6 <= bounds.width)
                ? preferRightX
                : max(6, min(altLeftX, bounds.width - sSz.width - 6))
            let anchorOffsetY: CGFloat = (sliderMode == .glow) ? (OverlaySidePillsView.pillSize + OverlaySidePillsView.gap) : 0
            let sy = min(max(6, sidePills.frame.minY + anchorOffsetY - 1), bounds.height - sSz.height - 6)
            cornerSlider.setFrameOrigin(NSPoint(x: round(sx), y: round(sy)))
        } else {
            cornerSlider.isHidden = true
        }

        if isSaveMenuVisible {
            saveMenu.isHidden = false
            let mSz = saveMenu.frame.size
            let tf = toolbar.frame
            let mx = min(max(8, tf.maxX - mSz.width - 54), bounds.width - mSz.width - 8)
            let belowY = tf.maxY + 6
            let aboveY = tf.minY - mSz.height - 6
            let my = (belowY + mSz.height + 8 <= bounds.height) ? belowY : max(8, aboveY)
            saveMenu.setFrameOrigin(NSPoint(x: round(mx), y: round(my)))
        } else {
            saveMenu.isHidden = true
        }

        if let ocrV = inPlaceOCRView { ocrV.frame = sel }
        if let trV = inPlaceTranslateView { trV.frame = sel }
        syncShortcutTipsView()
    }

    func clearSelectionFromSibling() {
        cancelTextEditing()
        barcodeScanTask?.cancel(); barcodeScanTask = nil
        deactivateInPlaceOCR()
        deactivateInPlaceTranslate()
        stopSnapGlide()
        activeSideSlider = nil
        cornerRadiusRatio = 0
        glowStrength = 0
        didAdjustGlow = false
        cornerSlider.isHidden = true
        isSaveMenuVisible = false
        saveMenu.isHidden = true
        caliperActive = false
        selection = nil
        lastMousePoint = nil
        syncMagnifierView()
        syncCaliperView()
        eyedropperActive = false
        autoSnap.clearTargets()
        selectedObjectIndex = nil
        draftAnnotation = nil
        doc = AnnotationDocument()
    }

    func repositionSubbar() {
        let shouldShow = !isRecordingMode && !toolbar.isHidden && !toolbar.inPlaceOCRActive && !toolbar.inPlaceTranslateActive && (activeTool != nil || selectedObjectIndex != nil)
        guard shouldShow else {
            subbar.isHidden = true
            return
        }
        subbar.refresh()
        subbar.isHidden = false
        let tf = toolbar.frame
        let sz = subbar.frame.size
        let sx = min(max(6, tf.minX), bounds.width - sz.width - 6)
        let belowY = tf.maxY + 6
        let sy = (belowY + sz.height + 6 <= bounds.height) ? belowY : max(6, tf.minY - sz.height - 6)
        subbar.setFrameOrigin(NSPoint(x: round(sx), y: round(sy)))
    }

    func drawLiveGlowFrameIfNeeded(ctx: CGContext, sel: CGRect, cornerRadius: CGFloat) {
        let s = min(1.0, max(0.0, glowStrength))
        guard s > 0.005 else { return }
        let pad: CGFloat = ceil(10.0 + 18.0 * s)
        let outer = sel.insetBy(dx: -pad, dy: -pad)
        let innerPath = cornerRadius > 0.5
            ? CGPath(roundedRect: sel, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            : CGPath(rect: sel, transform: nil)
        let blur: CGFloat = 3.0 + 10.0 * s

        ctx.saveGState()
        ctx.addRect(outer)
        ctx.addPath(innerPath)
        ctx.clip(using: .evenOdd)
        ctx.setShadow(offset: .zero, blur: blur, color: NSColor.white.withAlphaComponent(0.45 + 0.45 * s).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.addPath(innerPath)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.32 + 0.42 * s).cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(innerPath)
        ctx.strokePath()
        ctx.restoreGState()
    }
}
