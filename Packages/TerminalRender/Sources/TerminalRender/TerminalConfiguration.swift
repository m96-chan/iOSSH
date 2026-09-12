import UIKit

/// Colors are expressed in sRGB; the renderer converts them to linear light for blending.
public struct TerminalTheme: Equatable, Sendable {
    public var foreground: UInt32
    public var background: UInt32
    public var cursor: UInt32
    public var selection: UInt32
    public var ansi: [UInt32]

    public init(foreground: UInt32, background: UInt32, cursor: UInt32, selection: UInt32, ansi: [UInt32]) {
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.selection = selection
        self.ansi = Array(ansi.prefix(16))
        while self.ansi.count < 16 { self.ansi.append(foreground) }
    }

    public static let dark = TerminalTheme(
        foreground: 0xDCE2EB, background: 0x11151C, cursor: 0x82C8FA, selection: 0x345273,
        ansi: [0x20252D, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
               0x5C6370, 0xF07C85, 0xA8D389, 0xF5D08B, 0x71BFFF, 0xD688ED, 0x66C6D2, 0xF4F6FA]
    )
    public static let light = TerminalTheme(
        foreground: 0x24292F, background: 0xFAFBFC, cursor: 0x0969DA, selection: 0xB6D8FD,
        ansi: [0x24292F, 0xCF222E, 0x116329, 0x9A6700, 0x0550AE, 0x8250DF, 0x1B7C83, 0x6E7781,
               0x57606A, 0xA40E26, 0x1A7F37, 0x7D4E00, 0x0969DA, 0xA475F9, 0x0A7075, 0x8C959F]
    )
}

public struct TerminalConfiguration: Equatable, Sendable {
    public var fontSize: CGFloat
    public var fontName: String
    public var theme: TerminalTheme
    public var cursorBlinks: Bool

    public init(fontSize: CGFloat = 14, fontName: String = TerminalFont.postScriptName, theme: TerminalTheme = .dark, cursorBlinks: Bool = true) {
        self.fontSize = min(32, max(8, fontSize))
        self.fontName = fontName
        self.theme = theme
        self.cursorBlinks = cursorBlinks
    }
}

extension UInt32 {
    var terminalUIColor: UIColor {
        UIColor(red: CGFloat((self >> 16) & 255) / 255, green: CGFloat((self >> 8) & 255) / 255,
                blue: CGFloat(self & 255) / 255, alpha: 1)
    }

    var linearColor: SIMD4<Float> {
        func linear(_ value: UInt32) -> Float {
            let c = Float(value & 255) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return SIMD4(linear(self >> 16), linear(self >> 8), linear(self), 1)
    }
}
