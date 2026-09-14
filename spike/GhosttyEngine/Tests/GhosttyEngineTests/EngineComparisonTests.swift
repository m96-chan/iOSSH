import Compression
import CoreGraphics
import Foundation
import GhosttyEngine
import ImageIO
import TerminalCore
import Testing

/// #10 stage 2: the same bytes through both engines, comparing the grid they produce and how
/// long they take to produce it. Differences are reported per cell rather than as one failed
/// equality, because what matters is which constructs disagree.
@TerminalParserActor
struct EngineComparisonTests {
    private struct Case {
        let name: String
        let input: String
        let columns: Int
        let rows: Int
    }

    private let cases: [Case] = [
        .init(name: "plain text", input: "hello world", columns: 20, rows: 3),
        .init(name: "wrapping", input: String(repeating: "abcdefghij", count: 5), columns: 20, rows: 4),
        .init(name: "truecolor", input: "\u{1b}[38;2;10;200;30m\u{1b}[48;2;1;2;3mcolored\u{1b}[0m plain", columns: 20, rows: 2),
        .init(name: "palette", input: "\u{1b}[31mred\u{1b}[42mgreen-bg\u{1b}[0m", columns: 20, rows: 2),
        .init(name: "attributes", input: "\u{1b}[1mbold\u{1b}[0m \u{1b}[3mital\u{1b}[0m \u{1b}[4munder\u{1b}[0m \u{1b}[7minv\u{1b}[0m", columns: 30, rows: 2),
        .init(name: "japanese", input: "日本語とascii", columns: 20, rows: 2),
        // macOS normalizes filenames to NFD, so a listing from one arrives decomposed: the
        // dakuten is a separate combining codepoint rather than part of the character (#21).
        .init(name: "decomposed japanese", input: "\u{304B}\u{3099}\u{30AB}\u{3099}", columns: 20, rows: 2),
        .init(name: "cursor moves", input: "\u{1b}[2;5Hplaced\u{1b}[1;1Htop", columns: 20, rows: 3),
        .init(name: "erase", input: "dirty\u{1b}[2J\u{1b}[Hclean", columns: 20, rows: 3),
        .init(name: "half blocks", input: "\u{1b}[38;2;255;0;0m\u{1b}[48;2;0;0;255m▀▀▀", columns: 10, rows: 2)
    ]

    @Test func bothEnginesAgreeOnTheGrid() throws {
        var report: [String] = []
        for scenario in cases {
            let swiftTerm = SwiftTermEngine(columns: scenario.columns, rows: scenario.rows)
            let ghostty = try #require(GhosttyEngine(columns: scenario.columns, rows: scenario.rows))
            var palette: [TerminalColor] = []
            for index in 0..<16 {
                palette.append(TerminalColor(red: UInt8(index * 16), green: UInt8(index * 8), blue: UInt8(index * 4)))
            }
            swiftTerm.setColors(foreground: .foreground, background: .background, palette: palette)
            ghostty.setColors(foreground: .foreground, background: .background, palette: palette)
            swiftTerm.feed(Data(scenario.input.utf8))
            ghostty.feed(Data(scenario.input.utf8))

            let expected = swiftTerm.snapshot()
            let actual = ghostty.snapshot()
            var text = 0, foreground = 0, background = 0, attributes = 0, width = 0
            for index in 0..<min(expected.cells.count, actual.cells.count) {
                let left = expected.cells[index], right = actual.cells[index]
                if left.text.trimmingCharacters(in: .whitespaces) != right.text.trimmingCharacters(in: .whitespaces) { text += 1 }
                if left.foreground != right.foreground { foreground += 1 }
                if left.background != right.background { background += 1 }
                if left.attributes != right.attributes { attributes += 1 }
                if left.width != right.width { width += 1 }
            }
            let cursor = expected.cursor == actual.cursor ? "same" : "differs"
            let line = "\(scenario.name): cells=\(expected.cells.count) text=\(text) fg=\(foreground)"
                + " bg=\(background) attr=\(attributes) width=\(width) cursor=\(cursor)"
            report.append(line)
        }
        print("COMPARISON\n" + report.joined(separator: "\n"))
    }

    /// #21: Japanese from a macOS host arrives decomposed. Dropping the combining codepoint
    /// turns が into か, which reads as the text being garbled.
    @Test func decomposedJapaneseKeepsItsCombiningMark() throws {
        for engine in [SwiftTermEngine(columns: 20, rows: 2) as any TerminalEngine,
                       try #require(GhosttyEngine(columns: 20, rows: 2))] {
            engine.feed(Data("\u{304B}\u{3099}".utf8))
            let cell = engine.snapshot().cells[0]
            #expect(cell.text == "\u{304B}\u{3099}", "\(type(of: engine)) produced \(cell.text.unicodeScalars.map { String($0.value, radix: 16) })")
        }
    }

    /// #21 also asked whether a multibyte character survives being split across chunks, which
    /// is the ordinary case over SSH: the boundary falls wherever the network put it.
    @Test func japaneseSplitAcrossChunksIsNotLost() throws {
        let bytes = Array("日本語".utf8)
        for engine in [SwiftTermEngine(columns: 20, rows: 2) as any TerminalEngine,
                       try #require(GhosttyEngine(columns: 20, rows: 2))] {
            for byte in bytes { engine.feed(Data([byte])) }
            let cells = engine.snapshot().cells
            #expect(cells[0].text == "日", "\(type(of: engine)) produced \(cells[0].text)")
            #expect(cells[2].text == "本", "\(type(of: engine)) produced \(cells[2].text)")
            #expect(cells[4].text == "語", "\(type(of: engine)) produced \(cells[4].text)")
        }
    }

    @Test func throughputOfBothEngines() throws {
        let columns = 105, rows = 95
        var frame = ""
        for row in 0..<rows {
            frame += "\u{1b}[\(row + 1);1H"
            for column in 0..<columns {
                frame += "\u{1b}[38;2;\((row * 7 + column * 3) % 256);\((row * 11) % 256);\((column * 13) % 256)m"
                frame += "\u{1b}[48;2;\((column * 5) % 256);\((row * 3) % 256);\((row + column) % 256)m▀"
            }
        }
        let data = Data(frame.utf8)

        func measure(_ body: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        }

        let swiftTerm = SwiftTermEngine(columns: columns, rows: rows)
        let ghostty = try #require(GhosttyEngine(columns: columns, rows: rows))
        swiftTerm.feed(data); _ = swiftTerm.snapshot()
        ghostty.feed(data); _ = ghostty.snapshot()

        var swiftFeed = 0.0, swiftSnapshot = 0.0, ghosttyFeed = 0.0, ghosttySnapshot = 0.0
        for _ in 0..<20 {
            swiftFeed += measure { swiftTerm.feed(data) }
            swiftSnapshot += measure { _ = swiftTerm.snapshot() }
            ghosttyFeed += measure { ghostty.feed(data) }
            ghosttySnapshot += measure { _ = ghostty.snapshot() }
        }
        print(String(format: "THROUGHPUT bytes=%d\n  SwiftTerm feed=%.2fms snapshot=%.2fms\n  Ghostty   feed=%.2fms snapshot=%.2fms",
                     data.count, swiftFeed / 20, swiftSnapshot / 20, ghosttyFeed / 20, ghosttySnapshot / 20))
    }
}

/// The engine has to answer the questions a program asks before it draws. Nothing did until a
/// device crash traced back to how the callbacks were installed, so this pins the behaviour.
@TerminalParserActor
struct GhosttyQueryTests {
    @Test func queriesAreAnswered() throws {
        let engine = try #require(GhosttyEngine(columns: 80, rows: 24))
        engine.setCellSize(width: 14, height: 31)
        var replies = Data()
        engine.onOutput = { replies.append($0) }
        engine.feed(Data("\u{1b}[16t".utf8))   // cell size in pixels
        engine.feed(Data("\u{1b}[c".utf8))     // primary device attributes
        let text = String(decoding: replies, as: UTF8.self)
        #expect(text.contains("6;31;14t"))
        #expect(text.contains("\u{1b}[?"))
    }
}

/// #18: a Kitty image that arrives compressed, as PNG, or placed through Unicode
/// placeholders drew nothing at all under the trial engine, with no sign that anything had
/// been dropped. These compare what each engine hands the renderer for the same bytes,
/// because the Settings picker makes that difference a user-visible one.
@TerminalParserActor
struct KittyGraphicsParityTests {
    /// The renderer only looks at these, so this is what "both engines drew the same thing"
    /// means. `contentRevision` is deliberately absent: it is each engine's own counter.
    private struct Drawn: Equatable, CustomStringConvertible {
        let id, placementID: UInt32
        let column, row, columns, rows, zIndex, pixelWidth, pixelHeight: Int
        let source: [Int], fraction: [Int]
        let rgba: Data
        init(_ placement: TerminalImagePlacement) {
            id = placement.id; placementID = placement.placementID
            column = placement.column; row = placement.row
            columns = placement.columns; rows = placement.rows; zIndex = placement.zIndex
            pixelWidth = placement.pixelWidth; pixelHeight = placement.pixelHeight
            // Rounded to a thousandth: the two engines reach the same texture coordinates by
            // the same arithmetic, but comparing binary doubles would pin more than that.
            source = [placement.sourceX, placement.sourceY, placement.sourceWidth, placement.sourceHeight].map { Int(($0 * 1000).rounded()) }
            fraction = [placement.widthFraction, placement.heightFraction].map { Int(($0 * 1000).rounded()) }
            rgba = placement.rgba
        }
        var description: String {
            "id=\(id)/\(placementID) at \(column),\(row) \(columns)x\(rows) z=\(zIndex)"
                + " px=\(pixelWidth)x\(pixelHeight) src=\(source) frac=\(fraction) bytes=\(rgba.count)"
        }

        /// A placement id the program did not choose is the engine's own counter — SwiftTerm's
        /// store hands out the next number in its sequence, libghostty-vt leaves it zero — and
        /// nothing is drawn differently for it. Tests that care about a chosen id assert on it
        /// directly.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.column == rhs.column && lhs.row == rhs.row
                && lhs.columns == rhs.columns && lhs.rows == rhs.rows && lhs.zIndex == rhs.zIndex
                && lhs.pixelWidth == rhs.pixelWidth && lhs.pixelHeight == rhs.pixelHeight
                && lhs.source == rhs.source && lhs.fraction == rhs.fraction && lhs.rgba == rhs.rgba
        }
    }

    /// A zlib stream: the two-byte header, raw deflate, and the Adler-32 of the input. This
    /// is what a sender puts on the wire for `o=z`, so the test has to produce a real one
    /// rather than assert against a mock.
    private func zlib(_ data: Data) -> Data {
        var destination = [UInt8](repeating: 0, count: data.count * 2 + 128)
        let written = data.withUnsafeBytes { source in
            compression_encode_buffer(&destination, destination.count,
                                      source.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                      nil, COMPRESSION_ZLIB)
        }
        var stream = Data([0x78, 0x01])
        stream.append(contentsOf: destination[0..<written])
        var low: UInt32 = 1, high: UInt32 = 0
        for byte in data { low = (low &+ UInt32(byte)) % 65521; high = (high &+ low) % 65521 }
        let adler = (high << 16) | low
        stream.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: adler >> (24 - 8 * $0)) })
        return stream
    }

    private func png(width: Int, height: Int) -> Data {
        var pixels = Data(count: width * height * 4)
        for index in 0..<(width * height) {
            pixels[index * 4] = UInt8(index * 7 % 256); pixels[index * 4 + 1] = UInt8(index * 3 % 256)
            pixels[index * 4 + 2] = 40; pixels[index * 4 + 3] = 255
        }
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: CGDataProvider(data: pixels as CFData)!, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return encoded as Data
    }

    private func engines() throws -> [(name: String, engine: any TerminalEngine)] {
        let swiftTerm = SwiftTermEngine(columns: 20, rows: 6)
        let ghostty = try #require(GhosttyEngine(columns: 20, rows: 6))
        for engine in [swiftTerm as any TerminalEngine, ghostty] { engine.setCellSize(width: 10, height: 20) }
        return [("SwiftTermEngine", swiftTerm), ("GhosttyEngine", ghostty)]
    }

    private func drawn(_ engine: any TerminalEngine, _ transfers: [String]) -> [Drawn] {
        for transfer in transfers { engine.feed(Data(transfer.utf8)) }
        return engine.snapshot().images.map(Drawn.init).sorted { ($0.row, $0.column) < ($1.row, $1.column) }
    }

    /// A `o=z` payload is what a sender uses once the image is big enough to be worth
    /// compressing, which is when it is most worth showing.
    @Test func bothEnginesDrawACompressedTransfer() throws {
        let rgb = Data((0..<(6 * 5 * 3)).map { UInt8($0 % 251) })
        var expected: [Drawn] = []
        for (name, engine) in try engines() {
            let images = drawn(engine, ["\u{1b}_Gi=1,f=24,s=6,v=5,o=z,a=T,C=1,q=2;\(zlib(rgb).base64EncodedString())\u{1b}\\"])
            #expect(images.count == 1, "\(name) drew \(images.count) placements for a compressed transfer")
            guard let image = images.first else { continue }
            #expect(image.pixelWidth == 6 && image.pixelHeight == 5, "\(name): \(image)")
            // The pixels have to be the ones that were sent, not merely some pixels: an
            // engine that inflated wrongly would still produce a placement.
            #expect(image.rgba.count == 6 * 5 * 4, "\(name): \(image)")
            for index in 0..<(6 * 5) {
                #expect(Array(image.rgba[(index * 4)..<(index * 4 + 4)])
                        == [rgb[index * 3], rgb[index * 3 + 1], rgb[index * 3 + 2], 255],
                        "\(name) inflated pixel \(index) wrongly")
            }
            expected.append(image)
        }
        #expect(expected.count == 2 && expected[0] == expected[1],
                "engines disagree: \(expected.map(\.description))")
    }

    /// The same pixels sent uncompressed have to arrive as the same pixels. This is the
    /// comparison that showed the compression guard in `rgba(for:image:)` was never what
    /// stopped a compressed image from drawing: libghostty-vt inflates before storage.
    @Test func compressionDoesNotChangeWhatIsDrawn() throws {
        let rgb = Data((0..<(6 * 5 * 3)).map { UInt8($0 % 251) })
        for (name, engine) in try engines() {
            let plain = drawn(engine, ["\u{1b}_Gi=1,f=24,s=6,v=5,a=T,C=1,q=2;\(rgb.base64EncodedString())\u{1b}\\"])
            engine.reset()
            let compressed = drawn(engine, ["\u{1b}_Gi=1,f=24,s=6,v=5,o=z,a=T,C=1,q=2;\(zlib(rgb).base64EncodedString())\u{1b}\\"])
            #expect(plain.count == 1 && plain == compressed,
                    "\(name) drew \(plain.map(\.description)) uncompressed and \(compressed.map(\.description)) compressed")
        }
    }

    /// PNG is what a sender uses for anything it cannot describe as raw pixels, so it is most
    /// of what is actually transmitted. libghostty-vt has no decoder of its own and rejects
    /// the payload unless the engine installs one.
    @Test func bothEnginesDrawAPNGTransfer() throws {
        let encoded = png(width: 6, height: 5).base64EncodedString()
        var expected: [Drawn] = []
        for (name, engine) in try engines() {
            // 4096 bytes is the protocol's payload limit per packet, so a PNG of any size
            // arrives in chunks; this one is small but the path is the same.
            let images = drawn(engine, ["\u{1b}_Gi=1,f=100,a=T,C=1,q=2;\(encoded)\u{1b}\\"])
            #expect(images.count == 1, "\(name) drew \(images.count) placements for a PNG transfer")
            guard let image = images.first else { continue }
            #expect(image.pixelWidth == 6 && image.pixelHeight == 5, "\(name): \(image)")
            expected.append(image)
        }
        #expect(expected.count == 2 && expected[0] == expected[1],
                "engines disagree: \(expected.map(\.description))")
    }

    /// A virtual placement has no position of its own: the U+10EEEE cells are its position,
    /// and each one draws the single tile of the image its diacritics name. libghostty-vt
    /// reports no rectangle for these by contract, which is why the trial engine drew nothing.
    @Test func bothEnginesDrawUnicodePlaceholderPlacements() throws {
        let rgb = Data((0..<(20 * 40 * 3)).map { UInt8($0 % 251) })
        let marks = KittyDiacriticsForTests.values
        var cells = "\u{1b}[38;5;1m"
        for row in 0..<2 {
            for column in 0..<2 { cells += "\u{10EEEE}\(marks[row])\(marks[column])" }
            cells += "\r\n"
        }
        cells += "\u{1b}[0m"
        var expected: [[Drawn]] = []
        for (name, engine) in try engines() {
            let images = drawn(engine, ["\u{1b}_Gi=1,f=24,s=20,v=40,a=t,q=2;\(rgb.base64EncodedString())\u{1b}\\",
                                        "\u{1b}_Ga=p,i=1,p=9,U=1,c=2,r=2,q=2\u{1b}\\",
                                        cells])
            #expect(images.count == 4, "\(name) drew \(images.count) placeholder cells, expected 4: \(images.map(\.description))")
            #expect(images.map { [$0.column, $0.row] } == [[0, 0], [1, 0], [0, 1], [1, 1]], "\(name): \(images.map(\.description))")
            // Each cell shows its own tile, so the four source rectangles must differ, and
            // each must be one cell of the block wide and tall.
            #expect(Set(images.map(\.source)).count == 4, "\(name) drew the same tile in every cell: \(images.map(\.description))")
            #expect(images.allSatisfy { $0.columns == 1 && $0.rows == 1 }, "\(name): \(images.map(\.description))")
            // The placement id here was chosen by the program, so both engines must report it.
            #expect(images.allSatisfy { $0.placementID == 9 }, "\(name): \(images.map(\.description))")
            expected.append(images)
        }
        #expect(expected.count == 2 && expected[0] == expected[1],
                "engines disagree:\n  \(expected[0].map(\.description))\n  \(expected.last!.map(\.description))")
    }

    /// The placeholder run continues across cells that leave the diacritics off, which is how
    /// a sender writes a wide image without repeating itself. Dropping that continuation puts
    /// every cell of the row at image column zero.
    @Test func bothEnginesContinueAPlaceholderRunWithoutDiacritics() throws {
        let rgb = Data((0..<(30 * 20 * 3)).map { UInt8($0 % 251) })
        let marks = KittyDiacriticsForTests.values
        let cells = "\u{1b}[38;5;1m" + "\u{10EEEE}\(marks[0])\(marks[0])" + String(repeating: "\u{10EEEE}", count: 2) + "\u{1b}[0m"
        var expected: [[Drawn]] = []
        for (name, engine) in try engines() {
            let images = drawn(engine, ["\u{1b}_Gi=1,f=24,s=30,v=20,a=t,q=2;\(rgb.base64EncodedString())\u{1b}\\",
                                        "\u{1b}_Ga=p,i=1,p=3,U=1,c=3,r=1,q=2\u{1b}\\",
                                        cells])
            #expect(images.count == 3, "\(name) drew \(images.count) cells of a continued run: \(images.map(\.description))")
            #expect(Set(images.map(\.source)).count == 3, "\(name) did not advance the image column: \(images.map(\.description))")
            expected.append(images)
        }
        #expect(expected.count == 2 && expected[0] == expected[1],
                "engines disagree:\n  \(expected[0].map(\.description))\n  \(expected.last!.map(\.description))")
    }
}

/// The first few row/column diacritics of the Kitty placeholder encoding. `KittyDiacritics`
/// itself is internal to TerminalCore, and these tests only need to write a small block.
enum KittyDiacriticsForTests {
    static let values: [Character] = ["\u{0305}", "\u{030D}", "\u{030E}", "\u{0310}"]
}
