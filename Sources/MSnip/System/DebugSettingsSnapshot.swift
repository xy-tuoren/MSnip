#if DEBUG
import AppKit
import Foundation
import MSnipCore

/// 仅 Debug 构建：`swift run MSnip --debug-render-settings <输出目录> [--lang en]`
/// 离屏构建设置窗口并把各标签页（含滚动区完整内容）渲染为 PNG，用于检查不同界面语言下的截断与重叠。
/// 全程只读：使用默认配置与内置示例服务，断开窗口代理、不调用 `switchTab` / `close` 等会落盘的方法，也不注册热键或显示窗口。
enum DebugSettingsSnapshot {
    @MainActor
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--debug-render-settings"), flag + 1 < args.count else { return false }
        let outDir = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        var suffix = "zh"
        if let langFlag = args.firstIndex(of: "--lang"), langFlag + 1 < args.count, args[langFlag + 1] == "en" {
            let table = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/en.lproj/Localizable.strings")
            guard let dict = NSDictionary(contentsOf: table) as? [String: String] else {
                fputs("cannot read \(table.path)\n", stderr)
                return true
            }
            MSnipL10n.setOverrideTable(dict)
            suffix = "en"
        }
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        TranslationSettingsWindow().debugRender(to: outDir, suffix: suffix)
        PermissionGuideController().debugRender(to: outDir, suffix: suffix)
        renderCustomBars(to: outDir, suffix: suffix)
        renderCollageStudio(to: outDir, suffix: suffix)
        return true
    }

    /// 自绘的截图工具栏、录屏控制栏、长截图控制栏、速览卡与暂存架侧栏（固定槽位最容易被长译文撑破）
    @MainActor
    private static func renderCustomBars(to dir: URL, suffix: String) {
        let bg = NSColor(white: 0.55, alpha: 1)
        let toolbar = ToolbarView()
        let toolStates: [(String, (ToolbarView) -> Void)] = [
            ("idle", { _ in }),
            ("rect", { $0.activeTool = .rect }),
            ("text", { $0.activeTool = .text }),
            ("mosaic", { $0.activeTool = .mosaic }),
            ("eraser", { $0.activeTool = .eraser }),
            ("pinedit", { $0.activeTool = nil; $0.isPinEditorMode = true }),
            ("recording", { $0.isPinEditorMode = false; $0.isRecordingMode = true })
        ]
        for (name, apply) in toolStates {
            apply(toolbar)
            toolbar.rebuildItems()
            writePNG(toolbar, named: "\(suffix)-bar-toolbar-\(name)", to: dir, background: bg)
        }

        let sub = ToolbarSubbarView()
        for tool in [ToolKind.rect, .text, .mosaic, .eraser] {
            sub.activeTool = tool
            writePNG(sub, named: "\(suffix)-bar-subbar-\(tool)", to: dir, background: bg)
        }

        let rec = RecordingControlBarView()
        writePNG(rec, named: "\(suffix)-bar-rec-idle", to: dir, background: bg)
        rec.countdownNumber = 3
        writePNG(rec, named: "\(suffix)-bar-rec-countdown", to: dir, background: bg)
        rec.countdownNumber = nil; rec.isRecording = true; rec.elapsedSeconds = 12
        writePNG(rec, named: "\(suffix)-bar-rec-recording", to: dir, background: bg)
        rec.isEncoding = true
        writePNG(rec, named: "\(suffix)-bar-rec-encoding", to: dir, background: bg)

        let long = LongShotControlBarView()
        writePNG(long, named: "\(suffix)-bar-longshot", to: dir, background: bg)

        let thumb = sampleImage(width: 320, height: 200)
        for (name, media, saved) in [("image", false, false), ("saved", false, true), ("media", true, true)] {
            let card = QuickAccessCardView(thumbnail: thumb, badgeText: media ? "MP4" : "PNG", isMediaFile: media, hasSavedURL: saved)
            writePNG(card, named: "\(suffix)-bar-quick-\(name)", to: dir, background: bg)
        }

        let rail = ShelfActionRailView(frame: NSRect(x: 0, y: 0, width: ShelfPanelController.railWidth - 18, height: 96))
        rail.itemCount = 12
        writePNG(rail, named: "\(suffix)-bar-shelf-rail", to: dir, background: GeekTheme.windowBg)
        rail.selectedCount = 3
        writePNG(rail, named: "\(suffix)-bar-shelf-rail-selected", to: dir, background: GeekTheme.windowBg)
    }

    /// 拼图与 PDF 工作台：拼图模式（网格 + 水印输入）、PDF 模式与窗内编辑器顶栏
    @MainActor
    private static func renderCollageStudio(to dir: URL, suffix: String) {
        let studio = CollageStudioController()
        studio.ensureWindowBuilt()
        guard let win = studio.window, let root = win.contentView else { return }
        win.delegate = nil
        studio.options.layout = .grid
        studio.options.watermark = .corner
        studio.syncControlsFromOptions(); studio.applyTheme(); studio.layoutUI()
        writePNG(root, named: "\(suffix)-collage-grid", to: dir, background: GeekTheme.windowBg)
        studio.studioMode = .pdfMerge
        studio.layoutUI()
        writePNG(root, named: "\(suffix)-collage-pdf", to: dir, background: GeekTheme.windowBg)
        studio.studioMode = .collage
        if let img = sampleImage(width: 640, height: 400) {
            studio.inlineEditor.enter(title: L("素材 #%@", 1), cgImage: img, scaleFactor: 2, mode: .sourceItem(index: 0, hasBackup: true))
            studio.layoutUI()
            writePNG(root, named: "\(suffix)-collage-editor", to: dir, background: GeekTheme.windowBg)
        }
    }

    private static func sampleImage(width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.35, green: 0.55, blue: 0.85, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// 先铺底色再 cacheDisplay：文字、控件与图层背景都会进入位图
    @MainActor
    static func writePNG(_ view: NSView, named name: String, to dir: URL, background: NSColor) {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        background.setFill()
        bounds.fill()
        NSGraphicsContext.restoreGraphicsState()
        view.cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }
}

extension TranslationSettingsWindow {
    @MainActor
    func debugRender(to dir: URL, suffix: String) {
        appConfigProvider = { AppConfig() }
        draft = TranslationSettingsConfig(profiles: TranslationSettingsConfig.defaultStarterProfiles())
        ocrLatex.ocrConfig = OCRRecognitionConfig()
        ocrLatex.latexConfig = LatexRecognitionConfig()
        selectedIndex = 1
        ensureWindowBuilt()
        guard let win = window, let root = win.contentView else { return }
        // 断开窗口代理：windowWillClose 会把草稿与 OCR 配置写回磁盘，调试渲染绝不能触发
        win.delegate = nil
        refreshTopBarPopups()
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        loadSelectedProfileIntoForm()
        refreshGeneralAndPermissionsUI()

        let pages: [(SettingsTab, GeekFlippedView)] = [
            (.general, generalPage), (.shortcuts, shortcutsPage), (.ocrAndLatex, ocrAndLatexPage), (.translation, translationPage)
        ]
        func show(_ tab: SettingsTab) {
            for (t, page) in pages { page.isHidden = (t != tab) }
            tabSegment.selectedIndex = tab.rawValue
        }
        for (tab, page) in pages {
            show(tab)
            if tab == .ocrAndLatex {
                ocrLatex.ocrConfig.engineKind = .customHTTP
                ocrLatex.latexConfig.engineKind = .autoVisionLLM
                relayoutOCRLatexCards()
            }
            if tab == .shortcuts { shortcutSubMode = 0 }
            write(root, named: "\(suffix)-\(tab.rawValue)-window", to: dir)
            for (i, scroll) in scrollViews(in: page).enumerated() {
                guard let doc = scroll.documentView, doc.bounds.height > scroll.contentSize.height + 1 else { continue }
                write(doc, named: "\(suffix)-\(tab.rawValue)-scroll\(i)", to: dir)
            }
        }
        // 快捷键页第二子模式（截图内单键）
        show(.shortcuts)
        globalShortcutsBox.isHidden = true
        canvasShortcutsBox.isHidden = false
        shortcutModeSegment.selectedIndex = 1
        write(root, named: "\(suffix)-1-canvas-window", to: dir)
        for (i, scroll) in scrollViews(in: canvasShortcutsBox).enumerated() {
            guard let doc = scroll.documentView else { continue }
            write(doc, named: "\(suffix)-1-canvas-scroll\(i)", to: dir)
        }
        // 不调用 close()：进程随即退出，避免任何收尾保存逻辑
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        var out: [NSScrollView] = []
        for sub in view.subviews {
            if let s = sub as? NSScrollView, !s.isHidden { out.append(s) } else { out += scrollViews(in: sub) }
        }
        return out
    }

    private func write(_ view: NSView, named name: String, to dir: URL) {
        DebugSettingsSnapshot.writePNG(view, named: name, to: dir, background: window?.backgroundColor ?? .windowBackgroundColor)
    }
}
#endif
