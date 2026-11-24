import AppKit
import CoreGraphics
import Foundation
import MSnipCore
import QuartzCore

/// 覆盖层的 PixPin 级零延迟矩阵吸附、最新优先后台合并探测与干脆 VSync 过渡扩展
extension OverlayView {
    func refreshAutoSnapAtCurrentMouse() {
        guard let win = window else { return }
        let winPt = win.convertPoint(fromScreen: NSEvent.mouseLocation)
        let localPt = convert(winPt, from: nil)
        if bounds.contains(localPt) {
            updateAutoSnap(at: localPt, immediate: true)
        }
    }

    /// 0ms 瞬时响应光标移动：
    /// 1. 先查 0.005ms 内存快表（程序坞/菜单栏/已缓存控件/窗口边界）立即出框，绝不因防抖而冻住；
    /// 2. 未命中的新位置立即推入 0ms 最新优先后台队列（Latest-Wins），拿到真实 AX/视觉框后干脆落位。
    func updateAutoSnap(at localPoint: CGPoint, previousPoint: CGPoint? = nil, immediate: Bool = false, fastWindowOnly: Bool? = nil) {
        guard selection == nil else { return }

        // 光标离开滚轮切层锚点 > 14pt 时自动重置回最内层目标，做到指哪吸哪、绝不粘滞
        if let anchor = autoSnap.tierAnchorPoint, hypot(localPoint.x - anchor.x, localPoint.y - anchor.y) > 14.0 {
            autoSnap.tierAnchorPoint = nil
            autoSnap.manualTierOffset = 0
        }

        let fast = regionDetector.fastMemoryHierarchy(at: localPoint, in: snapshot)
        let crossedWindow: Bool = {
            switch (autoSnap.activeWindowRect, fast.winRect) {
            case (nil, nil): return false
            case (let a?, let b?): return !Self.isSameRegion(a, b, tol: 8)
            default: return true
            }
        }()

        // 命中预索引系统栏（Dock/菜单栏）、命中空间缓存细粒度控件、首次上屏或跨入新窗口 -> 0ms 立即更新！
        let hasFineCacheHit = fast.stack.count > 2
        if fast.isComplete || hasFineCacheHit || fastWindowOnly == true || autoSnap.displayedRect == nil || crossedWindow {
            autoSnap.activeWindowRect = fast.winRect
            applyDetectedSnapStack(fast.stack, immediate: immediate || autoSnap.displayedRect == nil)
        }
        if fast.isComplete || fastWindowOnly == true { return }

        autoSnap.querySeq &+= 1
        let seq = autoSnap.querySeq
        let token = autoSnap.cancelToken
        regionDetector.requestLatestHierarchy(at: localPoint, in: snapshot) { [weak self] refined, winRect in
            guard let self, self.selection == nil,
                  self.autoSnap.cancelToken == token,
                  seq > self.autoSnap.appliedSeq else { return }
            self.autoSnap.appliedSeq = seq
            self.autoSnap.activeWindowRect = winRect
            self.applyDetectedSnapStack(refined, immediate: immediate && self.autoSnap.displayedRect == nil)
        }
    }

    private func applyDetectedSnapStack(_ newStack: [CGRect], immediate: Bool) {
        guard !newStack.isEmpty else { return }
        let prevTarget = hoveredAutoRect
        let chosenIndex = min(max(0, autoSnap.manualTierOffset), newStack.count - 1)
        autoSnap.stack = newStack
        autoSnap.index = chosenIndex
        autoSnap.scrollAccumulator = 0

        guard let target = hoveredAutoRect else { return }
        if immediate || autoSnap.displayedRect == nil {
            let prevDisplayed = autoSnap.displayedRect
            stopSnapGlide(cancelPendingQuery: false)
            autoSnap.displayedRect = target
            invalidateAutoSnapTransition(from: prevDisplayed, to: target)
        } else if prevTarget != target {
            startSnapGlideToTarget()
        } else {
            invalidateAutoSnapTransition(from: autoSnap.displayedRect, to: target)
        }
    }

    func stepAutoSnapTier(by step: Int) {
        guard autoSnap.stack.count > 1 else { return }
        let nextIdx = min(max(0, autoSnap.index + step), autoSnap.stack.count - 1)
        guard nextIdx != autoSnap.index else { return }
        autoSnap.index = nextIdx
        autoSnap.manualTierOffset = nextIdx
        autoSnap.tierAnchorPoint = lastMousePoint
        if let target = hoveredAutoRect {
            startSnapGlideToTarget()
            invalidateAutoSnapTransition(from: autoSnap.displayedRect, to: target)
        }
    }

    func stopSnapGlide(cancelPendingQuery: Bool = true) {
        if cancelPendingQuery {
            autoSnap.cancelToken &+= 1
        }
        autoSnap.animTimer?.invalidate()
        autoSnap.animTimer = nil
        if #available(macOS 14.0, *), let dl = autoSnap.displayLink as? CADisplayLink {
            dl.invalidate()
        }
        autoSnap.displayLink = nil
    }

    func drawAutoSnapChrome(ctx: CGContext, displayRect: CGRect, targetRect: CGRect) {
        ctx.saveGState()
        let borderCol = isRecordingMode ? MSnipUITheme.danger : MSnipUITheme.accent
        ctx.setStrokeColor(borderCol.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(2.0)
        ctx.stroke(displayRect.insetBy(dx: 0.5, dy: 0.5))
        ctx.restoreGState()

        let pxW = Int((targetRect.width * snapshot.scaleFactor).rounded())
        let pxH = Int((targetRect.height * snapshot.scaleFactor).rounded())
        let prefix = isRecordingMode ? "录屏 · " : quickLaunchMode.hudPrefix
        let tierInfo: String
        if autoSnap.stack.count > 1 {
            let kind = semanticTierLabel(for: targetRect)
            tierInfo = "  ·  \(kind) \(autoSnap.index + 1)/\(autoSnap.stack.count) 滚轮切层"
        } else {
            let pxX = Int((targetRect.minX * snapshot.scaleFactor).rounded())
            let pxY = Int((targetRect.minY * snapshot.scaleFactor).rounded())
            tierInfo = "  (\(pxX),\(pxY))"
        }
        drawHUDPill(ctx: ctx, anchorRect: displayRect, text: "\(prefix)\(pxW) × \(pxH) px\(tierInfo)")
    }

    private func semanticTierLabel(for rect: CGRect) -> String {
        if Self.isSameRegion(rect, bounds, tol: 4) { return "全屏" }
        if let winRect = autoSnap.activeWindowRect, Self.isSameRegion(rect, winRect, tol: 6) { return "窗口" }
        return "区域"
    }

    private func startSnapGlideToTarget() {
        guard let target = hoveredAutoRect else { return }
        if autoSnap.displayedRect == nil {
            autoSnap.displayedRect = target
            invalidateAutoSnapTransition(from: nil, to: target)
            return
        }
        if autoSnap.displayLink != nil || autoSnap.animTimer != nil { return }

        if #available(macOS 14.0, *) {
            let link = self.displayLink(target: self, selector: #selector(onSnapDisplayLinkTick(_:)))
            link.add(to: .main, forMode: .common)
            autoSnap.displayLink = link
            return
        }

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceSnapGlide(dt: 1.0 / 60.0) }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoSnap.animTimer = timer
    }

    @available(macOS 14.0, *)
    @objc private func onSnapDisplayLinkTick(_ link: CADisplayLink) {
        let dt = min(0.05, max(0.004, link.duration))
        advanceSnapGlide(dt: dt)
    }

    private func advanceSnapGlide(dt: TimeInterval) {
        guard selection == nil, let target = hoveredAutoRect, var cur = autoSnap.displayedRect else {
            stopSnapGlide(cancelPendingQuery: false)
            return
        }
        let prevDisplayed = cur
        // 干脆利落的 35ms 高速阻尼（对标 PixPin 即指即吸手感，不拖泥带水）
        let k = CGFloat(1.0 - pow(1e-12, dt))
        cur.origin.x += (target.origin.x - cur.origin.x) * k
        cur.origin.y += (target.origin.y - cur.origin.y) * k
        cur.size.width += (target.size.width - cur.size.width) * k
        cur.size.height += (target.size.height - cur.size.height) * k

        let maxErr = max(
            max(abs(target.origin.x - cur.origin.x), abs(target.origin.y - cur.origin.y)),
            max(abs(target.size.width - cur.size.width), abs(target.size.height - cur.size.height))
        )
        if maxErr < 1.0 {
            autoSnap.displayedRect = target
            stopSnapGlide(cancelPendingQuery: false)
        } else {
            autoSnap.displayedRect = cur
        }
        invalidateAutoSnapTransition(from: prevDisplayed, to: autoSnap.displayedRect)
    }

    private static func isSameRegion(_ a: CGRect, _ b: CGRect, tol: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tol &&
        abs(a.minY - b.minY) <= tol &&
        abs(a.maxX - b.maxX) <= tol &&
        abs(a.maxY - b.maxY) <= tol
    }
}
