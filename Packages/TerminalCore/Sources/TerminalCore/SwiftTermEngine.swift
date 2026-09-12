import Foundation
@preconcurrency import SwiftTerm

/// UI-independent SwiftTerm adapter, pinned while libghostty-vt packaging is unavailable.
@MainActor public final class SwiftTermEngine: TerminalEngine, @preconcurrency TerminalDelegate {
    public var onOutput: ((Data) -> Void)?
    public var onNeedsDisplay: (() -> Void)?
    public var onTitleChange: ((String) -> Void)?
    public var columns: Int { terminal.cols }
    public var rows: Int { terminal.rows }

    private var terminal: Terminal!
    private var framer = GraphicsFramer()
    private let graphics: KittyGraphicsStore
    private var revision: UInt64 = 0
    private var previous: TerminalSnapshot?
    private var title = ""
    private var cursorVisible = true
    private var cursorStyle: TerminalCursor.Style = .block
    private var cursorBlinking = true
    private var historyOffset = 0
    private var pixelWidth = 8
    private var pixelHeight = 16
    private var palette: [TerminalColor] = []
    private var changedPalette: Set<Int> = []
    private var readingPalette = false
    private var paletteResponse = Data()
    private var configuredForeground: TerminalColor = .foreground
    private var configuredBackground: TerminalColor = .background
    private var configuredPalette: [TerminalColor] = []

    public init(columns: Int = 80, rows: Int = 24, scrollback: Int = 10_000,
                imageLimits: TerminalImageLimits = .default) {
        graphics = KittyGraphicsStore(limits: imageLimits)
        terminal = Terminal(delegate: self, options: TerminalOptions(
            cols: min(1000, max(2, columns)), rows: min(1000, max(1, rows)),
            termName: "xterm-256color", scrollback: min(100_000, max(0, scrollback)),
            enableSixelReported: false))
        setColors(foreground: .foreground, background: .background,
                  palette: SwiftTerm.Color.xtermColors.map(Self.color))
    }

    public func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        let oldTop = terminal.getTopVisibleRow() + terminal.buffer.totalLinesTrimmed
        // The framer only intercepts bounded APC packets. VT parsing and Unicode state
        // (including UTF-8 split between network reads) remain owned by SwiftTerm.
        framer.feed(data, onTerminal: { [self] bytes in terminal.feed(byteArray: bytes) },
                    onGraphics: { [self] packet in
            graphics.receive(packet, context: graphicsContext(),
                             output: { [self] data in onOutput?(data) },
                             moveCursor: { [self] cols, rows in
                if rows > 1 { terminal.feed(text: String(repeating: "\n", count: rows - 1)) }
                terminal.buffer.x = min(columns - 1, terminal.buffer.x + cols)
            })
        }, onOverflow: { [self] in graphics.cancelTransfer() }, onReset: { [self] in graphics.reset() })
        let newTop = terminal.getTopVisibleRow() + terminal.buffer.totalLinesTrimmed
        if historyOffset > 0 { historyOffset = min(historyCount, max(0, historyOffset + newTop - oldTop)) }
        refreshPalette()
        if !terminal.synchronizedOutputActive { changed() }
    }

    public func resize(columns: Int, rows: Int) {
        let cols = min(1000, max(2, columns)), rows = min(1000, max(1, rows))
        guard cols != self.columns || rows != self.rows else { return }
        terminal.resize(cols: cols, rows: rows)
        historyOffset = min(historyOffset, historyCount)
        // SwiftTerm's public API does not expose placement anchors across reflow.
        // Drop placements, retaining their bounded image data for explicit redisplay.
        graphics.clearPlacements()
        previous = nil
        changed()
    }

    private var historyCount: Int { terminal.isCurrentBufferAlternate ? 0 : terminal.getTopVisibleRow() }
    private var viewportTop: Int { terminal.getTopVisibleRow() - min(historyOffset, historyCount) }

    public func snapshot() -> TerminalSnapshot {
        var cells: [TerminalCell] = []
        cells.reserveCapacity(columns * rows)
        var damage = Set<Int>()
        var placeholders: [KittyPlaceholderCell] = []
        for row in 0..<rows {
            let line = terminal.bufferLine(atRow: viewportTop + row)
            let start = cells.count
            var decoder = KittyPlaceholderDecoder()
            for column in 0..<columns {
                if let line, column < line.count {
                    var data = line[column]
                    let text = String(terminal.getCharacter(for: data))
                    if data.width == 0, text == "\0", column > 0, line[column - 1].width == 2 {
                        // SwiftTerm 1.20.0 builds wide-character stubs with a stale
                        // Attribute.empty, giving their right half an inverted background.
                        // Normalize only genuine continuation cells in this snapshot copy.
                        data.attribute = line[column - 1].attribute
                    }
                    if let placeholder = decoder.decode(text: text, attribute: data.attribute, column: column, row: row), placeholders.count < 16_384 {
                        placeholders.append(placeholder)
                    }
                    cells.append(cell(data))
                }
                else { cells.append(TerminalCell(foreground: Self.color(terminal.foregroundColor), background: Self.color(terminal.backgroundColor))) }
            }
            if let previous, previous.columns == columns, previous.rows == rows {
                if !cells[start..<(start + columns)].elementsEqual(previous.cells[start..<(start + columns)]) { damage.insert(row) }
            } else { damage.insert(row) }
        }
        let cursor = TerminalCursor(column: min(columns - 1, terminal.buffer.x),
                                    row: terminal.buffer.y + historyOffset,
                                    visible: cursorVisible && historyOffset == 0,
                                    style: cursorStyle, blinking: cursorBlinking)
        let images = graphics.snapshot(context: graphicsContext(), viewportTop: viewportTop, placeholders: placeholders)
        if previous?.cursor != cursor {
            if (0..<rows).contains(cursor.row) { damage.insert(cursor.row) }
            if let old = previous?.cursor.row, (0..<rows).contains(old) { damage.insert(old) }
        }
        if previous?.images != images { damage.formUnion(0..<rows) }
        let result = TerminalSnapshot(revision: revision, columns: columns, rows: rows, cells: cells,
                                      damageRows: damage, cursor: cursor, images: images, title: title,
                                      scrollbackOffset: historyOffset, scrollbackCount: historyCount,
                                      applicationCursor: terminal.applicationCursor,
                                      bracketedPaste: terminal.bracketedPasteMode,
                                      defaultForeground: Self.color(terminal.foregroundColor),
                                      defaultBackground: Self.color(terminal.backgroundColor))
        previous = result
        terminal.clearUpdateRange()
        return result
    }

    public func scroll(by lines: Int) {
        let bounded = min(historyCount, max(-historyCount, lines))
        historyOffset = min(historyCount, max(0, historyOffset + bounded))
        changed()
    }
    public func scrollToBottom() { historyOffset = 0; changed() }

    public func text(in selection: TerminalSelection) -> String {
        let ordered = [selection.start, selection.end].sorted { ($0.row, $0.column) < ($1.row, $1.column) }
        let start = ordered[0], end = ordered[1]
        guard start.row < rows, end.row >= 0 else { return "" }
        let first = max(0, start.row), last = min(rows - 1, end.row)
        guard first <= last else { return "" }
        var text = ""
        for row in first...last {
            guard let line = terminal.bufferLine(atRow: viewportTop + row) else { continue }
            let lower = row == start.row ? min(columns, max(0, start.column)) : 0
            let upper = row == end.row ? min(columns, max(0, end.column)) : columns
            if lower < upper {
                text += line.translateToString(trimRight: true, startCol: lower, endCol: upper,
                                               skipNullCellsFollowingWide: true,
                                               characterProvider: { [self] in terminal.getCharacter(for: $0) })
            }
            if row < last, terminal.bufferLine(atRow: viewportTop + row + 1)?.isWrapped != true { text += "\n" }
        }
        return text
    }

    public func paste(_ text: String) {
        // Remove terminal controls so a pasted ESC cannot terminate bracketed paste.
        let safe = String(text.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 || $0 == "\n" || $0 == "\t" })
            .replacingOccurrences(of: "\n", with: "\r")
        let value = terminal.bracketedPasteMode ? "\u{1b}[200~\(safe)\u{1b}[201~" : safe
        onOutput?(Data(value.utf8))
    }

    public func sendKey(_ key: TerminalKey) {
        let prefix = terminal.applicationCursor ? "\u{1b}O" : "\u{1b}["
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

    public func setCellSize(width: Int, height: Int) { pixelWidth = min(1000, max(1, width)); pixelHeight = min(1000, max(1, height)) }

    public func setColors(foreground: TerminalColor, background: TerminalColor, palette: [TerminalColor]) {
        guard palette.count == 16 else { return }
        configuredForeground = foreground; configuredBackground = background; configuredPalette = palette
        terminal.foregroundColor = Self.swiftColor(foreground)
        terminal.backgroundColor = Self.swiftColor(background)
        terminal.installPalette(colors: palette.map(Self.swiftColor))
        self.palette = palette
        let levels: [UInt8] = [0, 95, 135, 175, 215, 255]
        for red in levels { for green in levels { for blue in levels { self.palette.append(TerminalColor(red: red, green: green, blue: blue)) } } }
        for gray in 0..<24 { let value = UInt8(8 + gray * 10); self.palette.append(TerminalColor(red: value, green: value, blue: value)) }
        changedPalette.removeAll()
        changed()
    }

    public func reset() {
        framer = GraphicsFramer()
        graphics.reset()
        terminal.resetToInitialState()
        historyOffset = 0; title = ""; cursorVisible = true; cursorStyle = .block; cursorBlinking = true; previous = nil
        terminal.setCursorStyle(.blinkBlock)
        setColors(foreground: configuredForeground, background: configuredBackground, palette: configuredPalette)
        onTitleChange?("")
    }

    private func graphicsContext() -> KittyGraphicsContext {
        KittyGraphicsContext(column: terminal.buffer.x, row: terminal.buffer.y,
                             liveTop: terminal.getTopVisibleRow(), trimmed: terminal.buffer.totalLinesTrimmed,
                             columns: columns, rows: rows, cellWidth: pixelWidth, cellHeight: pixelHeight,
                             alternate: terminal.isCurrentBufferAlternate)
    }
    private func changed() { revision &+= 1; onNeedsDisplay?() }

    private func cell(_ data: CharData) -> TerminalCell {
        let attr = data.attribute
        var attributes = TerminalCellAttributes()
        let pairs: [(CharacterStyle, TerminalCellAttributes)] = [(.bold, .bold), (.italic, .italic), (.dim, .dim), (.inverse, .inverse), (.invisible, .invisible), (.blink, .blink), (.underline, .underline), (.crossedOut, .strikethrough)]
        for (source, target) in pairs where attr.style.contains(source) { attributes.insert(target) }
        var fg = resolve(attr.fg, foreground: true), bg = resolve(attr.bg, foreground: false)
        if attributes.contains(.inverse) { swap(&fg, &bg) }
        let underline: TerminalUnderlineStyle
        switch attr.underlineStyle {
        case .none: underline = .none
        case .single: underline = .single
        case .double: underline = .double
        case .curly: underline = .curly
        case .dotted: underline = .dotted
        case .dashed: underline = .dashed
        }
        let character = terminal.getCharacter(for: data)
        let hiddenPlaceholder = character.unicodeScalars.first?.value == 0x10EEEE
        return TerminalCell(text: character == "\0" || hiddenPlaceholder ? " " : String(character), width: Int(data.width),
                            foreground: fg, background: bg, attributes: attributes,
                            underlineStyle: underline, underlineColor: attr.underlineColor.map { resolve($0, foreground: true) })
    }

    private func resolve(_ value: Attribute.Color, foreground: Bool) -> TerminalColor {
        switch value {
        // SwiftTerm uses .defaultColor in both slots. Its meaning depends on the
        // slot; .defaultInvertedColor selects the other side of that default pair.
        // Resolve before applying SGR inverse so explicit and default colors swap alike.
        case .defaultColor: return Self.color(foreground ? terminal.foregroundColor : terminal.backgroundColor)
        case .defaultInvertedColor: return Self.color(foreground ? terminal.backgroundColor : terminal.foregroundColor)
        case let .trueColor(red, green, blue): return TerminalColor(red: red, green: green, blue: blue)
        case let .ansi256(code): return palette.indices.contains(Int(code)) ? palette[Int(code)] : .foreground
        }
    }
    private static func color(_ color: SwiftTerm.Color) -> TerminalColor {
        TerminalColor(red: UInt8(color.red / 257), green: UInt8(color.green / 257), blue: UInt8(color.blue / 257))
    }
    private static func swiftColor(_ color: TerminalColor) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16(color.red) * 257, green: UInt16(color.green) * 257, blue: UInt16(color.blue) * 257)
    }

    // SwiftTerm does not publicly expose the live OSC palette. Query its standard
    // public VT interface after parsing (never recursively from a parser callback).
    private func refreshPalette() {
        guard !changedPalette.isEmpty else { return }
        let indices = changedPalette.sorted(); changedPalette.removeAll()
        readingPalette = true
        defer { readingPalette = false; paletteResponse.removeAll(keepingCapacity: true) }
        for index in indices {
            paletteResponse.removeAll(keepingCapacity: true)
            terminal.feed(text: "\u{1b}]4;\(index);?\u{1b}\\")
            let value = String(decoding: paletteResponse, as: UTF8.self)
            if let range = value.range(of: "rgb:"),
               let end = value[range.lowerBound...].firstIndex(of: "\u{1b}"),
               let parsed = SwiftTerm.Color.parse(String(value[range.lowerBound..<end])), palette.indices.contains(index) {
                palette[index] = Self.color(parsed)
            }
        }
    }

    public func send(source: Terminal, data: ArraySlice<UInt8>) {
        if readingPalette { paletteResponse.append(contentsOf: data); return }
        // The UI sends legacy keyboard events. Decline upstream Kitty keyboard
        // negotiation until the input layer implements the complete protocol.
        if data.starts(with: [0x1b, 0x5b, 0x3f]), data.last == 0x75,
           data.dropFirst(3).dropLast().allSatisfy({ (0x30...0x39).contains($0) }) { return }
        onOutput?(Data(data))
    }
    public func showCursor(source: Terminal) { cursorVisible = true }
    public func hideCursor(source: Terminal) { cursorVisible = false }
    public func setTerminalTitle(source: Terminal, title: String) { self.title = String(title.prefix(1024)); onTitleChange?(self.title) }
    public func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        switch newStyle {
        case .blinkBlock: cursorStyle = .block; cursorBlinking = true
        case .steadyBlock: cursorStyle = .block; cursorBlinking = false
        case .blinkBar: cursorStyle = .bar; cursorBlinking = true
        case .steadyBar: cursorStyle = .bar; cursorBlinking = false
        case .blinkUnderline: cursorStyle = .underline; cursorBlinking = true
        case .steadyUnderline: cursorStyle = .underline; cursorBlinking = false
        }
    }
    public func colorChanged(source: Terminal, idx: Int?) {
        if let idx { changedPalette.insert(idx) } else { changedPalette.formUnion(0..<256) }
    }
    public func cellSizeInPixels(source: Terminal) -> (width: Int, height: Int)? { (pixelWidth, pixelHeight) }
    public func scrolled(source: Terminal, yDisp: Int) {
        graphics.scrollRegion(top: source.buffer.scrollTop, bottom: source.buffer.scrollBottom, context: graphicsContext())
    }
    public func bufferActivated(source: Terminal) { historyOffset = 0; previous = nil; graphics.clearAlternatePlacements() }
    public func isProcessTrusted(source: Terminal) -> Bool { false }
}
