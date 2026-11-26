import AppKit
import CoreGraphics
import Foundation
import ImageIO
import MSnipCore
import UniformTypeIdentifiers

/// 拼图工作室自定义浮窗（自动兼容内嵌标注画布的 Esc / ⌘Z / ⌘C / ⌘V / ⌘S 快捷键分发）
final class CollageStudioWindow: NSWindow {
    var onCopyShortcut: (() -> Void)?
    var onPasteShortcut: (() -> Void)?
    var onSaveShortcut: (() -> Void)?
    var onEscapeShortcut: (() -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command && ch == "w" { close(); return true }
        if firstResponder is NSTextView {
            if flags == .command && ch == "s" { onSaveShortcut?(); return true }
            if flags.isEmpty && event.keyCode == 53 && !(firstResponder?.nextResponder is PinAnnotationCanvasView) {
                makeFirstResponder(nil); return true
            }
            return super.performKeyEquivalent(with: event)
        }
        if firstResponder is PinCropOverlayView { return false }
        if let canvas = firstResponder as? PinAnnotationCanvasView {
            if flags == .command && ch == "s" { onSaveShortcut?(); return true }
            if flags == .command && ch == "c" && canvas.selectedIndex == nil { onCopyShortcut?(); return true }
            return canvas.performKeyEquivalent(with: event)
        }
        if flags == .command && ch == "c" { onCopyShortcut?(); return true }
        if flags == .command && ch == "v" { onPasteShortcut?(); return true }
        if flags == .command && ch == "s" { onSaveShortcut?(); return true }
        if flags.isEmpty && event.keyCode == 53 {
            if onEscapeShortcut?() == true { return true }
            close(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// 拼图工作室素材导入、高清拼图导出与多页 PDF 合并扩展
extension CollageStudioController {
    enum ExportAction { case copy, pin, save }

    func openSourceLightbox(startIndex: Int) {
        let list = items.map { CollageImageLightbox.Entry(title: $0.title, cgImage: $0.cgImage, scaleFactor: $0.scaleFactor) }
        lightbox.show(entries: list, startIndex: startIndex, showsCheckerboard: false)
    }

    func openCollageLightbox() {
        let refScale = items.last?.scaleFactor ?? 2.0
        if let edited = editedCollageOverride {
            lightbox.show(entries: [.init(title: "已标注拼图预览", cgImage: edited, scaleFactor: refScale)], startIndex: 0, showsCheckerboard: options.background == .transparent)
            return
        }
        let imgs = items.map(\.cgImage), opts = options
        guard !imgs.isEmpty else { return }
        Task { @MainActor [weak self] in
            let hd = await Task.detached(priority: .userInitiated) { ImageCollageStitcher.stitch(images: imgs, options: opts, maxRefSide: 2400) }.value
            guard let self, let hd else { return }
            self.lightbox.show(entries: [.init(title: "\(opts.layout.title)拼图预览", cgImage: hd, scaleFactor: refScale)], startIndex: 0, showsCheckerboard: opts.background == .transparent)
        }
    }

    func layoutTopBarMeta() {
        guard let tBar = topBarView else { return }
        let barH: CGFloat = 38, editing = inlineEditor.isActive
        titleLabel?.isHidden = editing
        metaPill?.isHidden = editing || (metaPill?.text.isEmpty ?? true)
        modeSeg?.isHidden = editing
        inlineEditor.topControlsView.isHidden = !editing
        inlineEditor.topControlsView.frame = NSRect(x: 74, y: 0, width: max(200, tBar.bounds.width - 74), height: barH)
        if !editing {
            titleLabel?.frame = NSRect(x: 78, y: 10, width: 74, height: 18)
            metaPill?.frame = NSRect(x: 154, y: 9, width: metaPill?.fittingWidth() ?? 0, height: 20)
            modeSeg?.frame = NSRect(x: tBar.bounds.width - 12 - 182, y: round((barH - 26) * 0.5), width: 182, height: 26)
        }
        if let close = window?.standardWindowButton(.closeButton), let mini = window?.standardWindowButton(.miniaturizeButton),
           let zoom = window?.standardWindowButton(.zoomButton), let sup = close.superview {
            let cy = round(sup.bounds.height - barH * 0.5 - close.frame.height * 0.5)
            close.setFrameOrigin(NSPoint(x: 14, y: cy)); mini.setFrameOrigin(NSPoint(x: 34, y: cy)); zoom.setFrameOrigin(NSPoint(x: 54, y: cy))
        }
    }

    func applyTheme() {
        window?.appearance = GeekTheme.windowAppearance; window?.backgroundColor = GeekTheme.windowBg
        titleLabel?.textColor = GeekTheme.inkPrimary; styleHeaderLabel?.textColor = GeekTheme.inkMuted
        [bgLabel, alignLabel, aspectLabel, badgeLabel, watermarkLabel].forEach { $0?.textColor = GeekTheme.inkSecondary }
        pdfHintLabel?.textColor = GeekTheme.inkMuted
        [rootView, topBarView, topBarDivider, metaPill, canvasView, stripDivider, div1, div2, div3, divExport].forEach { $0?.needsDisplay = true }
    }

    func syncControlsFromOptions() {
        gapRow?.intValue = options.gapPx; padRow?.intValue = options.padPx; radiusRow?.intValue = Int(options.cornerRadiusPx)
        bgTrigger?.style = options.background; bgTrigger?.customColor = options.customBackgroundColor; bgTrigger?.gradientPreset = options.gradientPreset
        shadowPill?.isOn = options.cardShadow
        alignSeg?.selectedIndex = options.scaleAlignment.rawValue; aspectSeg?.selectedIndex = options.aspectPreset.rawValue
        badgeSeg?.selectedIndex = options.badge.rawValue; pdfPageNumSeg?.selectedIndex = options.pdfPageNumber.rawValue
        watermarkSeg?.selectedIndex = options.watermark.rawValue; watermarkField?.stringValue = options.watermarkText
        syncPresetHighlight()
    }

    func presentBgColorPopover() {
        guard let anchor = bgTrigger else { return }
        colorPopover.show(anchoredTo: anchor, options: options, allowsTransparent: studioMode == .collage) { [weak self] sel in
            guard let self else { return }
            switch sel {
            case .transparent: self.options.background = .transparent; self.options.customBackgroundColor = nil
            case .gradient(let g): self.options.background = .gradient; self.options.gradientPreset = g; self.options.customBackgroundColor = nil
            case .solid(let rgb): self.options.background = .lightGray; self.options.customBackgroundColor = rgb
            }
            self.syncControlsFromOptions(); self.invalidateCollageEditsAndRender()
        }
    }

    func pickBackgroundFromScreen() {
        colorPopover.closeIfShown()
        NSColorSampler().show { [weak self] picked in
            guard let srgb = picked?.usingColorSpace(.sRGB) else { return }
            let rgb = RGBAColor(
                UInt8(min(255, max(0, Int((srgb.redComponent * 255).rounded())))),
                UInt8(min(255, max(0, Int((srgb.greenComponent * 255).rounded())))),
                UInt8(min(255, max(0, Int((srgb.blueComponent * 255).rounded()))))
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.options.background = .lightGray; self.options.customBackgroundColor = rgb
                self.syncControlsFromOptions(); self.invalidateCollageEditsAndRender()
            }
        }
    }

    func syncPresetHighlight() {
        presetBar?.selectedIndex = Self.presets.firstIndex { $0.gap == options.gapPx && $0.pad == options.padPx && $0.radius == Int(options.cornerRadiusPx) } ?? -1
    }

    func pickImageFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false; panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK { appendImageURLs(panel.urls) }
    }

    @discardableResult
    func appendImageURLs(_ urls: [URL]) -> Int {
        var added = 0
        for u in urls where u.isFileURL {
            guard let src = CGImageSourceCreateWithURL(u as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            items.append(makeSourceItem(title: u.lastPathComponent, cgImage: cg, scaleFactor: 2.0)); added += 1
        }
        if added > 0 { reloadFilmstrip(); invalidateCollageEditsAndRender() }
        return added
    }

    func appendFromClipboard() {
        if let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty, appendImageURLs(urls) > 0 { return }
        guard let ns = ClipboardAndSave.readImageFromClipboard(), let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            ToastHUD.show(message: "剪贴板暂无图片"); return
        }
        items.append(makeSourceItem(title: "剪贴板图片", cgImage: cg, scaleFactor: 2.0))
        reloadFilmstrip(); invalidateCollageEditsAndRender()
    }

    func clearAllItems() {
        guard !items.isEmpty else { return }
        items.removeAll(); reloadFilmstrip(); invalidateCollageEditsAndRender()
    }

    func showRecentCapturesPicker() {
        guard let ring = historyRingProvider?(), let anchor = addRecentBtn else { return }
        let menu = NSMenu(); let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss"
        if ring.originalEntries.isEmpty {
            let empty = NSMenuItem(title: "暂无最近截图", action: nil, keyEquivalent: ""); empty.isEnabled = false; menu.addItem(empty)
        } else {
            for (idx, e) in ring.originalEntries.prefix(10).enumerated() {
                let it = NSMenuItem(title: "\(tf.string(from: e.createdAt)) · \(e.pixelWidth)×\(e.pixelHeight)", action: #selector(pickRecentItem(_:)), keyEquivalent: "")
                it.tag = idx; it.target = self; it.setVisibleImage(ring.menuThumbnail(for: e)); menu.addItem(it)
            }
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 2), in: anchor)
    }

    @objc func pickRecentItem(_ sender: NSMenuItem) {
        guard let ring = historyRingProvider?(), ring.originalEntries.indices.contains(sender.tag) else { return }
        let e = ring.originalEntries[sender.tag]
        guard let cg = ring.loadCGImage(for: e) else { return }
        let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss"
        items.append(makeSourceItem(title: "截图 \(tf.string(from: e.createdAt))", cgImage: cg, scaleFactor: e.scaleFactor))
        reloadFilmstrip(); invalidateCollageEditsAndRender()
    }

    func exportCollage(action: ExportAction) {
        let refScale = items.last?.scaleFactor ?? 2.0
        if let edited = editedCollageOverride { deliverStitchedExport(edited, scale: refScale, action: action); return }
        let imgs = items.map(\.cgImage), opts = options
        guard !imgs.isEmpty else { return }
        Task { @MainActor [weak self] in
            let hd = await Task.detached(priority: .userInitiated) { ImageCollageStitcher.stitch(images: imgs, options: opts, maxRefSide: 2400) }.value
            guard let self, let hd else { ToastHUD.show(message: "拼图合成失败"); return }
            self.deliverStitchedExport(hd, scale: refScale, action: action)
        }
    }

    func deliverStitchedExport(_ hd: CGImage, scale: CGFloat, action: ExportAction) {
        switch action {
        case .copy: onCopyCollage?(hd, scale)
        case .pin:  window?.close(); onPinCollage?(hd, scale)
        case .save: onSaveCollage?(hd, scale)
        }
    }

    func exportPDF() {
        let imgs = items.map(\.cgImage), opts = options, bg = opts.background == .transparent ? .white : opts.background
        guard !imgs.isEmpty else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]
        let tf = DateFormatter(); tf.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "MSnip-合并文档-\(tf.string(from: Date())).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            let ok = await Task.detached(priority: .userInitiated) {
                ImageCollageStitcher.exportMultiPagePDF(images: imgs, padPx: opts.padPx, background: bg, customBackgroundColor: opts.customBackgroundColor,
                                                        gradientPreset: opts.gradientPreset, watermark: opts.watermark, watermarkText: opts.watermarkText, pageNumber: opts.pdfPageNumber, to: url)
            }.value
            if ok {
                ToastHUD.show(message: "✓ 已合并导出 \(imgs.count) 页 PDF 文档", subtitle: url.lastPathComponent,
                              actionTitle: "在访达中显示", onAction: { ClipboardAndSave.revealInFinder(url) })
            } else { ToastHUD.show(message: "导出 PDF 失败") }
        }
    }

    func makeSourceItem(title: String, cgImage: CGImage, scaleFactor: CGFloat) -> CollageSourceItem {
        let thumb = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) * 0.5, height: CGFloat(cgImage.height) * 0.5))
        return CollageSourceItem(title: title, cgImage: cgImage, scaleFactor: scaleFactor, thumbnail: thumb)
    }

    func schedulePreviewRender() {
        renderSeq &+= 1; let isPDF = (studioMode == .pdfMerge)
        onOptionsChanged?(options)
        canvasView?.isPDFMode = isPDF
        canvasView?.pdfPadPx = options.padPx
        canvasView?.pdfBgStyle = options.background == .transparent ? .white : options.background
        canvasView?.pdfCustomBgColor = options.customBackgroundColor; canvasView?.pdfGradientPreset = options.gradientPreset
        canvasView?.pdfPageItems = items; canvasView?.pdfPageNumStyle = options.pdfPageNumber
        canvasView?.pdfWatermarkStyle = options.watermark; canvasView?.pdfWatermarkText = options.watermarkText
        canvasView?.showsCheckerboard = (options.background == .transparent)
        if isPDF {
            hasPendingPreviewRender = false
            metaPill?.text = items.isEmpty ? "" : "共 \(items.count) 页 · 原图无损"
            layoutTopBarMeta(); return
        }
        if let edited = editedCollageOverride {
            hasPendingPreviewRender = false
            canvasView?.previewImage = edited
            metaPill?.text = "\(items.count) 张 · \(edited.width)×\(edited.height) · 已标注"
            layoutTopBarMeta(); return
        }
        if items.isEmpty {
            hasPendingPreviewRender = false
            canvasView?.previewImage = nil; metaPill?.text = ""; layoutTopBarMeta(); return
        }
        if isRenderingPreview { hasPendingPreviewRender = true; return }
        runNextCoalescedPreviewRender()
    }

    /// 单飞合并渲染：滑条或 2D 色盘高频拖动时最多保持 1 个后台 CGContext 合成在途，消除并发内存峰值
    private func runNextCoalescedPreviewRender() {
        hasPendingPreviewRender = false
        let seq = renderSeq, imgs = items.map(\.cgImage), opts = options
        guard !imgs.isEmpty, studioMode == .collage, editedCollageOverride == nil else {
            isRenderingPreview = false; return
        }
        isRenderingPreview = true
        Task { @MainActor [weak self] in
            let preview = await Task.detached(priority: .userInitiated) {
                ImageCollageStitcher.stitch(images: imgs, options: opts, maxRefSide: 1440)
            }.value
            guard let self else { return }
            if self.renderSeq == seq {
                self.canvasView?.previewImage = preview
                self.metaPill?.text = preview.map { "\(imgs.count) 张 · \($0.width)×\($0.height)" } ?? ""
                self.layoutTopBarMeta()
            }
            if self.hasPendingPreviewRender {
                self.runNextCoalescedPreviewRender()
            } else {
                self.isRenderingPreview = false
            }
        }
    }
}
