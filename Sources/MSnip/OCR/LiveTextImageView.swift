import AppKit
import CoreGraphics
import Foundation
import ImageIO
import VisionKit

/// 原生实况文本（Live Text）图像容器：
/// - 在 macOS 13+ 自动挂载系统 `ImageAnalysisOverlayView`，直接支持原图 `I` 光标划词复制与链接点击；
/// - 强制开启 `isSupplementaryInterfaceHidden = true` 隐藏右下角系统自带的「翻译/实况文本」冗余悬浮角标。
@MainActor
final class LiveTextImageView: NSView {
    let imageView = NSImageView()
    private var overlayRef: AnyObject?
    private var analysisTask: Task<Void, Never>?

    var highlightBlocks: Bool = false {
        didSet {
            if #available(macOS 13.0, *), let ov = overlayRef as? ImageAnalysisOverlayView {
                ov.selectableItemsHighlighted = highlightBlocks
            }
        }
    }

    var hasSelection: Bool {
        if #available(macOS 13.0, *), let ov = overlayRef as? ImageAnalysisOverlayView {
            return ov.hasActiveTextSelection
        }
        return false
    }

    var selectedText: String {
        if #available(macOS 14.0, *), let ov = overlayRef as? ImageAnalysisOverlayView {
            return ov.selectedText
        }
        return ""
    }

    @discardableResult
    func copySelectionIfActive() -> Bool {
        guard hasSelection else { return false }
        if #available(macOS 14.0, *), let ov = overlayRef as? ImageAnalysisOverlayView, !ov.selectedText.isEmpty {
            ClipboardAndSave.copyText(ov.selectedText)
            return true
        }
        return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
    }

    init(scaling: NSImageScaling) {
        super.init(frame: .zero)
        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = scaling
        imageView.imageAlignment = .alignCenter
        imageView.isEditable = false
        imageView.allowsCutCopyPaste = false
        addSubview(imageView)

        if #available(macOS 13.0, *), ImageAnalyzer.isSupported {
            let ov = ImageAnalysisOverlayView(frame: bounds)
            ov.autoresizingMask = [.width, .height]
            ov.trackingImageView = imageView
            ov.preferredInteractionTypes = [.textSelection, .dataDetectors]
            ov.isSupplementaryInterfaceHidden = true
            addSubview(ov)
            overlayRef = ov
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        analysisTask?.cancel()
    }

    func setPreviewImageOnly(cgImage: CGImage, logicalSize: NSSize, highlightBlocks: Bool = false) {
        analysisTask?.cancel()
        self.highlightBlocks = highlightBlocks
        imageView.image = NSImage(cgImage: cgImage, size: logicalSize)
        if #available(macOS 13.0, *), let ov = overlayRef as? ImageAnalysisOverlayView {
            ov.analysis = nil
            ov.isSupplementaryInterfaceHidden = true
        }
    }

    /// 直接复用 `VisionTextExtractor` 已经跑完的 `ImageAnalysis`，零重复推理开销
    func applyPrecomputedAnalysis(_ analysisObj: AnyObject?, highlightBlocks: Bool) {
        self.highlightBlocks = highlightBlocks
        if #available(macOS 13.0, *),
           let ov = overlayRef as? ImageAnalysisOverlayView,
           let analysis = analysisObj as? ImageAnalysis {
            ov.analysis = analysis
            ov.isSupplementaryInterfaceHidden = true
            ov.selectableItemsHighlighted = highlightBlocks
        }
    }

    /// 供桌面贴图窗 (`PinWindow`) 独立异步挂载实况文本图层
    func configure(cgImage: CGImage, logicalSize: NSSize, highlightBlocks: Bool = false) {
        setPreviewImageOnly(cgImage: cgImage, logicalSize: logicalSize, highlightBlocks: highlightBlocks)
        guard #available(macOS 13.0, *),
              ImageAnalyzer.isSupported,
              let ov = overlayRef as? ImageAnalysisOverlayView else { return }

        analysisTask = Task { @MainActor [weak self, weak ov] in
            var cfg = ImageAnalyzer.Configuration([.text, .machineReadableCode])
            cfg.locales = ["zh-Hans", "zh-Hant", "en-US", "ja-JP"]
            guard let analysis = try? await SharedLiveAnalyzer.instance.analyze(cgImage, orientation: .up, configuration: cfg),
                  !Task.isCancelled,
                  let self, let ov else { return }
            ov.analysis = analysis
            ov.isSupplementaryInterfaceHidden = true
            ov.selectableItemsHighlighted = self.highlightBlocks
        }
    }

    func hasInteractiveItem(atWindowPoint windowPoint: NSPoint) -> Bool {
        guard #available(macOS 13.0, *),
              let ov = overlayRef as? ImageAnalysisOverlayView,
              ov.analysis != nil else {
            return false
        }
        let localPt = ov.convert(windowPoint, from: nil)
        guard ov.bounds.contains(localPt) else { return false }
        return ov.hasInteractiveItem(at: localPt)
    }

    func clearSelection() {
        if #available(macOS 13.0, *), let ov = overlayRef as? ImageAnalysisOverlayView {
            ov.resetSelection()
        }
    }

    func clearAll() {
        analysisTask?.cancel()
        analysisTask = nil
        highlightBlocks = false
        imageView.image = nil
        if #available(macOS 13.0, *), let ov = overlayRef as? ImageAnalysisOverlayView {
            ov.resetSelection()
            ov.analysis = nil
        }
    }
}
