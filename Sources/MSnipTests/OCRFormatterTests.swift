import CoreGraphics
import Foundation
import MSnipCore

func testOCRTextFormatterModes() {
    // 1. 测试中文折行自动无空格合并，以及分段保留
    let items: [OCRLineObservation] = [
        // 第一段第 1 行（铺满右侧 0.92）
        OCRLineObservation(box: CGRect(x: 0.08, y: 0.80, width: 0.84, height: 0.06), text: "MSnip 是一款纯原生超轻量级"),
        // 第一段第 2 行（短尾句 + 句号结尾）
        OCRLineObservation(box: CGRect(x: 0.08, y: 0.72, width: 0.42, height: 0.06), text: "截图与贴图工具。"),
        // 第二段英文连字符跨行 + 正常词跨行（与上段有明显垂直间距）
        OCRLineObservation(box: CGRect(x: 0.08, y: 0.54, width: 0.83, height: 0.06), text: "Pure native frame-"),
        OCRLineObservation(box: CGRect(x: 0.08, y: 0.46, width: 0.82, height: 0.06), text: "work with zero external"),
        OCRLineObservation(box: CGRect(x: 0.08, y: 0.38, width: 0.38, height: 0.06), text: "dependencies."),
        // 列表项保持独立行段
        OCRLineObservation(box: CGRect(x: 0.08, y: 0.28, width: 0.50, height: 0.06), text: "• 支持左图实况划词"),
        OCRLineObservation(box: CGRect(x: 0.08, y: 0.20, width: 0.52, height: 0.06), text: "• 支持桌面贴图直接取字")
    ]

    let preserved = OCRTextFormatter.format(items, mode: .preserveLines)
    let preservedLines = preserved.components(separatedBy: "\n")
    check(preservedLines.count == 7, "保持换行模式应完整保留 7 行视觉行，实际: \(preservedLines.count)")

    let merged = OCRTextFormatter.format(items, mode: .mergeParagraphs)
    check(
        merged.contains("MSnip 是一款纯原生超轻量级截图与贴图工具。"),
        "中文跨行合并应无多余空格: got \(merged)"
    )
    check(
        merged.contains("Pure native framework with zero external dependencies."),
        "英文跨行应自动消去连字符并在普通单词间补空格: got \(merged)"
    )
    check(
        merged.contains("\n\n• 支持左图实况划词\n\n• 支持桌面贴图直接取字"),
        "列表项应保持独立分段不被吞并: got \(merged)"
    )

    // 2. 测试同行左右分栏按 X 排序与制表间隔拼接
    let rowSegments: [OCRLineObservation] = [
        OCRLineObservation(box: CGRect(x: 0.62, y: 0.50, width: 0.25, height: 0.05), text: "⌘3 识字"),
        OCRLineObservation(box: CGRect(x: 0.10, y: 0.51, width: 0.25, height: 0.05), text: "⌘1 截图")
    ]
    let rowOut = OCRTextFormatter.format(rowSegments, mode: .preserveLines)
    check(rowOut == "⌘1 截图    ⌘3 识字", "同行多列应按从左到右排序并保留列间距，实际: \(rowOut)")

    // 3. 测试 VisionKit transcript 纯文本跨行合段与连字符消去
    let rawTranscript = """
    第一行铺满整段宽度的中文内容测试文本在这里继续延伸
    接着第二行句尾结束。
    - 列表项一独立保留
    Build ultra-lightweight na-
    tive macOS apps.
    """
    let mergedTrans = OCRTextFormatter.mergeTranscriptLines(rawTranscript)
    check(
        mergedTrans.contains("延伸接着第二行句尾结束。"),
        "transcript 中文折行合段不应插入空格: got \(mergedTrans)"
    )
    check(
        mergedTrans.contains("native macOS apps."),
        "transcript 英文跨行连字符应自动消去: got \(mergedTrans)"
    )

    // 4. 测试 OCR 三模式（原位划词 / 双栏面板 / 静默直拷）在工具栏与快捷键下的统一路由矩阵
    check(OCRDefaultPresentation.inPlace.resolvedTrigger(inPlaceActive: false, optionHeld: false) == .toggleInPlace,
          "原位划词默认触发应进入页内划词")
    check(OCRDefaultPresentation.inPlace.resolvedTrigger(inPlaceActive: false, optionHeld: true) == .openDualPane,
          "原位划词按住 ⌥ 应临时打开双栏面板")
    check(OCRDefaultPresentation.dualPane.resolvedTrigger(inPlaceActive: false, optionHeld: false) == .openDualPane,
          "双栏面板默认触发应打开双栏对照窗")
    check(OCRDefaultPresentation.dualPane.resolvedTrigger(inPlaceActive: false, optionHeld: true) == .toggleInPlace,
          "双栏面板按住 ⌥ 应临时进入页内划词")
    check(OCRDefaultPresentation.dualPane.resolvedTrigger(inPlaceActive: true, optionHeld: false) == .toggleInPlace,
          "已处于原位划词态时再次普通触发应退出原位态而非直接跳双栏")
    check(OCRDefaultPresentation.silentCopy.resolvedTrigger(inPlaceActive: false, optionHeld: false) == .silentCopyAndClose,
          "静默直拷默认触发应直接关闭截图窗口并后台静默识别复制")
    check(OCRDefaultPresentation.silentCopy.resolvedTrigger(inPlaceActive: false, optionHeld: true) == .openDualPane,
          "静默直拷按住 ⌥ 应临时打开双栏面板")
    check(OCRDefaultPresentation.silentCopy.resolvedTrigger(inPlaceActive: true, optionHeld: true) == .openDualPane,
          "原位划词激活态按住 ⌥ 应切换至双栏对照窗")

    // 5. 测试统一 OCR 识字配置持久化与多模态大模型解析优先级（指定接口 → 当前活跃大模型 → 首个已就绪大模型）
    let tmpOCR = FileManager.default.temporaryDirectory.appendingPathComponent("msnip_ocr_cfg_\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmpOCR) }
    var appleProf = TranslationProviderProfile.makePreset(.appleNative)
    var llm1 = TranslationProviderProfile(name: "Relay1", kind: .openAIResponses, isEnabled: true, endpoint: "https://relay.example.com", apiKey: "sk-1", model: "gpt-5-mini")
    var llm2 = TranslationProviderProfile(name: "Relay2", kind: .anthropicCompatible, isEnabled: true, endpoint: "https://claude.example.com", apiKey: "sk-2", model: "claude-sonnet-4")
    appleProf.isEnabled = true; llm1.isEnabled = true; llm2.isEnabled = true
    let cfgToSave = OCRRecognitionConfig(engineKind: .visionLLM, visionProfileID: llm2.id, visionModelOverride: "qwen-vl-plus")
    cfgToSave.save(to: tmpOCR)
    let reloadedOCR = OCRRecognitionConfig.load(from: tmpOCR)
    check(reloadedOCR == cfgToSave, "OCRRecognitionConfig 应完整支持本地 JSON 持久化与回读")
    check(
        OCRRecognitionConfig.resolveVisionProfile(preferredID: llm2.id, activeID: llm1.id, profiles: [appleProf, llm1, llm2])?.id == llm2.id
            && OCRRecognitionConfig.resolveVisionProfile(preferredID: nil, activeID: llm1.id, profiles: [appleProf, llm1, llm2])?.id == llm1.id
            && OCRRecognitionConfig.resolveVisionProfile(preferredID: nil, activeID: appleProf.id, profiles: [appleProf, llm1, llm2])?.id == llm1.id,
        "多模态视觉接口解析应按「指定接口 → 当前活跃大模型 → 首个已就绪大模型」降级并自动跳过 Apple 离线翻译"
    )
    check(OCREngineKind.allCases.count == 6 && OCREngineKind.allCases.contains(.baiduOCR) && OCREngineKind.allCases.contains(.customHTTP),
          "OCR 引擎列表应完整涵盖离线/视觉大模型/百度/腾讯/有道/自定义 HTTP 6 大选项")
    let umiJSON = Data("{\"code\":100,\"data\":[{\"text\":\"第一行\"},{\"text\":\"第二行\"}]}".utf8)
    let baiduLikeJSON = Data("{\"words_result\":[{\"words\":\"Hello\"},{\"words\":\"MSnip\"}]}".utf8)
    check(
        OCRRecognitionConfig.extractCustomOCRText(from: umiJSON, path: "data.*.text") == "第一行\n第二行"
            && OCRRecognitionConfig.extractCustomOCRText(from: baiduLikeJSON, path: "words_result.*.words") == "Hello\nMSnip",
        "通用自定义 HTTP OCR 路径提取器应支持 * 数组通配符并按行拼接"
    )
}
