#if DEBUG
import AppKit
import Foundation
import MSnipCore

/// 仅 Debug 构建：`swift run MSnip --debug-render-settings <输出目录> [--lang en]`
/// 离屏构建设置窗口并把各标签页（含滚动区完整内容）渲染为 PNG，用于检查不同界面语言下的截断与重叠。
/// 全程只读：使用默认配置与内置示例服务，断开窗口代理、不调用 `switchTab` / `close` 等会落盘的方法，也不注册热键或显示窗口。
enum DebugSettingsSnapshot {
    /// 为 true 时三个设置弹窗只构建内容、不真正弹出（供离屏渲染）
    nonisolated(unsafe) static var suppressPopoverPresentation = false

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
        TruncationAudit.isRecording = true
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        TranslationSettingsWindow().debugRender(to: outDir, suffix: suffix)
        PermissionGuideController().debugRender(to: outDir, suffix: suffix)
        renderCustomBars(to: outDir, suffix: suffix)
        renderCollageStudio(to: outDir, suffix: suffix)
        renderPopovers(to: outDir, suffix: suffix)
        if TruncationAudit.writeReport(to: outDir, suffix: suffix) > 0 { exit(2) }
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

    /// 设置里的三个弹窗：目标语种、添加服务 / 大模型预设、热键冲突体检（不探测注册热键，只读系统与运行中应用）
    @MainActor
    private static func renderPopovers(to dir: URL, suffix: String) {
        suppressPopoverPresentation = true
        defer { suppressPopoverPresentation = false }
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        func render(_ view: NSView?, _ name: String) {
            guard let view else { return }
            view.appearance = GeekTheme.windowAppearance
            for case let table as NSTableView in allSubviews(of: view) { table.reloadData(); table.layoutSubtreeIfNeeded() }
            writePNG(view, named: "\(suffix)-pop-\(name)", to: dir, background: GeekTheme.cardBg)
        }

        LanguagePickerPopover.shared.show(anchoredTo: anchor, current: .autoZhEn, dark: true, onPick: { _ in })
        render(LanguagePickerPopover.shared.debugContentView, "language")

        ProviderAddAndPresetPopover.shared.showAddService(anchoredTo: anchor, onCreate: { _ in })
        render(ProviderAddAndPresetPopover.shared.debugContentView, "add-service")
        ProviderAddAndPresetPopover.shared.showLLMPresetPicker(anchoredTo: anchor, currentEndpoint: "", onPick: { _ in })
        render(ProviderAddAndPresetPopover.shared.debugContentView, "llm-presets")

        let snapshot = HotKeyConflictScanner.scan(probing: [])
        let conflicts = HotKeyConflictPopover.shared
        conflicts.show(
            anchoredTo: anchor,
            configProvider: { AppConfig() },
            snapshotProvider: { snapshot },
            isPriorityActiveProvider: { false },
            onRescan: { snapshot },
            onApplyRecommended: { _, _ in },
            onApplyBatchRecommended: { _ in },
            onToggleLiveProbe: {},
            onPopoverClosed: {}
        )
        for tab in 0..<4 {
            conflicts.debugSelectTab(tab)
            render(conflicts.debugContentView, "hotkeys\(tab)")
        }
    }

    private static func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
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
        TruncationAudit.context = name
        view.layoutSubtreeIfNeeded()
        TruncationAudit.scan(view)
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
        // 「模型与服务」页：逐个服务类型渲染基础与高级表单
        let extraKinds: [TranslationProviderKind] = [.youdao, .deepl, .customWebhook, .openAIResponses, .anthropicCompatible, .geminiNative]
        draft.profiles += extraKinds.map { TranslationProviderProfile.makePreset($0) }
        tableView.reloadData()
        show(.translation)
        for i in draft.profiles.indices {
            for advanced in [false, true] {
                selectedIndex = i; isAdvancedExpanded = advanced
                tableView.selectRowIndexes(IndexSet(integer: i), byExtendingSelection: false)
                loadSelectedProfileIntoForm()
                write(root, named: "\(suffix)-3-service\(i)\(advanced ? "-adv" : "")", to: dir)
            }
        }
        isAdvancedExpanded = false; selectedIndex = 1
        tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        loadSelectedProfileIntoForm()

        // 「识字与翻译」页：逐个 OCR / 公式引擎渲染动态行
        show(.ocrAndLatex)
        for i in 0..<max(OCREngineKind.allCases.count, LatexEngineKind.allCases.count) {
            ocrLatex.ocrConfig.engineKind = OCREngineKind.allCases[i % OCREngineKind.allCases.count]
            ocrLatex.latexConfig.engineKind = LatexEngineKind.allCases[i % LatexEngineKind.allCases.count]
            relayoutOCRLatexCards()
            for scroll in scrollViews(in: ocrAndLatexPage) {
                if let doc = scroll.documentView { write(doc, named: "\(suffix)-2-engines\(i)", to: dir) }
            }
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
/// 仅 Debug：截断审计。离屏渲染期间收集「放不下」的文字（自绘 drawText 截断 + 标签/系统按钮宽度不足），
/// 渲染结束写出 truncation-report.txt；有截断时进程以 2 退出，便于脚本或 CI 判定。
enum TruncationAudit {
    nonisolated(unsafe) static var isRecording = false
    nonisolated(unsafe) static var context = ""
    nonisolated(unsafe) private(set) static var hits: [String] = []
    nonisolated(unsafe) private static var seen = Set<String>()

    static func record(_ text: String, needed: CGFloat, available: CGFloat) {
        guard isRecording else { return }
        let flat = text.replacingOccurrences(of: "\n", with: " ⏎ ")
        let line = "[\(context)] “\(flat)” needs \(Int(needed.rounded(.up)))pt, has \(Int(available.rounded(.down)))pt"
        if seen.insert(line).inserted { hits.append(line) }
    }

    /// 遍历可见视图：单行只读标签与系统按钮的文字宽度超过自身宽度即记一条（截断且带完整提示的标签视为有意为之）
    @MainActor
    static func scan(_ view: NSView) {
        for sub in view.subviews where !sub.isHidden {
            if let tf = sub as? NSTextField, tf.isEditable, tf.stringValue.isEmpty,
               let ph = tf.placeholderAttributedString?.string ?? tf.placeholderString, !ph.isEmpty {
                // 输入框占位提示：按字段字体测量，留出左右内边距
                let font = (tf.placeholderAttributedString?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
                    ?? tf.font ?? .systemFont(ofSize: NSFont.systemFontSize)
                let need = GeekTheme.measureTextWidth(ph, font: font) + 6
                if need > tf.bounds.width + 1 { record("(placeholder) " + ph, needed: need, available: tf.bounds.width) }
            } else if let tf = sub as? NSTextField, !tf.isEditable, tf.cell?.wraps != true, !tf.stringValue.isEmpty {
                let truncatingByDesign = tf.toolTip != nil
                    && [.byTruncatingTail, .byTruncatingMiddle, .byTruncatingHead].contains(tf.lineBreakMode)
                let need = ceil(tf.intrinsicContentSize.width)
                if !truncatingByDesign, need > tf.bounds.width + 1 {
                    record(tf.stringValue, needed: need, available: tf.bounds.width)
                }
            } else if let btn = sub as? NSButton, !btn.title.isEmpty, btn.fittingSize.width > btn.bounds.width + 1 {
                record(btn.title, needed: btn.fittingSize.width, available: btn.bounds.width)
            }
            scan(sub)
        }
    }

    static func writeReport(to dir: URL, suffix: String) -> Int {
        let body = hits.isEmpty ? "No truncated text.\n" : hits.joined(separator: "\n") + "\n"
        try? body.write(to: dir.appendingPathComponent("truncation-report-\(suffix).txt"), atomically: true, encoding: .utf8)
        print("Truncation audit (\(suffix)): \(hits.count) issue(s) → \(dir.appendingPathComponent("truncation-report-\(suffix).txt").path)")
        return hits.count
    }
}
#endif
