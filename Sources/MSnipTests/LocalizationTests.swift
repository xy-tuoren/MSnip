import Foundation
import MSnipCore

/// 界面本地化：占位符格式化、语言偏好读写，以及源码 `L("…")` 键与英文译文表的一致性审计
func testLocalization() {
    // 1) 只认 %@ / %n$@ / %%，参数不足留空、其余 % 原样保留，绝不因占位符不符崩溃
    check(MSnipL10n.format("已复制 %@ 项", ["3"]) == "已复制 3 项", "顺序占位符应按参数替换")
    check(MSnipL10n.format("%2$@ of %1$@", ["a", "b"]) == "b of a", "位置占位符应允许译文调换参数顺序")
    check(MSnipL10n.format("%@ and %@", ["x"]) == "x and ", "参数不足时应留空而不是崩溃")
    check(MSnipL10n.format("100%% done %d", []) == "100% done %d", "%% 应转义为 %，其余格式符原样保留")
    check(MSnipL10n.format("缩放 100%", ["x"]) == "缩放 100%", "结尾孤立的 % 应原样保留")
    check(MSnipL10n.placeholderSignature("%@ / %@") == [1, 2] && MSnipL10n.placeholderSignature("%2$@ / %1$@") == [1, 2],
          "顺序与位置占位符应得到相同签名")
    check(MSnipL10n.placeholderSignature("100%% 无参数") == [], "无占位符的模板签名应为空")

    // 2) L()：命中译文表返回译文，缺译回落中文原文
    MSnipL10n.setOverrideTable(["复制": "Copy", "共 %@ 项": "%@ items", "%@ 秒后截图": "Capture in %@ s"])
    check(L("复制") == "Copy", "命中译文表时应返回英文")
    check(L("粘贴") == "粘贴", "缺少译文时应回落中文原文")
    check(L("共 %@ 项", 5) == "5 items" && L("%@ 秒后截图", 3) == "Capture in 3 s", "插值文案应先查表再填参数")
    MSnipL10n.setOverrideTable(nil)
    check(L("复制") == "复制", "单测进程主 Bundle 不含译文，恢复后应回落原文")

    // 3) 界面语言偏好写入/清除本应用域的 AppleLanguages
    let suite = "top.xy.msnip.l10n-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    check(MSnipInterfaceLanguage.current(defaults: defaults, bundleID: suite) == .system, "未设置时应跟随系统")
    MSnipInterfaceLanguage.apply(.english, defaults: defaults, bundleID: suite)
    check(MSnipInterfaceLanguage.current(defaults: defaults, bundleID: suite) == .english, "应能切换为英文")
    check((defaults.persistentDomain(forName: suite)?["AppleLanguages"] as? [String]) == ["en"], "应写入 AppleLanguages = [en]")
    MSnipInterfaceLanguage.apply(.simplifiedChinese, defaults: defaults, bundleID: suite)
    check(MSnipInterfaceLanguage.current(defaults: defaults, bundleID: suite) == .simplifiedChinese, "应能切换为简体中文")
    MSnipInterfaceLanguage.apply(.system, defaults: defaults, bundleID: suite)
    check(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil, "跟随系统时应移除应用级覆盖")
    check(MSnipInterfaceLanguage.english.nativeName == "English" && MSnipInterfaceLanguage.simplifiedChinese.nativeName == "简体中文",
          "语言名应始终以该语言自身书写")

    // 4) Toast 语气判断同时认中英文措辞
    check(MessageTone.classify("保存图片失败") == .warning && MessageTone.classify("Failed to save the image") == .warning, "失败提示应为警告")
    check(MessageTone.classify("请先框选需要识别文字的区域") == .warning && MessageTone.classify("Select an area first") == .warning, "「请先」类提示应为警告")
    check(MessageTone.classify("当前桌面暂无贴图") == .neutral || MessageTone.classify("当前桌面暂无贴图") == .warning, "暂无类提示不应显示为成功")
    check(MessageTone.classify("No text or QR code found in the selection") == .warning, "英文「No …」提示应为警告")
    check(MessageTone.classify("已复制贴图图像") == .success && MessageTone.classify("Copied the pinned image") == .success, "完成类提示应为成功")
    check(MessageTone.classify("Extracting text offline…") == .neutral && MessageTone.classify("正在离线识字…") == .neutral, "进行中提示应为中性")

    // 5) 源码键与英文译文表审计
    auditLocalizationTable()
}

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func auditLocalizationTable() {
    let tableURL = repoRoot.appendingPathComponent("Resources/en.lproj/Localizable.strings")
    guard let raw = NSDictionary(contentsOf: tableURL) as? [String: String] else {
        check(false, "无法解析英文译文表（.strings 语法错误？）: \(tableURL.path)")
        return
    }
    check(!raw.isEmpty, "英文译文表不应为空")

    var usedKeys = Set<String>()
    var problems: [String] = []
    let fm = FileManager.default
    for dir in ["Sources/MSnip", "Sources/MSnipCore"] {
        let base = repoRoot.appendingPathComponent(dir)
        let files = (fm.enumerator(at: base, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" }
        for file in files {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let (keys, issues) = extractLocalizationKeys(from: source)
            usedKeys.formUnion(keys)
            problems += issues.map { "\(file.lastPathComponent): \($0)" }
        }
    }
    check(problems.isEmpty, "L() 只接受普通字符串字面量（不可插值、不可传变量）:\n  " + problems.prefix(20).joined(separator: "\n  "))

    let missing = usedKeys.subtracting(raw.keys).sorted()
    check(missing.isEmpty, "以下 \(missing.count) 条界面文案缺少英文译文（Resources/en.lproj/Localizable.strings）:\n  "
          + missing.prefix(30).joined(separator: "\n  "))
    let unused = Set(raw.keys).subtracting(usedKeys).sorted()
    check(unused.isEmpty, "英文译文表中有 \(unused.count) 条键已不在源码中使用，请删除:\n  " + unused.prefix(30).joined(separator: "\n  "))

    var badValues: [String] = []
    for (key, value) in raw {
        if value.trimmingCharacters(in: .whitespaces).isEmpty {
            badValues.append("译文为空: \(key)")
        } else if MSnipL10n.placeholderSignature(key) != MSnipL10n.placeholderSignature(value) {
            badValues.append("占位符不一致: \(key) → \(value)")
        } else if value.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) {
            badValues.append("译文仍含中文: \(key) → \(value)")
        }
    }
    check(badValues.isEmpty, "英文译文有误:\n  " + badValues.sorted().prefix(20).joined(separator: "\n  "))
}

/// 从 Swift 源码中提取 `L("…")` 的键（按 Swift 转义规则还原），并报告无法静态审计的调用
private func extractLocalizationKeys(from source: String) -> (keys: [String], problems: [String]) {
    var scanner = SwiftLiteralScanner(chars: Array(source.unicodeScalars))
    scanner.scanCode(untilCloseParen: false)
    return (scanner.keys, scanner.problems)
}

/// 极简 Swift 词法扫描：跳过注释与普通/原始/多行字符串，但会进入插值表达式继续寻找嵌套的 `L(`
private struct SwiftLiteralScanner {
    let chars: [Unicode.Scalar]
    var i = 0
    var line = 1
    var keys: [String] = []
    var problems: [String] = []

    init(chars: [Unicode.Scalar]) { self.chars = chars }

    private func at(_ k: Int) -> Unicode.Scalar? { k < chars.count ? chars[k] : nil }
    private func isIdent(_ c: Unicode.Scalar) -> Bool { CharacterSet.alphanumerics.contains(c) || c == "_" }

    mutating func scanCode(untilCloseParen: Bool) {
        var depth = 0
        while let c = at(i) {
            switch c {
            case "\n":
                line += 1; i += 1
            case "/" where at(i + 1) == "/":
                while let d = at(i), d != "\n" { i += 1 }
            case "/" where at(i + 1) == "*":
                i += 2
                while let d = at(i), !(d == "*" && at(i + 1) == "/") { if d == "\n" { line += 1 }; i += 1 }
                i += 2
            case "(":
                depth += 1; i += 1
            case ")":
                i += 1
                if untilCloseParen && depth == 0 { return }
                depth -= 1
            case "#" where at(i + 1) == "\"" || at(i + 1) == "#":
                skipRawString()
            case "\"":
                _ = readString()
            case "L" where at(i + 1) == "(" && (i == 0 || !(isIdent(chars[i - 1]) || chars[i - 1] == ".")):
                let before = String(String.UnicodeScalarView(chars[max(0, i - 5)..<i]))
                i += 2
                depth += 1
                if before.hasSuffix("func ") { continue }
                guard at(i) == "\"" else { problems.append("第 \(line) 行 L( 后不是字符串字面量"); continue }
                let startLine = line
                let (value, interpolated, multiline) = readString()
                if multiline {
                    problems.append("第 \(startLine) 行 L() 不支持多行字符串")
                } else if interpolated {
                    problems.append("第 \(startLine) 行 L() 的键含插值，请改为 %@ 占位符")
                } else {
                    keys.append(value)
                }
            default:
                i += 1
            }
        }
    }

    /// 读取以 `"` 或 `"""` 开头的字符串，遇到 `\(` 时递归扫描插值表达式
    private mutating func readString() -> (String, Bool, Bool) {
        let multiline = at(i + 1) == "\"" && at(i + 2) == "\""
        i += multiline ? 3 : 1
        var value = String.UnicodeScalarView()
        var interpolated = false
        while let c = at(i) {
            if c == "\"" {
                if !multiline { i += 1; break }
                if at(i + 1) == "\"" && at(i + 2) == "\"" { i += 3; break }
            }
            if c == "\n" {
                line += 1
                if !multiline { i += 1; break }
            }
            if c == "\\", let e = at(i + 1) {
                i += 2
                switch e {
                case "n": value.append("\n")
                case "t": value.append("\t")
                case "r": value.append("\r")
                case "0": value.append("\0")
                case "(":
                    interpolated = true
                    scanCode(untilCloseParen: true)
                case "u":
                    var hex = ""
                    i += 1
                    while let h = at(i), h != "}" { hex.unicodeScalars.append(h); i += 1 }
                    i += 1
                    if let v = UInt32(hex, radix: 16), let s = Unicode.Scalar(v) { value.append(s) }
                default: value.append(e)
                }
                continue
            }
            value.append(c)
            i += 1
        }
        return (String(value), interpolated, multiline)
    }

    private mutating func skipRawString() {
        var hashes = 0
        while at(i) == "#" { hashes += 1; i += 1 }
        guard at(i) == "\"" else { return }
        let multiline = at(i + 1) == "\"" && at(i + 2) == "\""
        let quotes = multiline ? 3 : 1
        i += quotes
        while let c = at(i) {
            if c == "\n" { line += 1 }
            if c == "\"" {
                var k = i
                var q = 0
                while at(k) == "\"", q < quotes { q += 1; k += 1 }
                var h = 0
                while at(k) == "#", h < hashes { h += 1; k += 1 }
                if q == quotes && h == hashes { i = k; return }
            }
            i += 1
        }
    }
}
