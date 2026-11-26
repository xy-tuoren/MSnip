import CoreGraphics
import Foundation

/// 安全高性能底图像素采样器：
/// - 标准 8-bit 32bpp RGB 位图走零拷贝 `CFData` 指针直读（带严格长度边界保护）；
/// - 8-bit 灰度、24-bit 无透明通道、16-bit/浮点 HDR 或索引色位图自动一次性栅格化为紧凑 8-bit RGBA 缓冲，彻底杜绝越界崩溃与通道错位。
public final class PixelSampler: @unchecked Sendable {
    public let cgImage: CGImage
    public let width: Int
    public let height: Int
    private let bytesPerRow: Int
    private let bytesPerPixel: Int
    private let rIdx: Int
    private let gIdx: Int
    private let bIdx: Int
    private let data: CFData?
    private let ownedBuffer: [UInt8]?
    private let ptr: UnsafePointer<UInt8>?
    private let byteLength: Int

    public init(cgImage: CGImage) {
        self.cgImage = cgImage
        let w = cgImage.width, h = cgImage.height
        self.width = w
        self.height = h

        let info = cgImage.bitmapInfo
        let byteOrder = info.rawValue & CGBitmapInfo.byteOrderMask.rawValue
        let isFloat = info.contains(.floatComponents)
        let canDirectRead = w > 0 && h > 0
            && cgImage.bitsPerComponent == 8
            && cgImage.bitsPerPixel == 32
            && !isFloat
            && cgImage.colorSpace?.model == .rgb
            && cgImage.bytesPerRow >= w * 4

        if canDirectRead,
           let cfData = cgImage.dataProvider?.data,
           CFDataGetLength(cfData) >= (h - 1) * cgImage.bytesPerRow + w * 4 {
            self.bytesPerRow = cgImage.bytesPerRow
            self.bytesPerPixel = 4
            let isLittle32 = (byteOrder == CGBitmapInfo.byteOrder32Little.rawValue)
            let alpha = CGImageAlphaInfo(rawValue: info.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
            let alphaFirst = (alpha == .premultipliedFirst || alpha == .first || alpha == .noneSkipFirst)
            if isLittle32 {
                if alphaFirst { self.bIdx = 0; self.gIdx = 1; self.rIdx = 2 }
                else          { self.bIdx = 1; self.gIdx = 2; self.rIdx = 3 }
            } else {
                if alphaFirst { self.rIdx = 1; self.gIdx = 2; self.bIdx = 3 }
                else          { self.rIdx = 0; self.gIdx = 1; self.bIdx = 2 }
            }
            self.data = cfData
            self.ownedBuffer = nil
            self.ptr = CFDataGetBytePtr(cfData)
            self.byteLength = CFDataGetLength(cfData)
            return
        }

        // 非 32bpp 8-bit RGB（如扫描灰度图、24-bit JPEG、16-bit/HDR PNG）：安全转栅格为标准 8-bit RGBA
        self.data = nil
        self.bytesPerPixel = 4
        self.rIdx = 0; self.gIdx = 1; self.bIdx = 2
        guard w > 0, h > 0 else {
            self.bytesPerRow = 0; self.ownedBuffer = nil; self.ptr = nil; self.byteLength = 0
            return
        }
        let bpr = w * 4
        var buf = [UInt8](repeating: 128, count: h * bpr)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        buf.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                      data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return }
            ctx.interpolationQuality = .none
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        self.bytesPerRow = bpr
        self.byteLength = buf.count
        self.ownedBuffer = buf
        self.ptr = self.ownedBuffer?.withUnsafeBufferPointer { $0.baseAddress }
    }

    /// 零分配安全读取物理像素 `(px, py)`（左上角为原点）的 RGB 分量 (0...255)
    @inline(__always)
    public func sampleRGB(px: Int, py: Int) -> (Int, Int, Int) {
        guard let ptr, width > 0, height > 0 else { return (128, 128, 128) }
        let cx = min(max(0, px), width - 1)
        let cy = min(max(0, py), height - 1)
        let offset = cy * bytesPerRow + cx * bytesPerPixel
        guard offset >= 0, offset + 3 < byteLength else { return (128, 128, 128) }
        return (Int(ptr[offset + rIdx]), Int(ptr[offset + gIdx]), Int(ptr[offset + bIdx]))
    }

    /// 按物理像素坐标 `(px, py)`（左上角为原点）读取原色域颜色
    public func sampleColor(px: Int, py: Int) -> CGColor {
        let (r, g, b) = sampleRGB(px: px, py: py)
        if let cs = cgImage.colorSpace, cs.model == .rgb, cs.supportsOutput,
           let c = CGColor(colorSpace: cs, components: [CGFloat(r) / 255.0, CGFloat(g) / 255.0, CGFloat(b) / 255.0, 1.0]) {
            return c
        }
        return CGColor(srgbRed: CGFloat(r) / 255.0, green: CGFloat(g) / 255.0, blue: CGFloat(b) / 255.0, alpha: 1.0)
    }
}
