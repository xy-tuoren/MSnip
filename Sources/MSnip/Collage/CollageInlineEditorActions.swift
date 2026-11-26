import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 拼图原窗口内嵌编辑器操作扩展：自由裁剪、90°旋转/翻转、11 种标注工具联动与离线隐私敏感信息遮盖
extension CollageInlineEditorView {
    func loadBaseImage(_ cg: CGImage, titlePrefix: String? = nil, initialDoc: AnnotationDocument = AnnotationDocument()) {
        cropOverlay?.removeFromSuperview(); cropOverlay = nil; cropBtn?.style = .subtle
        annotationCanvas?.removeFromSuperview(); annotationCanvas = nil

        baseImage = cg
        imageStageView?.cgImage = cg
        if let p = titlePrefix {
            titleLabel?.stringValue = "\(p) · \(cg.width)×\(cg.height)"
        } else if let cur = titleLabel?.stringValue.components(separatedBy: " · ").first {
            titleLabel?.stringValue = "\(cur) · \(cg.width)×\(cg.height)"
        }

        let baseSz = NSSize(width: max(8, CGFloat(cg.width) / imageScale), height: max(8, CGFloat(cg.height) / imageScale))
        let canvas = PinAnnotationCanvasView(baseSampler: PixelSampler(cgImage: cg), baseSize: baseSz, imageScale: imageScale)
        canvas.doc = initialDoc
        canvas.activeTool = toolbarView.activeTool
        canvas.zoomProvider = { [weak self] in self?.fitZoom ?? 1.0 }
        canvas.onCommit = { [weak self] _ in self?.commitPrimaryAction() }
        canvas.onCancel = { [weak self] in self?.cancelAndExit() }
        canvas.onDocStateChanged = { [weak self] in self?.syncToolbarFromCanvas() }
        stageWell?.addSubview(canvas)
        annotationCanvas = canvas
        syncToolbarFromCanvas()
        layoutEditor()
    }

    func bakeCurrentImage() -> CGImage? {
        guard let canvas = annotationCanvas, let base = baseImage else { return baseImage }
        canvas.commitTextField()
        if canvas.doc.isEmpty { return base }
        return AnnotationRenderer.bakeExportImage(
            sampler: canvas.baseSampler, selection: CGRect(origin: .zero, size: canvas.baseSize),
            imageScale: imageScale, annotations: canvas.doc.objects
        ) ?? base
    }

    func applyGeometryTransform(_ fn: (CGImage) -> CGImage?) {
        guard let cur = bakeCurrentImage(), let transformed = fn(cur) else { return }
        geometryModified = true
        loadBaseImage(transformed)
        configureHeaderButtons()
        if let c = annotationCanvas { window?.makeFirstResponder(c) }
    }

    func toggleCropMode() {
        if let ov = cropOverlay {
            ov.removeFromSuperview(); cropOverlay = nil; cropBtn?.style = .subtle
            if let c = annotationCanvas { window?.makeFirstResponder(c) }
            return
        }
        guard let cur = bakeCurrentImage(), let imgV = imageStageView else { return }
        if annotationCanvas?.doc.isEmpty == false { loadBaseImage(cur) }
        cropBtn?.style = .accent
        let ov = PinCropOverlayView(frame: imgV.frame)
        ov.onCancelCrop = { [weak self] in
            guard let self else { return }
            self.cropOverlay?.removeFromSuperview(); self.cropOverlay = nil; self.cropBtn?.style = .subtle
            if let c = self.annotationCanvas { self.window?.makeFirstResponder(c) }
        }
        ov.onCommitCrop = { [weak self] norm in
            guard let self, let src = self.baseImage else { return }
            let px = max(0, Int((norm.minX * CGFloat(src.width)).rounded()))
            let py = max(0, Int((norm.minY * CGFloat(src.height)).rounded()))
            let pw = max(16, min(src.width - px, Int((norm.width * CGFloat(src.width)).rounded())))
            let ph = max(16, min(src.height - py, Int((norm.height * CGFloat(src.height)).rounded())))
            if let sub = src.cropping(to: CGRect(x: px, y: py, width: pw, height: ph)) {
                self.geometryModified = true
                self.loadBaseImage(ImageTransform.detachedCopy(sub))
                self.configureHeaderButtons()
                if let c = self.annotationCanvas { self.window?.makeFirstResponder(c) }
            }
        }
        stageWell?.addSubview(ov)
        cropOverlay = ov; window?.makeFirstResponder(ov)
    }

    func handleToolbarAction(_ act: ToolbarView.Action) {
        guard let canvas = annotationCanvas else { return }
        canvas.commitTextField()
        switch act {
        case .selectTool(let t): canvas.activeTool = t; syncToolbarFromCanvas(); layoutEditor()
        case .toggleTextCapsule: canvas.togglePinTextCapsule()
        case .selectColor(let c): canvas.applyStyleColor(c); syncToolbarFromCanvas()
        case .selectStroke(let w): canvas.applyStrokeWidth(w); syncToolbarFromCanvas()
        case .undo: _ = canvas.doc.undo(); canvas.needsDisplay = true; syncToolbarFromCanvas()
        case .redo: _ = canvas.doc.redo(); canvas.needsDisplay = true; syncToolbarFromCanvas()
        case .clearAnnotations: canvas.doc.clearAll(); canvas.selectedIndex = nil; canvas.needsDisplay = true; syncToolbarFromCanvas()
        case .autoRedact:
            guard let img = baseImage else { return }
            let useBlur = (canvas.activeTool == .gaussianBlur), st = canvas.style, bSz = canvas.baseSize
            ToastHUD.show(message: "正在离线扫描隐私敏感信息…")
            Task { @MainActor [weak canvas, weak self] in
                let boxes = await VisionTextExtractor.detectSensitiveBoxesOffMain(cgImage: img)
                guard let canvas, !boxes.isEmpty else { ToastHUD.show(message: "未检测到敏感信息"); return }
                canvas.doc.beginTransaction()
                var objs = canvas.doc.objects
                for nb in boxes {
                    let r = CGRect(x: nb.minX * bSz.width, y: (1 - nb.maxY) * bSz.height, width: nb.width * bSz.width, height: nb.height * bSz.height).insetBy(dx: -3, dy: -2).intersection(CGRect(origin: .zero, size: bSz))
                    if r.width >= 4, r.height >= 4 { objs.append(Annotation(payload: useBlur ? .gaussianBlur(r) : .mosaic(r), style: st)) }
                }
                canvas.doc.replaceObjectsWithoutHistory(objs); canvas.doc.commitTransaction(changed: true)
                canvas.needsDisplay = true; self?.syncToolbarFromCanvas()
                ToastHUD.show(message: "✓ 已自动遮盖 \(boxes.count) 处隐私信息")
            }
        case .cancel: cancelAndExit()
        case .confirmCopy: commitPrimaryAction()
        default: break
        }
    }

    func syncToolbarFromCanvas() {
        guard let c = annotationCanvas else { return }
        toolbarView.activeTool = c.activeTool; toolbarView.textCapsule = c.style.textCapsule
        toolbarView.canUndo = c.doc.canUndo; toolbarView.canRedo = c.doc.canRedo
        toolbarView.nextStepNumber = c.doc.nextStepNumber(); toolbarView.colorIndex = c.colorIndex; toolbarView.lineWidth = c.style.lineWidth
        toolbarView.refreshState()
        subbarView.activeTool = c.activeTool; subbarView.lineWidth = c.style.lineWidth
        subbarView.colorIndex = c.colorIndex; subbarView.textCapsule = c.style.textCapsule
        subbarView.isHidden = (c.activeTool == nil); subbarView.refresh()
        configureHeaderButtons()
    }

    func configureHeaderButtons() {
        let hasDoc = (annotationCanvas?.doc.isEmpty == false)
        switch mode {
        case .sourceItem(_, let hasBackup):
            primaryBtn?.title = "应用修改 (↩)"
            [copyOutBtn, pinOutBtn, saveOutBtn].forEach { $0?.isHidden = true }
            revertBtn?.isHidden = !(hasBackup || geometryModified || hasDoc)
        case .stitchedCollage(let hasRevert):
            primaryBtn?.title = "完成 (↩)"
            [copyOutBtn, pinOutBtn, saveOutBtn].forEach { $0?.isHidden = false }
            revertBtn?.isHidden = !(hasRevert || geometryModified || hasDoc)
        }
    }

    func handleRevertAction() {
        switch mode {
        case .sourceItem(let idx, let hasBackup):
            if hasBackup { dismissInline(); onRevertSourceItem?(idx) }
            else { cancelAndExit() }
        case .stitchedCollage:
            dismissInline(); onRevertStitched?()
        }
    }

    func commitPrimaryAction() {
        switch mode {
        case .sourceItem(let idx, _):
            guard let baked = bakeCurrentImage() else { return }
            dismissInline(); onApplySourceItem?(idx, baked)
        case .stitchedCollage:
            guard let base = baseImage, let baked = bakeCurrentImage() else { return }
            let doc = annotationCanvas?.doc ?? AnnotationDocument()
            let geoMod = geometryModified
            dismissInline(); onCommitStitched?(baked, base, doc, geoMod)
        }
    }

    func finishWithExport(_ action: CollageStudioController.ExportAction) {
        guard let base = baseImage, let baked = bakeCurrentImage() else { return }
        let sc = imageScale
        let doc = annotationCanvas?.doc ?? AnnotationDocument()
        let geoMod = geometryModified
        if action != .copy {
            dismissInline()
        }
        onCommitStitched?(baked, base, doc, geoMod)
        onExportStitched?(baked, sc, action)
    }
}

/// 拼图工作室主控制器与原窗口内嵌编辑器的状态桥接扩展
extension CollageStudioController {
    func wireInlineEditorCallbacks() {
        inlineEditor.onBack = { [weak self] in self?.layoutUI() }
        inlineEditor.onApplySourceItem = { [weak self] idx, updated in self?.applyEditedSourceItem(at: idx, cgImage: updated) }
        inlineEditor.onRevertSourceItem = { [weak self] idx in self?.revertSourceItem(at: idx) }
        inlineEditor.onCommitStitched = { [weak self] baked, base, doc, geoMod in
            guard let self else { return }
            if !doc.isEmpty || geoMod {
                self.editedCollageOverride = baked; self.collageEditorBase = base
                self.collageEditorDoc = doc; self.collageEditorGeoModified = geoMod
            } else { self.resetCollageEdits() }
            self.syncAnnotateButtonBadge(); self.layoutUI(); self.schedulePreviewRender()
        }
        inlineEditor.onRevertStitched = { [weak self] in
            guard let self else { return }
            self.resetCollageEdits(); self.layoutUI(); self.schedulePreviewRender()
        }
        inlineEditor.onExportStitched = { [weak self] img, scale, act in self?.deliverStitchedExport(img, scale: scale, action: act) }
    }

    func resetCollageEdits() {
        editedCollageOverride = nil; collageEditorBase = nil
        collageEditorDoc = AnnotationDocument(); collageEditorGeoModified = false
        syncAnnotateButtonBadge()
    }

    func invalidateCollageEditsAndRender() {
        resetCollageEdits(); schedulePreviewRender()
    }

    func syncAnnotateButtonBadge() {
        let active = (editedCollageOverride != nil)
        annotateBtn?.title = active ? "已标注" : "标注"
        annotateBtn?.style = active ? .amberSoft : .subtle
    }

    func openSourceEditor(at index: Int) {
        guard items.indices.contains(index) else { return }
        colorPopover.closeIfShown()
        let it = items[index]
        inlineEditor.enter(title: "素材 #\(index + 1)", cgImage: it.cgImage, scaleFactor: it.scaleFactor,
                           mode: .sourceItem(index: index, hasBackup: it.originalBackup != nil))
        layoutUI()
    }

    func openCollageEditor() {
        colorPopover.closeIfShown()
        let refScale = items.last?.scaleFactor ?? 2.0
        if let existingBase = collageEditorBase {
            inlineEditor.enter(title: "标注合成拼图", cgImage: existingBase, scaleFactor: refScale,
                               mode: .stitchedCollage(hasRevert: editedCollageOverride != nil),
                               initialDoc: collageEditorDoc, alreadyModifiedGeometry: collageEditorGeoModified)
            layoutUI(); return
        }
        let imgs = items.map(\.cgImage), opts = options
        guard !imgs.isEmpty else { return }
        Task { @MainActor [weak self] in
            let hd = await Task.detached(priority: .userInitiated) { ImageCollageStitcher.stitch(images: imgs, options: opts, maxRefSide: 2400) }.value
            guard let self, let hd else { return }
            self.inlineEditor.enter(title: "标注合成拼图", cgImage: hd, scaleFactor: refScale, mode: .stitchedCollage(hasRevert: false))
            self.layoutUI()
        }
    }

    func applyEditedSourceItem(at index: Int, cgImage: CGImage) {
        guard items.indices.contains(index) else { layoutUI(); return }
        if items[index].originalBackup == nil { items[index].originalBackup = items[index].cgImage }
        items[index].cgImage = cgImage
        items[index].thumbnail = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) * 0.5, height: CGFloat(cgImage.height) * 0.5))
        reloadFilmstrip(); layoutUI(); invalidateCollageEditsAndRender()
    }

    func transformSourceItem(at index: Int, using fn: (CGImage) -> CGImage?) {
        guard items.indices.contains(index), let next = fn(items[index].cgImage) else { return }
        applyEditedSourceItem(at: index, cgImage: next)
    }

    func revertSourceItem(at index: Int) {
        guard items.indices.contains(index), let orig = items[index].originalBackup else { layoutUI(); return }
        items[index].cgImage = orig; items[index].originalBackup = nil
        items[index].thumbnail = NSImage(cgImage: orig, size: NSSize(width: CGFloat(orig.width) * 0.5, height: CGFloat(orig.height) * 0.5))
        reloadFilmstrip(); layoutUI(); invalidateCollageEditsAndRender()
    }
}
