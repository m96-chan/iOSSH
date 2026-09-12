import Foundation
@preconcurrency import SwiftTerm

struct KittyPlaceholderCell {
    let column, row, imageColumn, imageRow: Int
    let imageID, placementID: UInt32
}

/// Decode placeholder metadata from original SGR values; palette RGB colors must
/// never be substituted for the image ID carried by a 256-color index.
struct KittyPlaceholderDecoder {
    private struct Previous {
        let imageLow, placementID: UInt32
        let row, column, highByte: Int
    }
    private var previous: Previous?

    mutating func decode(text: String, attribute: Attribute, column: Int, row: Int) -> KittyPlaceholderCell? {
        guard text.unicodeScalars.first?.value == 0x10EEEE else { previous = nil; return nil }
        let low = colorID(attribute.fg), placementID = attribute.underlineColor.map(colorID) ?? 0
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

    private func colorID(_ color: Attribute.Color) -> UInt32 {
        switch color {
        case let .ansi256(code): return UInt32(code)
        case let .trueColor(red, green, blue): return UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
        case .defaultColor, .defaultInvertedColor: return 0
        }
    }
}
