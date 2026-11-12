import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 覆盖层的智能矩阵防抖驻留、滚轮尺度记忆与 60fps 丝滑过渡动画扩展
extension OverlayView {
    /// 按全局鼠标位置初始化首帧自动高亮框（首帧直接到位，无入场位移）
    func refreshAutoSnapAtCurrentMouse() {
        guard let win = window else { return }
        let winPt = win.convertPoint(fromScreen: NSEvent.mouseLocation)
        let localPt = convert(winPt, from: nil)
        if bounds.contains(localPt) {
            updateAutoSnap(at: localPt, immediate: true)
        }
    }

    /// 刷新局部坐标处的自动识别矩阵栈（带边界防抖驻留与滚轮层级尺度保持）
    func updateAutoSnap(at localPoint: CGPoint, immediate: Bool = false) {
        guard selection == nil else { return }
        let newStack = regionDetector.detectHierarchy(at: localPoint, in: snapshot)
        guard !newStack.isEmpty else { return }

        let prevTarget = hoveredAutoRect
        // 若移出了原先所在的顶层窗口，重置滚轮偏好的层级面积
        if newStack.count <= 1 {
            preferredSnapArea = nil
        } else if let prevWin = autoSnapStack.dropLast().last,
                  let curWin = newStack.dropLast().last,
                  !Self.isSameRegion(prevWin, curWin, tol: 8) {
            preferredSnapArea = nil
        }

        let chosenIndex = chooseStableIndex(
            in: newStack,
            at: localPoint,
            previousTarget: prevTarget
        )

        autoSnapStack = newStack
        autoSnapIndex = chosenIndex
        scrollSnapAccumulator = 0

        guard let target = hoveredAutoRect else { return }
        if immediate || displayedAutoRect == nil {
            stopSnapGlide()
            displayedAutoRect = target
            needsDisplay = true
        } else if prevTarget != target {
            startSnapGlideToTarget()
        }
    }

    /// 滚轮切换当前光标下的嵌套矩阵层级（小控件 <-> 父容器 <-> 整窗口）
    func stepAutoSnapTier(by step: Int) {
        guard autoSnapStack.count > 1 else { return }
        let nextIdx = min(max(0, autoSnapIndex + step), autoSnapStack.count - 1)
        guard nextIdx != autoSnapIndex else { return }
        autoSnapIndex = nextIdx
        if let target = hoveredAutoRect {
            preferredSnapArea = target.width * target.height
            startSnapGlideToTarget()
        }
    }

    func stopSnapGlide() {
        snapAnimTimer?.invalidate()
        snapAnimTimer = nil
    }

    func drawAutoSnapChrome(ctx: CGContext, displayRect: CGRect, targetRect: CGRect) {
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.systemCyan.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(2.0)
        ctx.stroke(displayRect.insetBy(dx: 0.5, dy: 0.5))
        ctx.restoreGState()

        // 尺寸数字始终读取目标整数矩阵（过渡动画期间数字不乱跳）
        let pxW = Int((targetRect.width * snapshot.scaleFactor).rounded())
        let pxH = Int((targetRect.height * snapshot.scaleFactor).rounded())
        let tierHint = autoSnapStack.count > 1
            ? "  ·  \(autoSnapIndex + 1)/\(autoSnapStack.count) 滚轮切换"
            : ""
        drawHUDPill(ctx: ctx, anchorRect: displayRect, text: "\(pxW) × \(pxH)\(tierHint)")
    }

    // MARK: - Hysteresis & Smooth Interpolation

    private func chooseStableIndex(
        in stack: [CGRect],
        at pt: CGPoint,
        previousTarget: CGRect?
    ) -> Int {
        // 1) 若用户刚用滚轮选定过偏好尺度（如切到了『侧边栏』或『整窗』），移动鼠标时优先保持同一量级
        if let prefArea = preferredSnapArea, prefArea > 0 {
            let targetLog = log(Double(prefArea))
            var bestIdx = 0
            var bestDiff = Double.greatestFiniteMagnitude
            for (i, r) in stack.enumerated() {
                let diff = abs(log(Double(max(1, r.width * r.height))) - targetLog)
                if diff < bestDiff {
                    bestDiff = diff
                    bestIdx = i
                }
            }
            return bestIdx
        }

        // 2) 擦边防闪烁：若最小框刚擦到边缘 (< 3.5pt)，暂不切入，优先驻留在上一帧稳定框
        let smallest = stack[0]
        let wellInsideSmallest = smallest.width < 12 || smallest.height < 12
            || smallest.insetBy(dx: 3.5, dy: 3.5).contains(pt)

        if let prev = previousTarget,
           let prevIdxInNew = stack.firstIndex(where: { Self.isSameRegion($0, prev, tol: 8) }) {
            let prevArea = prev.width * prev.height
            let smallestArea = smallest.width * smallest.height
            // 仅当真正深入了一个明显更小的子控件（面积 < 62%）时才向下收缩，杜绝同级包裹层来回跳变
            if prevIdxInNew > 0 {
                if wellInsideSmallest && smallestArea < prevArea * 0.62 {
                    return 0
                }
                return prevIdxInNew
            }
        }

        if !wellInsideSmallest && stack.count > 1 {
            return 1
        }
        return 0
    }

    private func startSnapGlideToTarget() {
        guard let target = hoveredAutoRect else { return }
        if displayedAutoRect == nil {
            displayedAutoRect = target
            needsDisplay = true
            return
        }
        guard snapAnimTimer == nil else { return }

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.selection == nil, let target = self.hoveredAutoRect, var cur = self.displayedAutoRect else {
                    self.stopSnapGlide()
                    return
                }
                let k: CGFloat = 0.42
                cur.origin.x += (target.origin.x - cur.origin.x) * k
                cur.origin.y += (target.origin.y - cur.origin.y) * k
                cur.size.width += (target.size.width - cur.size.width) * k
                cur.size.height += (target.size.height - cur.size.height) * k

                let maxErr = max(
                    max(abs(target.origin.x - cur.origin.x), abs(target.origin.y - cur.origin.y)),
                    max(abs(target.size.width - cur.size.width), abs(target.size.height - cur.size.height))
                )
                if maxErr < 0.6 {
                    self.displayedAutoRect = target
                    self.stopSnapGlide()
                } else {
                    self.displayedAutoRect = cur
                }
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        snapAnimTimer = timer
    }

    private static func isSameRegion(_ a: CGRect, _ b: CGRect, tol: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tol &&
        abs(a.minY - b.minY) <= tol &&
        abs(a.maxX - b.maxX) <= tol &&
        abs(a.maxY - b.maxY) <= tol
    }
}
