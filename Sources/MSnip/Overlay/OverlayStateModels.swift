import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 覆盖层快速启动直达模式
enum OverlayQuickLaunchMode: Equatable {
    case standard
    case quickOCR
    case quickTranslate
    case quickLongShot
    case quickLatex
    case quickRecord

    var hudPrefix: String {
        switch self {
        case .standard:       return ""
        case .quickOCR:       return "识字 · "
        case .quickTranslate: return "翻译 · "
        case .quickLongShot:  return "长截图 · "
        case .quickLatex:     return "公式 · "
        case .quickRecord:    return "录屏 · "
        }
    }
}

/// 覆盖层交互阶段与拖拽状态
enum DragOperation {
    case pendingSnapOrCreate(anchor: CGPoint, snapRect: CGRect?)
    case creatingSelection(anchor: CGPoint)
    case movingSelection(initialRect: CGRect, mouseStart: CGPoint)
    case resizingSelection(handle: ResizeHandle, initialRect: CGRect, mouseStart: CGPoint)
    case drawingAnnotation(tool: ToolKind, start: CGPoint)
    case erasing(lastPoint: CGPoint, erased: Bool)
    case movingAnnotation(index: Int, lastPoint: CGPoint, moved: Bool)
}

/// 自动矩阵识别预览与平滑过渡内聚状态模型（解耦 OverlayView 零散可变属性）
struct OverlayAutoSnapState {
    var stack: [CGRect] = []
    var index: Int = 0
    var scrollAccumulator: CGFloat = 0
    var preferredArea: CGFloat?
    var displayedRect: CGRect?
    var animTimer: Timer?
    var displayLink: AnyObject?
    var deferredWork: DispatchWorkItem?

    func hoveredRect(hasSelection: Bool) -> CGRect? {
        guard !hasSelection, stack.indices.contains(index) else { return nil }
        return stack[index]
    }

    mutating func clearTargets() {
        stack = []
        index = 0
        scrollAccumulator = 0
        preferredArea = nil
        displayedRect = nil
    }
}

/// 覆盖整个物理屏幕的无边框置顶窗口（禁用系统窗口弹出缩放动画与焦点抢占，实现 0ms 无抖动静默冻结）
final class OverlayWindow: NSPanel {
    init(screen: NSScreen, contentView: NSView) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = .screenSaver
        self.animationBehavior = .none
        self.becomesKeyOnlyIfNeeded = false
        self.setFrame(screen.frame, display: false)
        self.isFloatingPanel = true
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.isOpaque = true
        self.hasShadow = false
        self.acceptsMouseMovedEvents = true
        self.contentView = contentView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 独立 GPU 图层承载的 120fps 零全屏重绘光标放大镜视图（彻底隔离放大镜移动与全屏主画布脏区）
final class OverlayMagnifierLayerView: NSView {
    weak var ownerOverlay: OverlayView?
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: OverlayView.loupeCardW, height: OverlayView.loupeCardH))
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: 4)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let owner = ownerOverlay else { return }
        owner.renderMagnifierContent(in: ctx, cardRect: bounds)
    }
}

/// 覆盖层顶部坐标/状态胶囊绘制扩展
extension OverlayView {
    private static let sharedHudPillAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 12.0, weight: .semibold),
        .foregroundColor: MSnipUITheme.inkPrimary
    ]

    func drawHUDPill(ctx: CGContext, anchorRect: CGRect, text: String) {
        let nsText = text as NSString
        let textSize = nsText.size(withAttributes: Self.sharedHudPillAttrs)
        let badgeW = ceil(textSize.width + 16)
        let badgeH: CGFloat = 24
        let badgeX = round(min(max(8, anchorRect.minX), bounds.width - badgeW - 8))
        let badgeY = round(anchorRect.minY >= (badgeH + 10) ? (anchorRect.minY - badgeH - 7) : (anchorRect.minY + 7))
        let badgeRect = CGRect(x: badgeX, y: badgeY, width: badgeW, height: badgeH)

        ctx.saveGState()
        let pill = CGPath(roundedRect: badgeRect, cornerWidth: 6.0, cornerHeight: 6.0, transform: nil)
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: NSColor.black.withAlphaComponent(0.18).cgColor)
        ctx.setFillColor(MSnipUITheme.cardBg.cgColor)
        ctx.addPath(pill)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.setStrokeColor(MSnipUITheme.borderStrong.cgColor)
        ctx.setLineWidth(1.0)
        ctx.addPath(pill)
        ctx.strokePath()
        nsText.draw(
            at: CGPoint(x: round(badgeRect.minX + 8), y: round(badgeRect.minY + (badgeH - textSize.height) * 0.5)),
            withAttributes: Self.sharedHudPillAttrs
        )
        ctx.restoreGState()
    }
}
