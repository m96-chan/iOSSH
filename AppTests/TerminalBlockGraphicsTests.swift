import Metal
import TerminalCore
import Testing
import UIKit
@testable import TerminalRender

@MainActor
struct TerminalBlockGraphicsTests {
    @Test(arguments: [9.0, 16.0], [2.0, 3.0])
    func blockMasksCoverTheCellAndPartitionOddDimensions(fontSize: Double, scale: Double) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let atlas = GlyphAtlas(device: device, configuration: .init(fontSize: fontSize), scale: scale)
        let width = Int((atlas.cellSize.width * scale).rounded())
        let height = Int((atlas.cellSize.height * scale).rounded())
        print("Block graphics cell at \(fontSize)pt @\(scale)x: \(width)x\(height)")

        for styled in [false, true] {
            let full = try glyph("█", atlas: atlas, styled: styled)
            #expect(full.width == width && full.height == height)
            let unfilledPixels = stride(from: 0, to: full.bytes.count, by: 4).filter {
                full.bytes[$0..<$0 + 4].contains { $0 != 255 }
            }.count
            #expect(unfilledPixels == 0, "Full blocks must cover every edge pixel, including bold/italic cells")

            let top = try glyph("▀", atlas: atlas, styled: styled)
            let bottom = try glyph("▄", atlas: atlas, styled: styled)
            let left = try glyph("▌", atlas: atlas, styled: styled)
            let right = try glyph("▐", atlas: atlas, styled: styled)
            let topAlpha = top.alpha, bottomAlpha = bottom.alpha
            let leftAlpha = left.alpha, rightAlpha = right.alpha
            for raster in [top, bottom, left, right] {
                #expect(raster.width == width && raster.height == height)
                #expect(raster.alpha.allSatisfy { $0 == 0 || $0 == 255 },
                        "Block edges belong on pixel boundaries without antialiasing")
            }
            #expect(zip(topAlpha, bottomAlpha).allSatisfy { Int($0.0) + Int($0.1) == 255 },
                    "Upper and lower blocks must partition every pixel, including an odd middle row")
            #expect(zip(leftAlpha, rightAlpha).allSatisfy { Int($0.0) + Int($0.1) == 255 },
                    "Left and right blocks must partition every pixel, including an odd middle column")

            // Accept either allocation of the odd middle pixel. The contract is
            // one straight shared boundary, correct orientation, and equal halves
            // to within one pixel; it does not copy a rasterizer rounding formula.
            let horizontalSplit = (0..<height).first { topAlpha[$0 * width] == 0 } ?? height
            #expect(horizontalSplit > 0 && horizontalSplit < height)
            #expect(abs(horizontalSplit * 2 - height) <= 1)
            #expect((0..<width * height).allSatisfy {
                topAlpha[$0] == ($0 / width < horizontalSplit ? 255 : 0)
            })
            let verticalSplit = (0..<width).first { leftAlpha[$0] == 0 } ?? width
            #expect(verticalSplit > 0 && verticalSplit < width)
            #expect(abs(verticalSplit * 2 - width) <= 1)
            #expect((0..<width * height).allSatisfy {
                leftAlpha[$0] == ($0 % width < verticalSplit ? 255 : 0)
            })
        }
    }

    @Test(arguments: [9.0, 16.0], [2.0, 3.0])
    func swappingANSIForegroundAndBackgroundWithTheOppositeHalfBlockPreservesTheImage(
        fontSize: Double, scale: Double
    ) async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try MetalRenderer(device: device, configuration: .init(fontSize: fontSize), scale: scale)
        let columns = 6, rows = 4
        let upper = await imageSnapshot(columns: columns, rows: rows, lowerBlock: false)
        let lower = await imageSnapshot(columns: columns, rows: rows, lowerBlock: true)
        let cellWidth = Int((renderer.cellSize.width * scale).rounded())
        let cellHeight = Int((renderer.cellSize.height * scale).rounded())
        let width = columns * cellWidth, height = rows * cellHeight
        var reference: [UInt8]?

        // Alternate two equivalent ANSI encodings across all three reusable GPU
        // buffers. Unequal coverage or shifted baselines produce visible stripes
        // when an image renderer switches between foreground/background encoding.
        for frame in 0..<6 {
            renderer.update(frame.isMultiple(of: 2) ? upper : lower)
            let pixels = try render(renderer, device: device, width: width, height: height)
            if let reference {
                let differences = zip(reference, pixels).filter { $0.0 != $0.1 }.count
                #expect(differences == 0, "Opposite half-block encodings changed \(differences) channels on frame \(frame)")
            } else { reference = pixels }

            let unexpectedColors = stride(from: 0, to: pixels.count, by: 4).filter {
                Array(pixels[$0..<$0 + 4]) != [0, 0, 255, 255]
                    && Array(pixels[$0..<$0 + 4]) != [255, 0, 0, 255]
            }.count
            #expect(unexpectedColors == 0, "Two-color block images must not acquire blended seams")
            var incorrectEdgePixels = 0
            for row in 0..<rows {
                for column in 0..<columns {
                    let topIsRed = (row + column).isMultiple(of: 2)
                    let topColor: [UInt8] = topIsRed ? [0, 0, 255, 255] : [255, 0, 0, 255]
                    let bottomColor: [UInt8] = topIsRed ? [255, 0, 0, 255] : [0, 0, 255, 255]
                    for x in 0..<cellWidth {
                        let first = (row * cellHeight * width + column * cellWidth + x) * 4
                        let last = ((row * cellHeight + cellHeight - 1) * width + column * cellWidth + x) * 4
                        if Array(pixels[first..<first + 4]) != topColor { incorrectEdgePixels += 1 }
                        if Array(pixels[last..<last + 4]) != bottomColor { incorrectEdgePixels += 1 }
                    }
                }
            }
            #expect(incorrectEdgePixels == 0, "Image rows must reach all cell edges with the intended color")
        }
    }

    @TerminalParserActor private func imageSnapshot(columns: Int, rows: Int, lowerBlock: Bool) -> TerminalSnapshot {
        let engine = SwiftTermEngine(columns: columns, rows: rows)
        var ansi = "\u{1b}[?25l"
        for row in 0..<rows {
            for column in 0..<columns {
                let top = (row + column).isMultiple(of: 2) ? "255;0;0" : "0;0;255"
                let bottom = (row + column).isMultiple(of: 2) ? "0;0;255" : "255;0;0"
                let foreground = lowerBlock ? bottom : top
                let background = lowerBlock ? top : bottom
                ansi += "\u{1b}[\(row + 1);\(column + 1)H\u{1b}[38;2;\(foreground)m\u{1b}[48;2;\(background)m"
                ansi += lowerBlock ? "▄" : "▀"
            }
        }
        engine.feed(Data(ansi.utf8))
        return engine.snapshot()
    }

    private struct Raster {
        var bytes: [UInt8]
        var width: Int
        var height: Int
        var alpha: [UInt8] { stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] } }
    }

    private func glyph(_ text: String, atlas: GlyphAtlas, styled: Bool) throws -> Raster {
        let glyph = try #require(atlas.glyph(text: text, width: 1, bold: styled, italic: styled))
        #expect(!glyph.isColor)
        let texture = atlas.textures[glyph.page]
        let width = Int(glyph.size.x), height = Int(glyph.size.y)
        let x = Int((glyph.uv.x * Float(texture.width)).rounded())
        let y = Int((glyph.uv.y * Float(texture.height)).rounded())
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(x, y, width, height), mipmapLevel: 0)
        }
        return Raster(bytes: bytes, width: width, height: height)
    }

    private func render(_ renderer: MetalRenderer, device: any MTLDevice, width: Int, height: Int) throws -> [UInt8] {
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
            texture.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return bytes
    }
}
