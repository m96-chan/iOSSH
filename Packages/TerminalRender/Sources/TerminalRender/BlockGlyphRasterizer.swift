/// Solid Unicode block elements describe fractions of a terminal cell. Font
/// bearings and baseline fitting must not move their shared pixel boundaries.
enum BlockGlyphRasterizer {
    private struct Rectangle {
        let left: Int
        let top: Int
        let right: Int
        let bottom: Int
    }

    /// Writes white premultiplied RGBA, with the top scanline first, into a
    /// cleared glyph bitmap. Shades keep their font-specific stipple pattern.
    static func draw(_ text: String, width: Int, height: Int,
                     into storage: UnsafeMutableRawBufferPointer) -> Bool {
        guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first,
              width > 0, height > 0, storage.count >= width * height * 4 else { return false }
        let code = scalar.value
        var rectangles: [Rectangle] = []
        switch code {
        case 0x2580: // Upper half.
            rectangles = [.init(left: 0, top: 0, right: width, bottom: height / 2)]
        case 0x2581...0x2588: // Lower eighths, through the full block.
            let eighths = Int(code - 0x2580)
            rectangles = [.init(left: 0, top: (8 - eighths) * height / 8, right: width, bottom: height)]
        case 0x2589...0x258F: // Left seven eighths, through one eighth.
            let eighths = Int(0x2590 - code)
            rectangles = [.init(left: 0, top: 0, right: eighths * width / 8, bottom: height)]
        case 0x2590: // Right half, sharing the left half's rounded boundary.
            rectangles = [.init(left: width / 2, top: 0, right: width, bottom: height)]
        case 0x2594:
            rectangles = [.init(left: 0, top: 0, right: width, bottom: height / 8)]
        case 0x2595:
            rectangles = [.init(left: 7 * width / 8, top: 0, right: width, bottom: height)]
        case 0x2596...0x259F:
            // Bits: upper-left, upper-right, lower-left, lower-right.
            let masks = [0b0100, 0b1000, 0b0001, 0b1101, 0b1001,
                         0b0111, 0b1011, 0b0010, 0b0110, 0b1110]
            let mask = masks[Int(code - 0x2596)]
            for quadrant in 0..<4 where mask & (1 << quadrant) != 0 {
                let column = quadrant % 2, row = quadrant / 2
                rectangles.append(.init(left: column * width / 2, top: row * height / 2,
                                        right: (column + 1) * width / 2, bottom: (row + 1) * height / 2))
            }
        default:
            return false
        }
        for rect in rectangles {
            for y in rect.top..<rect.bottom {
                for x in rect.left..<rect.right {
                    let offset = (y * width + x) * 4
                    storage[offset] = 255
                    storage[offset + 1] = 255
                    storage[offset + 2] = 255
                    storage[offset + 3] = 255
                }
            }
        }
        return true
    }
}
