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
        case .clearAnnotations:
            selectedObjectIndex = nil
            doc.clearAll()
            updateToolbarLayout()
            needsDisplay = true
        case .autoRedact:
            performAutoRedactSensitiveText()
        case .cycleCornerRadius:
            toggleCornerRadiusSlider()
        case .cycleBackdrop:
            toggleGlowSlider()
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
        case .silentOCR:
            exportAndFinish(mode: .silentOCR)
        case .recognizeLatex:
            exportAndFinish(mode: .recognizeLatex)
        case .toggleInPlaceTranslate:
            toggleInPlaceTranslate()
        case .translateWindow:
            exportAndFinish(mode: .translateWindow)
        case .startLongShot:
            beginLongShot()
        case .startRecording:
            setRecordingMode(true, notifySiblings: true)
        case .selectRecordingFormat(let fmt):
            toolbar.recordingFormat = fmt
            onRecordingPrefsChanged?(fmt, toolbar.recordingHUDEnabled)
            updateToolbarLayout()
            syncGPUChromeLayers()
            needsDisplay = true
        case .toggleRecordingHUD:
            toolbar.recordingHUDEnabled.toggle()
            onRecordingPrefsChanged?(toolbar.recordingFormat, toolbar.recordingHUDEnabled)
            updateToolbarLayout()
        case .confirmBeginRecording:
            confirmBeginRegionRecording()
        case .exitRecordingMode:
            setRecordingMode(false, notifySiblings: true)
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
        onStartLongShot?(snapshot.screen, rect, snapshot.cgImage.cropping(to: pxRect).map(ImageTransform.detachedCopy))
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

    func toggleRecordingMode() {
        setRecordingMode(!isRecordingMode, notifySiblings: true)
    }

    func setRecordingMode(_ enabled: Bool, notifySiblings: Bool) {
        commitTextEditing()
        if enabled {
            deactivateInPlaceOCR()
            deactivateInPlaceTranslate()
            eyedropperActive = false
            activeTool = nil
            selectedObjectIndex = nil
            activeSideSlider = nil
            isSaveMenuVisible = false
            cornerRadiusRatio = 0
            glowStrength = 0
            didAdjustGlow = false
            backdropStyle = .none
        }
        toolbar.isRecordingMode = enabled
        updateToolbarLayout()
        syncGPUChromeLayers()
        needsDisplay = true
        if notifySiblings { onRecordingModeChanged?(enabled) }
    }

    func triggerQuickLaunchIfNeeded() {
        switch quickLaunchMode {
        case .standard, .quickRecord: break
        case .quickSilentOCR:
            exportAndFinish(mode: .silentOCR)
        case .quickOCR:
            switch ocrPresentation {
            case .inPlace:    activateInPlaceOCR()
            case .dualPane:   exportAndFinish(mode: .extractText)
            case .silentCopy: exportAndFinish(mode: .silentOCR)
            }
        case .quickTranslate:
            if translateAutoOpenDualPane { exportAndFinish(mode: .translateWindow) } else { activateInPlaceTranslate() }
        case .quickLongShot:  beginLongShot()
        case .quickLatex:     exportAndFinish(mode: .recognizeLatex)
        }
    }

    func confirmBeginRegionRecording() {
        commitTextEditing()
        deactivateInPlaceOCR()
        deactivateInPlaceTranslate()
        guard let raw = selection ?? hoveredAutoRect else {
            ToastHUD.show(message: "请先点击窗口或拖拽框选要录制的区域")
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
        onStartRecording?(snapshot.screen, rect, snapshot.cgImage.cropping(to: pxRect).map(ImageTransform.detachedCopy))
    }

    /// 离线一键隐私智能打码：扫描选区敏感字段并合并为单步 Undo 事务批量添加马赛克/毛玻璃遮罩
    func performAutoRedactSensitiveText() {
        commitTextEditing()
        if selection == nil, let snap = hoveredAutoRect { selection = snap }
        guard let sel = selection, sel.width >= 16, sel.height >= 16 else {
            ToastHUD.show(message: "请先框选需要智能打码的区域")
            return
        }
        guard let cropped = AnnotationRenderer.bakeExportImage(
            sampler: snapshot.sampler, selection: sel, imageScale: snapshot.scaleFactor, annotations: []
        ) else { return }
        let useBlur = (activeTool == .gaussianBlur)
        let curStyle = self.style
        ToastHUD.show(message: "正在离线扫描隐私敏感信息…")
        Task { @MainActor [weak self] in
            let normBoxes = await VisionTextExtractor.detectSensitiveBoxesOffMain(cgImage: cropped)
            guard let self, let activeSel = self.selection, activeSel == sel else { return }
            guard !normBoxes.isEmpty else {
                ToastHUD.show(message: "选区内未检测到 API Key、邮箱、手机号、身份证或 IP")
                return
            }
            self.doc.beginTransaction()
            var nextObjs = self.doc.objects
            for nb in normBoxes {
                let rawR = CGRect(
                    x: activeSel.minX + nb.minX * activeSel.width,
                    y: activeSel.minY + (1.0 - nb.maxY) * activeSel.height,
                    width: nb.width * activeSel.width,
                    height: nb.height * activeSel.height
                ).insetBy(dx: -3, dy: -2).intersection(activeSel)
                guard rawR.width >= 4, rawR.height >= 4 else { continue }
                let payload: AnnotationPayload = useBlur ? .gaussianBlur(rawR) : .mosaic(rawR)
                nextObjs.append(Annotation(payload: payload, style: curStyle))
            }
            self.doc.replaceObjectsWithoutHistory(nextObjs)
            self.doc.commitTransaction(changed: true)
            self.updateToolbarLayout()
            self.needsDisplay = true
            ToastHUD.show(message: "✓ 已一键遮盖 \(normBoxes.count) 处隐私敏感信息（可按 ⌘Z 撤回）")
        }
    }
}
