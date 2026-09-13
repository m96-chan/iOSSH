import Foundation

public struct TerminalColor: Sendable, Equatable, Hashable {
    public let red, green, blue, alpha: UInt8
    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    public static let foreground = TerminalColor(red: 220, green: 223, blue: 228)
    public static let background = TerminalColor(red: 20, green: 23, blue: 28)
}

public struct TerminalCellAttributes: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let bold = Self(rawValue: 1 << 0)
    public static let italic = Self(rawValue: 1 << 1)
    public static let dim = Self(rawValue: 1 << 2)
    /// Foreground/background in snapshots have already been swapped.
    public static let inverse = Self(rawValue: 1 << 3)
    public static let invisible = Self(rawValue: 1 << 4)
    public static let blink = Self(rawValue: 1 << 5)
    public static let underline = Self(rawValue: 1 << 6)
    public static let strikethrough = Self(rawValue: 1 << 7)
}

public enum TerminalUnderlineStyle: Sendable, Hashable {
    case none, single, double, curly, dotted, dashed
}

public struct TerminalCell: Sendable, Equatable {
    public let text: String
    /// Zero denotes the continuation of a wide cell; render only its background.
    public let width: Int
    public let foreground, background: TerminalColor
    public let attributes: TerminalCellAttributes
    public let underlineStyle: TerminalUnderlineStyle
    public let underlineColor: TerminalColor?
    public init(text: String = " ", width: Int = 1, foreground: TerminalColor = .foreground,
                background: TerminalColor = .background, attributes: TerminalCellAttributes = [],
                underlineStyle: TerminalUnderlineStyle = .none, underlineColor: TerminalColor? = nil) {
        self.text = text; self.width = width; self.foreground = foreground; self.background = background
        self.attributes = attributes; self.underlineStyle = underlineStyle; self.underlineColor = underlineColor
    }
}

public struct TerminalCursor: Sendable, Equatable {
    public enum Style: Sendable { case block, bar, underline }
    public let column, row: Int
    public let visible: Bool
    public let style: Style
    public let blinking: Bool
    public init(column: Int, row: Int, visible: Bool = true, style: Style = .block, blinking: Bool = true) {
        self.column = column; self.row = row; self.visible = visible; self.style = style; self.blinking = blinking
    }
}

/// A visible Kitty placement. Row can be negative when its top is above the viewport.
public struct TerminalImagePlacement: Sendable, Equatable {
    public let id, placementID: UInt32
    public let column, row, columns, rows, offsetX, offsetY, zIndex: Int
    public let pixelWidth, pixelHeight: Int
    /// Normalized texture coordinates, used to clip Unicode placeholders per cell.
    public let sourceX, sourceY, sourceWidth, sourceHeight: Double
    /// Fractions of the cell rectangle occupied by the image, preserving aspect ratio.
    public let widthFraction, heightFraction: Double
    /// Straight (unpremultiplied) sRGB RGBA8, tightly packed, top row first.
    public let rgba: Data
    public init(id: UInt32, placementID: UInt32, column: Int, row: Int, columns: Int, rows: Int,
                offsetX: Int = 0, offsetY: Int = 0, zIndex: Int = 0,
                pixelWidth: Int, pixelHeight: Int, rgba: Data,
                sourceX: Double = 0, sourceY: Double = 0, sourceWidth: Double = 1, sourceHeight: Double = 1,
                widthFraction: Double = 1, heightFraction: Double = 1) {
        self.id = id; self.placementID = placementID; self.column = column; self.row = row
        self.columns = columns; self.rows = rows; self.offsetX = offsetX; self.offsetY = offsetY; self.zIndex = zIndex
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.rgba = rgba
        self.sourceX = sourceX; self.sourceY = sourceY; self.sourceWidth = sourceWidth; self.sourceHeight = sourceHeight
        self.widthFraction = widthFraction; self.heightFraction = heightFraction
    }
}

public struct TerminalSnapshot: Sendable, Equatable {
    public let revision: UInt64
    public let columns, rows: Int
    public let cells: [TerminalCell]
    /// Rows changed since the preceding snapshot. The first snapshot damages every row.
    public let damageRows: Set<Int>
    public let cursor: TerminalCursor
    public let images: [TerminalImagePlacement]
    public let title: String
    public let scrollbackOffset, scrollbackCount: Int
    public let applicationCursor, bracketedPaste: Bool
    public let defaultForeground, defaultBackground: TerminalColor
    public init(revision: UInt64 = 0, columns: Int, rows: Int, cells: [TerminalCell],
                damageRows: Set<Int> = [], cursor: TerminalCursor,
                images: [TerminalImagePlacement] = [], title: String = "",
                scrollbackOffset: Int = 0, scrollbackCount: Int = 0,
                applicationCursor: Bool = false, bracketedPaste: Bool = false,
                defaultForeground: TerminalColor = .foreground, defaultBackground: TerminalColor = .background) {
        self.revision = revision; self.columns = columns; self.rows = rows; self.cells = cells
        self.damageRows = damageRows; self.cursor = cursor; self.images = images; self.title = title
        self.scrollbackOffset = scrollbackOffset; self.scrollbackCount = scrollbackCount
        self.applicationCursor = applicationCursor; self.bracketedPaste = bracketedPaste
        self.defaultForeground = defaultForeground; self.defaultBackground = defaultBackground
    }
    public subscript(column: Int, row: Int) -> TerminalCell { cells[row * columns + column] }
}

public struct TerminalPosition: Sendable, Equatable {
    public let column, row: Int
    public init(column: Int, row: Int) { self.column = column; self.row = row }
}

/// Viewport coordinates, with an exclusive end column. Drag direction is normalized.
public struct TerminalSelection: Sendable, Equatable {
    public let start, end: TerminalPosition
    public init(start: TerminalPosition, end: TerminalPosition) { self.start = start; self.end = end }
}

public enum TerminalKey: Sendable { case escape, tab, enter, backspace, up, down, left, right, home, end, pageUp, pageDown }

/// Mutable parser state stays on `TerminalParserActor`; immutable snapshots cross to the UI.
/// libghostty-vt can replace this fallback without coupling the view to a parser implementation.
/// The callbacks run inside the parser's isolation, where the state they report on lives;
/// a UI observer hops to its own actor from there.
@TerminalParserActor public protocol TerminalEngine: AnyObject {
    var onOutput: (@TerminalParserActor (Data) -> Void)? { get set }
    var onNeedsDisplay: (@TerminalParserActor () -> Void)? { get set }
    /// Release any retained snapshot synchronously when decoded images are
    /// removed, including from another session's shared-budget allocation. Do not
    /// call back into the parser here; `onNeedsDisplay` follows for scheduling.
    var onImageCacheInvalidated: (@TerminalParserActor () -> Void)? { get set }
    var onTitleChange: (@TerminalParserActor (String) -> Void)? { get set }
    var columns: Int { get }
    var rows: Int { get }
    func feed(_ data: Data)
    func resize(columns: Int, rows: Int)
    func snapshot() -> TerminalSnapshot
    /// Positive values move into history; negative values move toward the live screen.
    func scroll(by lines: Int)
    func scrollToBottom()
    func text(in selection: TerminalSelection) -> String
    func paste(_ text: String)
    func sendKey(_ key: TerminalKey)
    func setCellSize(width: Int, height: Int)
    func setColors(foreground: TerminalColor, background: TerminalColor, palette: [TerminalColor])
    func reset()
}
