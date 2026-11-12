import Foundation

/// 标注编辑文档：维护有序标注列表与 100 步快照撤销/重做栈。
/// 利用 Swift `Array` 与值类型 `Annotation` 的内置写时拷贝（CoW），
/// 快照克隆仅复制未修改元素的引用，无逆操作同步 Bug 且内存占用极小。
public struct AnnotationDocument: Sendable {
    public static let maxHistory = 100

    public private(set) var objects: [Annotation] = []
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var pendingSnapshot: [Annotation]?

    public init() {}

    public var isEmpty: Bool { objects.isEmpty }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// 开始一次可撤销事务（如鼠标按下拖拽移动/修改样式前调用）
    public mutating func beginTransaction() {
        pendingSnapshot = objects
    }

    /// 结束事务：`changed` 为真且内容确实变化时压入撤销栈，保证一次拖拽 = 一步撤销
    public mutating func commitTransaction(changed: Bool = true) {
        guard let before = pendingSnapshot else { return }
        pendingSnapshot = nil
        guard changed, before != objects else { return }
        pushUndo(before)
    }

    /// 新增单个有效标注并记录一步撤销
    public mutating func append(_ annotation: Annotation) {
        guard !annotation.isTrivial else { return }
        pushUndo(objects)
        objects.append(annotation)
    }

    /// 原地修改指定下标对象（用于连续拖拽中，需外层包裹 `beginTransaction` / `commitTransaction`）
    public mutating func updateWithoutHistory(at index: Int, _ body: (inout Annotation) -> Void) {
        guard objects.indices.contains(index) else { return }
        body(&objects[index])
    }

    /// 一步修改指定对象并记入历史（如单击色块改色）
    public mutating func modifyWithHistory(at index: Int, _ body: (inout Annotation) -> Void) {
        guard objects.indices.contains(index) else { return }
        let before = objects
        body(&objects[index])
        if before != objects {
            pushUndo(before)
        }
    }

    /// 删除指定下标的单个标注（`Delete` / `Backspace`），一步 `⌘Z` 可恢复
    @discardableResult
    public mutating func remove(at index: Int) -> Annotation? {
        guard objects.indices.contains(index) else { return nil }
        pushUndo(objects)
        return objects.remove(at: index)
    }

    /// 清空全部标注
    public mutating func clearAll() {
        guard !objects.isEmpty else { return }
        pushUndo(objects)
        objects.removeAll()
    }

    /// 从上层到下层（逆序）查找命中点 `p` 的标注下标
    public func hitIndex(at point: CGPoint, tolerance: CGFloat = 6.0) -> Int? {
        for idx in objects.indices.reversed() where objects[idx].hitTest(point, tolerance: tolerance) {
            return idx
        }
        return nil
    }

    /// 撤销一步，返回是否发生了回退
    @discardableResult
    public mutating func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(objects)
        objects = previous
        return true
    }

    /// 重做一步，返回是否发生了前进
    @discardableResult
    public mutating func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(objects)
        objects = next
        return true
    }

    private mutating func pushUndo(_ snapshot: [Annotation]) {
        undoStack.append(snapshot)
        if undoStack.count > Self.maxHistory {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }
}
