import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 覆盖层快速启动直达模式
enum OverlayQuickLaunchMode: Equatable {
    case standard
    case quickOCR
    case quickSilentOCR
    case quickTranslate
    case quickLongShot
    case quickLatex
    case quickRecord

    var hudPrefix: String {
        switch self {
        case .standard:       return ""
        case .quickOCR:       return "识字 · "
        case .quickSilentOCR: return "静默识字 · "
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
    case resizingAnnotation(index: Int, handle: AnnotationHandle, initialPayload: AnnotationPayload, moved: Bool)
}

/// 自动矩阵识别预览与平滑过渡内聚状态模型（解耦 OverlayView 零散可变属性）
struct OverlayAutoSnapState {
    var stack: [CGRect] = []
    var index: Int = 0
    var scrollAccumulator: CGFloat = 0
    var tierAnchorPoint: CGPoint?
    var manualTierOffset: Int = 0
    var displayedRect: CGRect?
    var activeWindowRect: CGRect?
    var querySeq: UInt64 = 0
    var appliedSeq: UInt64 = 0
    var cancelToken: UInt64 = 0
    var lastQueryDispatchUptime: TimeInterval = 0
    var settleTimer: Timer?
    var isGliding: Bool = false
    var vsyncTimer: Timer?
    var vsyncLink: AnyObject?
    var lastPolledScreenPoint: CGPoint?

    func hoveredRect(hasSelection: Bool) -> CGRect? {
        guard !hasSelection, stack.indices.contains(index) else { return nil }
        return stack[index]
    }

    mutating func clearTargets() {
        stack = []
        index = 0
        scrollAccumulator = 0
        tierAnchorPoint = nil
        manualTierOffset = 0
        displayedRect = nil
        activeWindowRect = nil
        cancelToken &+= 1
    }
}

/// 覆盖整个物理屏幕的无边框置顶窗口（禁用系统窗口弹出缩放动画与焦点抢占，实现 0ms 无抖动静默冻结）
final class OverlayWindow: NSPanel {
    init(screen: NSScreen, contentView: OverlayView, activateForMenu: Bool = false) {
        super.init(
            contentRect: screen.frame,
            styleMask: activateForMenu ? [.borderless] : [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.animationBehavior = .none
        self.isFloatingPanel = true
        // 必须在 isFloatingPanel = true 之后设置 level（AppKit 设置 isFloatingPanel 会把 level 重置为 .floating = 3，导致被程序坞与菜单栏遮挡）
        self.level = NSWindow.Level(rawValue: max(
            NSWindow.Level.screenSaver.rawValue,
            Int(CGShieldingWindowLevel())
        ))
        self.becomesKeyOnlyIfNeeded = false
        self.setFrame(screen.frame, display: false)
        self.hidesOnDeactivate = false
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.isOpaque = true
        self.hasShadow = false
        self.acceptsMouseMovedEvents = true

        // 静态 GPU 底图层托管冻结整屏 CGImage（WindowServer 合成器零拷贝直出，彻底免除 120Hz CPU 裁图重绘）
        let host = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        host.wantsLayer = true
        host.layer?.contents = contentView.snapshot.cgImage
        host.layer?.contentsGravity = .resize
        host.layer?.magnificationFilter = .nearest
        host.layer?.contentsScale = max(1.0, contentView.snapshot.scaleFactor)
        contentView.dimSnapView.frame = host.bounds
        host.addSubview(contentView.dimSnapView)
        contentView.frame = host.bounds
        contentView.wantsLayer = true
        contentView.layer?.isOpaque = false
        host.addSubview(contentView)
        self.contentView = host
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
