import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 覆盖层响应悬浮工具栏、二级样式栏及页内功能动作扩展
extension OverlayView {
    func handleToolbarAction(_ action: ToolbarView.Action) {
        commitTextEditing()
        if case .save = action {} else if isSaveMenuVisible {
            isSaveMenuVisible = false
        }
        switch action {
        case .selectTool(let tool):
            eyedropperActive = false
            if tool != nil {
                deactivateInPlaceOCR()
                deactivateInPlaceTranslate()
                selectedObjectIndex = nil
            }
            activeTool = tool
            updateToolbarLayout()
        case .toggleTextCapsule:
            toggleTextCapsuleMode()
        case .selectColor(let idx):
            eyedropperActive = false
            customPickedColor = nil
            colorIndex = idx
            if let selIdx = selectedObjectIndex {
                doc.modifyWithHistory(at: selIdx) { $0.style.color = style.color }
            }
            applyTextFieldVisualStyle()
            updateToolbarLayout()
            onStyleChanged?(colorIndex, style.lineWidth)
            needsDisplay = true
        case .toggleEyedropper:
            eyedropperActive.toggle()
            updateToolbarLayout()
        case .selectStroke(let w):
            applyAnnotationSize(w)
        case .undo:
            selectedObjectIndex = nil
            if doc.undo() { updateToolbarLayout(); needsDisplay = true }
        case .redo:
            selectedObjectIndex = nil
            if doc.redo() { updateToolbarLayout(); needsDisplay = true }
        case .cycleCornerRadius:
            toggleCornerRadiusSlider()
        case .cycleBackdrop:
            cycleBackdropStyle()
        case .captureWindow:
            if NSEvent.modifierFlags.contains(.option) {
                captureCurrentWindowAndFinish(pin: false)
            } else {
                snapSelectionToUnderlyingWindow()
            }
        case .toggleInPlaceOCR:
            toggleInPlaceOCR()
        case .extractTextWindow:
            exportAndFinish(mode: .extractText)
        case .toggleInPlaceTranslate:
            toggleInPlaceTranslate()
        case .translateWindow:
            exportAndFinish(mode: .translateWindow)
        case .startLongShot:
            beginLongShot()
        case .startRecording:
            beginRegionRecording()
        case .pin:
            exportAndFinish(mode: .pin)
        case .save:
            toggleSaveDirectoryMenu()
        case .quickSave:
            quickSaveInPlace()
        case .cancel:
            onCancel?()
        case .confirmCopy:
            exportAndFinish(mode: .copy)
        }
    }

    func quickSaveInPlace() {
        commitTextEditing()
        guard let targetRect = selection ?? hoveredAutoRect,
              targetRect.width >= 2, targetRect.height >= 2,
              let baked = currentExportableImage(for: targetRect, plainForOCR: false) else { return }
        onQuickSaveInPlace?(baked, snapshot.scaleFactor, targetRect)
    }

    func beginLongShot() {
        commitTextEditing()
        deactivateInPlaceOCR()
        deactivateInPlaceTranslate()
        guard let raw = selection ?? hoveredAutoRect else {
            ToastHUD.show(message: "请先框选或悬停要滚动截取的区域")
            return
        }
        let rect = CGRect(
            x: round(raw.minX), y: round(raw.minY),
            width: round(raw.width), height: round(raw.height)
        ).intersection(bounds)
        guard rect.width >= 48, rect.height >= 64 else {
            ToastHUD.show(message: "长截图区域至少需 48 × 64 pt")
            return
        }
        let s = snapshot.scaleFactor
        let pxRect = CGRect(
            x: round(rect.minX * s), y: round(rect.minY * s),
            width: CGFloat(max(24, Int((rect.width * s).rounded()))),
            height: CGFloat(max(32, Int((rect.height * s).rounded())))
        )
        onStartLongShot?(snapshot.screen, rect, snapshot.cgImage.cropping(to: pxRect))
    }

    func toggleSaveDirectoryMenu() {
        if selection == nil, let snap = hoveredAutoRect { selection = snap }
        if !isSaveMenuVisible {
            saveMenu.reload(folders: saveFolderOptions)
            isSaveMenuVisible = true
        } else {
            isSaveMenuVisible = false
        }
        updateToolbarLayout()
    }

    func toggleCornerRadiusSlider(resetOnly: Bool = false) {
        if selection == nil, let snap = hoveredAutoRect { selection = snap }
        if resetOnly {
            cornerRadiusRatio = 0
            isCornerSliderVisible = false
            updateToolbarLayout()
            return
        }
        if !isCornerSliderVisible {
            isCornerSliderVisible = true
            if cornerRadiusRatio < 0.01 {
                cornerRadiusRatio = 0.16
            }
        } else {
            isCornerSliderVisible = false
        }
        updateToolbarLayout()
    }

    func cycleBackdropStyle() {
        if selection == nil, let snap = hoveredAutoRect { selection = snap }
        backdropStyle = backdropStyle.next
        updateToolbarLayout()
    }

    func toggleTextCapsuleMode() {
        style.textCapsule.toggle()
        toolbar.textCapsule = style.textCapsule
        subbar.textCapsule = style.textCapsule
        applyTextFieldVisualStyle()
        if let idx = selectedObjectIndex, case .text(let origin, let content, _) = doc.objects[idx].payload {
            let newCap = !doc.objects[idx].style.textCapsule
            style.textCapsule = newCap
            toolbar.textCapsule = newCap
            subbar.textCapsule = newCap
            let sz = AnnotationRenderer.measureText(content, fontSize: doc.objects[idx].style.fontSize, capsule: newCap)
            doc.modifyWithHistory(at: idx) {
                $0.style.textCapsule = newCap
                $0.payload = .text(origin: origin, content: content, measuredSize: sz)
            }
        }
        onCapsuleChanged?(style.textCapsule)
        needsDisplay = true
    }

    func beginRegionRecording() {
        commitTextEditing()
        deactivateInPlaceOCR()
        guard let raw = selection ?? hoveredAutoRect else {
            ToastHUD.show(message: "请先框选或悬停要录制 GIF / MP4 的区域")
            return
        }
        let rect = CGRect(
            x: round(raw.minX), y: round(raw.minY),
            width: round(raw.width), height: round(raw.height)
        ).intersection(bounds)
        guard rect.width >= 48, rect.height >= 48 else {
            ToastHUD.show(message: "录屏选区至少需 48 × 48 pt")
            return
        }
        let s = snapshot.scaleFactor
        let pxRect = CGRect(
            x: round(rect.minX * s), y: round(rect.minY * s),
            width: CGFloat(Int((rect.width * s).rounded()) & ~1),
            height: CGFloat(Int((rect.height * s).rounded()) & ~1)
        )
        onStartRecording?(snapshot.screen, rect, snapshot.cgImage.cropping(to: pxRect))
    }
}
