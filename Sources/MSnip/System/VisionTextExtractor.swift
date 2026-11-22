import AppKit
import CoreGraphics
import Foundation
import ImageIO
import MSnipCore
import Vision
import VisionKit

/// 离线识别结构化输出（含多语种文本、二维码载荷、双模式排版文本及可复用的系统实况分析句柄）
struct OCRRecognitionOutput: @unchecked Sendable {
    let qrPayloads: [String]
    let preservedText: String
    let mergedText: String
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
    static let instance = ImageAnalyzer()
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
                liveAnalysisObject: liveObj
            ))
        }
    }

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
        return (try? await SharedLiveAnalyzer.instance.analyze(cgImage, orientation: .up, configuration: cfg)) as AnyObject?
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
                    bReq.symbologies = [.qr]
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
