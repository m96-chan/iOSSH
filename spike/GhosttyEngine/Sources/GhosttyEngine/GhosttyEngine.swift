import Foundation
import GhosttyVt
import TerminalCore

/// A `TerminalEngine` backed by libghostty-vt, for comparing against the shipping SwiftTerm
/// engine (#10). It covers parsing, the visible grid with its colours and attributes, the
/// cursor, resizing, scrollback navigation, selection text, and Kitty placements whose pixels
/// arrive uncompressed — virtual placements and compressed payloads still stay with
/// `SwiftTermEngine`.
@TerminalParserActor public final class GhosttyEngine: TerminalEngine {
    public var onOutput: (@TerminalParserActor (Data) -> Void)?
    public var onNeedsDisplay: (@TerminalParserActor () -> Void)?
    public var onImageCacheInvalidated: (@TerminalParserActor () -> Void)?
    public var onTitleChange: (@TerminalParserActor (String) -> Void)?

    public var columns: Int { readCount(GHOSTTY_TERMINAL_DATA_COLS) ?? 80 }
    public var rows: Int { readCount(GHOSTTY_TERMINAL_DATA_ROWS) ?? 24 }

    /// Owned for the object's lifetime and only touched on the engine's isolation; the
    /// deinit frees it without hopping, which is why it is marked unsafe here.
    private nonisolated(unsafe) var terminal: GhosttyTerminal?
    private var revision: UInt64 = 0
    private var previous: TerminalSnapshot?
    private var historyOffset = 0
    /// Decoded image bytes keyed by image id, refreshed when the library's generation stamp
    /// changes, so a placement seen every frame does not copy its pixels every frame.
    private var imageCache: [UInt32: (generation: UInt64, rgba: Data, width: Int, height: Int)] = [:]
    private var foreground = TerminalColor.foreground
    private var background = TerminalColor.background
    private var palette: [TerminalColor] = []
    private var pixelWidth = 8
    private var pixelHeight = 16
    /// Written by the C callbacks above, which only ever run inside a call this engine makes
    /// from its own isolation, and drained there.
    private nonisolated(unsafe) var replies: [Data] = []
    private nonisolated(unsafe) var reportedSize = GhosttySizeReportSize(rows: 24, columns: 80,
                                                                        cell_width: 8, cell_height: 16)

    public init(columns: Int = 80, rows: Int = 24) {
        var handle: GhosttyTerminal?
        guard ghostty_terminal_new(nil, &handle, UInt16(min(1000, max(2, columns))),
                                   UInt16(min(1000, max(1, rows)))) == GHOSTTY_SUCCESS else { return }
        terminal = handle
        install()
    }

    /// Programs ask the terminal questions — device attributes, XTVERSION, the size in pixels —
    /// and wait for the answer before drawing. Without these callbacks libghostty-vt parses the
    /// queries and drops the replies, so the program waits out its timeout on every one.
    private func install() {
        guard let terminal else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, context)

        // These run synchronously inside ghostty_terminal_vt_write, which this engine only
        // calls from its own isolation. They collect into storage the engine flushes right
        // after the write returns, so nothing crosses an isolation boundary mid-parse.
        let write: GhosttyTerminalWritePtyFn = { _, userdata, data, length in
            guard let userdata, let data, length > 0 else { return }
            let engine = Unmanaged<GhosttyEngine>.fromOpaque(userdata).takeUnretainedValue()
            engine.replies.append(Data(UnsafeBufferPointer(start: data, count: length)))
        }
        // The header is explicit: callbacks and userdata are passed by value, everything else
        // by address. Passing the address of a function pointer makes the library call into
        // the stack slot that held it.
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                                 unsafeBitCast(write, to: UnsafeMutableRawPointer.self))

        let size: GhosttyTerminalSizeFn = { _, userdata, out in
            guard let userdata, let out else { return false }
            let engine = Unmanaged<GhosttyEngine>.fromOpaque(userdata).takeUnretainedValue()
            out.pointee = engine.reportedSize
            return true
        }
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SIZE,
                                 unsafeBitCast(size, to: UnsafeMutableRawPointer.self))
    }

    deinit {
        if let terminal { ghostty_terminal_free(terminal) }
    }

    public func feed(_ data: Data) {
        guard let terminal, !data.isEmpty else { return }
        data.withUnsafeBytes { bytes in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
            ghostty_terminal_vt_write(terminal, base, bytes.count)
        }
        flushReplies()
        changed()
    }

    public func resize(columns: Int, rows: Int) {
        guard let terminal else { return }
        _ = ghostty_terminal_resize(terminal, UInt16(min(1000, max(2, columns))),
                                    UInt16(min(1000, max(1, rows))),
                                    UInt32(pixelWidth), UInt32(pixelHeight))
        updateReportedSize()
        changed()
    }

    public func snapshot() -> TerminalSnapshot {
        let columns = columns, rows = rows
        var cells: [TerminalCell] = []
        cells.reserveCapacity(columns * rows)
        var damage = Set<Int>()
        for row in 0..<rows {
            let start = cells.count
            for column in 0..<columns {
                cells.append(cell(column: column, row: row))
            }
            if let previous, previous.columns == columns, previous.rows == rows {
                if !cells[start..<(start + columns)].elementsEqual(previous.cells[start..<(start + columns)]) {
                    damage.insert(row)
                }
            } else { damage.insert(row) }
        }
        let cursor = TerminalCursor(column: min(columns - 1, readCount(GHOSTTY_TERMINAL_DATA_CURSOR_X) ?? 0),
                                    row: readCount(GHOSTTY_TERMINAL_DATA_CURSOR_Y) ?? 0,
                                    visible: readFlag(GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE) ?? true)
        if previous?.cursor != cursor {
            if (0..<rows).contains(cursor.row) { damage.insert(cursor.row) }
            if let old = previous?.cursor.row, (0..<rows).contains(old) { damage.insert(old) }
        }
        let images = placements()
        if previous?.images != images { damage.formUnion(0..<rows) }
        let result = TerminalSnapshot(revision: revision, columns: columns, rows: rows, cells: cells,
                                      damageRows: damage, cursor: cursor, images: images, title: "",
                                      scrollbackOffset: historyOffset,
                                      scrollbackCount: readSize(GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS) ?? 0,
                                      applicationCursor: mode(ghostty_mode_new(1, false)),
                                      bracketedPaste: mode(ghostty_mode_new(2004, false)),
                                      defaultForeground: foreground, defaultBackground: background)
        previous = result
        return result
    }


    /// Positive values move into history; negative values move toward the live screen, which
    /// is the opposite sign from the library's viewport delta.
    public func scroll(by lines: Int) {
        guard let terminal, lines != 0 else { return }
        let available = readSize(GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS) ?? 0
        let offset = min(available, max(0, historyOffset + lines))
        guard offset != historyOffset else { return }
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
        behavior.value.delta = Int(historyOffset - offset)
        ghostty_terminal_scroll_viewport(terminal, behavior)
        historyOffset = offset
        previous = nil
        changed()
    }

    public func scrollToBottom() {
        guard let terminal, historyOffset != 0 else { return }
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM
        ghostty_terminal_scroll_viewport(terminal, behavior)
        historyOffset = 0
        previous = nil
        changed()
    }

    /// Reads the selected cells straight from the grid. The library can format a selection
    /// through its formatter, but the range here is already in viewport coordinates and the
    /// cells are the same ones the snapshot reports.
    public func text(in selection: TerminalSelection) -> String {
        let columns = columns, rows = rows
        let start = selection.start, end = selection.end
        guard start.row <= end.row, rows > 0, columns > 0 else { return "" }
        var lines: [String] = []
        for row in max(0, start.row)...min(rows - 1, max(0, end.row)) {
            let lower = row == start.row ? min(columns, max(0, start.column)) : 0
            let upper = row == end.row ? min(columns, max(0, end.column)) : columns
            guard lower < upper else { lines.append(""); continue }
            var line = ""
            for column in lower..<upper {
                let cell = cell(column: column, row: row)
                guard cell.width != 0 else { continue }
                line += cell.text
            }
            while line.hasSuffix(" ") { line.removeLast() }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Input has to work for the engine to be usable on a device. Bracketed paste and
    /// application cursor mode are read back from the terminal's modes.
    public func paste(_ text: String) {
        let safe = String(text.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 || $0 == "\n" || $0 == "\t" })
            .replacingOccurrences(of: "\n", with: "\r")
        let value = mode(ghostty_mode_new(2004, false)) ? "\u{1b}[200~\(safe)\u{1b}[201~" : safe
        onOutput?(Data(value.utf8))
    }

    public func sendKey(_ key: TerminalKey) {
        let prefix = mode(ghostty_mode_new(1, false)) ? "\u{1b}O" : "\u{1b}["
        let value: String
        switch key {
        case .escape: value = "\u{1b}"
        case .tab: value = "\t"
        case .enter: value = "\r"
        case .backspace: value = "\u{7f}"
        case .up: value = prefix + "A"
        case .down: value = prefix + "B"
        case .right: value = prefix + "C"
        case .left: value = prefix + "D"
        case .home: value = prefix + "H"
        case .end: value = prefix + "F"
        case .pageUp: value = "\u{1b}[5~"
        case .pageDown: value = "\u{1b}[6~"
        }
        onOutput?(Data(value.utf8))
    }

    private func mode(_ mode: GhosttyMode) -> Bool {
        guard let terminal else { return false }
        var config = GhosttyTerminalModeConfig(mode: mode, value: false)
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &config) == GHOSTTY_SUCCESS else { return false }
        return config.value
    }

    public func setCellSize(width: Int, height: Int) {
        pixelWidth = min(1000, max(1, width))
        pixelHeight = min(1000, max(1, height))
        if let terminal {
            _ = ghostty_terminal_resize(terminal, UInt16(columns), UInt16(rows),
                                        UInt32(pixelWidth), UInt32(pixelHeight))
        }
        updateReportedSize()
    }

    private func updateReportedSize() {
        reportedSize = GhosttySizeReportSize(rows: UInt16(rows), columns: UInt16(columns),
                                             cell_width: UInt32(pixelWidth), cell_height: UInt32(pixelHeight))
    }

    public func setColors(foreground: TerminalColor, background: TerminalColor, palette: [TerminalColor]) {
        guard palette.count == 16 else { return }
        self.foreground = foreground
        self.background = background
        self.palette = palette
        changed()
    }

    public func reset() {
        guard let terminal else { return }
        ghostty_terminal_reset(terminal)
        changed()
    }

    /// Answers the terminal produced while parsing: device attributes, XTVERSION, size
    /// reports. A program that asked waits for these before it draws.
    private func flushReplies() {
        guard !replies.isEmpty else { return }
        let pending = replies
        replies.removeAll(keepingCapacity: true)
        for reply in pending { onOutput?(reply) }
    }

    /// Visible Kitty placements, mapped to what the renderer draws. Virtual placements
    /// (Unicode placeholders) report no rectangle and are skipped, as are payloads still in a
    /// compressed or encoded form — those stay with SwiftTermEngine for now.
    private func placements() -> [TerminalImagePlacement] {
        guard let terminal else { return [] }
        var storage: GhosttyKittyGraphics?
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &storage) == GHOSTTY_SUCCESS,
              let storage else { return [] }
        var iterator: GhosttyKittyGraphicsPlacementIterator?
        guard ghostty_kitty_graphics_placement_iterator_new(nil, &iterator) == GHOSTTY_SUCCESS else { return [] }
        defer { ghostty_kitty_graphics_placement_iterator_free(iterator) }
        // The storage populates the handle in place; keep one variable so a replacement is
        // both used and freed rather than leaving a stale copy behind.
        guard ghostty_kitty_graphics_get(storage, GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR, &iterator) == GHOSTTY_SUCCESS,
              let iterator else { return [] }

        var result: [TerminalImagePlacement] = []
        while ghostty_kitty_graphics_placement_next(iterator) {
            var imageID: UInt32 = 0, placementID: UInt32 = 0, zIndex: Int32 = 0
            var offsetX: UInt32 = 0, offsetY: UInt32 = 0
            _ = ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID, &imageID)
            _ = ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_PLACEMENT_ID, &placementID)
            _ = ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Z, &zIndex)
            _ = ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_X_OFFSET, &offsetX)
            _ = ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Y_OFFSET, &offsetY)
            guard let image = ghostty_kitty_graphics_image(storage, imageID),
                  let pixels = rgba(for: imageID, image: image) else { continue }

            var rect = GhosttySelection()
            rect.size = MemoryLayout<GhosttySelection>.size
            guard ghostty_kitty_graphics_placement_rect(iterator, image, terminal, &rect) == GHOSTTY_SUCCESS else { continue }
            var columns: UInt32 = 0, rows: UInt32 = 0
            guard ghostty_kitty_graphics_placement_grid_size(iterator, image, terminal, &columns, &rows) == GHOSTTY_SUCCESS else { continue }
            var point = GhosttyPointCoordinate()
            guard ghostty_terminal_point_from_grid_ref(terminal, &rect.start, GHOSTTY_POINT_TAG_VIEWPORT, &point) == GHOSTTY_SUCCESS else { continue }

            result.append(TerminalImagePlacement(id: imageID, placementID: placementID,
                                                 column: Int(point.x), row: Int(point.y),
                                                 columns: Int(columns), rows: Int(rows),
                                                 offsetX: Int(offsetX), offsetY: Int(offsetY),
                                                 zIndex: Int(zIndex),
                                                 pixelWidth: pixels.width, pixelHeight: pixels.height,
                                                 rgba: pixels.rgba, contentRevision: pixels.generation))
        }
        return result
    }

    private func rgba(for id: UInt32, image: GhosttyKittyGraphicsImage) -> (rgba: Data, width: Int, height: Int, generation: UInt64)? {
        var generation: UInt64 = 0
        _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_GENERATION, &generation)
        if let cached = imageCache[id], cached.generation == generation {
            return (cached.rgba, cached.width, cached.height, generation)
        }
        var width: UInt32 = 0, height: UInt32 = 0, format: GhosttyKittyImageFormat = GHOSTTY_KITTY_IMAGE_FORMAT_RGBA
        var compression: GhosttyKittyImageCompression = GHOSTTY_KITTY_IMAGE_COMPRESSION_NONE
        var length = 0
        var pointer: UnsafePointer<UInt8>?
        _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_WIDTH, &width)
        _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_HEIGHT, &height)
        _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_FORMAT, &format)
        _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_COMPRESSION, &compression)
        _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR, &pointer)
        _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN, &length)
        guard compression == GHOSTTY_KITTY_IMAGE_COMPRESSION_NONE, let pointer,
              width > 0, height > 0, length > 0 else { return nil }

        let pixels = Int(width) * Int(height)
        var converted = Data(count: pixels * 4)
        let source = UnsafeBufferPointer(start: pointer, count: length)
        switch format {
        case GHOSTTY_KITTY_IMAGE_FORMAT_RGBA:
            guard length >= pixels * 4 else { return nil }
            converted = Data(source.prefix(pixels * 4))
        case GHOSTTY_KITTY_IMAGE_FORMAT_RGB:
            guard length >= pixels * 3 else { return nil }
            converted.withUnsafeMutableBytes { destination in
                guard let out = destination.bindMemory(to: UInt8.self).baseAddress else { return }
                for index in 0..<pixels {
                    out[index * 4] = source[index * 3]
                    out[index * 4 + 1] = source[index * 3 + 1]
                    out[index * 4 + 2] = source[index * 3 + 2]
                    out[index * 4 + 3] = 255
                }
            }
        default:
            return nil
        }
        imageCache[id] = (generation, converted, Int(width), Int(height))
        if imageCache.count > 64 { imageCache.removeAll(keepingCapacity: true) }
        return (converted, Int(width), Int(height), generation)
    }

    private func changed() {
        revision &+= 1
        onNeedsDisplay?()
    }

    /// Each key writes its own type through the void pointer, so reading one through a
    /// differently sized variable corrupts the stack around it. The header documents the type
    /// per key; these three cover the ones this engine reads.
    private func readCount(_ key: GhosttyTerminalData) -> Int? {
        guard let terminal else { return nil }
        var value: UInt16 = 0
        guard ghostty_terminal_get(terminal, key, &value) == GHOSTTY_SUCCESS else { return nil }
        return Int(value)
    }

    private func readFlag(_ key: GhosttyTerminalData) -> Bool? {
        guard let terminal else { return nil }
        var value = false
        guard ghostty_terminal_get(terminal, key, &value) == GHOSTTY_SUCCESS else { return nil }
        return value
    }

    private func readSize(_ key: GhosttyTerminalData) -> Int? {
        guard let terminal else { return nil }
        var value = 0
        guard ghostty_terminal_get(terminal, key, &value) == GHOSTTY_SUCCESS else { return nil }
        return value
    }

    private func cell(column: Int, row: Int) -> TerminalCell {
        let blank = TerminalCell(foreground: foreground, background: background)
        guard let terminal else { return blank }
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate = GhosttyPointCoordinate(x: UInt16(column), y: UInt32(row))
        var ref = GhosttyGridRef()
        guard ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS else { return blank }

        var packed: GhosttyCell = 0
        guard ghostty_grid_ref_cell(&ref, &packed) == GHOSTTY_SUCCESS else { return blank }
        var codepoint: UInt32 = 0
        _ = ghostty_cell_get(packed, GHOSTTY_CELL_DATA_CODEPOINT, &codepoint)
        var wide: UInt32 = 0
        _ = ghostty_cell_get(packed, GHOSTTY_CELL_DATA_WIDE, &wide)

        var style = GhosttyStyle()
        style.size = MemoryLayout<GhosttyStyle>.size
        let hasStyle = ghostty_grid_ref_style(&ref, &style) == GHOSTTY_SUCCESS

        let text = codepoint == 0 ? " " : String(UnicodeScalar(codepoint).map(String.init) ?? " ")
        var attributes: TerminalCellAttributes = []
        if hasStyle {
            if style.bold { attributes.insert(.bold) }
            if style.italic { attributes.insert(.italic) }
            if style.faint { attributes.insert(.dim) }
            if style.blink { attributes.insert(.blink) }
            if style.inverse { attributes.insert(.inverse) }
            if style.invisible { attributes.insert(.invisible) }
            if style.strikethrough { attributes.insert(.strikethrough) }
            if style.underline != 0 { attributes.insert(.underline) }
        }
        let width: Int
        switch wide {
        case UInt32(GHOSTTY_CELL_WIDE_WIDE.rawValue): width = 2
        case UInt32(GHOSTTY_CELL_WIDE_SPACER_TAIL.rawValue): width = 0
        default: width = 1
        }
        var cellForeground = hasStyle ? color(style.fg_color, fallback: foreground) : foreground
        var cellBackground = hasStyle ? color(style.bg_color, fallback: background) : background
        // `TerminalCellAttributes.inverse` documents that snapshots carry colours already
        // swapped, so the renderer never has to know about the attribute.
        if attributes.contains(.inverse) { swap(&cellForeground, &cellBackground) }
        return TerminalCell(text: width == 0 ? "" : text, width: width,
                            foreground: cellForeground, background: cellBackground,
                            attributes: attributes)
    }

    private func color(_ value: GhosttyStyleColor, fallback: TerminalColor) -> TerminalColor {
        switch value.tag {
        case GHOSTTY_STYLE_COLOR_RGB:
            return TerminalColor(red: value.value.rgb.r, green: value.value.rgb.g, blue: value.value.rgb.b)
        case GHOSTTY_STYLE_COLOR_PALETTE:
            let index = Int(value.value.palette)
            return index < palette.count ? palette[index] : fallback
        default:
            return fallback
        }
    }
}
