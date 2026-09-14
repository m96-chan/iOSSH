import CoreGraphics
import Foundation
import ImageIO

/// PNG is the format a sender reaches for when the image is a photograph or a screenshot —
/// `kitty icat` sends one for anything it cannot describe as raw pixels — so an engine that
/// cannot decode PNG shows nothing for most of what is actually transmitted.
///
/// SwiftTerm's store decodes it here directly. libghostty-vt has no image decoder of its own
/// and rejects a PNG payload outright unless the embedder installs one through
/// `ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG)`; `GhosttyEngine` installs this function
/// (#18), so both engines decode the same bytes to the same pixels.
public enum KittyPNG {
    /// Straight (unpremultiplied) sRGB RGBA8, tightly packed, top row first — the layout
    /// `TerminalImagePlacement.rgba` documents.
    ///
    /// The dimensions come out of the IHDR header and are checked against the caller's limits
    /// before ImageIO is asked to allocate anything, because the decoded size of a PNG is
    /// unbounded by the size of the PNG: a few kilobytes of it can describe hundreds of
    /// megabytes of pixels.
    public static func decode(_ data: Data, maximumDimension: Int, maximumBytes: Int) -> (width: Int, height: Int, rgba: Data)? {
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard data.count >= 24, data.prefix(8).elementsEqual(signature),
              data[12..<16].elementsEqual("IHDR".utf8) else { return nil }
        func bigEndian(_ offset: Int) -> Int { data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) } }
        let width = bigEndian(16), height = bigEndian(20)
        guard width > 0, height > 0, width <= maximumDimension, height <= maximumDimension,
              width * height <= maximumBytes / 4,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              cgImage.width == width, cgImage.height == height else { return nil }
        var rgba = Data(count: width * height * 4)
        let succeeded = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in stride(from: 0, to: raw.count, by: 4) {
                let alpha = Int(bytes[index + 3])
                if alpha > 0 && alpha < 255 {
                    for component in 0..<3 { bytes[index + component] = UInt8(min(255, (Int(bytes[index + component]) * 255 + alpha / 2) / alpha)) }
                }
            }
            return true
        }
        return succeeded ? (width, height, rgba) : nil
    }
}
