import AppKit
import CoreGraphics
import Foundation
import ImageIO
import MSnipCore
import Vision
import VisionKit

/// 离线识别结构化输出（含多语种文本、二维码/条码载荷、表格结构、双模式排版文本及可复用的系统实况分析句柄）
struct OCRRecognitionOutput: @unchecked Sendable {
    let qrPayloads: [String]
    let preservedText: String
    let mergedText: String
    let tableResult: OCRTableResult?
    let liveAnalysisObject: AnyObject?

    var isEmpty: Bool {
        preservedText.isEmpty && qrPayloads.isEmpty
    }

    func formattedText(for mode: OCRLayoutMode) -> String {
        switch mode {
        case .preserveLines:   return preservedText
        case .mergeParagraphs: return mergedText
        }
    }

    var initialClipboardText: String {
        if !preservedText.isEmpty { return preservedText }
        return qrPayloads.joined(separator: "\n")
    }
}

@available(macOS 13.0, *)
@MainActor
enum SharedLiveAnalyzer {
    private static var cached: ImageAnalyzer?
    private static var inFlightCount: Int = 0
    private static var releaseWork: DispatchWorkItem?

    /// 按需懒加载并在闲置 25s 后自动释放 VisionKit / Neural Engine 神经缓冲（省去 ~80–120 MB 常驻脏内存）
    static var instance: ImageAnalyzer {
        let inst = cached ?? { let a = ImageAnalyzer(); cached = a; return a }()
        scheduleIdleRelease()
        return inst
    }

    static func analyze(_ image: CGImage, configuration: ImageAnalyzer.Configuration) async throws -> ImageAnalysis {
        inFlightCount += 1
        releaseWork?.cancel()
        defer {
            inFlightCount = max(0, inFlightCount - 1)
            if inFlightCount == 0 { scheduleIdleRelease() }
        }
        return try await instance.analyze(image, orientation: .up, configuration: configuration)
    }

    private static func scheduleIdleRelease() {
        releaseWork?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                if inFlightCount == 0 { cached = nil }
            }
        }
        releaseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 25.0, execute: work)
    }
}

/// 高精度离线文字与二维码双管线并行提取引擎：
/// 1. 文本主干：对 @1x / 小图执行自适应 1.5×~2.5× 超分放大、同色安全留白与 SIMD 温和锐化，再调用
///    `VNRecognizeTextRequest`（macOS 13+ 锁定 `Revision3` + `.accurate` + 自动语种检测），配合空间重排与双栏/缩进还原；
/// 2. 实况图层：在 macOS 13+ 并发运行 `VisionKit.ImageAnalyzer` 驱动左侧原图划词交互，同时作为特殊艺术字兜底。
enum VisionTextExtractor {
    private static let ocrLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]

    @MainActor
    static func recognizeAsync(
        from cgImage: CGImage,
        exactCodeMode: Bool = false,
        completion: @escaping @MainActor (OCRRecognitionOutput) -> Void
    ) {
        Task { @MainActor in
            async let visionResult = performAccurateVisionOCR(cgImage: cgImage, exactCodeMode: exactCodeMode)
            async let liveResult: AnyObject? = analyzeLiveTextOverlay(cgImage: cgImage)

            let (observations, qrList) = await visionResult
            let liveObj = await liveResult

            var preserved = OCRTextFormatter.format(observations, mode: .preserveLines)
            var merged = OCRTextFormatter.format(observations, mode: .mergeParagraphs)
            let table = OCRTableFormatter.extractTable(from: observations)

            // 若精确 Vision 未检出（如极度艺术字/竖排海报），回退使用 VisionKit transcript 兜底
            if preserved.isEmpty, #available(macOS 13.0, *), let analysis = liveObj as? ImageAnalysis {
                let fallback = OCRTextFormatter.sanitizeLine(analysis.transcript)
                if !fallback.isEmpty {
                    preserved = fallback
                    merged = OCRTextFormatter.mergeTranscriptLines(fallback)
                }
            }

            completion(OCRRecognitionOutput(
                qrPayloads: qrList,
                preservedText: preserved,
                mergedText: merged,
                tableResult: table,
                liveAnalysisObject: liveObj
            ))
        }
    }

    /// 轻量后台二维码/条形码快速扫描（供截图选区自动识别与贴图右键菜单即时调用）
    static func detectBarcodesOffMain(cgImage: CGImage) async -> [String] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let req = VNDetectBarcodesRequest()
                req.symbologies = supportedBarcodes
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform([req])
                var payloads: [String] = []
                for item in req.results ?? [] {
                    if let s = item.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !s.isEmpty, !payloads.contains(s) {
                        payloads.append(s)
                    }
                }
                cont.resume(returning: payloads)
            }
        }
    }

    /// 离线扫描选区中的隐私敏感子串（API Key / 邮箱 / 手机号 / 身份证 / IP / 银行卡），返回精确局部归一化边界框（左下角 `0..1`）
    static func detectSensitiveBoxesOffMain(cgImage: CGImage) async -> [CGRect] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let prepared = OCRImagePreprocessor.prepare(cgImage)
                let textReq = makeAccurateTextRequest(exactCodeMode: true)
                let handler = VNImageRequestHandler(cgImage: prepared.cgImage, options: [:])
                try? handler.perform([textReq])

                var boxes: [CGRect] = []
                for item in textReq.results ?? [] {
                    guard let best = item.topCandidates(1).first else { continue }
                    let raw = best.string
                    let hits = SensitiveTextDetector.detect(in: raw)
                    for hit in hits {
                        let normBox: CGRect
                        if let subObs = try? best.boundingBox(for: hit.range) {
                            normBox = prepared.mapBoxBack(subObs.boundingBox)
                        } else {
                            normBox = prepared.mapBoxBack(item.boundingBox)
                        }
                        if normBox.width > 0.002 && normBox.height > 0.002 {
                            boxes.append(normBox)
                        }
                    }
                }
                cont.resume(returning: boxes)
            }
        }
    }

    /// 提取段落级聚合块（归一化左下角坐标系 `0..1`），供页内段落原位翻译渲染
    static func recognizeParagraphsOffMain(cgImage: CGImage) async -> [OCRParagraphBlock] {
        let (observations, _) = await performAccurateVisionOCR(cgImage: cgImage, exactCodeMode: false, detectBarcodes: false)
        return OCRParagraphGrouper.group(observations)
    }

    private static let supportedBarcodes: [VNBarcodeSymbology] = [
        .qr, .ean13, .ean8, .code128, .code39, .upce, .aztec, .pdf417, .dataMatrix
    ]

    /// 提取带精确归一化边界框 (`0..1` 左下角原点) 的视觉合并行，供页内原位覆盖翻译渲染
    static func recognizeVisualLinesOffMain(cgImage: CGImage) async -> [OCRLineObservation] {
        let (observations, _) = await performAccurateVisionOCR(cgImage: cgImage, exactCodeMode: false, detectBarcodes: false)
        let grouped = OCRTextFormatter.groupIntoVisualRows(observations)
        return grouped.map { segs in
            var txt = ""
            for (i, seg) in segs.enumerated() {
                txt += (i == 0) ? seg.text : (OCRTextFormatter.smartInlineJoiner(left: txt, right: seg.text) + seg.text)
            }
            let minX = segs.map(\.box.minX).min() ?? 0
            let maxX = segs.map(\.box.maxX).max() ?? 1
            let minY = segs.map(\.box.minY).min() ?? 0
            let maxY = segs.map(\.box.maxY).max() ?? 0
            return OCRLineObservation(
                box: CGRect(x: minX, y: minY, width: max(0.01, maxX - minX), height: max(0.01, maxY - minY)),
                text: txt
            )
        }
    }

    // MARK: - Private Dual Pipelines

    @MainActor
    private static func analyzeLiveTextOverlay(cgImage: CGImage) async -> AnyObject? {
        guard #available(macOS 13.0, *), ImageAnalyzer.isSupported else { return nil }
        var cfg = ImageAnalyzer.Configuration([.text, .machineReadableCode])
        cfg.locales = ["zh-Hans", "zh-Hant", "en-US", "ja-JP"]
        return (try? await SharedLiveAnalyzer.analyze(cgImage, configuration: cfg)) as AnyObject?
    }

    private static func performAccurateVisionOCR(
        cgImage: CGImage,
        exactCodeMode: Bool,
        detectBarcodes: Bool = true
    ) async -> ([OCRLineObservation], [String]) {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let prepared = OCRImagePreprocessor.prepare(cgImage)
                let textReq = makeAccurateTextRequest(exactCodeMode: exactCodeMode)
                var requests: [VNRequest] = [textReq]
                var barcodeReq: VNDetectBarcodesRequest?
                if detectBarcodes {
                    let bReq = VNDetectBarcodesRequest()
                    bReq.symbologies = supportedBarcodes
                    barcodeReq = bReq
                    requests.append(bReq)
                }

                let handler = VNImageRequestHandler(cgImage: prepared.cgImage, options: [:])
                try? handler.perform(requests)

                var observations: [OCRLineObservation] = []
                for item in textReq.results ?? [] {
                    guard let best = item.topCandidates(1).first else { continue }
                    let text = OCRTextFormatter.sanitizeLine(best.string)
                    guard !text.isEmpty else { continue }
                    // 过滤极低置信度单字符随机噪点（防止图片纹理/图标被误识为孤立杂符）
                    if text.count == 1 && best.confidence < 0.28 { continue }
                    observations.append(OCRLineObservation(box: prepared.mapBoxBack(item.boundingBox), text: text))
                }

                var qrPayloads: [String] = []
                for item in barcodeReq?.results ?? [] {
                    if let s = item.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !s.isEmpty, !qrPayloads.contains(s) {
                        qrPayloads.append(s)
                    }
                }
                cont.resume(returning: (observations, qrPayloads))
            }
        }
    }

    private static func makeAccurateTextRequest(exactCodeMode: Bool) -> VNRecognizeTextRequest {
        let req = VNRecognizeTextRequest()
        if #available(macOS 13.0, *) {
            req.revision = VNRecognizeTextRequestRevision3
            req.automaticallyDetectsLanguage = true
        }
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = !exactCodeMode
        req.recognitionLanguages = ocrLanguages
        req.minimumTextHeight = 0.0
        return req
    }
}
