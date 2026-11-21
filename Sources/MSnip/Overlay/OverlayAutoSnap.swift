import AppKit
import CoreGraphics
import Foundation
import MSnipCore
import QuartzCore

/// 覆盖层的智能矩阵防抖驻留、高速扫鼠防 IPC 阻塞与硬件 VSync (`CADisplayLink`) 60/120Hz 丝滑过渡扩展
extension OverlayView {
    func refreshAutoSnapAtCurrentMouse() {
        guard let win = window else { return }
        let winPt = win.convertPoint(fromScreen: NSEvent.mouseLocation)
        let localPt = convert(winPt, from: nil)
        if bounds.contains(localPt) {
            updateAutoSnap(at: localPt, immediate: true)
        }
    }

    /// 刷新局部坐标处的自动识别矩阵栈（高速移动时先瞬时对齐窗口，停顿 22ms 后无感补齐子控件）
    func updateAutoSnap(at localPoint: CGPoint, previousPoint: CGPoint? = nil, immediate: Bool = false) {
        guard selection == nil else { return }
        deferredSnapWork?.cancel()

        let stepDist = previousPoint.map { hypot(localPoint.x - $0.x, localPoint.y - $0.y) } ?? 0
        let fastSweep = !immediate && stepDist > 18.0

        let newStack = regionDetector.detectHierarchy(at: localPoint, in: snapshot, fastWindowOnly: fastSweep)
        applyDetectedSnapStack(newStack, at: localPoint, immediate: immediate)

        if fastSweep {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.selection == nil, let curPt = self.lastMousePoint else { return }
                    let refined = self.regionDetector.detectHierarchy(at: curPt, in: self.snapshot, fastWindowOnly: false)
                    self.applyDetectedSnapStack(refined, at: curPt, immediate: false)
                }
            }
            deferredSnapWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.022, execute: work)
        }
    }

    private func applyDetectedSnapStack(_ newStack: [CGRect], at localPoint: CGPoint, immediate: Bool) {
        guard !newStack.isEmpty else { return }
        let prevTarget = hoveredAutoRect
        if newStack.count <= 1 {
            preferredSnapArea = nil
        } else if let prevWin = autoSnapStack.dropLast().last,
                  let curWin = newStack.dropLast().last,
                  !Self.isSameRegion(prevWin, curWin, tol: 8) {
            preferredSnapArea = nil
        }

        let chosenIndex = chooseStableIndex(in: newStack, at: localPoint, previousTarget: prevTarget)
        autoSnapStack = newStack
        autoSnapIndex = chosenIndex
        scrollSnapAccumulator = 0

        guard let target = hoveredAutoRect else { return }
        if immediate || displayedAutoRect == nil {
            let prevDisplayed = displayedAutoRect
            stopSnapGlide()
            displayedAutoRect = target
            invalidateAutoSnapTransition(from: prevDisplayed, to: target)
        } else if prevTarget != target {
            startSnapGlideToTarget()
        }
    }

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
        deferredSnapWork?.cancel()
        deferredSnapWork = nil
        snapAnimTimer?.invalidate()
        snapAnimTimer = nil
        if #available(macOS 14.0, *), let dl = snapDisplayLink as? CADisplayLink {
            dl.invalidate()
        }
        snapDisplayLink = nil
    }

    func drawAutoSnapChrome(ctx: CGContext, displayRect: CGRect, targetRect: CGRect) {
        ctx.saveGState()
        let borderCol = isRecordingMode ? MSnipUITheme.danger : MSnipUITheme.accent
        ctx.setStrokeColor(borderCol.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(2.0)
        ctx.stroke(displayRect.insetBy(dx: 0.5, dy: 0.5))
        ctx.restoreGState()

        let pxX = Int((targetRect.minX * snapshot.scaleFactor).rounded())
        let pxY = Int((targetRect.minY * snapshot.scaleFactor).rounded())
        let pxW = Int((targetRect.width * snapshot.scaleFactor).rounded())
        let pxH = Int((targetRect.height * snapshot.scaleFactor).rounded())
        let prefix = isRecordingMode ? "录屏 · " : (quickTranslateMode ? "翻译 · " : (quickOCRMode ? "识字 · " : ""))
        drawHUDPill(ctx: ctx, anchorRect: displayRect, text: "\(prefix)\(pxX),\(pxY)  \(pxW) × \(pxH) px")
    }

    private func chooseStableIndex(in stack: [CGRect], at pt: CGPoint, previousTarget: CGRect?) -> Int {
        if let prefArea = preferredSnapArea, prefArea > 0 {
            let targetLog = log(Double(prefArea))
            var bestIdx = 0
            var bestDiff = Double.greatestFiniteMagnitude
            for (i, r) in stack.enumerated() {
                let diff = abs(log(Double(max(1, r.width * r.height))) - targetLog)
                if diff < bestDiff { bestDiff = diff; bestIdx = i }
            }
            return bestIdx
        }

        let smallest = stack[0]
        let wellInsideSmallest = smallest.width < 12 || smallest.height < 12
            || smallest.insetBy(dx: 3.5, dy: 3.5).contains(pt)

        if let prev = previousTarget,
           let prevIdxInNew = stack.firstIndex(where: { Self.isSameRegion($0, prev, tol: 8) }) {
            let prevArea = prev.width * prev.height
            let smallestArea = smallest.width * smallest.height
            if prevIdxInNew > 0 {
                if wellInsideSmallest && smallestArea < prevArea * 0.62 { return 0 }
                return prevIdxInNew
            }
        }
        return (!wellInsideSmallest && stack.count > 1) ? 1 : 0
    }

    private func startSnapGlideToTarget() {
        guard let target = hoveredAutoRect else { return }
        if displayedAutoRect == nil {
            displayedAutoRect = target
            invalidateAutoSnapTransition(from: nil, to: target)
            return
        }
        if snapDisplayLink != nil || snapAnimTimer != nil { return }

        if #available(macOS 14.0, *) {
            let link = self.displayLink(target: self, selector: #selector(onSnapDisplayLinkTick(_:)))
            link.add(to: .main, forMode: .common)
            snapDisplayLink = link
            return
        }

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceSnapGlide(dt: 1.0 / 60.0) }
        }
        RunLoop.main.add(timer, forMode: .common)
        snapAnimTimer = timer
    }

    @available(macOS 14.0, *)
    @objc private func onSnapDisplayLinkTick(_ link: CADisplayLink) {
        let dt = min(0.05, max(0.004, link.duration))
        advanceSnapGlide(dt: dt)
    }

    private func advanceSnapGlide(dt: TimeInterval) {
        guard selection == nil, let target = hoveredAutoRect, var cur = displayedAutoRect else {
            stopSnapGlide()
            return
        }
        let prevDisplayed = cur
        // 帧率无关指数阻尼，60Hz 与 120Hz ProMotion 下手感完全一致且紧贴垂直同步
        let k = CGFloat(1.0 - pow(0.00004, dt))
        cur.origin.x += (target.origin.x - cur.origin.x) * k
        cur.origin.y += (target.origin.y - cur.origin.y) * k
        cur.size.width += (target.size.width - cur.size.width) * k
        cur.size.height += (target.size.height - cur.size.height) * k

        let maxErr = max(
            max(abs(target.origin.x - cur.origin.x), abs(target.origin.y - cur.origin.y)),
            max(abs(target.size.width - cur.size.width), abs(target.size.height - cur.size.height))
        )
        if maxErr < 0.6 {
            displayedAutoRect = target
            stopSnapGlide()
        } else {
            displayedAutoRect = cur
        }
        invalidateAutoSnapTransition(from: prevDisplayed, to: displayedAutoRect)
    }

    private static func isSameRegion(_ a: CGRect, _ b: CGRect, tol: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tol &&
        abs(a.minY - b.minY) <= tol &&
        abs(a.maxX - b.maxX) <= tol &&
        abs(a.maxY - b.maxY) <= tol
    }
}
