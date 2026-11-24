import AppKit
import Foundation
import MSnipCore

/// 紧凑 LaTeX 公式识别接口配置面板（支持一键复用视觉大模型、填写 SimpleTex 免费 Token 或 Mathpix 密钥，外观自动跟随深浅主题）
@MainActor
final class LatexConfigPanelController: NSObject {
    var onSaved: ((LatexRecognitionConfig) -> Void)?
    var onOpenMainAISettings: (() -> Void)?

    private var panel: NSPanel?
    private var draft = LatexRecognitionConfig.load()
    private var visionProfiles: [TranslationProviderProfile] = []

    private var enginePill: LightDropdownPill!
    private var visionProfileLabel: NSTextField!
    private var visionProfilePill: LightDropdownPill!
    private var visionModelLabel: NSTextField!
    private var visionModelField: NSTextField!
    private var tokenLabel: NSTextField!
    private var tokenField: NSTextField!
    private var mathpixKeyLabel: NSTextField!
    private var mathpixKeyField: NSTextField!
    private var hintLabel: NSTextField!
    private var openAIBtn: OCRPillButton!

    func show(relativeTo parentWindow: NSWindow?) {
        draft = LatexRecognitionConfig.load()
        visionProfiles = LatexRecognitionService.availableVisionLLMProfiles()
        ensurePanel()
        refreshFields()
        guard let p = panel else { return }
        ResultWindowChrome.applyAppearance(to: p, dark: ResultWindowChrome.prefersDarkAppearance)
        if let root = p.contentView { ResultWindowChrome.invalidateSubtree(root) }
        if let parent = parentWindow {
            let pf = parent.frame
            p.setFrameOrigin(NSPoint(x: round(pf.midX - p.frame.width * 0.5), y: round(pf.midY - p.frame.height * 0.5)))
        }
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
    }

    func closePanel() {
        panel?.close()
    }

    private func ensurePanel() {
        if panel != nil { return }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 318),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        p.title = "LaTeX 公式识别接口配置"
        p.titlebarAppearsTransparent = true
        p.level = .floating

        let root = FlippedContainer(frame: NSRect(x: 0, y: 0, width: 460, height: 318))
        root.wantsLayer = true
        p.contentView = root

        let head = makeText("选择公式识别引擎", size: 14, weight: .bold, color: ResultTheme.inkPrimary)
        head.frame = NSRect(x: 22, y: 36, width: 220, height: 20)
        root.addSubview(head)

        enginePill = LightDropdownPill(symbol: "function", items: LatexEngineKind.allCases.map(\.displayName))
        enginePill.frame = NSRect(x: 22, y: 66, width: 416, height: 30)
        enginePill.onSelect = { [weak self] idx in
            guard let self, LatexEngineKind.allCases.indices.contains(idx) else { return }
            self.draft.engineKind = LatexEngineKind.allCases[idx]
            self.refreshFields()
        }
        root.addSubview(enginePill)

        visionProfileLabel = makeText("视觉大模型接口", size: 12, weight: .semibold, color: ResultTheme.inkSecondary)
        visionProfileLabel.frame = NSRect(x: 22, y: 108, width: 120, height: 18)
        root.addSubview(visionProfileLabel)

        visionProfilePill = LightDropdownPill(symbol: "cpu")
        visionProfilePill.frame = NSRect(x: 22, y: 128, width: 416, height: 28)
        visionProfilePill.onSelect = { [weak self] idx in
            guard let self, self.visionProfiles.indices.contains(idx) else { return }
            self.draft.visionProfileID = self.visionProfiles[idx].id
        }
        root.addSubview(visionProfilePill)

        visionModelLabel = makeText("视觉模型名（选填，留空则沿用接口默认模型，如 gpt-4o-mini / qwen-vl-plus）", size: 11.5, weight: .medium, color: ResultTheme.inkSecondary)
        visionModelLabel.frame = NSRect(x: 22, y: 164, width: 416, height: 16)
        root.addSubview(visionModelLabel)

        visionModelField = makeInput(placeholder: "例如：gpt-4o-mini / glm-4v-flash / qwen2.5vl")
        visionModelField.frame = NSRect(x: 22, y: 184, width: 416, height: 28)
        root.addSubview(visionModelField)

        tokenLabel = makeText("SimpleTex UAT Token", size: 12, weight: .semibold, color: ResultTheme.inkSecondary)
        tokenLabel.frame = NSRect(x: 22, y: 108, width: 260, height: 18)
        root.addSubview(tokenLabel)

        tokenField = makeInput(placeholder: "粘贴 SimpleTex 个人令牌 (UAT)")
        tokenField.frame = NSRect(x: 22, y: 128, width: 416, height: 28)
        root.addSubview(tokenField)

        mathpixKeyLabel = makeText("Mathpix App Key", size: 12, weight: .semibold, color: ResultTheme.inkSecondary)
        mathpixKeyLabel.frame = NSRect(x: 22, y: 164, width: 200, height: 18)
        root.addSubview(mathpixKeyLabel)

        mathpixKeyField = makeInput(placeholder: "粘贴 Mathpix app_key")
        mathpixKeyField.frame = NSRect(x: 22, y: 184, width: 416, height: 28)
        root.addSubview(mathpixKeyField)

        hintLabel = NSTextField(wrappingLabelWithString: "")
        hintLabel.font = .systemFont(ofSize: 11.5)
        hintLabel.textColor = ResultTheme.inkMuted
        hintLabel.frame = NSRect(x: 22, y: 222, width: 416, height: 34)
        root.addSubview(hintLabel)

        openAIBtn = OCRPillButton(title: "管理 AI 翻译接口…", symbol: "slider.horizontal.3")
        openAIBtn.frame = NSRect(x: 22, y: 268, width: 152, height: 30)
        openAIBtn.onClick = { [weak self] in self?.panel?.close(); self?.onOpenMainAISettings?() }
        root.addSubview(openAIBtn)

        let saveBtn = OCRPillButton(title: "保存并重新识别", symbol: "checkmark", primary: true)
        saveBtn.frame = NSRect(x: 298, y: 268, width: 140, height: 30)
        saveBtn.onClick = { [weak self] in self?.commitAndClose() }
        root.addSubview(saveBtn)

        self.panel = p
    }

    private func refreshFields() {
        enginePill.selectedIndex = LatexEngineKind.allCases.firstIndex(of: draft.engineKind) ?? 0
        let kind = draft.engineKind
        let isVision = (kind == .autoVisionLLM)
        let isSimpleTex = (kind == .simpleTex)
        let isMathpix = (kind == .mathpix)

        visionProfileLabel.isHidden = !isVision
        visionProfilePill.isHidden = !isVision
        visionModelLabel.isHidden = !isVision
        visionModelField.isHidden = !isVision
        openAIBtn.isHidden = !isVision

        tokenLabel.isHidden = !(isSimpleTex || isMathpix)
        tokenField.isHidden = !(isSimpleTex || isMathpix)
        mathpixKeyLabel.isHidden = !isMathpix
        mathpixKeyField.isHidden = !isMathpix

        if isVision {
            visionProfilePill.items = visionProfiles.isEmpty ? ["暂无已配置的 AI 大模型（请先前往设置添加）"] : visionProfiles.map(\.name)
            visionProfilePill.selectedIndex = visionProfiles.firstIndex(where: { $0.id == draft.visionProfileID }) ?? 0
            visionModelField.stringValue = draft.visionModelOverride
            hintLabel.stringValue = "直接复用「设置 → 翻译」里配置好的 OpenAI / Claude / Gemini / 智谱 / 通义 / Ollama 接口识别复杂公式。"
        } else if isSimpleTex {
            tokenLabel.stringValue = "SimpleTex UAT 个人令牌"
            tokenField.placeholderString = "在 simpletex.cn 控制台免费获取 UAT Token"
            tokenField.stringValue = draft.simpleTexToken
            hintLabel.stringValue = "SimpleTex 专攻印刷体与手写数学公式，国内直连极快且每月自带充足免费识别额度。"
        } else if isMathpix {
            tokenLabel.stringValue = "Mathpix App ID"
            tokenField.placeholderString = "粘贴 Mathpix app_id"
            tokenField.stringValue = draft.mathpixAppID
            mathpixKeyField.stringValue = draft.mathpixAppKey
            hintLabel.stringValue = "Mathpix 学术级公式识别接口，支持极复杂多行方程组、矩阵与手写推演。"
        } else {
            hintLabel.stringValue = "完全离线运行（基于 Apple Vision + 数学符号转换），无需联网，适合基础行内公式。"
        }
    }

    private func commitAndClose() {
        switch draft.engineKind {
        case .autoVisionLLM:
            draft.visionModelOverride = visionModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        case .simpleTex:
            draft.simpleTexToken = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        case .mathpix:
            draft.mathpixAppID = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.mathpixAppKey = mathpixKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        case .offlineBasic:
            break
        }
        draft.save()
        panel?.close()
        onSaved?(draft)
    }

    private func makeText(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        ResultWindowChrome.makeLabel(s, size: size, weight: weight, color: color)
    }

    private func makeInput(placeholder: String) -> NSTextField {
        let tf = NSTextField()
        tf.placeholderString = placeholder
        tf.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
        tf.bezelStyle = .roundedBezel
        return tf
    }
}

private final class FlippedContainer: NSView {
    override var isFlipped: Bool { true }
}
