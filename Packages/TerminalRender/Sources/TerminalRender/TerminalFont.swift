import CoreText
import UIKit

/// Bundled Japanese, Latin, and Nerd Font glyphs share a halfwidth/fullwidth ratio of 1:2.
public enum TerminalFont {
    public static let displayName = "UDEV Gothic NF"
    public static let postScriptName = "UDEVGothicNF-Regular"

    // Swift package resources are not registered through the application's UIAppFonts key.
    // Register every style together before UIFont or Core Text first resolves this family.
    @MainActor private static let registered: Void = {
        for style in ["Regular", "Bold", "Italic", "BoldItalic"] {
            guard let url = Bundle.module.url(forResource: "UDEVGothicNF-\(style)", withExtension: "ttf", subdirectory: "Fonts") else {
                assertionFailure("Missing bundled terminal font: \(style)")
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    @MainActor public static func font(ofSize size: CGFloat, bold: Bool = false, italic: Bool = false) -> UIFont {
        _ = registered
        let style = bold ? (italic ? "BoldItalic" : "Bold") : (italic ? "Italic" : "Regular")
        return UIFont(name: "UDEVGothicNF-\(style)", size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    @MainActor static func font(named name: String, size: CGFloat, bold: Bool = false, italic: Bool = false) -> UIFont {
        if name == postScriptName { return font(ofSize: size, bold: bold, italic: italic) }
        let base = UIFont(name: name, size: size) ?? font(ofSize: size)
        var traits = base.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        return base.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: size) } ?? base
    }

    /// Notices are also kept beside the unmodified font files in the resource bundle.
    public static var licenseText: String {
        ["LICENSE", "LICENSE_BIZUDGothic", "LICENSE_JetBrainsMono", "LICENSE_NerdFonts"].compactMap { name in
            guard let url = Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fonts") else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }.joined(separator: "\n\n")
    }
}
