import Foundation
import Testing
import CoreGraphics
import ImageIO
@testable import TerminalCore

@Suite @MainActor struct TerminalCoreTests {
    @Test func splitUTF8AndWideCombiningCharacters() {
        let engine = SwiftTermEngine(columns: 12, rows: 3)
        for byte in "A日e\u{301}🙂Z".utf8 { engine.feed(Data([byte])) }
        let screen = engine.snapshot()
        #expect(screen[0, 0].text == "A")
        #expect(screen[1, 0].text == "日")
        #expect(screen[1, 0].width == 2)
        #expect(screen[2, 0].width == 0)
        #expect(screen[3, 0].text == "e\u{301}")
        #expect(screen[4, 0].text == "🙂")
        #expect(screen[4, 0].width == 2)
        #expect(screen[6, 0].text == "Z")
    }

    @Test(arguments: [false, true])
    func wideJapaneseContinuationUsesTheSameThemeOnBothHalves(light: Bool) {
        let engine = SwiftTermEngine(columns: 12, rows: 3)
        let foreground = light ? TerminalColor(red: 20, green: 23, blue: 28) : .foreground
        let background = light ? TerminalColor(red: 245, green: 245, blue: 245) : .background
        engine.setColors(foreground: foreground, background: background, palette: Array(repeating: foreground, count: 16))
        // Japanese letters and ideographic space all use a two-cell glyph. Every UTF-8
        // boundary can arrive in another packet without changing the continuation style.
        for byte in "日\u{3000}本".utf8 { engine.feed(Data([byte])) }
        let screen = engine.snapshot()
        for column in stride(from: 0, to: 6, by: 2) {
            let lead = screen[column, 0]
            #expect(lead.width == 2)
            #expect(lead.foreground == foreground)
            #expect(lead.background == background)
            #expect(screen[column + 1, 0] == continuation(of: lead))
        }
        #expect(screen[2, 0].text == "\u{3000}")
        #expect(screen[6, 0].width == 1)
        #expect(screen[6, 0].background == background)
    }

    @Test(arguments: [false, true])
    func wideContinuationPreservesTruecolorInverseAndEveryVisualStyle(inverse: Bool) {
        let engine = SwiftTermEngine(columns: 12, rows: 3)
        let foreground = TerminalColor(red: 17, green: 34, blue: 51)
        let background = TerminalColor(red: 68, green: 85, blue: 102)
        let underline = TerminalColor(red: 119, green: 136, blue: 153)
        let sgr = "\u{1b}[1;2;3;5;8;9;4:3;38;2;17;34;51;48;2;68;85;102;58;2;119;136;153m"
            + (inverse ? "\u{1b}[7m" : "")
        for byte in (sgr + "日\u{3000}").utf8 { engine.feed(Data([byte])) }
        engine.feed(Data("\u{1b}[0;38;2;201;202;203;48;2;204;205;206mX".utf8))
        let screen = engine.snapshot()
        for column in [0, 2] {
            let lead = screen[column, 0]
            #expect(lead.foreground == (inverse ? background : foreground))
            #expect(lead.background == (inverse ? foreground : background))
            #expect(lead.attributes.contains([.bold, .dim, .italic, .blink, .invisible, .strikethrough, .underline]))
            #expect(lead.attributes.contains(.inverse) == inverse)
            #expect(lead.underlineStyle == .curly)
            #expect(lead.underlineColor == underline)
            #expect(screen[column + 1, 0] == continuation(of: lead))
        }
        // A following ordinary cell retains its own style instead of inheriting a wide glyph's.
        #expect(screen[4, 0].text == "X")
        #expect(screen[4, 0].width == 1)
        #expect(screen[4, 0].foreground == TerminalColor(red: 201, green: 202, blue: 203))
        #expect(screen[4, 0].background == TerminalColor(red: 204, green: 205, blue: 206))
        #expect(screen[4, 0].attributes.isEmpty)
        #expect(screen[4, 0].underlineColor == nil)
    }

    private func continuation(of lead: TerminalCell) -> TerminalCell {
        TerminalCell(text: " ", width: 0, foreground: lead.foreground, background: lead.background,
                     attributes: lead.attributes, underlineStyle: lead.underlineStyle, underlineColor: lead.underlineColor)
    }

    @Test func longJapaneseOutputKeepsWideCellsAcrossPacketsAndReflow() {
        let engine = SwiftTermEngine(columns: 33, rows: 40)
        let japanese = "日本語の出力確認" + String((0..<384).compactMap { UnicodeScalar(0x4E00 + $0) }.map(Character.init))
        let bytes = Array(japanese.utf8)
        var offset = 0
        while offset < bytes.count {
            let end = min(bytes.count, offset + offset % 19 + 1)
            engine.feed(Data(bytes[offset..<end]))
            offset = end
        }
        func check(_ screen: TerminalSnapshot) {
            let visible = screen.cells.filter { $0.width > 0 && $0.text != " " }.map(\.text).joined()
            #expect(visible == japanese)
            for row in 0..<screen.rows {
                for column in 0..<screen.columns where screen[column, row].text != " " {
                    let cell = screen[column, row]
                    #expect(cell.width == 2)
                    #expect(column + 1 < screen.columns)
                    if column + 1 < screen.columns {
                        #expect(screen[column + 1, row].width == 0)
                        #expect(screen[column + 1, row].text == " ")
                        #expect(screen[column + 1, row] == continuation(of: cell))
                    }
                }
            }
        }
        check(engine.snapshot())
        // Complete this paragraph before resizing: SwiftTerm intentionally leaves the
        // cursor's active paragraph for the remote application to redraw on SIGWINCH.
        engine.feed(Data("\r\n".utf8))
        engine.resize(columns: 25, rows: 40)
        check(engine.snapshot())
    }

    @Test func cursorEraseAndAlternateScreen() {
        let engine = SwiftTermEngine(columns: 12, rows: 3)
        engine.feed(Data("hello\u{1b}[2;3Hworld\u{1b}[?25l".utf8))
        var screen = engine.snapshot()
        #expect(screen[2, 1].text == "w")
        #expect(screen.cursor.visible == false)
        engine.feed(Data("\u{1b}[?1049h\u{1b}[HALT".utf8))
        #expect(engine.snapshot()[0, 0].text == "A")
        engine.feed(Data("\u{1b}[?1049l\u{1b}[1;1H\u{1b}[2K".utf8))
        screen = engine.snapshot()
        #expect(screen[0, 0].text == " ")
        #expect(screen[2, 1].text == "w")
    }

    @Test func colorsStylesAndPaletteChanges() {
        let engine = SwiftTermEngine(columns: 12, rows: 3)
        engine.feed(Data("\u{1b}[38;2;10;20;30m\u{1b}[48;5;196m\u{1b}[1;3;4mX".utf8))
        let cell = engine.snapshot()[0, 0]
        #expect(cell.foreground == TerminalColor(red: 10, green: 20, blue: 30))
        #expect(cell.background == TerminalColor(red: 255, green: 0, blue: 0))
        #expect(cell.attributes.contains([.bold, .italic, .underline]))
        engine.feed(Data("\u{1b}]4;1;#123456\u{1b}\\\u{1b}[0;31mY".utf8))
        #expect(engine.snapshot()[1, 0].foreground == TerminalColor(red: 18, green: 52, blue: 86))
    }

    @Test func deviceResponseAndInputModes() {
        let engine = SwiftTermEngine(columns: 12, rows: 3)
        var output = Data()
        engine.onOutput = { output.append($0) }
        engine.feed(Data("\u{1b}[2;4H\u{1b}[6n".utf8))
        #expect(String(decoding: output, as: UTF8.self) == "\u{1b}[2;4R")
        output.removeAll()
        engine.feed(Data("\u{1b}[?1h\u{1b}[?2004h".utf8))
        engine.sendKey(.up)
        engine.paste("a\u{1b}[201~b")
        #expect(String(decoding: output, as: UTF8.self) == "\u{1b}OA\u{1b}[200~a[201~b\u{1b}[201~")
    }

    @Test func scrollbackSelectionReflowAndDamage() {
        let engine = SwiftTermEngine(columns: 8, rows: 3, scrollback: 10)
        engine.feed(Data("one\r\ntwo\r\nthree\r\nfour".utf8))
        #expect(engine.snapshot().scrollbackCount == 1)
        engine.scroll(by: 1)
        #expect(engine.snapshot()[0, 0].text == "o")
        #expect(engine.text(in: TerminalSelection(start: .init(column: 0, row: 0), end: .init(column: 3, row: 1))) == "one\ntwo")
        #expect(engine.snapshot().damageRows.isEmpty)
        engine.scrollToBottom()
        engine.resize(columns: 4, rows: 4)
        let screen = engine.snapshot()
        #expect(screen.columns == 4)
        #expect(screen.cells.count == 16)
        #expect(!screen.damageRows.isEmpty)
        #expect(engine.text(in: TerminalSelection(start: .init(column: 0, row: 0), end: .init(column: 4, row: 3))).contains("three"))
    }

    private func kitty(_ control: String, _ payload: Data = Data()) -> Data {
        Data("\u{1b}_G\(control);\(payload.base64EncodedString())\u{1b}\\".utf8)
    }

    @Test func kittySplitTransferPlacementScrollAndDeletion() {
        let engine = SwiftTermEngine(columns: 12, rows: 3)
        let first = kitty("a=T,f=32,s=2,v=1,i=7,c=2,r=1,C=1,m=1", Data([255, 0, 0, 255]))
        for byte in first { engine.feed(Data([byte])) }
        #expect(engine.snapshot().images.isEmpty)
        engine.feed(kitty("m=0", Data([0, 255, 0, 255])))
        var screen = engine.snapshot()
        #expect(screen.images.count == 1)
        #expect(screen.images.first?.rgba == Data([255, 0, 0, 255, 0, 255, 0, 255]))
        engine.feed(Data("\r\n1\r\n2\r\n3".utf8))
        #expect(engine.snapshot().images.isEmpty)
        engine.scroll(by: 1)
        screen = engine.snapshot()
        #expect(screen.images.first?.row == 0)
        engine.feed(kitty("a=d,d=I,i=7"))
        #expect(engine.snapshot().images.isEmpty)
        engine.feed(kitty("a=p,i=7"))
        #expect(engine.snapshot().images.isEmpty)
    }

    @Test func kittyTransferAndCacheBounds() {
        let engine = SwiftTermEngine(columns: 12, rows: 3,
                                    imageLimits: .init(maximumImageBytes: 8, maximumTotalBytes: 8, maximumImages: 2))
        var output = Data()
        engine.onOutput = { output.append($0) }
        engine.feed(kitty("a=T,f=32,s=10000,v=10000,i=9", Data([0, 0, 0, 255])))
        #expect(engine.snapshot().images.isEmpty)
        #expect(String(decoding: output, as: UTF8.self).contains("EINVAL"))
        for id in 1...3 { engine.feed(kitty("a=T,f=32,s=1,v=1,i=\(id),C=1", Data([0, 0, 0, 255]))) }
        #expect(Set(engine.snapshot().images.map(\.id)) == [2, 3])
        engine.feed(kitty("a=T,f=32,s=3,v=1,i=5,m=1", Data([0, 0, 0, 255, 0, 0, 0, 255])))
        engine.feed(kitty("m=0", Data([0, 0, 0, 255])))
        #expect(!engine.snapshot().images.contains { $0.id == 5 })
        engine.feed(Data(("\u{1b}_G" + String(repeating: "x", count: 20_000) + "\u{1b}\\OK").utf8))
        #expect(engine.snapshot()[0, 0].text == "O")
    }

    @Test func kittyRejectsFilesystemAndRelativeRequests() {
        let engine = SwiftTermEngine(columns: 12, rows: 3)
        var output = Data()
        engine.onOutput = { output.append($0) }
        engine.feed(kitty("a=T,t=f,f=100,i=1", Data("/etc/passwd".utf8)))
        engine.feed(kitty("a=T,P=1,f=32,s=1,v=1,i=2", Data([0, 0, 0, 255])))
        #expect(engine.snapshot().images.isEmpty)
        #expect(String(decoding: output, as: UTF8.self).components(separatedBy: "ENOTSUP").count == 3)
    }

    @Test func kittyUnicodePlaceholdersFollowTextAndInheritance() {
        let engine = SwiftTermEngine(columns: 12, rows: 3)
        engine.setCellSize(width: 10, height: 10)
        engine.feed(kitty("a=T,U=1,f=32,s=2,v=1,i=42,p=5,c=2,r=1,q=2", Data([255, 0, 0, 255, 0, 255, 0, 255])))
        #expect(engine.snapshot().images.isEmpty)
        engine.feed(Data("\u{1b}[38;5;42m\u{1b}[58;5;5m\u{10EEEE}\u{305}\u{10EEEE}".utf8))
        var screen = engine.snapshot()
        #expect(screen.images.count == 2)
        #expect(screen.images.first?.sourceWidth == 0.5)
        #expect(screen.images.last?.sourceX == 0.5)
        #expect(screen[0, 0].text == " ")
        engine.feed(kitty("a=d,d=a"))
        #expect(engine.snapshot().images.count == 2)
        engine.feed(Data("\u{1b}[1;1H ".utf8))
        screen = engine.snapshot()
        #expect(screen.images.count == 1)
        #expect(screen.images.first?.column == 1)
        engine.resize(columns: 10, rows: 3)
        #expect(engine.snapshot().images.count == 1)
        engine.feed(kitty("a=d,d=I,i=42"))
        #expect(engine.snapshot().images.isEmpty)
    }

    @Test func kittyHighImageIDAndExplicitClippedCells() {
        let engine = SwiftTermEngine(columns: 12, rows: 3)
        engine.setCellSize(width: 10, height: 10)
        engine.feed(kitty("a=T,U=1,f=32,s=2,v=1,i=33554474,c=2,r=1", Data([255, 0, 0, 255, 0, 255, 0, 255])))
        engine.feed(Data("\u{1b}[38;5;42m\u{10EEEE}\u{305}\u{305}\u{30e}\u{10EEEE}\u{305}\u{30d}".utf8))
        #expect(engine.snapshot().images.map(\.id) == [33554474, 33554474])
    }

    @Test func kittyPNGOrientationAndRGB() throws {
        let pixels = Data([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255])
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let cgImage = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let png = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, nil)
        #expect(CGImageDestinationFinalize(destination))
        let engine = SwiftTermEngine(columns: 12, rows: 3)
        engine.feed(kitty("a=T,f=100,i=1,C=1", png as Data))
        #expect(Array(engine.snapshot().images.first?.rgba ?? Data()) == Array(pixels))
        engine.feed(kitty("a=T,f=24,s=1,v=1,i=2,C=1", Data([3, 7, 11])))
        #expect(engine.snapshot().images.last?.rgba == Data([3, 7, 11, 255]))
    }

    @Test func kittyFramingCannotBypassTransportRestrictions() {
        let engine = SwiftTermEngine(columns: 12, rows: 3)
        var output = Data()
        engine.onOutput = { output.append($0) }
        engine.feed(Data("\u{1b}]0;unfinished".utf8))
        engine.feed(kitty("a=T,t=f,f=100,i=1", Data("/etc/passwd".utf8)))
        engine.feed(Data([0x9f]) + Data("Ga=T,t=f,f=100,i=2;L2V0Yy9wYXNzd2Q=".utf8) + Data([0x9c]))
        #expect(String(decoding: output, as: UTF8.self).components(separatedBy: "ENOTSUP").count == 3)
        #expect(engine.snapshot().images.isEmpty)
        engine.feed(kitty("a=T,f=32,s=1,v=1,i=3,C=1", Data([0, 0, 0, 255])))
        #expect(engine.snapshot().images.count == 1)
        engine.feed(Data("\u{1b}c".utf8))
        #expect(engine.snapshot().images.isEmpty)
    }

    @Test func kittyImagesScrollAndClipWithinAlternateScreen() {
        let engine = SwiftTermEngine(columns: 12, rows: 3)
        engine.feed(Data("\u{1b}[?1049h\u{1b}[2;1H".utf8))
        engine.feed(kitty("a=T,f=32,s=1,v=2,i=1,c=1,r=2,C=1", Data([255, 0, 0, 255, 0, 255, 0, 255])))
        engine.feed(Data("\u{1b}[3;1H\n".utf8))
        #expect(engine.snapshot().images.first?.row == 0)
        engine.feed(Data("\n".utf8))
        let image = engine.snapshot().images.first
        #expect(image?.rows == 2)
        #expect(image?.row == -1) // Viewport clips the first image row.
        engine.feed(Data("\n".utf8))
        #expect(engine.snapshot().images.isEmpty)
    }

    @Test func kittyPartialScrollRegionClipsImage() {
        let engine = SwiftTermEngine(columns: 12, rows: 4)
        engine.feed(Data("\u{1b}[2;3r\u{1b}[2;1H".utf8))
        engine.feed(kitty("a=T,f=32,s=1,v=2,i=1,c=1,r=2,C=1", Data([255, 0, 0, 255, 0, 255, 0, 255])))
        engine.feed(Data("\u{1b}[3;1H\n".utf8))
        let image = engine.snapshot().images.first
        #expect(image?.row == 1)
        #expect(image?.rows == 1)
        #expect(image?.sourceY == 0.5)
        engine.feed(Data("\n".utf8))
        #expect(engine.snapshot().images.isEmpty)
    }

    @Test func resetRestoresConfiguredThemeAndCursor() {
        let engine = SwiftTermEngine(columns: 12, rows: 3)
        let foreground = TerminalColor(red: 1, green: 2, blue: 3)
        let background = TerminalColor(red: 4, green: 5, blue: 6)
        let palette = (0..<16).map { TerminalColor(red: UInt8($0), green: 7, blue: 8) }
        engine.setColors(foreground: foreground, background: background, palette: palette)
        engine.feed(Data("\u{1b}]4;1;#ffffff\u{1b}\\\u{1b}]10;#abcdef\u{1b}\\\u{1b}[6 q\u{1b}[?25l".utf8))
        engine.reset()
        engine.feed(Data("\u{1b}[31mA".utf8))
        let screen = engine.snapshot()
        #expect(screen.defaultForeground == foreground)
        #expect(screen.defaultBackground == background)
        #expect(screen[0, 0].foreground == palette[1])
        #expect(screen.cursor.visible)
        #expect(screen.cursor.style == .block)
        #expect(screen.cursor.blinking)
    }

    @Test(arguments: [false, true]) func defaultCellColorsRespectThemeAndInverse(light: Bool) {
        let engine = SwiftTermEngine(columns: 12, rows: 3)
        let dark = TerminalColor(red: 17, green: 21, blue: 28)
        let pale = TerminalColor(red: 220, green: 226, blue: 235)
        let foreground = light ? dark : pale, background = light ? pale : dark
        let palette = (0..<16).map { TerminalColor(red: UInt8($0), green: 7, blue: 8) }
        engine.setColors(foreground: foreground, background: background, palette: palette)
        #expect(engine.snapshot().cells.allSatisfy { $0.foreground == foreground && $0.background == background })
        engine.feed(Data("A\u{1b}[7mB\u{1b}[27mC\u{1b}[31;7mD\u{1b}[0mE".utf8))
        var screen = engine.snapshot()
        #expect(screen[0, 0].foreground == foreground)
        #expect(screen[0, 0].background == background)
        #expect(screen[1, 0].foreground == background)
        #expect(screen[1, 0].background == foreground)
        #expect(screen[2, 0].foreground == foreground)
        #expect(screen[2, 0].background == background)
        #expect(screen[3, 0].foreground == background)
        #expect(screen[3, 0].background == palette[1])
        #expect(screen[4, 0].background == background)
        engine.feed(Data("\u{1b}[38;2;1;2;3;48;2;4;5;6mF\u{1b}[39;49mG\u{1b}[2J".utf8))
        screen = engine.snapshot()
        #expect(screen.cells.allSatisfy { $0.background == background })
        engine.resize(columns: 14, rows: 4)
        #expect(engine.snapshot().cells.allSatisfy { $0.background == background })
    }

    @Test func OSCDefaultColorsUpdateBlankNormalAndInverseCells() {
        let engine = SwiftTermEngine(columns: 12, rows: 3)
        engine.feed(Data("A\u{1b}[7mB\u{1b}[0m\u{1b}]10;#123456\u{1b}\\\u{1b}]11;#abcdef\u{1b}\\".utf8))
        let foreground = TerminalColor(red: 18, green: 52, blue: 86)
        let background = TerminalColor(red: 171, green: 205, blue: 239)
        let screen = engine.snapshot()
        #expect(screen[0, 0].foreground == foreground)
        #expect(screen[0, 0].background == background)
        #expect(screen[1, 0].foreground == background)
        #expect(screen[1, 0].background == foreground)
        #expect(screen[11, 2].foreground == foreground)
        #expect(screen[11, 2].background == background)
    }

    @Test func unsupportedKeyboardNegotiationAndSynchronizedOutput() {
        let engine = SwiftTermEngine(columns: 12, rows: 3)
        var output = Data()
        var invalidations = 0
        engine.onOutput = { output.append($0) }
        engine.onNeedsDisplay = { invalidations += 1 }
        engine.feed(Data("\u{1b}[?u".utf8))
        #expect(output.isEmpty)
        invalidations = 0
        engine.feed(Data("\u{1b}[?2026hHELLO".utf8))
        #expect(invalidations == 0)
        engine.feed(Data("\u{1b}[?2026l".utf8))
        #expect(invalidations == 1)
        #expect(engine.snapshot()[0, 0].text == "H")
    }
}
