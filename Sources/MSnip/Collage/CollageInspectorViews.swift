import AppKit
import CoreGraphics
import Foundation
import ImageIO
import MSnipCore
import UniformTypeIdentifiers

/// 拼图工作室自定义窗口（支持 ⌘C 快捷复制拼图、⌘S 快捷保存/导出 PDF、Esc 快捷关闭）
final class CollageStudioWindow: NSWindow {
    var onCopyShortcut: (() -> Void)?
    var onSaveShortcut: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == .command && ch == "c" { onCopyShortcut?(); return true }
        if flags == .command && ch == "s" { onSaveShortcut?(); return true }
        if flags.isEmpty && event.keyCode == 53 { close(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// 拼图右侧属性区：带实时数值读数的极客滑条行（间距 / 边距 / 圆角）
final class CollageSliderRow: NSView {
    private let titleLabel: NSTextField
    private let valueLabel: NSTextField
    private let slider: NSSlider
    private let unit: String
    var onChange: ((Int) -> Void)?

    override var isFlipped: Bool { true }

    var intValue: Int {
        get { Int(slider.doubleValue.rounded()) }
        set {
            slider.doubleValue = Double(newValue)
            valueLabel.stringValue = "\(newValue) \(unit)"
        }
    }

    init(title: String, min: Double, max: Double, value: Int, unit: String = "px") {
        self.unit = unit
        self.titleLabel = NSTextField(labelWithString: title)
        self.valueLabel = NSTextField(labelWithString: "\(value) \(unit)")
        self.slider = NSSlider(value: Double(value), minValue: min, maxValue: max, target: nil, action: nil)
        super.init(frame: .zero)

        titleLabel.font = .systemFont(ofSize: 12.0, weight: .medium)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        valueLabel.alignment = .right
        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderChanged)

        addSubview(titleLabel); addSubview(valueLabel); addSubview(slider)
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width
        titleLabel.frame = NSRect(x: 0, y: 0, width: w - 58, height: 16)
        valueLabel.frame = NSRect(x: w - 56, y: 0, width: 56, height: 16)
        slider.frame = NSRect(x: 0, y: 19, width: w, height: 18)
    }

    func applyTheme() {
        titleLabel.textColor = GeekTheme.inkSecondary
        valueLabel.textColor = GeekTheme.inkPrimary
    }

    @objc private func sliderChanged() {
        let v = Int(slider.doubleValue.rounded())
        valueLabel.stringValue = "\(v) \(unit)"
        onChange?(v)
    }
}

/// 拼图背景底色色板（柔灰 / 纯白 / 深炭 / 透明棋盘格，PDF 模式自动隐藏透明项）
final class CollageBgSwatchView: NSView {
    var availableStyles: [CollageBackgroundStyle] = CollageBackgroundStyle.allCases { didSet { needsDisplay = true } }
    var selected: CollageBackgroundStyle = .lightGray { didSet { needsDisplay = true } }
    var onSelect: ((CollageBackgroundStyle) -> Void)?
    private var hoveredIdx: Int? { didSet { if oldValue != hoveredIdx { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        guard !availableStyles.isEmpty else { return }
        let x = convert(event.locationInWindow, from: nil).x
        hoveredIdx = min(availableStyles.count - 1, max(0, Int(x / (bounds.width / CGFloat(availableStyles.count)))))
    }

    override func mouseExited(with event: NSEvent) { hoveredIdx = nil }

    override func mouseDown(with event: NSEvent) {
        guard !availableStyles.isEmpty else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let idx = min(availableStyles.count - 1, max(0, Int(x / (bounds.width / CGFloat(availableStyles.count)))))
        selected = availableStyles[idx]
        onSelect?(availableStyles[idx])
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !availableStyles.isEmpty else { return }
        let gap: CGFloat = 6
        let cellW = (bounds.width - gap * CGFloat(availableStyles.count - 1)) / CGFloat(availableStyles.count)

        for (i, item) in availableStyles.enumerated() {
            let r = CGRect(x: CGFloat(i) * (cellW + gap), y: 1, width: cellW, height: bounds.height - 2)
            let p = CGPath(roundedRect: r, cornerWidth: 7, cornerHeight: 7, transform: nil)
            let isSel = (item == selected)

            ctx.saveGState()
            ctx.setFillColor((isSel ? GeekTheme.accent.withAlphaComponent(GeekTheme.isDark ? 0.22 : 0.12) : (hoveredIdx == i ? GeekTheme.hoverSoft : GeekTheme.segTrackBg)).cgColor)
            ctx.addPath(p); ctx.fillPath()
            ctx.setStrokeColor((isSel ? GeekTheme.accent : GeekTheme.border).cgColor)
            ctx.setLineWidth(isSel ? 1.4 : 0.9); ctx.addPath(p); ctx.strokePath()

            let sw = CGRect(x: r.minX + 6, y: round(r.midY - 5.5), width: 11, height: 11)
            let swP = CGPath(roundedRect: sw, cornerWidth: 3, cornerHeight: 3, transform: nil)
            ctx.saveGState()
            ctx.addPath(swP); ctx.clip()
            if let rgba = item.rgbaColor {
                ctx.setFillColor(rgba.cgColor); ctx.fill(sw)
            } else {
                ctx.setFillColor(NSColor.white.cgColor); ctx.fill(sw)
                ctx.setFillColor(NSColor(white: 0.72, alpha: 1).cgColor)
                ctx.fill(CGRect(x: sw.minX, y: sw.minY, width: 5.5, height: 5.5))
                ctx.fill(CGRect(x: sw.minX + 5.5, y: sw.minY + 5.5, width: 5.5, height: 5.5))
            }
            ctx.restoreGState()
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.22).cgColor)
            ctx.setLineWidth(0.6); ctx.addPath(swP); ctx.strokePath()

            GeekTheme.drawText(
                item.title,
                in: CGRect(x: sw.maxX + 4, y: r.minY, width: r.maxX - sw.maxX - 7, height: r.height),
                font: .systemFont(ofSize: 11.0, weight: isSel ? .semibold : .regular),
                color: isSel ? GeekTheme.inkPrimary : GeekTheme.inkSecondary
            )
            ctx.restoreGState()
        }
    }
}

/// 拼图工作室素材导入、高清拼图导出与多页 PDF 合并扩展
extension CollageStudioController {
    enum ExportAction { case copy, pin, save }

    func pickImageFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK { appendImageURLs(panel.urls) }
    }

    func appendImageURLs(_ urls: [URL]) {
        var added = 0
        for u in urls where u.isFileURL {
            guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            items.append(makeSourceItem(title: u.lastPathComponent, cgImage: cg, scaleFactor: 2.0))
            added += 1
        }
        if added > 0 { reloadFilmstrip(); schedulePreviewRender() }
    }

    func appendFromClipboard() {
        guard let ns = ClipboardAndSave.readImageFromClipboard(),
              let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            ToastHUD.show(message: "剪贴板暂无图片"); return
        }
        items.append(makeSourceItem(title: "剪贴板图片", cgImage: cg, scaleFactor: 2.0))
        reloadFilmstrip(); schedulePreviewRender()
    }

    func clearAllItems() {
        guard !items.isEmpty else { return }
        items.removeAll()
        reloadFilmstrip()
        schedulePreviewRender()
    }

    func showRecentCapturesPicker() {
        guard let ring = historyRingProvider?(), let anchor = addRecentBtn else { return }
        let menu = NSMenu()
        let tf = DateFormatter(); tf.dateFormat = "HH:mm:ss"
        if ring.originalEntries.isEmpty {
            let empty = NSMenuItem(title: "暂无最近截图", action: nil, keyEquivalent: "")
            empty.isEnabled = false; menu.addItem(empty)
        } else {
            for (idx, e) in ring.originalEntries.prefix(10).enumerated() {
                let it = NSMenuItem(title: "\(tf.string(from: e.createdAt)) · \(e.pixelWidth)×\(e.pixelHeight)", action: #selector(pickRecentItem(_:)), keyEquivalent: "")
                it.tag = idx; it.target = self; it.image = ring.menuThumbnail(for: e); menu.addItem(it)
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
        reloadFilmstrip(); schedulePreviewRender()
    }

    func exportCollage(action: ExportAction) {
        let imgs = items.map(\.cgImage), opts = options
        let refScale = items.last?.scaleFactor ?? 2.0
        guard !imgs.isEmpty else { return }
        Task { @MainActor [weak self] in
            let hd = await Task.detached(priority: .userInitiated) {
                ImageCollageStitcher.stitch(images: imgs, options: opts, maxRefSide: 2400)
            }.value
            guard let self, let hd else { ToastHUD.show(message: "拼图合成失败"); return }
            switch action {
            case .copy: self.onCopyCollage?(hd, refScale)
            case .pin:  self.window?.close(); self.onPinCollage?(hd, refScale)
            case .save: self.onSaveCollage?(hd, refScale)
            }
        }
    }

    func exportPDF() {
        let imgs = items.map(\.cgImage), pad = options.padPx, bg = options.background == .transparent ? .white : options.background
        guard !imgs.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let tf = DateFormatter(); tf.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "MSnip-合并文档-\(tf.string(from: Date())).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            let ok = await Task.detached(priority: .userInitiated) {
                ImageCollageStitcher.exportMultiPagePDF(images: imgs, padPx: pad, background: bg, to: url)
            }.value
            if ok {
                ToastHUD.show(
                    message: "✓ 已合并导出 \(imgs.count) 页 PDF 文档",
                    subtitle: url.lastPathComponent,
                    actionTitle: "在访达中显示",
                    onAction: { ClipboardAndSave.revealInFinder(url) }
                )
            } else { ToastHUD.show(message: "导出 PDF 失败") }
        }
    }

    func makeSourceItem(title: String, cgImage: CGImage, scaleFactor: CGFloat) -> CollageSourceItem {
        let thumb = NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) * 0.5, height: CGFloat(cgImage.height) * 0.5))
        return CollageSourceItem(title: title, cgImage: cgImage, scaleFactor: scaleFactor, thumbnail: thumb)
    }
}
