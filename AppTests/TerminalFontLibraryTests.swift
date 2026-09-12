import CoreText
import Foundation
import Testing
@testable import iOSSH
@testable import TerminalRender

@MainActor
struct TerminalFontLibraryTests {
    @Test
    func importOwnsTheFileAndRestoresSelectionAcrossLibraryReloads() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set("UDEVGothicNF-Regular", forKey: TerminalFontLibrary.selectionKey)
        let library = fixture.library()
        #expect(library.selectedFontName == TerminalFont.postScriptName)
        let source = try fixture.makeFont()
        let entry = try await library.importFont(from: source)
        defer { try? library.remove(entry) }
        let owned = fixture.directory.appendingPathComponent(entry.fileName)
        #expect(try Data(contentsOf: owned) == Data(contentsOf: source))
        #expect(library.selectedFontName == entry.postScriptName)
        #expect(library.font(ofSize: 14, selection: entry.postScriptName).fontName == entry.postScriptName)
        try FileManager.default.removeItem(at: source)

        let restored = fixture.library()
        #expect(restored.fonts == [entry])
        #expect(restored.selectedFontName == entry.postScriptName)
        #expect(restored.font(ofSize: 14, selection: entry.postScriptName).fontName == entry.postScriptName)
        try restored.remove(entry)
        #expect(restored.fonts.isEmpty)
        #expect(restored.selectedFontName == TerminalFont.postScriptName)
        #expect(fixture.defaults.string(forKey: TerminalFontLibrary.selectionKey) == TerminalFont.postScriptName)
        #expect(!FileManager.default.fileExists(atPath: owned.path))
        #expect(TerminalFont.font(ofSize: 14).fontName == TerminalFont.postScriptName)
    }

    @Test
    func removedFontCanBeImportedAgainWhileARendererRetainsItsUIFont() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let library = fixture.library()
        let source = try fixture.makeFont()
        let entry = try await library.importFont(from: source)
        let retainedFont = library.font(ofSize: 14, selection: entry.postScriptName)
        defer { withExtendedLifetime(retainedFont) {} }
        try library.remove(entry)
        #expect(library.selectedFontName == TerminalFont.postScriptName)
        #expect(retainedFont.fontName == entry.postScriptName)
        let reimported = try await library.importFont(from: source)
        defer { try? library.remove(reimported) }
        #expect(reimported.postScriptName == entry.postScriptName)
        #expect(library.selectedFontName == reimported.postScriptName)
    }

    @Test
    func corruptOrRemovedFontRestoresTheBundledDefault() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let library = fixture.library()
        let entry = try await library.importFont(from: fixture.makeFont())
        defer { try? library.remove(entry) }
        try Data("damaged font".utf8).write(to: fixture.directory.appendingPathComponent(entry.fileName))
        let restored = fixture.library()
        #expect(restored.fonts.isEmpty)
        #expect(restored.selectedFontName == TerminalFont.postScriptName)
        #expect(restored.loadWarning != nil)
        restored.select("no-such-font")
        #expect(restored.selectedFontName == TerminalFont.postScriptName)
    }

    @Test
    func rejectsMalformedUnsupportedAndOversizedFilesWithoutChangingSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let library = fixture.library()
        let broken = fixture.root.appendingPathComponent("broken.otf")
        try Data("not a font".utf8).write(to: broken)
        await #expect(throws: TerminalFontLibrary.ImportError.invalidFont) { try await library.importFont(from: broken) }
        await #expect(throws: TerminalFontLibrary.ImportError.unsupportedFile) {
            try await library.importFont(from: fixture.root.appendingPathComponent("fonts.zip"))
        }
        let large = fixture.root.appendingPathComponent("too-large.ttf")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(TerminalFontLibrary.maximumFileBytes + 1))
        try handle.close()
        await #expect(throws: TerminalFontLibrary.ImportError.tooLarge) { try await library.importFont(from: large) }
        #expect(library.fonts.isEmpty)
        #expect(library.selectedFontName == TerminalFont.postScriptName)
    }

    @Test
    func rejectsProportionalFontsAndCannotReplaceTheBundledFace() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let library = fixture.library()
        let proportional = try fixture.makeFont(proportional: true)
        await #expect(throws: TerminalFontLibrary.ImportError.notMonospaced) {
            try await library.importFont(from: proportional)
        }
        let bundled = try #require(TerminalFont.resourceURL(forStyle: "Regular"))
        await #expect(throws: TerminalFontLibrary.ImportError.alreadyAvailable) { try await library.importFont(from: bundled) }
        #expect(library.fonts.isEmpty)
        #expect(library.selectedFontName == TerminalFont.postScriptName)
        #expect(TerminalFont.font(ofSize: 14).fontName == TerminalFont.postScriptName)
    }

    /// Derive a temporary, uniquely named OFL fixture from the bundled real font. This
    /// exercises Core Graphics decoding/registration without adding another binary asset.
    /// Only name metadata changes, except the explicit proportional-font negative case.
    @MainActor private struct Fixture {
        let root: URL
        let defaults: UserDefaults
        let suite: String
        var directory: URL { root.appendingPathComponent("owned", isDirectory: true) }

        init() throws {
            suite = "iOSSH.FontTests.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suite))
            root = URL.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func library() -> TerminalFontLibrary { TerminalFontLibrary(directory: directory, defaults: defaults) }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        func makeFont(proportional: Bool = false) throws -> URL {
            let source = try #require(TerminalFont.resourceURL(forStyle: "Regular"))
            var data = try Data(contentsOf: source)
            func u16(_ offset: Int) -> Int { Int(data[offset]) << 8 | Int(data[offset + 1]) }
            func u32(_ offset: Int) -> UInt32 {
                UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
            }
            func write32(_ offset: Int, _ value: UInt32) {
                for n in 0..<4 { data[offset + n] = UInt8(truncatingIfNeeded: value >> ((3 - n) * 8)) }
            }
            func checksum(_ start: Int, _ length: Int) -> UInt32 {
                var sum: UInt32 = 0
                for offset in stride(from: start, to: start + ((length + 3) & ~3), by: 4) { sum &+= u32(offset) }
                return sum
            }
            var tables: [String: (record: Int, offset: Int, length: Int)] = [:]
            for index in 0..<u16(4) {
                let record = 12 + index * 16
                let tag = String(data: data[record..<(record + 4)], encoding: .ascii)!
                tables[tag] = (record, Int(u32(record + 8)), Int(u32(record + 12)))
            }
            let names = try #require(tables["name"])
            let replacement = "T" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6)
            let strings = names.offset + u16(names.offset + 4)
            for index in 0..<u16(names.offset + 2) {
                let record = names.offset + 6 + index * 12
                guard [1, 3, 4, 6, 16, 17].contains(u16(record + 6)) else { continue }
                let platform = u16(record)
                let encoding: String.Encoding = platform == 1 ? .macOSRoman : .utf16BigEndian
                let start = strings + u16(record + 10), length = u16(record + 8)
                if let value = String(data: data[start..<(start + length)], encoding: encoding),
                   let renamed = value.replacingOccurrences(of: "HackGen", with: replacement).data(using: encoding), renamed.count == length {
                    data.replaceSubrange(start..<(start + length), with: renamed)
                }
            }
            write32(names.record + 4, checksum(names.offset, names.length))
            if proportional {
                let metrics = try #require(tables["hmtx"])
                let font = TerminalFont.font(ofSize: 16)
                let ctFont = CTFontCreateWithName(font.fontName as CFString, 16, nil)
                var character: UniChar = 77, glyph: CGGlyph = 0
                #expect(CTFontGetGlyphsForCharacters(ctFont, &character, &glyph, 1))
                let advanceOffset = metrics.offset + Int(glyph) * 4
                let wider = u16(advanceOffset) + 400
                data[advanceOffset] = UInt8(truncatingIfNeeded: wider >> 8)
                data[advanceOffset + 1] = UInt8(truncatingIfNeeded: wider)
                write32(metrics.record + 4, checksum(metrics.offset, metrics.length))
            }
            let head = try #require(tables["head"])
            write32(head.offset + 8, 0)
            write32(head.offset + 8, 0xB1B0AFBA &- checksum(0, data.count))
            let output = root.appendingPathComponent("\(replacement).ttf")
            try data.write(to: output)
            return output
        }
    }
}
