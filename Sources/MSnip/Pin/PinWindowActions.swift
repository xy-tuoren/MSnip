import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 贴图窗口的鼠标穿透对照、无损二次标注编辑、缩放与右键菜单动作扩展
extension PinWindow {
    @objc func enableClickThrough() { setClickThrough(true) }

    func setClickThrough(_ enabled: Bool) {
        guard isClickThrough != enabled else { return }
        if enabled { endAnnotationEditing(commit: false) }
        isClickThrough = enabled
        ignoresMouseEvents = enabled
        pinContentView.isGhostMode = enabled
        if enabled {
            preGhostAlpha = alphaValue
            if alphaValue > 0.82 { alphaValue = 0.68 }
            ToastHUD.show(message: "已开启贴图鼠标穿透对照 · 可在顶部菜单栏一键恢复")
        } else {
            alphaValue = preGhostAlpha
        }
        onStateChanged?()
    }

    @objc func beginAnnotationEditing() {
        guard editorCanvas == nil, !isClickThrough else { return }
        pinContentView.liveTextView.clearSelection()
        pinContentView.liveTextView.configure(cgImage: baseCGImage, logicalSize: frame.size)
        pinContentView.isAnnotating = true

        let canvas = PinAnnotationCanvasView(baseSampler: baseSampler, baseSize: baseSize, imageScale: imageScale)
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
        canvas.onDocStateChanged = { [weak panel, weak canvas] in
            guard let panel, let canvas else { return }
            panel.barView.activeTool = canvas.activeTool
            panel.barView.canUndo = canvas.doc.canUndo
            panel.barView.canRedo = canvas.doc.canRedo
            panel.barView.nextStepNumber = canvas.doc.nextStepNumber()
            panel.barView.refreshState()
        }
        panel.barView.onAction = { [weak self, weak canvas, weak panel] act in
            guard let self, let canvas, let panel else { return }
            canvas.commitTextField()
            switch act {
            case .selectTool(let t): canvas.activeTool = t; panel.barView.activeTool = t
            case .selectColor(let c): canvas.applyStyleColor(c); panel.barView.colorIndex = c
            case .selectStroke(let w): canvas.applyStrokeWidth(w); panel.barView.lineWidth = w
            case .undo: _ = canvas.doc.undo(); canvas.needsDisplay = true; canvas.onDocStateChanged?()
            case .redo: _ = canvas.doc.redo(); canvas.needsDisplay = true; canvas.onDocStateChanged?()
            case .cancel: self.endAnnotationEditing(commit: false)
            case .confirmCopy: self.annotationDoc = canvas.doc; self.endAnnotationEditing(commit: true)
            default: break
            }
        }

        pinContentView.addSubview(canvas)
        editorCanvas = canvas
        toolbarPanel = panel
        panel.reposition(anchoringTo: frame, on: screen)
        panel.orderFrontRegardless()
        makeKeyAndOrderFront(nil)
        makeFirstResponder(canvas)
        canvas.onDocStateChanged?()
    }

    func endAnnotationEditing(commit: Bool) {
        editorCanvas?.commitTextField()
        if commit, let baked = AnnotationRenderer.bakeExportImage(
            sampler: baseSampler,
            selection: CGRect(origin: .zero, size: baseSize),
            imageScale: imageScale,
            annotations: annotationDoc.objects
        ) {
            currentCGImage = baked
            ToastHUD.show(message: "已更新贴图标注")
        }
        editorCanvas?.removeFromSuperview()
        editorCanvas = nil
        toolbarPanel?.orderOut(nil)
        toolbarPanel = nil
        pinContentView.isAnnotating = false
        pinContentView.liveTextView.configure(cgImage: currentCGImage, logicalSize: frame.size)
        AnnotationRenderer.purgeCaches()
    }

    @objc func copyImage() { ClipboardAndSave.copyToClipboard(cgImage: currentCGImage, scaleFactor: imageScale) }
    @objc func openOCRPanel() { if let scr = screen ?? NSScreen.main ?? NSScreen.screens.first { onExtractOCR?(currentCGImage, imageScale, scr) } }
    @objc func toggleTextHighlights() {
        pinContentView.liveTextView.highlightBlocks.toggle()
        highlightMenuItem?.state = pinContentView.liveTextView.highlightBlocks ? .on : .off
    }
    @objc func saveImage() { onSavePNG?(currentCGImage, imageScale) }
    @objc func resetZoom() { applyZoom(newZoom: 1.0); alphaValue = 1.0 }
    @objc func toggleHalfOpacity() { alphaValue = alphaValue < 0.95 ? 1.0 : 0.55 }
    @objc func closePin() { endAnnotationEditing(commit: false); orderOut(nil); onClose?(self) }
    @objc func closeAllPins() { onCloseAll?() }

    func applyZoom(newZoom: CGFloat) {
        guard abs(newZoom - zoomFactor) > 0.001 else { return }
        let mouse = NSEvent.mouseLocation, old = frame
        let rx = old.width > 0 ? (mouse.x - old.minX) / old.width : 0.5
        let ry = old.height > 0 ? (mouse.y - old.minY) / old.height : 0.5
        zoomFactor = newZoom
        let sz = NSSize(width: round(baseSize.width * zoomFactor), height: round(baseSize.height * zoomFactor))
        let ax = old.contains(mouse) ? mouse.x - sz.width * rx : old.midX - sz.width * 0.5
        let ay = old.contains(mouse) ? mouse.y - sz.height * ry : old.midY - sz.height * 0.5
        setFrame(NSRect(origin: NSPoint(x: ax, y: ay), size: sz), display: true)
        toolbarPanel?.reposition(anchoringTo: frame, on: screen)
    }

    func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "编辑 / 二次标注贴图 (E)…", action: #selector(beginAnnotationEditing), keyEquivalent: "")
        menu.addItem(withTitle: "开启鼠标穿透对照 (P)", action: #selector(enableClickThrough), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "提取图中文字 (OCR 对照窗)…", action: #selector(openOCRPanel), keyEquivalent: "o")
        let hlItem = NSMenuItem(title: "高亮图中可划选文字块", action: #selector(toggleTextHighlights), keyEquivalent: "")
        self.highlightMenuItem = hlItem
        menu.addItem(hlItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "复制贴图图像 (按住 ⌘ 可拖拽成文件)", action: #selector(copyImage), keyEquivalent: "c")
        menu.addItem(withTitle: "另存为 PNG...", action: #selector(saveImage), keyEquivalent: "s")
        menu.addItem(.separator())
        menu.addItem(withTitle: "重置 100% 大小与不透明", action: #selector(resetZoom), keyEquivalent: "0")
        menu.addItem(withTitle: "切换半透明对照 (55%)", action: #selector(toggleHalfOpacity), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "关闭此贴图 (双击空白处)", action: #selector(closePin), keyEquivalent: "")
        menu.addItem(withTitle: "关闭全部贴图", action: #selector(closeAllPins), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }
}
