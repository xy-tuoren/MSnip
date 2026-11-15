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

/// 原生离线文字与二维码提取引擎：
/// macOS 13+ 优先走 `VisionKit.ImageAnalyzer`（~0.2s 极速单次推理同时产出右栏文本与左栏 Live Text 图层），
/// macOS 12 自动平滑回退 `VNRecognizeTextRequest`。
enum VisionTextExtractor {
    @MainActor
    static func recognizeAsync(
        from cgImage: CGImage,
        completion: @escaping @MainActor (OCRRecognitionOutput) -> Void
    ) {
        if #available(macOS 13.0, *), ImageAnalyzer.isSupported {
            Task { @MainActor in
                var cfg = ImageAnalyzer.Configuration([.text, .machineReadableCode])
                cfg.locales = ["zh-Hans", "zh-Hant", "en-US", "ja-JP"]
                let analysis = try? await SharedLiveAnalyzer.instance.analyze(cgImage, orientation: .up, configuration: cfg)
                let transcript = analysis?.transcript.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let qrList = await detectQRCodesOffMain(cgImage: cgImage)
                let merged = OCRTextFormatter.mergeTranscriptLines(transcript)
                completion(OCRRecognitionOutput(
                    qrPayloads: qrList,
                    preservedText: transcript,
                    mergedText: merged,
                    liveAnalysisObject: analysis as AnyObject?
                ))
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let fallback = recognizeFallbackVision(cgImage: cgImage)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(fallback) }
            }
        }
    }

    private static func detectQRCodesOffMain(cgImage: CGImage) async -> [String] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let req = VNDetectBarcodesRequest()
                req.symbologies = [.qr]
                try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([req])
                var codes: [String] = []
                for item in req.results ?? [] {
                    if let s = item.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !s.isEmpty, !codes.contains(s) {
                        codes.append(s)
                    }
                }
                cont.resume(returning: codes)
            }
        }
    }

    private static func recognizeFallbackVision(cgImage: CGImage) -> OCRRecognitionOutput {
        let barcodeReq = VNDetectBarcodesRequest()
        barcodeReq.symbologies = [.qr]
        let textReq = VNRecognizeTextRequest()
        textReq.recognitionLevel = .accurate
        textReq.usesLanguageCorrection = true
        textReq.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([textReq])
        try? handler.perform([barcodeReq])

        let qrPayloads = (barcodeReq.results ?? []).compactMap {
            $0.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        let observations = (textReq.results ?? []).compactMap { item -> OCRLineObservation? in
            guard let best = item.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines),
                  !best.isEmpty else { return nil }
            return OCRLineObservation(box: item.boundingBox, text: best)
        }
        return OCRRecognitionOutput(
            qrPayloads: qrPayloads,
            preservedText: OCRTextFormatter.format(observations, mode: .preserveLines),
            mergedText: OCRTextFormatter.format(observations, mode: .mergeParagraphs),
            liveAnalysisObject: nil
        )
    }
}
