import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 贴图窗口的外置悬浮条联动、鼠标穿透对照、无损二次标注与右键菜单扩展
extension PinWindow {
    func syncHoverBarVisibility() {
        hideHoverWorkItem?.cancel()
        hideHoverWorkItem = nil

        if isClickThrough || editorCanvas != nil {
            hoverBarPanel.orderOut(nil)
            return
        }

        if isMouseInPin || isMouseInHoverBar || isDraggingFromBar {
            hoverBarPanel.reposition(anchoringTo: frame, on: screen)
            if !hoverBarPanel.isVisible {
                hoverBarPanel.orderFrontRegardless()
            }
        } else {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isMouseInPin, !self.isMouseInHoverBar, !self.isDraggingFromBar else { return }
                    self.hoverBarPanel.orderOut(nil)
                }
            }
            hideHoverWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
        }
    }

    @objc func enableClickThrough() { setClickThrough(true) }

    func setClickThrough(_ enabled: Bool) {
        guard isClickThrough != enabled else { return }
        if enabled { endAnnotationEditing(commit: false) }
        isClickThrough = enabled
        ignoresMouseEvents = enabled
        pinContentView.isGhostMode = enabled
        syncHoverBarVisibility()
        if enabled {
            preGhostAlpha = alphaValue
            if alphaValue > 0.82 { alphaValue = 0.68 }
            ToastHUD.show(message: "已开启贴图鼠标穿透对照 · 可在顶部菜单栏一键恢复")
        } else {
            alphaValue = preGhostAlpha
        }
        onStateChanged?()
    }

    private func acquireBaseSampler() -> PixelSampler {
        if let existing = activeBaseSampler { return existing }
        let created = PixelSampler(cgImage: baseCGImage)
        activeBaseSampler = created
        return created
    }

    @objc func beginAnnotationEditing() {
        guard editorCanvas == nil, !isClickThrough else { return }
        pinContentView.liveTextView.clearSelection()
        pinContentView.liveTextView.configure(cgImage: baseCGImage, logicalSize: frame.size)
        pinContentView.isAnnotating = true
        syncHoverBarVisibility()

        let canvas = PinAnnotationCanvasView(baseSampler: acquireBaseSampler(), baseSize: baseSize, imageScale: imageScale)
        canvas.frame = pinContentView.bounds
        canvas.autoresizingMask = [.width, .height]
        canvas.doc = annotationDoc
        canvas.zoomProvider = { [weak self] in self?.zoomFactor ?? 1.0 }
        canvas.onCommit = { [weak self] updatedDoc in
            self?.annotationDoc = updatedDoc
            self?.endAnnotationEditing(commit: true)
        }
        canvas.onCancel = { [weak self] in self?.endAnnotationEditing(commit: false) }

        let panel = PinToolbarPanel()
        canvas.onDocStateChanged = { [weak self, weak panel, weak canvas] in
            guard let self, let panel, let canvas else { return }
            panel.barView.activeTool = canvas.activeTool
            panel.barView.textCapsule = canvas.style.textCapsule
            panel.barView.canUndo = canvas.doc.canUndo
            panel.barView.canRedo = canvas.doc.canRedo
            panel.barView.nextStepNumber = canvas.doc.nextStepNumber()
            panel.subbarView.activeTool = canvas.activeTool
            panel.subbarView.lineWidth = canvas.style.lineWidth
            panel.subbarView.colorIndex = canvas.colorIndex
            panel.subbarView.textCapsule = canvas.style.textCapsule
            panel.reposition(anchoringTo: self.frame, on: self.screen)
        }
        let handleBarAct: (ToolbarView.Action) -> Void = { [weak self, weak canvas, weak panel] act in
            guard let self, let canvas, let panel else { return }
            canvas.commitTextField()
            switch act {
            case .selectTool(let t):
                canvas.activeTool = t; panel.barView.activeTool = t; panel.subbarView.activeTool = t
                panel.reposition(anchoringTo: self.frame, on: self.screen)
            case .toggleTextCapsule: canvas.togglePinTextCapsule()
            case .selectColor(let c):
                canvas.applyStyleColor(c); panel.barView.colorIndex = c; panel.subbarView.colorIndex = c
            case .selectStroke(let w):
                canvas.applyStrokeWidth(w); panel.barView.lineWidth = w; panel.subbarView.lineWidth = w
            case .undo: _ = canvas.doc.undo(); canvas.needsDisplay = true; canvas.onDocStateChanged?()
            case .redo: _ = canvas.doc.redo(); canvas.needsDisplay = true; canvas.onDocStateChanged?()
            case .clearAnnotations: canvas.doc.clearAll(); canvas.selectedIndex = nil; canvas.needsDisplay = true; canvas.onDocStateChanged?()
            case .cancel: self.endAnnotationEditing(commit: false)
            case .confirmCopy: self.annotationDoc = canvas.doc; self.endAnnotationEditing(commit: true)
            default: break
            }
        }
        panel.barView.onAction = handleBarAct
        panel.subbarView.onAction = handleBarAct

        pinContentView.addSubview(canvas)
        editorCanvas = canvas
        toolbarPanel = panel
        panel.reposition(anchoringTo: frame, on: screen)
        panel.orderFrontRegardless()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(canvas)
        canvas.onDocStateChanged?()
    }

    func endAnnotationEditing(commit: Bool, reanalyzeLiveText: Bool = true) {
        guard editorCanvas != nil || toolbarPanel != nil else { return }
        editorCanvas?.commitTextField()
        if commit, let baked = AnnotationRenderer.bakeExportImage(
            sampler: acquireBaseSampler(), selection: CGRect(origin: .zero, size: baseSize),
            imageScale: imageScale, annotations: annotationDoc.objects
        ) {
            currentCGImage = baked
            ToastHUD.show(message: "已更新贴图标注")
        }
        editorCanvas?.removeFromSuperview(); editorCanvas = nil
        toolbarPanel?.orderOut(nil); toolbarPanel = nil
        activeBaseSampler = nil
        pinContentView.isAnnotating = false
        if reanalyzeLiveText {
            pinContentView.liveTextView.configure(cgImage: currentCGImage, logicalSize: baseSize)
        }
        syncHoverBarVisibility()
        AnnotationRenderer.purgeCaches()
    }

    @objc func copyImage() { ClipboardAndSave.copyToClipboard(cgImage: currentCGImage, scaleFactor: imageScale) }
    @objc func copyImageWithPath() {
        ClipboardAndSave.copyToClipboard(cgImage: currentCGImage, scaleFactor: imageScale, forceIncludePath: true)
        ToastHUD.show(message: "已复制贴图与临时文件路径 · 可直接粘贴到任意终端")
    }
    @objc func openOCRPanel() { if let scr = screen ?? NSScreen.main ?? NSScreen.screens.first { onExtractOCR?(currentCGImage, imageScale, scr) } }
    @objc func openTranslatePanel() { if let scr = screen ?? NSScreen.main ?? NSScreen.screens.first { onTranslateImage?(currentCGImage, imageScale, scr) } }
    @objc func scanBarcodeInPin() {
        let img = currentCGImage
        Task { @MainActor in
            let codes = await VisionTextExtractor.detectBarcodesOffMain(cgImage: img)
            if let first = codes.first {
                OverlayView.presentBarcodeToast(first)
            } else {
                ToastHUD.show(message: "贴图中未检测到二维码或条形码")
            }
        }
    }
    @objc func toggleTextHighlights() {
        pinContentView.liveTextView.highlightBlocks.toggle()
        highlightMenuItem?.state = pinContentView.liveTextView.highlightBlocks ? .on : .off
    }
    @objc func saveImage() { onSavePNG?(currentCGImage, imageScale) }
    @objc func quickSaveImage() { onQuickSavePNG?(currentCGImage, imageScale) }
    @objc func resetZoom() { applyZoom(newZoom: 1.0); alphaValue = 1.0 }
    @objc func toggleHalfOpacity() { alphaValue = alphaValue < 0.95 ? 1.0 : 0.55 }
    @objc func rotateClockwise90() { applyImageTransform(ImageTransform.rotateClockwise90, toast: "已顺时针旋转 90°") }
    @objc func flipHorizontal() { applyImageTransform(ImageTransform.flipHorizontal, toast: "已水平镜像翻转") }

    private func applyImageTransform(_ transform: (CGImage) -> CGImage?, toast: String) {
        guard editorCanvas == nil, !isClickThrough else { return }
        guard let nextCG = transform(currentCGImage) else { return }
        baseCGImage = nextCG
        currentCGImage = nextCG
        activeBaseSampler = nil
        annotationDoc = AnnotationDocument()
        let nextBase = NSSize(
            width: max(8, CGFloat(nextCG.width) / imageScale),
            height: max(8, CGFloat(nextCG.height) / imageScale)
        )
        baseSize = nextBase
        let sz = NSSize(width: round(nextBase.width * zoomFactor), height: round(nextBase.height * zoomFactor))
        let old = frame
        let nx = ((old.midX - sz.width * 0.5) * imageScale).rounded() / imageScale
        let ny = ((old.midY - sz.height * 0.5) * imageScale).rounded() / imageScale
        setFrame(NSRect(origin: NSPoint(x: nx, y: ny), size: sz), display: true)
        pinContentView.liveTextView.configure(cgImage: nextCG, logicalSize: nextBase)
        if hoverBarPanel.isVisible { hoverBarPanel.reposition(anchoringTo: frame, on: screen) }
        ToastHUD.show(message: toast)
    }

    @objc func closePin() {
        hideHoverWorkItem?.cancel(); hideHoverWorkItem = nil
        hoverBarPanel.orderOut(nil)
        endAnnotationEditing(commit: false, reanalyzeLiveText: false)
        activeBaseSampler = nil
        pinContentView.liveTextView.clearAll()
        pinContentView.menu = nil
        pinContentView.liveTextView.menu = nil
        orderOut(nil)
        onClose?(self)
    }

    @objc func closeAllPins() { onCloseAll?() }

    func applyZoom(newZoom: CGFloat) {
        guard abs(newZoom - zoomFactor) > 0.001 else { return }
        let mouse = NSEvent.mouseLocation, old = frame
        let rx = old.width > 0 ? (mouse.x - old.minX) / old.width : 0.5
        let ry = old.height > 0 ? (mouse.y - old.minY) / old.height : 0.5
        zoomFactor = newZoom
        let sz = NSSize(width: round(baseSize.width * zoomFactor), height: round(baseSize.height * zoomFactor))
        let ax = ((old.contains(mouse) ? mouse.x - sz.width * rx : old.midX - sz.width * 0.5) * imageScale).rounded() / imageScale
        let ay = ((old.contains(mouse) ? mouse.y - sz.height * ry : old.midY - sz.height * 0.5) * imageScale).rounded() / imageScale
        setFrame(NSRect(origin: NSPoint(x: ax, y: ay), size: sz), display: true)
        toolbarPanel?.reposition(anchoringTo: frame, on: screen)
        if hoverBarPanel.isVisible { hoverBarPanel.reposition(anchoringTo: frame, on: screen) }
    }

    func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "编辑 / 二次标注贴图 (E)…", action: #selector(beginAnnotationEditing), keyEquivalent: "")
        menu.addItem(withTitle: "开启鼠标穿透对照 (P)", action: #selector(enableClickThrough), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "提取图中文字 (T)…", action: #selector(openOCRPanel), keyEquivalent: "o")
        menu.addItem(withTitle: "翻译图中文字 (Y)…", action: #selector(openTranslatePanel), keyEquivalent: "")
        menu.addItem(withTitle: "扫描二维码 / 条形码", action: #selector(scanBarcodeInPin), keyEquivalent: "")
        let hlItem = NSMenuItem(title: "高亮图中可划选文字块", action: #selector(toggleTextHighlights), keyEquivalent: "")
        self.highlightMenuItem = hlItem
        menu.addItem(hlItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "复制贴图图像 (按住 ⌘ 可拖拽成文件)", action: #selector(copyImage), keyEquivalent: "c")
        menu.addItem(withTitle: "复制临时文件路径 (供 IDE / 终端粘贴)", action: #selector(copyImageWithPath), keyEquivalent: "")
        let quickItem = NSMenuItem(title: "一键保存到默认目录", action: #selector(quickSaveImage), keyEquivalent: "s")
        menu.addItem(quickItem)
        let saveAsItem = NSMenuItem(title: "另存为…", action: #selector(saveImage), keyEquivalent: "s")
        saveAsItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(saveAsItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "顺时针旋转 90° (R)", action: #selector(rotateClockwise90), keyEquivalent: "")
        menu.addItem(withTitle: "水平镜像翻转 (H)", action: #selector(flipHorizontal), keyEquivalent: "")
        menu.addItem(withTitle: "重置 100% 大小与不透明", action: #selector(resetZoom), keyEquivalent: "0")
        menu.addItem(withTitle: "切换半透明对照 (55%)", action: #selector(toggleHalfOpacity), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "关闭此贴图 (Esc / 双击空白处)", action: #selector(closePin), keyEquivalent: "")
        menu.addItem(withTitle: "关闭全部贴图", action: #selector(closeAllPins), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }
}
