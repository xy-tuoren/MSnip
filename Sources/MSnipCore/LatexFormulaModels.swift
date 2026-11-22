import Foundation

/// LaTeX 数学公式一键复制包裹格式
public enum LatexWrapFormat: String, CaseIterable, Codable, Sendable {
    case raw = "raw"
    case inlineDollar = "inline_dollar"
    case blockDollar = "block_dollar"
    case displayBrackets = "display_brackets"

    public var shortTitle: String {
        switch self {
        case .raw:             return "纯 LaTeX"
        case .inlineDollar:    return "$ 行内 $"
        case .blockDollar:     return "$$ 行间 $$"
        case .displayBrackets: return "\\[ 块级 \\]"
        }
    }

    public func wrap(_ latex: String) -> String {
        let clean = LatexPostProcessor.stripFencesAndDelimiters(latex)
        guard !clean.isEmpty else { return "" }
        switch self {
        case .raw:
            return clean
        case .inlineDollar:
            return "$\(clean)$"
        case .blockDollar:
            return "$$\n\(clean)\n$$"
        case .displayBrackets:
            return "\\[\n\(clean)\n\\]"
        }
    }
}

/// LaTeX 公式识别引擎类型
public enum LatexEngineKind: String, CaseIterable, Codable, Sendable {
    case autoVisionLLM = "vision_llm"
    case simpleTex = "simpletex"
    case mathpix = "mathpix"
    case offlineBasic = "offline_basic"

    public var displayName: String {
        switch self {
        case .autoVisionLLM: return "视觉大模型（复用已配 AI 接口）"
        case .simpleTex:     return "SimpleTex 专用公式识别"
        case .mathpix:       return "Mathpix 学术公式识别"
        case .offlineBasic:  return "离线基础转换（Apple Vision）"
        }
    }

    public var shortName: String {
        switch self {
        case .autoVisionLLM: return "视觉大模型"
        case .simpleTex:     return "SimpleTex"
        case .mathpix:       return "Mathpix"
        case .offlineBasic:  return "离线基础"
        }
    }
}

/// LaTeX 公式识别偏好配置（轻量 JSON 持久化在 `Application Support/MSnip/latex.json`）
public struct LatexRecognitionConfig: Codable, Equatable, Sendable {
    public var engineKind: LatexEngineKind = .autoVisionLLM
    public var preferredWrap: LatexWrapFormat = .blockDollar
    public var autoCopy: Bool = true
    public var visionProfileID: UUID? = nil
    public var visionModelOverride: String = ""
    public var simpleTexToken: String = ""
    public var mathpixAppID: String = ""
    public var mathpixAppKey: String = ""

    public init() {}

    private static var configURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("MSnip", isDirectory: true).appendingPathComponent("latex.json")
    }

    public static func load() -> LatexRecognitionConfig {
        guard let data = try? Data(contentsOf: configURL),
              let cfg = try? JSONDecoder().decode(LatexRecognitionConfig.self, from: data) else {
            return LatexRecognitionConfig()
        }
        return cfg
    }

    public func save() {
        let url = Self.configURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// LaTeX 输出后处理器（清洗 Markdown 围栏/冗余定界符 + 离线 Unicode 数学符号转 LaTeX 兜底）
public enum LatexPostProcessor {
    /// 剥离模型可能附带的 ```latex 围栏与外层 $$ / $ / \[ \] / \( \) 定界符，防止二次包裹出错
    public static func stripFencesAndDelimiters(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let nl = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: nl)...])
            } else {
                s = s.replacingOccurrences(of: "```latex", with: "").replacingOccurrences(of: "```", with: "")
            }
            if let endFence = s.range(of: "```", options: .backwards) {
                s = String(s[..<endFence.lowerBound])
            }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let pairs: [(String, String)] = [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)"), ("$", "$")]
        for (open, close) in pairs {
            if s.hasPrefix(open), s.hasSuffix(close), s.count > open.count + close.count {
                s = String(s.dropFirst(open.count).dropLast(close.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return s
    }

    /// 离线基础启发式转换：将 Apple Vision 识别到的常见 Unicode 数学符号与上下标规整为标准 LaTeX
    public static func heuristicUnicodeToLatex(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let symbolMap: [(String, String)] = [
            ("∑", "\\sum "), ("∏", "\\prod "), ("∫", "\\int "), ("∮", "\\oint "),
            ("∞", "\\infty "), ("√", "\\sqrt "), ("∂", "\\partial "), ("∇", "\\nabla "),
            ("≤", " \\leq "), ("≥", " \\geq "), ("≠", " \\neq "), ("≈", " \\approx "),
            ("≡", " \\equiv "), ("±", " \\pm "), ("∓", " \\mp "), ("×", " \\times "),
            ("÷", " \\div "), ("·", " \\cdot "), ("→", " \\to "), ("←", " \\leftarrow "),
            ("⇒", " \\Rightarrow "), ("⇔", " \\Leftrightarrow "), ("∈", " \\in "),
            ("∉", " \\notin "), ("⊂", " \\subset "), ("⊆", " \\subseteq "),
            ("∪", " \\cup "), ("∩", " \\cap "), ("∀", "\\forall "), ("∃", "\\exists "),
            ("°", "^\\circ "),
            ("α", "\\alpha "), ("β", "\\beta "), ("γ", "\\gamma "), ("δ", "\\delta "),
            ("ε", "\\epsilon "), ("ϵ", "\\varepsilon "), ("ζ", "\\zeta "), ("η", "\\eta "),
            ("θ", "\\theta "), ("λ", "\\lambda "), ("μ", "\\mu "), ("π", "\\pi "),
            ("ρ", "\\rho "), ("σ", "\\sigma "), ("τ", "\\tau "), ("φ", "\\phi "),
            ("ϕ", "\\varphi "), ("ψ", "\\psi "), ("ω", "\\omega "),
            ("Γ", "\\Gamma "), ("Δ", "\\Delta "), ("Θ", "\\Theta "), ("Λ", "\\Lambda "),
            ("Π", "\\Pi "), ("Σ", "\\Sigma "), ("Φ", "\\Phi "), ("Ψ", "\\Psi "), ("Ω", "\\Omega ")
        ]
        let supMap: [Character: Character] = [
            "⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4",
            "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9", "⁺": "+", "⁻": "-", "ⁿ": "n"
        ]
        let subMap: [Character: Character] = [
            "₀": "0", "₁": "1", "₂": "2", "₃": "3", "₄": "4",
            "₅": "5", "₆": "6", "₇": "7", "₈": "8", "₉": "9", "₊": "+", "₋": "-"
        ]

        // 先折叠连续 Unicode 上标 / 下标为 ^{...} / _{...}
        var out = ""
        let chars = Array(trimmed)
        var i = 0
        while i < chars.count {
            if supMap[chars[i]] != nil {
                var run = ""
                while i < chars.count, let m = supMap[chars[i]] { run.append(m); i += 1 }
                out += (run.count == 1) ? "^\(run)" : "^{\(run)}"
            } else if subMap[chars[i]] != nil {
                var run = ""
                while i < chars.count, let m = subMap[chars[i]] { run.append(m); i += 1 }
                out += (run.count == 1) ? "_\(run)" : "_{\(run)}"
            } else {
                out.append(chars[i])
                i += 1
            }
        }

        for (src, dst) in symbolMap {
            out = out.replacingOccurrences(of: src, with: dst)
        }
        while out.contains("  ") {
            out = out.replacingOccurrences(of: "  ", with: " ")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
