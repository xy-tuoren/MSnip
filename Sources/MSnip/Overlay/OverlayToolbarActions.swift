import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 覆盖层响应悬浮工具栏按钮事件与长截图/动图录屏会话触发扩展
extension OverlayView {
    func handleToolbarAction(_ action: ToolbarView.Action) {
        commitTextEditing()
        switch action {
        case .selectTool(let tool):
            eyedropperActive = false
            activeTool = tool
            if tool != nil { selectedObjectIndex = nil }
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
            onStyleChanged?(colorIndex, style.lineWidth)
            needsDisplay = true
        case .toggleEyedropper:
            eyedropperActive.toggle()
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
        case .cycleCornerRadius:
            cycleCornerRadius()
        case .cycleBackdrop:
            cycleBackdropStyle()
        case .captureWindow:
            captureCurrentWindowAndFinish(pin: NSEvent.modifierFlags.contains(.option))
        case .extractText:
            exportAndFinish(mode: .extractText)
        case .startLongShot:
            beginLongShot()
        case .startRecording:
            beginRegionRecording()
        case .pin:
            exportAndFinish(mode: .pin)
        case .save:
            exportAndFinish(mode: .save)
        case .quickSave:
            exportAndFinish(mode: .quickSave)
        case .cancel:
            onCancel?()
        case .confirmCopy:
            exportAndFinish(mode: .copy)
        }
    }

    func beginLongShot() {
        commitTextEditing()
        guard let raw = selection ?? hoveredAutoRect else {
            ToastHUD.show(message: "请先框选或悬停要滚动截取的区域")
            return
        }
        let rect = CGRect(
            x: round(raw.minX),
            y: round(raw.minY),
            width: round(raw.width),
            height: round(raw.height)
        ).intersection(bounds)
        guard rect.width >= 48, rect.height >= 64 else {
            ToastHUD.show(message: "长截图区域至少需 48 × 64 pt")
            return
        }
        let s = snapshot.scaleFactor
        let pxRect = CGRect(
            x: round(rect.minX * s),
            y: round(rect.minY * s),
            width: CGFloat(Int((rect.width * s).rounded()) & ~1),
            height: CGFloat(Int((rect.height * s).rounded()) & ~1)
        )
        let initial = snapshot.cgImage.cropping(to: pxRect)
        onStartLongShot?(snapshot.screen, rect, initial)
    }

    func cycleCornerRadius() {
        if selection == nil, let snap = hoveredAutoRect {
            selection = snap
        }
        if cornerRadiusPt < 1 {
            cornerRadiusPt = 10
        } else if cornerRadiusPt < 14 {
            cornerRadiusPt = 18
        } else {
            cornerRadiusPt = 0
        }
    }

    func cycleBackdropStyle() {
        if selection == nil, let snap = hoveredAutoRect {
            selection = snap
        }
        backdropStyle = backdropStyle.next
    }

    func toggleTextCapsuleMode() {
        style.textCapsule.toggle()
        toolbar.textCapsule = style.textCapsule
        applyTextFieldVisualStyle()
        if let idx = selectedObjectIndex, case .text(let origin, let content, _) = doc.objects[idx].payload {
            let newCap = !doc.objects[idx].style.textCapsule
            style.textCapsule = newCap
            toolbar.textCapsule = newCap
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
        guard let raw = selection ?? hoveredAutoRect else {
            ToastHUD.show(message: "请先框选或悬停要录制 GIF / MP4 的区域")
            return
        }
        let rect = CGRect(
            x: round(raw.minX),
            y: round(raw.minY),
            width: round(raw.width),
            height: round(raw.height)
        ).intersection(bounds)
        guard rect.width >= 48, rect.height >= 48 else {
            ToastHUD.show(message: "录屏选区至少需 48 × 48 pt")
            return
        }
        let s = snapshot.scaleFactor
        let pxRect = CGRect(
            x: round(rect.minX * s),
            y: round(rect.minY * s),
            width: CGFloat(Int((rect.width * s).rounded()) & ~1),
            height: CGFloat(Int((rect.height * s).rounded()) & ~1)
        )
        let initial = snapshot.cgImage.cropping(to: pxRect)
        onStartRecording?(snapshot.screen, rect, initial)
    }
}
