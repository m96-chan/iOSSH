import CoreText
import UIKit

/// Bundled Japanese, Latin, and Nerd Font glyphs share a halfwidth/fullwidth ratio of 1:2.
public enum TerminalFont {
    public static let displayName = "HackGen Console NF"
    public static let postScriptName = "HackGenConsoleNF-Regular"
    public static let fallbackDisplayName = "Noto Sans CJK JP"
    public static let fallbackPostScriptName = "NotoSansCJKjp-Regular"
    public static let bundledPostScriptNames: Set<String> = [
        "HackGenConsoleNF-Regular", "HackGenConsoleNF-Bold", "NotoSansCJKjp-Regular", "NotoSansCJKjp-Bold"
    ]

    // Swift package resources are not registered through the application's UIAppFonts key.
    // Register every style together before UIFont or Core Text first resolves this family.
    @MainActor private static let registered: Void = {
        for style in ["Regular", "Bold"] {
            for url in [resourceURL(forStyle: style), fallbackResourceURL(forStyle: style)] {
                guard let url else {
                    assertionFailure("Missing bundled terminal font: \(style)")
                    continue
                }
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }()

    @MainActor public static func font(ofSize size: CGFloat, bold: Bool = false, italic: Bool = false) -> UIFont {
        _ = registered
        let base = UIFont(name: "HackGenConsoleNF-\(bold ? "Bold" : "Regular")", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
        return withFallbacks(italic ? slanted(base) : base, bold: bold, italic: italic)
    }

    @MainActor public static func font(named name: String, size: CGFloat, bold: Bool = false, italic: Bool = false) -> UIFont {
        if name == postScriptName { return font(ofSize: size, bold: bold, italic: italic) }
        _ = registered
        var base = UIFont(name: name, size: size) ?? font(ofSize: size)
        var traits = base.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if let descriptor = base.fontDescriptor.withSymbolicTraits(traits) {
            let styled = UIFont(descriptor: descriptor, size: size)
            if styled.familyName == base.familyName { base = styled }
        }
        let useBold = bold || base.fontDescriptor.symbolicTraits.contains(.traitBold)
        let useItalic = italic || base.fontDescriptor.symbolicTraits.contains(.traitItalic)
        if italic && !base.fontDescriptor.symbolicTraits.contains(.traitItalic) { base = slanted(base) }
        return withFallbacks(base, bold: useBold, italic: useItalic)
    }

    @MainActor private static func withFallbacks(_ primary: UIFont, bold: Bool, italic: Bool) -> UIFont {
        let style = bold ? "Bold" : "Regular"
        // Explicit JP faces prevent the device language from selecting another CJK
        // regional glyph form. Core Text still appends its system/emoji fallback list.
        let names = ["NotoSansCJKjp-\(style)", "HackGenConsoleNF-\(style)"]
        let cascade = names.filter { $0 != primary.fontName }.compactMap { name -> CTFontDescriptor? in
            guard let font = UIFont(name: name, size: primary.pointSize) else { return nil }
            return CTFontCopyFontDescriptor((italic ? slanted(font) : font) as CTFont)
        }
        let attributes = CTFontDescriptorCreateWithAttributes([kCTFontCascadeListAttribute: cascade] as CFDictionary)
        return CTFontCreateCopyWithAttributes(primary as CTFont, primary.pointSize, nil, attributes) as UIFont
    }

    @MainActor private static func slanted(_ font: UIFont) -> UIFont {
        // HackGen distributes upright Regular/Bold. Shear the same glyphs instead of
        // switching families, preserving Japanese and Nerd Font coverage for SGR 3.
        // UIFont(descriptor:size:) discards this matrix on iOS. Keep the Core Text
        // font itself when bridging back to UIFont so CTLine receives the transform.
        var matrix = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
        return CTFontCreateCopyWithAttributes(font as CTFont, font.pointSize, &matrix, nil) as UIFont
    }

    static func resourceURL(forStyle style: String) -> URL? {
        Bundle.module.url(forResource: "HackGenConsoleNF-\(style)", withExtension: "ttf", subdirectory: "Fonts")
    }

    static func fallbackResourceURL(forStyle style: String) -> URL? {
        Bundle.module.url(forResource: "NotoSansCJKjp-\(style)", withExtension: "otf", subdirectory: "Fonts")
    }

    /// Notices are also kept beside the unmodified font files in the resource bundle.
    public static var licenseText: String {
        ["LICENSE", "LICENSE_GenJyuuGothic", "LICENSE_Hack", "LICENSE_NerdFonts", "LICENSE_NotoSansCJKJP"].compactMap { name in
            guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fonts") else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }.joined(separator: "\n\n")
    }
}
