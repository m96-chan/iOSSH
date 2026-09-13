import CoreText
import Metal
import TerminalCore
import Testing
import UIKit
@testable import TerminalRender

@MainActor
struct TerminalFontTests {
    @Test
    func bundledStylesCoverJapaneseAndStarshipWithoutFontFallback() {
        for (bold, italic, style) in [(false, false, "Regular"), (true, false, "Bold"),
                                      (false, true, "Regular"), (true, true, "Bold")] {
            let font = TerminalFont.font(ofSize: 14, bold: bold, italic: italic)
            #expect(font.fontName == "HackGenConsoleNF-\(style)")
            if italic { #expect(CTFontGetMatrix(font as CTFont).c > 0) }
            for text in ["日本語", "e\u{301}", "❯", "\u{e0a0}", "\u{e0b0}", "\u{f120}", "\u{f17c}", "\u{f121}", "\u{f015}", "\u{f07b}", "\u{f0318}"] {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
                for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                    let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                    #expect(CTFontCopyPostScriptName(runFont) as String == font.fontName)
                    var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
                    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                    #expect(!glyphs.isEmpty && glyphs.allSatisfy { $0 != 0 }, "Missing glyph for \(text) in \(style)")
                }
            }
            let advance = ("M" as NSString).size(withAttributes: [.font: font]).width
            let japanese = ("日本語" as NSString).size(withAttributes: [.font: font]).width
            #expect(abs(japanese - advance * 6) < 0.01)
        }
    }

    @Test(arguments: [9, 16], [2, 3])
    func missingCJKGlyphsUseTheBundledJapaneseFallbackAndMatchingStyle(fontSize: Int, scale: Int) throws {
        let samples = ["\u{3400}", "\u{20021}", "\u{30ede}"]
        let atlas = try atlas(fontSize: CGFloat(fontSize), scale: CGFloat(scale))
        for bold in [false, true] {
            for italic in [false, true] {
                let font = TerminalFont.font(ofSize: CGFloat(fontSize), bold: bold, italic: italic)
                let primaryCharacters = CTFontCopyCharacterSet(font as CTFont) as CharacterSet
                for text in samples {
                    // These scalars are absent in HackGen, so the test cannot pass by
                    // silently drawing the primary font or an unrelated system CJK face.
                    #expect(text.unicodeScalars.allSatisfy { !primaryCharacters.contains($0) })
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
                    let runs = CTLineGetGlyphRuns(line) as! [CTRun]
                    #expect(!runs.isEmpty)
                    for run in runs {
                        let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                        #expect(CTFontCopyPostScriptName(runFont) as String == "NotoSansCJKjp-\(bold ? "Bold" : "Regular")")
                        if italic { #expect(CTFontGetMatrix(runFont).c > 0) }
                        var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
                        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                        #expect(glyphs.allSatisfy { $0 != 0 })
                    }
                    let rendered = try pixels(atlas, text: text, width: 2, bold: bold, italic: italic)
                    #expect(rendered.inkBounds != nil)
                    #expect(rendered.width == Int(ceil(atlas.cellSize.width * 2 * atlas.scale)))
                    #expect(!rendered.isColor)
                }
            }
        }
    }

    @Test
    func latinPrimaryStillUsesNotoJPForJapaneseAndHackGenForNerdSymbols() {
        let font = TerminalFont.font(named: "Menlo-Regular", size: 14)
        for (text, expected) in [("日本語", "NotoSansCJKjp-Regular"), ("\u{f0318}", "HackGenConsoleNF-Regular")] {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            let runs = CTLineGetGlyphRuns(line) as! [CTRun]
            #expect(!runs.isEmpty)
            for run in runs {
                let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
                #expect(CTFontCopyPostScriptName(runFont) as String == expected)
            }
        }
    }

    @Test
    func synthesizedItalicChangesTheActualGlyphSlant() throws {
        let atlas = try atlas()
        let upright = try pixels(atlas, text: "H", width: 1)
        let italic = try pixels(atlas, text: "H", width: 1, italic: true)
        #expect(abs(try upright.slant()) < 0.75)
        #expect(abs(try italic.slant()) > 1.5)
    }

    @Test @TerminalParserActor
    func promptCellsKeepUnicodeWidthsAndWrapAtTheDeclaredColumns() {
        let engine = SwiftTermEngine(columns: 16, rows: 3)
        // 1 + 2 + 2 + 1 + 1 + 2 + 2 + 2 + 1 = 14 columns, followed by two ASCII cells.
        let glyphs = [("\u{e0b0}", 1), ("日", 2), ("本", 2), ("e\u{301}", 1), ("\u{f0318}", 1),
                      ("😀", 2), ("👩🏽‍💻", 2), ("🇯🇵", 2), ("❯", 1)]
        for (text, _) in glyphs {
            // Network packets can split a UTF-8 scalar or a combining/emoji sequence.
            for byte in text.utf8 { engine.feed(Data([byte])) }
        }
        engine.feed(Data("ABZ".utf8))
        let snapshot = engine.snapshot()
        var column = 0
        for (text, width) in glyphs {
            #expect(snapshot.cells[column].text == text)
            #expect(snapshot.cells[column].width == width)
            if width == 2 { #expect(snapshot.cells[column + 1].width == 0) }
            column += width
        }
        #expect(snapshot.cells[14].text == "A")
        #expect(snapshot.cells[15].text == "B")
        #expect(snapshot.cells[16].text == "Z")
        #expect(snapshot.cursor.column == 1 && snapshot.cursor.row == 1)
    }

    @Test
    func oversizedIconsRetainTheirShapeInsteadOfBeingClipped() throws {
        let atlas = try atlas()
        for text in ["\u{f121}", "\u{f120}", "\u{f015}"] {
            let narrow = try pixels(atlas, text: text, width: 1)
            let wide = try pixels(atlas, text: text, width: 2)
            let narrowInk = try #require(narrow.inkBounds)
            let wideInk = try #require(wide.inkBounds)
            let narrowRatio = narrowInk.width / narrowInk.height
            let wideRatio = wideInk.width / wideInk.height
            #expect(abs(narrowRatio - wideRatio) < 0.22, "Clipped icon shape: \(text)")
            #expect(narrowInk.height < wideInk.height)
        }
    }

    @Test(arguments: [9, 16], [2, 3])
    func powerlineJoinsCoverLineSpacingAndEmojiRemainColored(fontSize: Int, scale: Int) throws {
        let atlas = try atlas(fontSize: CGFloat(fontSize), scale: CGFloat(scale))
        let right = try pixels(atlas, text: "\u{e0b0}", width: 1)
        let left = try pixels(atlas, text: "\u{e0b2}", width: 1)
        #expect((0..<right.height).allSatisfy { right.alpha(x: 0, y: $0) > 0 })
        #expect((0..<left.height).allSatisfy { left.alpha(x: left.width - 1, y: $0) > 0 })
        for text in ["日", "e\u{301}", "😀", "👩🏽‍💻", "🇯🇵"] {
            let value = try pixels(atlas, text: text, width: text == "e\u{301}" ? 1 : 2)
            #expect(value.inkBounds != nil)
            if ["😀", "👩🏽‍💻", "🇯🇵"].contains(text) {
                #expect(value.isColor)
                #expect(stride(from: 0, to: value.bytes.count, by: 4).contains { offset in
                    value.bytes[offset + 3] > 100 && abs(Int(value.bytes[offset]) - Int(value.bytes[offset + 2])) > 30
                })
            }
        }
    }

    /// Shell output assumes 80 columns, and the grid takes the full display width on an
    /// iPhone. The narrowest supported portrait width is 375 points at 2×; recent phones
    /// are 390 points at 3×. Cell widths round up to a device pixel, so a size that fits
    /// on paper can still lose the column count on one of the two scales.
    @Test(arguments: [(375.0, 2.0), (390.0, 3.0)])
    func theInitialPhoneFontSizeKeepsEightyColumnsUpright(width: Double, scale: Double) throws {
        let atlas = try atlas(fontSize: TerminalConfiguration.phoneFontSize, scale: CGFloat(scale))
        #expect(Int(width / atlas.cellSize.width) >= 80)
    }

    private func atlas(fontSize: CGFloat = 16, scale: CGFloat = 3) throws -> GlyphAtlas {
        let device = try #require(MTLCreateSystemDefaultDevice(), "Glyph rendering requires Metal")
        return GlyphAtlas(device: device, configuration: .init(fontSize: fontSize), scale: scale)
    }

    private struct Pixels {
        let bytes: [UInt8]
        let width: Int
        let height: Int
        let isColor: Bool

        func alpha(x: Int, y: Int) -> UInt8 { bytes[(y * width + x) * 4 + 3] }

        func slant() throws -> Double {
            let bounds = try #require(inkBounds)
            let first = Int(bounds.minY), last = Int(bounds.maxY) - 1
            let band = max(1, Int(bounds.height) / 4)
            func centroid(_ rows: Range<Int>) -> Double {
                var mass = 0.0, weightedX = 0.0
                for y in rows {
                    for x in 0..<width {
                        let value = Double(alpha(x: x, y: y))
                        mass += value
                        weightedX += Double(x) * value
                    }
                }
                return weightedX / max(1, mass)
            }
            return centroid(first..<(first + band)) - centroid((last - band + 1)..<(last + 1))
        }

        var inkBounds: CGRect? {
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                for x in 0..<width where alpha(x: x, y: y) > 64 {
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
    }

    private func pixels(_ atlas: GlyphAtlas, text: String, width: Int, bold: Bool = false, italic: Bool = false) throws -> Pixels {
        let glyph = try #require(atlas.glyph(text: text, width: width, bold: bold, italic: italic))
        let texture = atlas.textures[glyph.page]
        let pixelWidth = Int(glyph.size.x), pixelHeight = Int(glyph.size.y)
        let region = MTLRegionMake2D(Int((glyph.uv.x * Float(texture.width)).rounded()),
                                     Int((glyph.uv.y * Float(texture.height)).rounded()), pixelWidth, pixelHeight)
        var bytes = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        bytes.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: pixelWidth * 4, from: region, mipmapLevel: 0)
        }
        return Pixels(bytes: bytes, width: pixelWidth, height: pixelHeight, isColor: glyph.isColor)
    }
}
