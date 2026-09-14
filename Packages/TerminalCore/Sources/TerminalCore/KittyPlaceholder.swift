import Foundation
@preconcurrency import SwiftTerm

/// A Kitty placeholder cell carries its image id in the cell's colour, and the protocol
/// distinguishes a 256-colour index from a direct RGB triple: the index *is* the low byte of
/// the id, while an RGB triple packs three bytes of it. Resolving either through a palette
/// before decoding loses the id, so both engines hand the decoder the colour as the terminal
/// stored it rather than as the renderer would paint it.
public enum KittyPlaceholderColor: Sendable, Equatable {
    case unset
    case palette(Int)
    case rgb(UInt8, UInt8, UInt8)

    var identifier: UInt32 {
        switch self {
        case let .palette(index): return UInt32(truncatingIfNeeded: index)
        case let .rgb(red, green, blue): return UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
        case .unset: return 0
        }
    }
}

public struct KittyPlaceholderCell: Sendable, Equatable {
    public let column, row, imageColumn, imageRow: Int
    public let imageID, placementID: UInt32
    public init(column: Int, row: Int, imageColumn: Int, imageRow: Int, imageID: UInt32, placementID: UInt32) {
        self.column = column; self.row = row; self.imageColumn = imageColumn; self.imageRow = imageRow
        self.imageID = imageID; self.placementID = placementID
    }
}

/// The virtual placement a run of placeholder cells belongs to. Both engines read the same
/// four values from their own storage — the library's placement iterator for libghostty-vt,
/// `KittyGraphicsStore`'s own placement list for SwiftTerm — and hand them here, so the cell
/// geometry below is written once.
public struct KittyPlaceholderPrototype: Sendable, Equatable {
    public let placementID: UInt32
    public let columns, rows, zIndex: Int
    public init(placementID: UInt32, columns: Int, rows: Int, zIndex: Int) {
        self.placementID = placementID; self.columns = columns; self.rows = rows; self.zIndex = zIndex
    }
}

/// Decode placeholder metadata from original SGR values; palette RGB colors must
/// never be substituted for the image ID carried by a 256-color index.
///
/// One decoder per row, and `decode` must be called for every cell of that row in order: the
/// protocol lets a sender omit the row/column diacritics on a cell that continues the
/// previous one, so a cell that is not a placeholder has to be seen in order to end the run.
public struct KittyPlaceholderDecoder {
    private struct Previous {
        let imageLow, placementID: UInt32
        let row, column, highByte: Int
    }
    private var previous: Previous?

    public init() {}

    public mutating func decode(text: String, foreground: KittyPlaceholderColor,
                                underlineColor: KittyPlaceholderColor,
                                column: Int, row: Int) -> KittyPlaceholderCell? {
        guard text.unicodeScalars.first?.value == 0x10EEEE else { previous = nil; return nil }
        let low = foreground.identifier, placementID = underlineColor.identifier
        let marks = text.unicodeScalars.dropFirst().compactMap { KittyDiacritics.indices[$0.value] }.prefix(3)
        let values = Array(marks)
        let compatible = previous?.imageLow == low && previous?.placementID == placementID
        var imageRow = values.first ?? 0
        var imageColumn = values.count > 1 ? values[1] : 0
        var high = values.count > 2 ? values[2] : 0
        if compatible, let previous {
            if values.isEmpty { imageRow = previous.row; imageColumn = previous.column + 1; high = previous.highByte }
            else if values.count == 1, imageRow == previous.row { imageColumn = previous.column + 1; high = previous.highByte }
            else if values.count == 2, imageRow == previous.row, imageColumn == previous.column + 1 { high = previous.highByte }
        }
        guard high <= 255 else { self.previous = nil; return nil }
        previous = Previous(imageLow: low, placementID: placementID, row: imageRow, column: imageColumn, highByte: high)
        return KittyPlaceholderCell(column: column, row: row, imageColumn: imageColumn, imageRow: imageRow,
                                    imageID: low | UInt32(high) << 24, placementID: placementID)
    }

    /// SwiftTerm's cells carry the colour as an `Attribute`; libghostty-vt's carry a tagged
    /// union. Both land on `KittyPlaceholderColor` above.
    mutating func decode(text: String, attribute: Attribute, column: Int, row: Int) -> KittyPlaceholderCell? {
        decode(text: text, foreground: Self.color(attribute.fg),
               underlineColor: attribute.underlineColor.map(Self.color) ?? .unset,
               column: column, row: row)
    }

    private static func color(_ color: Attribute.Color) -> KittyPlaceholderColor {
        switch color {
        case let .ansi256(code): return .palette(Int(code))
        case let .trueColor(red, green, blue): return .rgb(red, green, blue)
        case .defaultColor, .defaultInvertedColor: return .unset
        }
    }
}

/// Where one placeholder cell draws from inside its image.
///
/// A virtual placement reserves a `columns` x `rows` block of cells and the image is fitted
/// into it preserving its aspect ratio; each placeholder cell then shows the one cell-sized
/// tile of that fitted image its diacritics name. Because every cell is an independent
/// placement of the whole image, the run follows the text through reflow and scrollback
/// instead of being anchored to a screen position, which is the behaviour the README
/// promises. Both engines synthesise those cells through this function so they cannot drift.
public enum KittyPlaceholderLayout {
    public static func placement(cell: KittyPlaceholderCell, prototype: KittyPlaceholderPrototype,
                                 imageWidth: Int, imageHeight: Int, rgba: Data, contentRevision: UInt64,
                                 cellWidth: Int, cellHeight: Int) -> TerminalImagePlacement? {
        guard imageWidth > 0, imageHeight > 0, cellWidth > 0, cellHeight > 0,
              prototype.columns > 0, prototype.rows > 0,
              cell.imageColumn < prototype.columns, cell.imageRow < prototype.rows else { return nil }
        let scale = min(Double(prototype.columns * cellWidth) / Double(imageWidth),
                        Double(prototype.rows * cellHeight) / Double(imageHeight))
        let displayedWidth = Double(imageWidth) * scale, displayedHeight = Double(imageHeight) * scale
        let left = Double(cell.imageColumn * cellWidth), top = Double(cell.imageRow * cellHeight)
        guard left < displayedWidth, top < displayedHeight else { return nil }
        let width = min(Double(cellWidth), displayedWidth - left)
        let height = min(Double(cellHeight), displayedHeight - top)
        return TerminalImagePlacement(id: cell.imageID, placementID: prototype.placementID,
                                      column: cell.column, row: cell.row, columns: 1, rows: 1,
                                      zIndex: prototype.zIndex,
                                      pixelWidth: imageWidth, pixelHeight: imageHeight, rgba: rgba,
                                      contentRevision: contentRevision,
                                      sourceX: left / displayedWidth, sourceY: top / displayedHeight,
                                      sourceWidth: width / displayedWidth, sourceHeight: height / displayedHeight,
                                      widthFraction: width / Double(cellWidth),
                                      heightFraction: height / Double(cellHeight))
    }
}
