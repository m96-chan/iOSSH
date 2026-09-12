import CoreText
import CryptoKit
import Foundation
import Observation
import TerminalRender
import UIKit

@MainActor @Observable
final class TerminalFontLibrary {
    struct ImportedFont: Codable, Identifiable, Equatable {
        let id: UUID
        let displayName: String
        let postScriptName: String
        let fileExtension: String

        var fileName: String { "\(id.uuidString).\(fileExtension)" }
    }

    enum ImportError: LocalizedError, Equatable {
        case unsupportedFile, invalidFont, notMonospaced, tooLarge, countLimit, storageLimit, alreadyAvailable, nameInUse, registrationFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedFile: "Choose a single .ttf or .otf font file. Font collections and archives aren't supported."
            case .invalidFont: "This file isn't a readable TrueType or OpenType font."
            case .notMonospaced: "Choose a monospaced font with equal Latin character widths and 1:2 Latin/Japanese widths."
            case .tooLarge: "A font file must be no larger than 32 MB."
            case .countLimit: "You can import up to 8 fonts. Remove an imported font first."
            case .storageLimit: "Imported fonts can use up to 128 MB. Remove an imported font first."
            case .alreadyAvailable: "This font is already available. Choose it from the font list."
            case .nameInUse: "Another version of this font is still in use. Close and reopen iOSSH before importing it."
            case .registrationFailed: "iOS couldn't load this font. Try another TrueType or OpenType font file."
            }
        }
    }

    static let selectionKey = "terminal.fontName"
    nonisolated static let maximumFileBytes = 32 * 1024 * 1024
    static let maximumTotalBytes = 128 * 1024 * 1024
    static let maximumFonts = 8
    static let shared = TerminalFontLibrary(
        directory: URL.applicationSupportDirectory.appendingPathComponent("TerminalFonts", isDirectory: true),
        defaults: .standard
    )

    private struct LoadedFont {
        let fingerprint: SHA256.Digest
        let registrationURL: URL
    }
    // UIKit can retain a font after its library entry is removed. Remember only faces
    // registered by this manager, so identical bytes may be reimported without allowing
    // an imported file to shadow a bundled/system font or another version of a live face.
    private static var loadedFonts: [String: LoadedFont] = [:]

    private(set) var fonts: [ImportedFont] = []
    private(set) var loadWarning: String?
    private let directory: URL
    private let defaults: UserDefaults
    private var manifestURL: URL { directory.appendingPathComponent("fonts.json") }

    init(directory: URL, defaults: UserDefaults) {
        self.directory = directory
        self.defaults = defaults
        _ = TerminalFont.font(ofSize: 14)
        load()
    }

    func resolvedFontName(_ selection: String) -> String {
        if selection == TerminalFont.postScriptName { return selection }
        guard fonts.contains(where: { $0.postScriptName == selection }), UIFont(name: selection, size: 14) != nil else {
            return TerminalFont.postScriptName
        }
        return selection
    }

    var selectedFontName: String {
        resolvedFontName(defaults.string(forKey: Self.selectionKey) ?? TerminalFont.postScriptName)
    }

    func select(_ name: String) {
        defaults.set(resolvedFontName(name), forKey: Self.selectionKey)
    }

    func font(ofSize size: CGFloat, selection: String) -> UIFont {
        TerminalFont.font(named: resolvedFontName(selection), size: size)
    }

    @discardableResult
    func importFont(from source: URL) async throws -> ImportedFont {
        let fileExtension = source.pathExtension.lowercased()
        guard ["ttf", "otf"].contains(fileExtension) else { throw ImportError.unsupportedFile }
        let data = try await Task.detached(priority: .userInitiated) { try Self.readImportedFile(source) }.value
        guard fonts.count < Self.maximumFonts else { throw ImportError.countLimit }
        let info = try Self.inspect(data)
        guard !fonts.contains(where: { $0.postScriptName == info.postScriptName }) else { throw ImportError.alreadyAvailable }
        let fingerprint = SHA256.hash(data: data)
        try Self.checkAvailable(info.postScriptName, fingerprint: fingerprint)
        let storedBytes = fonts.reduce(0) { total, font in
            total + ((try? directory.appendingPathComponent(font.fileName).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        guard storedBytes + data.count <= Self.maximumTotalBytes else { throw ImportError.storageLimit }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let entry = ImportedFont(id: UUID(), displayName: info.displayName, postScriptName: info.postScriptName, fileExtension: fileExtension)
        let ownedURL = directory.appendingPathComponent(entry.fileName)
        try data.write(to: ownedURL, options: .atomic)
        do {
            try Self.register(ownedURL, postScriptName: entry.postScriptName, fingerprint: fingerprint)
            try save(fonts + [entry])
        } catch {
            Self.unregister(entry.postScriptName)
            try? FileManager.default.removeItem(at: ownedURL)
            throw error
        }
        fonts.append(entry)
        select(entry.postScriptName)
        return entry
    }

    func remove(_ entry: ImportedFont) throws {
        guard fonts.contains(entry) else { return }
        let remaining = fonts.filter { $0.id != entry.id }
        try save(remaining)
        fonts = remaining
        select(defaults.string(forKey: Self.selectionKey) ?? TerminalFont.postScriptName)
        let ownedURL = directory.appendingPathComponent(entry.fileName)
        Self.unregister(entry.postScriptName)
        try FileManager.default.removeItem(at: ownedURL)
    }

    private func load() {
        defer { select(defaults.string(forKey: Self.selectionKey) ?? TerminalFont.postScriptName) }
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return }
        do {
            let data = try Self.readBounded(manifestURL, limit: 64 * 1024)
            let saved = try JSONDecoder().decode([ImportedFont].self, from: data)
            guard saved.count <= Self.maximumFonts else { throw ImportError.countLimit }
            var total = 0
            for entry in saved {
                do {
                    guard ["ttf", "otf"].contains(entry.fileExtension),
                          !TerminalFont.bundledPostScriptNames.contains(entry.postScriptName),
                          !fonts.contains(where: { $0.id == entry.id || $0.postScriptName == entry.postScriptName }) else {
                        throw ImportError.invalidFont
                    }
                    let url = directory.appendingPathComponent(entry.fileName)
                    let bytes = try Self.readBounded(url)
                    total += bytes.count
                    guard total <= Self.maximumTotalBytes else { throw ImportError.storageLimit }
                    let info = try Self.inspect(bytes)
                    guard info.postScriptName == entry.postScriptName else { throw ImportError.invalidFont }
                    try Self.register(url, postScriptName: entry.postScriptName, fingerprint: SHA256.hash(data: bytes))
                    fonts.append(entry)
                } catch {
                    loadWarning = "An imported font couldn't be loaded. HackGen Console NF is available as the default."
                }
            }
            if fonts != saved { try save(fonts) }
        } catch {
            loadWarning = "The font library couldn't be loaded. You can continue with HackGen Console NF."
        }
    }

    private func save(_ entries: [ImportedFont]) throws {
        try JSONEncoder().encode(entries).write(to: manifestURL, options: .atomic)
    }

    private static func checkAvailable(_ postScriptName: String, fingerprint: SHA256.Digest) throws {
        guard !TerminalFont.bundledPostScriptNames.contains(postScriptName) else { throw ImportError.alreadyAvailable }
        guard UIFont(name: postScriptName, size: 14) != nil else { return }
        guard let loaded = loadedFonts[postScriptName] else { throw ImportError.alreadyAvailable }
        guard loaded.fingerprint == fingerprint else { throw ImportError.nameInUse }
    }

    private static func register(_ url: URL, postScriptName: String, fingerprint: SHA256.Digest) throws {
        try checkAvailable(postScriptName, fingerprint: fingerprint)
        if UIFont(name: postScriptName, size: 14) != nil { return }
        guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) else { throw ImportError.registrationFailed }
        loadedFonts[postScriptName] = LoadedFont(fingerprint: fingerprint, registrationURL: url)
        guard UIFont(name: postScriptName, size: 14) != nil else {
            unregister(postScriptName)
            throw ImportError.registrationFailed
        }
    }

    private static func unregister(_ postScriptName: String) {
        guard let loaded = loadedFonts[postScriptName] else { return }
        CTFontManagerUnregisterFontsForURL(loaded.registrationURL as CFURL, .process, nil)
        if UIFont(name: postScriptName, size: 14) == nil { loadedFonts.removeValue(forKey: postScriptName) }
    }

    nonisolated private static func readImportedFile(_ source: URL) throws -> Data {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { url in
            result = Result { try readBounded(url) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ImportError.invalidFont }
        return try result.get()
    }

    nonisolated private static func readBounded(_ url: URL, limit: Int = maximumFileBytes) throws -> Data {
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > limit { throw ImportError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let next = try handle.read(upToCount: min(1024 * 1024, limit + 1 - data.count)), !next.isEmpty {
            data.append(next)
            if data.count > limit { throw ImportError.tooLarge }
        }
        return data
    }

    private static func inspect(_ data: Data) throws -> (postScriptName: String, displayName: String) {
        // Reject WOFF, collections, and arbitrary payloads before asking Core Graphics to decode.
        let signature = Array(data.prefix(4))
        guard signature == [0, 1, 0, 0] || signature == Array("OTTO".utf8) || signature == Array("true".utf8),
              let provider = CGDataProvider(data: data as CFData), let graphicsFont = CGFont(provider),
              let name = graphicsFont.postScriptName as String?, !name.isEmpty, name.count <= 128 else {
            throw ImportError.invalidFont
        }
        let font = CTFontCreateWithGraphicsFont(graphicsFont, 16, nil, nil)
        var characters = Array("MWil 01@#".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count), glyphs.allSatisfy({ $0 != 0 }) else {
            throw ImportError.notMonospaced
        }
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advances, glyphs.count)
        let cell = advances[0].width
        guard cell.isFinite, cell > 0, advances.allSatisfy({ abs($0.width - cell) < 0.02 }) else { throw ImportError.notMonospaced }
        for character in "日本語あア".utf16 {
            var character = character, glyph: CGGlyph = 0, advance = CGSize.zero
            if CTFontGetGlyphsForCharacters(font, &character, &glyph, 1), glyph != 0 {
                CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
                guard abs(advance.width - cell * 2) < 0.04 else { throw ImportError.notMonospaced }
            }
        }
        return (name, String(((graphicsFont.fullName as String?) ?? name).prefix(100)))
    }
}
