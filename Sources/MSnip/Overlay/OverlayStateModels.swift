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
