import Metal
import TerminalCore
import Testing
import UIKit
@testable import TerminalRender

@MainActor
struct TerminalOutputTests {
    @Test
    func japaneseRightHalvesMatchTheirGlyphsAcrossFrameBuffers() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let configuration = TerminalConfiguration(fontSize: 16)
        let renderer = try MetalRenderer(device: device, configuration: configuration, scale: 3)
        let atlas = GlyphAtlas(device: device, configuration: configuration, scale: 3)
        let engine = SwiftTermEngine(columns: 20, rows: 2)
        engine.setColors(foreground: .init(red: 255, green: 255, blue: 255),
                         background: .init(red: 0, green: 0, blue: 0),
                         palette: Array(repeating: .init(red: 255, green: 255, blue: 255), count: 16))
        // Hide the cursor and include a fullwidth blank between two Japanese runs.
        engine.feed(Data("\u{1b}[?25l日本語　日本語ABC".utf8))
        for frame in 0..<5 {
            if frame == 2 { engine.feed(Data("\r\u{1b}[1m仮名交じり文　出力".utf8)) }
            let snapshot = engine.snapshot()
            renderer.update(snapshot)
            let pixels = try render(renderer, device: device, scale: 3)
            let cellWidth = Int((atlas.cellSize.width * 3).rounded())
            let cellHeight = Int((atlas.cellSize.height * 3).rounded())
            var expectedPixels = [UInt8](repeating: 0, count: pixels.bytes.count)
            for offset in stride(from: 3, to: expectedPixels.count, by: 4) { expectedPixels[offset] = 255 }
            if frame == 0 {
                print("Terminal output cell size: \(cellWidth)x\(cellHeight), snapshot: \(Array(snapshot.cells.prefix(16)))")
            }
            for column in 0..<snapshot.columns {
                let cell = snapshot[column, 0]
                guard cell.width > 0, let glyph = atlas.glyph(text: cell.text, width: cell.width,
                    bold: cell.attributes.contains(.bold), italic: cell.attributes.contains(.italic)) else { continue }
                let raster = readGlyph(glyph, atlas: atlas)
                let glyphWidth = Int(glyph.size.x), glyphHeight = Int(glyph.size.y)
                for y in 0..<min(cellHeight, glyphHeight) {
                    for x in 0..<glyphWidth {
                        let alpha = Double(raster[(y * glyphWidth + x) * 4 + 3]) / 255
                        let expected = Int(((alpha <= 0.0031308 ? 12.92 * alpha : 1.055 * pow(alpha, 1 / 2.4) - 0.055) * 255).rounded())
                        let offset = (y * pixels.width + column * cellWidth + x) * 4
                        for channel in 0..<3 { expectedPixels[offset + channel] = UInt8(expected) }
                    }
                }
                if cell.width == 2 { #expect(snapshot[column + 1, 0].width == 0) }
            }
            // Compare the entire viewport, including U+3000, continuation cells,
            // blank rows, and narrow characters immediately after a Japanese run.
            let differingPixels = stride(from: 0, to: pixels.bytes.count, by: 4).filter { offset in
                (0..<3).contains { abs(Int(pixels.bytes[offset + $0]) - Int(expectedPixels[offset + $0])) > 2 }
            }.count
            #expect(differingPixels == 0, "\(differingPixels) pixels obscured on frame \(frame)")
            if frame == 0 {
                try savePNG(pixels.bytes, width: pixels.width, name: "TerminalOutput-actual")
                try savePNG(expectedPixels, width: pixels.width, name: "TerminalOutput-expected")
            }
        }
    }

    @Test
    func continuationCellsNeverDrawOverTheWideGlyph() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try MetalRenderer(device: device, configuration: .init(fontSize: 16), scale: 3)
        let white = TerminalColor(red: 255, green: 255, blue: 255)
        let black = TerminalColor(red: 0, green: 0, blue: 0)
        func snapshot(continuation: String, revision: UInt64) -> TerminalSnapshot {
            .init(revision: revision, columns: 2, rows: 1, cells: [
                .init(text: "語", width: 2, foreground: white, background: black),
                .init(text: continuation, width: 0, foreground: white, background: black,
                      attributes: [.underline, .strikethrough])
            ], damageRows: [0], cursor: .init(column: 0, row: 0, visible: false),
                  defaultForeground: white, defaultBackground: black)
        }
        renderer.update(snapshot(continuation: " ", revision: 0))
        let reference = try render(renderer, device: device, scale: 3)
        renderer.update(snapshot(continuation: "■", revision: 1))
        let output = try render(renderer, device: device, scale: 3)
        #expect(output.bytes == reference.bytes)
    }

    @Test
    func terminalWhitespaceDoesNotCreateGlyphsAndAtlasGuttersAreTransparent() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let atlas = GlyphAtlas(device: device, configuration: .init(fontSize: 16), scale: 3)
        for blank in ["", " ", "　", "\0", "\t", "\n"] {
            #expect(atlas.glyph(text: blank, width: 2, bold: false, italic: false) == nil)
        }
        #expect(atlas.textures.isEmpty)
        // Use enough distinct CJK entries to cross a shelf, with mixed cell widths.
        var entries: [GlyphAtlas.Glyph] = []
        for value in 0x4E00..<0x4E50 {
            let text = String(try #require(UnicodeScalar(value)))
            entries.append(try #require(atlas.glyph(text: text, width: value.isMultiple(of: 2) ? 1 : 2, bold: false, italic: false)))
        }
        for glyph in entries {
            let texture = atlas.textures[glyph.page]
            let width = Int(glyph.size.x) + 2, height = Int(glyph.size.y) + 2
            let x = Int((glyph.uv.x * Float(texture.width)).rounded()) - 1
            let y = Int((glyph.uv.y * Float(texture.height)).rounded()) - 1
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            bytes.withUnsafeMutableBytes {
                texture.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                                 from: MTLRegionMake2D(x, y, width, height), mipmapLevel: 0)
            }
            let border = (0..<width).map { $0 * 4 + 3 } + (0..<width).map { ((height - 1) * width + $0) * 4 + 3 }
                + (0..<height).map { $0 * width * 4 + 3 } + (0..<height).map { ($0 * width + width - 1) * 4 + 3 }
            #expect(border.allSatisfy { bytes[$0] == 0 })
        }
    }

    private func render(_ renderer: MetalRenderer, device: any MTLDevice, scale: CGFloat) throws -> (bytes: [UInt8], width: Int) {
        let snapshot = try #require(renderer.snapshot)
        let width = Int((renderer.cellSize.width * scale).rounded()) * snapshot.columns
        let height = Int((renderer.cellSize.height * scale).rounded()) * snapshot.rows
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
                                                                 width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        let texture = try #require(device.makeTexture(descriptor: descriptor))
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
        renderer.encodeFrame(to: encoder, drawableSize: CGSize(width: width, height: height))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return (bytes, width)
    }

    private func readGlyph(_ glyph: GlyphAtlas.Glyph, atlas: GlyphAtlas) -> [UInt8] {
        let texture = atlas.textures[glyph.page]
        let width = Int(glyph.size.x), height = Int(glyph.size.y)
        let x = Int((glyph.uv.x * Float(texture.width)).rounded())
        let y = Int((glyph.uv.y * Float(texture.height)).rounded())
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(x, y, width, height), mipmapLevel: 0)
        }
        return bytes
    }

    private func savePNG(_ bytes: [UInt8], width: Int, name: String) throws {
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: width, height: bytes.count / (width * 4), bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name).appendingPathExtension("png")
        try #require(UIImage(cgImage: image).pngData()).write(to: url)
        print("Terminal output diagnostic PNG: \(url.path)")
    }
}
