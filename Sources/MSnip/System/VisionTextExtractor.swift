import AppKit
import CoreGraphics
import Foundation
import Vision

/// 原生离线文字与二维码提取引擎（基于系统内置 Apple Vision，零外部依赖、支持简繁中文与英文）
enum VisionTextExtractor {
    enum ResultKind {
        case qrAndText(String)
        case qrOnly(String)
        case textOnly(String)
        case empty
    }

    /// 异步识别图像中的二维码/条码与多语种文本，完成后自动复制到剪贴板并弹出轻提示
    static func extractAndCopy(from cgImage: CGImage, toastAnchor: NSPoint?) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = recognizeSynchronously(cgImage: cgImage)
            DispatchQueue.main.async {
                switch result {
                case .qrOnly(let code):
                    ClipboardAndSave.copyText(code)
                    let preview = code.count > 22 ? String(code.prefix(22)) + "…" : code
                    ToastHUD.show(message: "已复制二维码：\(preview)", near: toastAnchor)
                case .qrAndText(let combined):
                    ClipboardAndSave.copyText(combined)
                    ToastHUD.show(message: "已复制二维码与文本（\(combined.count) 字）", near: toastAnchor)
                case .textOnly(let text):
                    ClipboardAndSave.copyText(text)
                    ToastHUD.show(message: "已识别复制文本（\(text.count) 字）", near: toastAnchor)
                case .empty:
                    NSSound.beep()
                    ToastHUD.show(message: "选区内未识别到文字或二维码", near: toastAnchor)
                }
            }
        }
    }

    static func recognizeSynchronously(cgImage: CGImage) -> ResultKind {
        var qrPayloads: [String] = []
        var recognizedLines: [(box: CGRect, text: String)] = []

        let barcodeReq = VNDetectBarcodesRequest { req, _ in
            guard let obs = req.results as? [VNBarcodeObservation] else { return }
            for item in obs {
                if let str = item.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !str.isEmpty, !qrPayloads.contains(str) {
                    qrPayloads.append(str)
                }
            }
        }

        let textReq = VNRecognizeTextRequest { req, _ in
            guard let obs = req.results as? [VNRecognizedTextObservation] else { return }
            for item in obs {
                if let best = item.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines),
                   !best.isEmpty {
                    recognizedLines.append((item.boundingBox, best))
                }
            }
        }
        textReq.recognitionLevel = .accurate
        textReq.usesLanguageCorrection = true
        if #available(macOS 13.0, *) {
            textReq.automaticallyDetectsLanguage = true
        }
        textReq.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([barcodeReq, textReq])

        // Vision 的 boundingBox 原点在左下角 (0..1)：按从上到下、同行从左到右排序
        recognizedLines.sort { a, b in
            let rowTol: CGFloat = max(0.012, min(a.box.height, b.box.height) * 0.55)
            if abs(a.box.midY - b.box.midY) > rowTol {
                return a.box.midY > b.box.midY
            }
            return a.box.minX < b.box.minX
        }

        let textBody = recognizedLines.map(\.text).joined(separator: "\n")
        let qrBody = qrPayloads.joined(separator: "\n")

        if !qrBody.isEmpty && !textBody.isEmpty {
            return .qrAndText(qrBody == textBody ? qrBody : "\(qrBody)\n\(textBody)")
        } else if !qrBody.isEmpty {
            return .qrOnly(qrBody)
        } else if !textBody.isEmpty {
            return .textOnly(textBody)
        }
        return .empty
    }
}
