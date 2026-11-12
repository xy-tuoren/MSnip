import AppKit
import CoreGraphics
import Foundation
import MSnipCore

/// 悬浮标注工具栏的底层矢量绘制辅助方法与工具栏动作派发
extension ToolbarView {
    static func drawButtonBg(ctx: CGContext, rect: CGRect, active: Bool, hovered: Bool) {
        guard active || hovered else { return }
        let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        let color = active
            ? NSColor.controlAccentColor.withAlphaComponent(0.85)
            : NSColor.white.withAlphaComponent(0.14)
        ctx.setFillColor(color.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
    }

    static func drawSymbol(_ name: String, in rect: CGRect, alpha: CGFloat, tint: NSColor = .white) {
        guard let baseImg = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .medium)
        let configured = baseImg.withSymbolConfiguration(cfg) ?? baseImg
        guard let cg = configured.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = NSGraphicsContext.current?.cgContext else { return }

        let size = configured.size
        let dst = CGRect(
            x: round(rect.midX - size.width * 0.5),
            y: round(rect.midY - size.height * 0.5),
            width: size.width,
            height: size.height
        )
        ctx.saveGState()
        ctx.translateBy(x: 0, y: dst.minY + dst.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.clip(to: dst, mask: cg)
        ctx.setFillColor(tint.withAlphaComponent(alpha).cgColor)
        ctx.fill(dst)
        ctx.restoreGState()
    }

    static func drawEyedropperItem(
        ctx: CGContext,
        rect: CGRect,
        active: Bool,
        customColor: RGBAColor?,
        hovered: Bool
    ) {
        drawButtonBg(ctx: ctx, rect: rect, active: active, hovered: hovered)
        let tint: NSColor
        if let c = customColor {
            tint = NSColor(srgbRed: CGFloat(c.r) / 255.0, green: CGFloat(c.g) / 255.0, blue: CGFloat(c.b) / 255.0, alpha: 1.0)
        } else {
            tint = .white
        }
        drawSymbol("eyedropper", in: rect, alpha: 0.95, tint: tint)
        if let c = customColor, !active {
            let dot = CGRect(x: rect.maxX - 8, y: rect.maxY - 8, width: 5, height: 5)
            ctx.setFillColor(c.cgColor)
            ctx.fillEllipse(in: dot)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(0.8)
            ctx.strokeEllipse(in: dot)
        }
    }
}

extension OverlayView {
    func handleToolbarAction(_ action: ToolbarView.Action) {
        commitTextEditing()
        switch action {
        case .selectTool(let tool):
            eyedropperActive = false
            activeTool = tool
            if tool != nil { selectedObjectIndex = nil }
        case .selectColor(let idx):
            eyedropperActive = false
            customPickedColor = nil
            colorIndex = idx
            if let selIdx = selectedObjectIndex {
                doc.modifyWithHistory(at: selIdx) { $0.style.color = style.color }
            }
            onStyleChanged?(colorIndex, style.lineWidth)
            needsDisplay = true
        case .toggleEyedropper:
            eyedropperActive.toggle()
        case .selectStroke(let w):
            style.lineWidth = w
            style.fontSize = max(14, w * 4.5)
            toolbar.lineWidth = w
            if let selIdx = selectedObjectIndex {
                doc.modifyWithHistory(at: selIdx) {
                    $0.style.lineWidth = w
                    $0.style.fontSize = max(14, w * 4.5)
                }
            }
            onStyleChanged?(colorIndex, style.lineWidth)
            needsDisplay = true
        case .undo:
            selectedObjectIndex = nil
            if doc.undo() { updateToolbarLayout(); needsDisplay = true }
        case .redo:
            selectedObjectIndex = nil
            if doc.redo() { updateToolbarLayout(); needsDisplay = true }
        case .cycleCornerRadius:
            cycleCornerRadius()
        case .extractText:
            exportAndFinish(mode: .extractText)
        case .pin:
            exportAndFinish(mode: .pin)
        case .save:
            exportAndFinish(mode: .save)
        case .cancel:
            onCancel?()
        case .confirmCopy:
            exportAndFinish(mode: .copy)
        }
    }

    func cycleCornerRadius() {
        if selection == nil, let snap = hoveredAutoRect {
            selection = snap
        }
        if cornerRadiusPt < 1 {
            cornerRadiusPt = 10
        } else if cornerRadiusPt < 14 {
            cornerRadiusPt = 18
        } else {
            cornerRadiusPt = 0
        }
    }
}
