import AppKit
import CoreGraphics
import Foundation

/// 选区录屏交互回显合成器（零外部依赖）：
/// 在导出 GIF / MP4 的帧上实时叠加「鼠标点击扩散波纹」与「修饰快捷键胶囊角标」，
/// 无交互发生时走 O(1) 零拷贝直通，不额外分配任何位图缓冲。
public final class RecordingOverlayCompositor: @unchecked Sendable {
    public struct ClickRipple: Sendable {
        public let normalizedX: CGFloat // 0...1 相对选区宽度
        public let normalizedY: CGFloat // 0...1 相对选区顶部高度
        public let isRightClick: Bool
        public let timestamp: TimeInterval

        public init(normalizedX: CGFloat, normalizedY: CGFloat, isRightClick: Bool, timestamp: TimeInterval) {
            self.normalizedX = normalizedX
            self.normalizedY = normalizedY
            self.isRightClick = isRightClick
            self.timestamp = timestamp
        }
    }

    public struct KeyBadge: Sendable {
        public let label: String
        public let timestamp: TimeInterval

        public init(label: String, timestamp: TimeInterval) {
            self.label = label
            self.timestamp = timestamp
        }
    }

    public static let rippleDuration: TimeInterval = 0.46
    public static let keyBadgeDuration: TimeInterval = 1.15
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private let lock = NSLock()
    private var _isEnabled: Bool
    private var ripples: [ClickRipple] = []
    private var latestKeyBadge: KeyBadge?

    public init(isEnabled: Bool = true) {
        self._isEnabled = isEnabled
    }

    public var isEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isEnabled }
        set {
            lock.lock()
            _isEnabled = newValue
            if !newValue {
                ripples.removeAll()
                latestKeyBadge = nil
            }
            lock.unlock()
        }
    }

    public func recordClick(normalizedX: CGFloat, normalizedY: CGFloat, isRightClick: Bool, at timestamp: TimeInterval) {
        guard (0.0...1.0).contains(normalizedX), (0.0...1.0).contains(normalizedY) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard _isEnabled else { return }
        ripples.removeAll { timestamp - $0.timestamp > Self.rippleDuration }
        if ripples.count >= 12 { ripples.removeFirst() }
        ripples.append(ClickRipple(
            normalizedX: normalizedX,
            normalizedY: normalizedY,
            isRightClick: isRightClick,
            timestamp: timestamp
        ))
    }

    public func recordKeyBadge(_ label: String, at timestamp: TimeInterval) {
        guard !label.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard _isEnabled else { return }
        latestKeyBadge = KeyBadge(label: label, timestamp: timestamp)
    }

    /// 将当前活跃的点击波纹与快捷键胶囊合成至帧图像（若无活跃事件则直接返回原图零开销）
    public func compositeIfNeeded(onto frame: CGImage, at timestamp: TimeInterval) -> CGImage {
        let snapshot: (ripples: [ClickRipple], badge: KeyBadge?) = {
            lock.lock()
            defer { lock.unlock() }
            guard _isEnabled else { return ([], nil) }
            ripples.removeAll { timestamp - $0.timestamp > Self.rippleDuration || timestamp < $0.timestamp }
            let validBadge: KeyBadge?
            if let b = latestKeyBadge, timestamp >= b.timestamp, (timestamp - b.timestamp) <= Self.keyBadgeDuration {
                validBadge = b
            } else {
                validBadge = nil
            }
            return (ripples, validBadge)
        }()

        if snapshot.ripples.isEmpty && snapshot.badge == nil {
            return frame
        }

        let w = frame.width
        let h = frame.height
        guard w >= 16, h >= 16,
              let ctx = CGContext(
                  data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: Self.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return frame }

        ctx.interpolationQuality = .none
        ctx.draw(frame, in: CGRect(x: 0, y: 0, width: w, height: h))

        // 切换至左上角原点像素坐标系绘制叠加层
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let uiScale = max(1.0, min(2.4, CGFloat(min(w, h)) / 360.0))

        // 1) 渲染扩散鼠标点击波纹（左键亮青/珊瑚红双环，右键琥珀橙环）
        for r in snapshot.ripples {
            let progress = CGFloat(min(1.0, max(0.0, (timestamp - r.timestamp) / Self.rippleDuration)))
            let eased = 1.0 - pow(1.0 - progress, 2.4)
            let alpha = (1.0 - progress) * 0.88
            let cx = r.normalizedX * CGFloat(w)
            let cy = r.normalizedY * CGFloat(h)
            let radius = (8.0 + eased * 24.0) * uiScale

            ctx.saveGState()
            let stroke = r.isRightClick
                ? CGColor(srgbRed: 1.0, green: 0.62, blue: 0.08, alpha: alpha)
                : CGColor(srgbRed: 0.06, green: 0.78, blue: 1.0, alpha: alpha)
            let fill = r.isRightClick
                ? CGColor(srgbRed: 1.0, green: 0.62, blue: 0.08, alpha: alpha * 0.22)
                : CGColor(srgbRed: 0.06, green: 0.78, blue: 1.0, alpha: alpha * 0.22)
            let box = CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)
            ctx.setFillColor(fill)
            ctx.fillEllipse(in: box)
            ctx.setStrokeColor(stroke)
            ctx.setLineWidth(max(2.0, 2.6 * uiScale))
            ctx.strokeEllipse(in: box)
            ctx.restoreGState()
        }

        // 2) 渲染底部居中的修饰快捷键回显胶囊（如 `⌘C` / `⇧⌘P`）
        if let badge = snapshot.badge {
            let age = timestamp - badge.timestamp
            let fadeStart = Self.keyBadgeDuration - 0.26
            let alpha: CGFloat = age > fadeStart
                ? CGFloat(max(0.0, (Self.keyBadgeDuration - age) / 0.26))
                : 1.0
            drawKeyBadge(badge.label, alpha: alpha, width: CGFloat(w), height: CGFloat(h), scale: uiScale, in: ctx)
        }

        return ctx.makeImage() ?? frame
    }

    private func drawKeyBadge(_ text: String, alpha: CGFloat, width: CGFloat, height: CGFloat, scale: CGFloat, in ctx: CGContext) {
        let fontPt = round(15.0 * scale)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontPt, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha)
        ]
        let ns = text as NSString
        let sz = ns.size(withAttributes: attrs)
        let padX = 12.0 * scale
        let padY = 6.0 * scale
        let bw = ceil(sz.width + padX * 2)
        let bh = ceil(sz.height + padY * 2)
        let bx = (width - bw) * 0.5
        let by = max(8.0, height - bh - 14.0 * scale)
        let rect = CGRect(x: bx, y: by, width: bw, height: bh)
        let path = CGPath(roundedRect: rect, cornerWidth: 8.0 * scale, cornerHeight: 8.0 * scale, transform: nil)

        ctx.saveGState()
        ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 0.86 * alpha))
        ctx.addPath(path)
        ctx.fillPath()
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.24 * alpha))
        ctx.setLineWidth(max(1.0, 1.0 * scale))
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()

        let prev = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.current = prev }
        ns.draw(at: CGPoint(x: bx + (bw - sz.width) * 0.5, y: by + (bh - sz.height) * 0.5), withAttributes: attrs)
    }
}
