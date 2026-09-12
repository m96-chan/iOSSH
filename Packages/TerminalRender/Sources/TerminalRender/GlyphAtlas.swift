import CoreText
import Metal
import UIKit

@MainActor
final class GlyphAtlas {
    struct Key: Hashable {
        var text: String
        var width: Int
        var bold: Bool
        var italic: Bool
    }
    struct Glyph {
        var page: Int
        var uv: SIMD4<Float>
        var size: SIMD2<Float>
        var isColor: Bool
    }

    let cellSize: CGSize
    let scale: CGFloat
    private(set) var textures: [any MTLTexture] = []
    private let device: any MTLDevice
    private let font: UIFont
    private let fontName: String
    private let side = 2048
    private var glyphs: [Key: Glyph] = [:]
    private var x = 1
    private var y = 1
    private var shelfHeight = 0

    init(device: any MTLDevice, configuration: TerminalConfiguration, scale: CGFloat) {
        self.device = device
        self.scale = scale
        self.fontName = configuration.fontName
        let size = min(32, max(8, configuration.fontSize))
        self.font = TerminalFont.font(named: configuration.fontName, size: size)
        let advance = ("M" as NSString).size(withAttributes: [.font: font]).width
        cellSize = CGSize(width: ceil(advance * scale) / scale, height: ceil((font.lineHeight + 2) * scale) / scale)
    }

    func glyph(text: String, width: Int, bold: Bool, italic: Bool) -> Glyph? {
        guard !text.isEmpty, text != " ", width > 0 else { return nil }
        let key = Key(text: text, width: width, bold: bold, italic: italic)
        if let result = glyphs[key] { return result }
        let pixelWidth = min(side - 2, Int(ceil(cellSize.width * CGFloat(min(2, width)) * scale)))
        let pixelHeight = min(side - 2, Int(ceil(cellSize.height * scale)))
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        if x + pixelWidth + 1 > side {
            x = 1
            y += shelfHeight + 1
            shelfHeight = 0
        }
        if textures.isEmpty || y + pixelHeight + 1 > side {
            // Bound glyph texture memory to 64 MiB. Font/scale changes create a fresh atlas.
            guard textures.count < 4 else { return glyphs[Key(text: "?", width: 1, bold: false, italic: false)] }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: side, height: side, mipmapped: false)
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            texture.label = "Terminal glyph atlas \(textures.count)"
            textures.append(texture)
            x = 1
            y = 1
            shelfHeight = 0
        }

        let styledFont = TerminalFont.font(named: fontName, size: font.pointSize, bold: bold, italic: italic)
        let isColor = text.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }
        let bytesPerRow = pixelWidth * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * pixelHeight)
        let drew = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: pixelWidth, height: pixelHeight,
                                          bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)
            context.setShouldSmoothFonts(false)
            context.scaleBy(x: scale, y: scale)
            context.textMatrix = .identity
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: styledFont, .foregroundColor: UIColor.white, .ligature: 0
            ]))
            let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            let slot = CGSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
            let separator = text.unicodeScalars.count == 1 && text.unicodeScalars.first.map { (0xE0B0...0xE0B7).contains($0.value) } == true
            if separator, !ink.isEmpty, !ink.isInfinite {
                // Powerline joins must reach all cell edges, including the line spacing.
                // Their intentional font bearings otherwise leave seams or crop the arrow.
                context.scaleBy(x: slot.width / ink.width, y: slot.height / ink.height)
                context.textPosition = CGPoint(x: -ink.minX, y: -ink.minY)
            } else if !ink.isEmpty, !ink.isInfinite {
                // Fallback emoji and Nerd Font icons can have ink substantially wider than
                // their advance. Fit the complete grapheme into the parser's cell allocation;
                // never use a shaped advance to position the following terminal cell.
                let left = min(0, ink.minX)
                let right = max(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)), ink.maxX)
                let fit = min(1, slot.width / max(1, right - left), slot.height / max(1, ink.height))
                let originX = (slot.width - (right - left) * fit) / 2 - left * fit
                let baseline = (cellSize.height - styledFont.lineHeight) / 2 - styledFont.descender
                let originY = fit < 1
                    ? (slot.height - ink.height * fit) / 2 - ink.minY * fit
                    : min(slot.height - ink.maxY, max(-ink.minY, baseline))
                context.translateBy(x: originX, y: originY)
                context.scaleBy(x: fit, y: fit)
                context.textPosition = .zero
            } else {
                context.textPosition = CGPoint(x: 0, y: (cellSize.height - styledFont.lineHeight) / 2 - styledFont.descender)
            }
            CTLineDraw(line, context)
            return true
        }
        guard drew else { return nil }
        // CGContext's bitmap storage already has the top scanline first.
        // Store straight sRGB so hardware sRGB decoding precedes alpha multiplication.
        // This matters at translucent color-emoji edges when blending in linear light.
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Int(pixels[offset + 3])
            if alpha > 0 && alpha < 255 {
                for component in 0..<3 {
                    pixels[offset + component] = UInt8(min(255, (Int(pixels[offset + component]) * 255 + alpha / 2) / alpha))
                }
            }
        }
        let page = textures.count - 1
        pixels.withUnsafeBytes { bytes in
            textures[page].replace(region: MTLRegionMake2D(x, y, pixelWidth, pixelHeight), mipmapLevel: 0,
                                   withBytes: bytes.baseAddress!, bytesPerRow: bytesPerRow)
        }
        let result = Glyph(page: page,
                           uv: SIMD4(Float(x) / Float(side), Float(y) / Float(side), Float(pixelWidth) / Float(side), Float(pixelHeight) / Float(side)),
                           size: SIMD2(Float(pixelWidth), Float(pixelHeight)), isColor: isColor)
        glyphs[key] = result
        x += pixelWidth + 1
        shelfHeight = max(shelfHeight, pixelHeight)
        return result
    }
}
