import Foundation
import GhosttyVt
import TerminalCore

/// A `TerminalEngine` backed by libghostty-vt, for comparing against the shipping SwiftTerm
/// engine (#10). It covers parsing, the visible grid with its colours and attributes, the
/// cursor, resizing, scrollback navigation, selection text, and Kitty graphics: direct
/// transfers in RGB, RGBA and PNG, compressed or not, placed either at the cursor or through
/// Unicode placeholders (#18).
@TerminalParserActor public final class GhosttyEngine: TerminalEngine, TerminalImageBudgetOwner {
    public var onOutput: (@TerminalParserActor (Data) -> Void)?
    public var onNeedsDisplay: (@TerminalParserActor () -> Void)?
    public var onImageCacheInvalidated: (@TerminalParserActor () -> Void)?
    public var onTitleChange: (@TerminalParserActor (String) -> Void)?

    public var columns: Int { readCount(GHOSTTY_TERMINAL_DATA_COLS) ?? 80 }
    public var rows: Int { readCount(GHOSTTY_TERMINAL_DATA_ROWS) ?? 24 }

    /// Owned for the object's lifetime and only touched on the engine's isolation; the
    /// deinit frees it without hopping, which is why it is marked unsafe here.
    ///
    /// It is not optional, and that is the point. It used to be, and an engine whose
    /// allocation had failed carried on with every method guarding on nil: output was
    /// discarded, the size read back as 80x24 and `snapshot()` returned a full grid of blank
    /// cells, which on screen is indistinguishable from a connection that hung (#28). The
    /// initializer fails instead, and the caller picks an engine that works.
    private nonisolated(unsafe) let terminal: GhosttyTerminal
    private var revision: UInt64 = 0
    private var previous: TerminalSnapshot?
    private var historyOffset = 0
    /// Decoded image bytes keyed by image id, refreshed when the library's generation stamp
    /// changes, so a placement seen every frame does not copy its pixels every frame.
    private var imageCache: [UInt32: CachedImage] = [:]
    private var imageTick: UInt64 = 0
    /// The ceiling the sessions of one workspace share. Decoded pixels are accounted through
    /// it rather than against a private count of entries, so one oversized image cannot pass
    /// the workspace's ceiling on its own and a memory warning reaches these bytes the same
    /// way it reaches `SwiftTermEngine`'s (#26).
    private let imageBudget: TerminalImageBudget?
    private let imageLimits: TerminalImageLimits
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

    /// One decoded image. `tick` is bumped every time a placement draws it, so the entry the
    /// count cap drops is the one nothing has looked at for the longest rather than all of them.
    private struct CachedImage {
        let generation: UInt64
        let rgba: Data
        let width, height: Int
        var tick: UInt64
    }

    /// A ceiling on synthesised placeholder placements, matching the one `SwiftTermEngine`
    /// puts on the cells it collects. A screen cannot hold this many cells at any size the
    /// app uses; it bounds what a program can make a single snapshot allocate.
    private static let maximumPlaceholderCells = 16_384

    /// Matches `SwiftTermEngine`'s default.
    private static let scrollbackLines = 10_000
    /// The ceiling that actually decides how much memory history can take. See `install()`.
    private static let scrollbackBytes = 24 * 1024 * 1024

    /// Fails when the library refuses to allocate a terminal, which is the only outcome an
    /// engine cannot usefully continue from: there is no parser to feed and no grid to read,
    /// so every call would quietly do nothing (#28). `ConnectionModel` falls back to
    /// `SwiftTermEngine` rather than showing a terminal that never draws.
    public init?(columns: Int = 80, rows: Int = 24,
                 imageBudget: TerminalImageBudget? = nil,
                 imageLimits: TerminalImageLimits = .default) {
        var handle: GhosttyTerminal?
        guard ghostty_terminal_new(nil, &handle, UInt16(min(1000, max(2, columns))),
                                   UInt16(min(1000, max(1, rows)))) == GHOSTTY_SUCCESS,
              let handle else { return nil }
        terminal = handle
        self.imageBudget = imageBudget
        self.imageLimits = imageLimits
        install()
    }

    /// Programs ask the terminal questions — device attributes, XTVERSION, the size in pixels —
    /// and wait for the answer before drawing. Without these callbacks libghostty-vt parses the
    /// queries and drops the replies, so the program waits out its timeout on every one.
    private func install() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, context)
        _ = Self.pngDecoderInstalled

        // Two limits bound history and the byte one binds first, which is the limit that
        // matters when the question is how close a device gets to a jetsam kill. Setting only
        // the line limit left the byte limit at the library's own default of 10,000 *bytes* —
        // about one page — so this engine kept a few hundred lines of history where
        // `SwiftTermEngine` keeps 10,000, while the comment here claimed the two matched.
        // Measured with the byte limit lifted, against per-cell truecolor output, which is the
        // worst case for how many lines fit in a page: 10,000 lines grew the process by 18.7MB
        // and compression brought that back to 13.1MB. Ordinary output reaches the 10,000 line
        // limit inside this ceiling; output designed not to stops at about 4,500 lines instead
        // of running on, which is the trade this number is making.
        var scrollbackBytes = Self.scrollbackBytes
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollbackBytes)
        var scrollback = Self.scrollbackLines
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &scrollback)

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

    /// libghostty-vt carries no image decoder. Its header is explicit that PNG support is the
    /// embedder's to provide — "When set, the terminal can accept PNG images via the Kitty
    /// Graphics Protocol. When cleared (NULL value), PNG decoding is unsupported and PNG image
    /// data will be rejected" — and nothing installed one here, so every `f=100` transfer was
    /// parsed, refused and drawn as nothing while `SwiftTermEngine` drew it. PNG is what a
    /// sender uses for anything it cannot describe as raw pixels, which is most of what is
    /// actually transmitted, so this was the widest of the silent drops in #18.
    ///
    /// The setting is process-global rather than per terminal, which is why this is a static
    /// evaluated once and read from every `install()`. The decode itself is `KittyPNG`, the
    /// same function `SwiftTermEngine`'s store calls, so the two engines produce the same
    /// pixels from the same bytes.
    ///
    /// The limits are the default ones rather than this engine's, because a process-global
    /// callback has no engine to ask. They bound only what the library will hold; the decoded
    /// copy this engine hands the renderer is still reserved against the workspace budget in
    /// `rgba(for:image:)` before it is made.
    private static let pngDecoderInstalled: Bool = {
        let decode: GhosttySysDecodePngFn = { _, allocator, data, length, out in
            guard let data, let out, length > 0 else { return false }
            let limits = TerminalImageLimits.default
            let png = Data(UnsafeBufferPointer(start: data, count: length))
            guard let image = KittyPNG.decode(png, maximumDimension: limits.maximumDimension,
                                              maximumBytes: limits.maximumImageBytes),
                  // The buffer has to come from the allocator the library handed us: it takes
                  // ownership of it and frees it with that same allocator.
                  let buffer = ghostty_alloc(allocator, image.rgba.count) else { return false }
            image.rgba.copyBytes(to: buffer, count: image.rgba.count)
            out.pointee = GhosttySysImage(width: UInt32(image.width), height: UInt32(image.height),
                                          data: buffer, data_len: image.rgba.count)
            return true
        }
        // A sys option takes the function pointer itself, the way the header's own example
        // passes `&ghostty_sys_log_stderr`, and not the address of a variable holding it.
        return ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG,
                               unsafeBitCast(decode, to: UnsafeRawPointer.self)) == GHOSTTY_SUCCESS
    }()

    deinit {
        // The maintenance loop below holds this engine weakly and never across a sleep, so it
        // is not what keeps the object alive and does not have to be cancelled from here — it
        // finds nil on its next hop and ends.
        ghostty_terminal_free(terminal)
    }

    public func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { bytes in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return }
            ghostty_terminal_vt_write(terminal, base, bytes.count)
        }
        flushReplies()
        changed()
        lastFeed = .now
        scheduleCompression()
    }

    public func resize(columns: Int, rows: Int) {
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
        guard lines != 0 else { return }
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
        guard historyOffset != 0 else { return }
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
        var config = GhosttyTerminalModeConfig(mode: mode, value: false)
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &config) == GHOSTTY_SUCCESS else { return false }
        return config.value
    }

    public func setCellSize(width: Int, height: Int) {
        pixelWidth = min(1000, max(1, width))
        pixelHeight = min(1000, max(1, height))
        _ = ghostty_terminal_resize(terminal, UInt16(columns), UInt16(rows),
                                    UInt32(pixelWidth), UInt32(pixelHeight))
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
        ghostty_terminal_reset(terminal)
        releaseAllImages()
        changed()
    }

    // MARK: - Scrollback compression

    /// libghostty-vt reclaims the mappings behind history pages only when its host asks. The
    /// header is explicit about it: "Scrollback compression is caller-driven... libghostty-vt
    /// does not create a timer or background thread." Nothing in this app ever asked, which is
    /// the lead #19 gives for a footprint that climbs for as long as a program keeps writing
    /// and falls back only once it stops.
    ///
    /// The library hands out an activity token that changes when compression-relevant state
    /// moves. Caching it here is what the header asks a host to do: it decides whether there is
    /// anything to schedule at all, so quiet output costs one state read per batch and no task.
    private var compressedActivity: UInt64 = 0
    private var compressionTask: Task<Void, Never>?
    /// Identifies the loop that is allowed to run. A loop suspended in its idle delay can find
    /// on waking that the pass it belonged to has already ended — `compressScrollbackNow` can
    /// end one, and so can the library reporting no continuation — by which point a later feed
    /// may have started a replacement. Carrying the number it started with lets the superseded
    /// one recognise itself and stop instead of stepping alongside its successor.
    private var compressionGeneration: UInt64 = 0
    /// A pass that reported pending work still owes the remaining steps, even though the token
    /// it started from has already been accounted for.
    private var isCompressionPassOpen = false
    /// When output last arrived and when a step last ran, so compression fills the gaps between
    /// writes instead of competing with them. `ghostty_terminal_compress` is documented as
    /// unsafe to interleave with other terminal calls; both run on `TerminalParserActor` and a
    /// step never suspends, so the actor is what serializes them.
    private var lastFeed = ContinuousClock.now
    private var lastStep = ContinuousClock.now

    /// Incremental steps run and passes finished. Published so a test can assert the scheduler
    /// ran and the library reported progress, which is checkable anywhere, rather than assert a
    /// footprint that only means something on the device it was measured on.
    public private(set) var compressionSteps = 0
    public private(set) var compressionPasses = 0
    /// True once the library answers that this target cannot reclaim retained mappings. It is a
    /// property of the target, not of the moment, so asking again on every batch would cost a
    /// call per batch to learn the same answer.
    public private(set) var compressionIsUnsupported = false

    /// Long enough not to fire between the batches of one repaint, short enough that the pause
    /// after a command finishes is already an opportunity.
    private static let compressionIdleDelay = Duration.milliseconds(150)
    /// Output that never pauses never goes idle, and that is exactly the case #19 measured. A
    /// step costs about a millisecond, so letting one through at this interval puts a bound on
    /// how far history runs uncompressed while a program keeps writing, at a share of the parse
    /// loop too small to show up against it.
    private static let compressionBusyInterval = Duration.milliseconds(250)

    private func scheduleCompression() {
        guard !compressionIsUnsupported, compressionTask == nil else { return }
        // Only reads state. A task costs more than the read, so ask first whether anything
        // compression-relevant moved before paying for one.
        var activity: UInt64 = 0
        guard ghostty_terminal_compression_activity(terminal, &activity) == GHOSTTY_SUCCESS,
              activity != compressedActivity else { return }
        compressionGeneration &+= 1
        let generation = compressionGeneration
        compressionTask = Task { @TerminalParserActor [weak self] in
            while true {
                // The engine is held for one hop at a time and never across a suspension, so a
                // session that goes away is not kept alive by its own maintenance: the next hop
                // finds nil and the loop ends.
                guard let wait = self?.compressionWait(generation: generation) else { return }
                if wait > .zero {
                    try? await Task.sleep(for: wait)
                    continue
                }
                guard self?.compressionStep() == true else { return }
                // Between steps, never inside one. A repaint that arrives mid-pass is parsed
                // before the next step rather than behind the whole pass.
                await Task.yield()
            }
        }
    }

    /// How long to wait before the next step: zero to take one now, nil when there is nothing
    /// left to do and the loop should end.
    private func compressionWait(generation: UInt64) -> Duration? {
        guard generation == compressionGeneration else { return nil }
        var activity: UInt64 = 0
        guard ghostty_terminal_compression_activity(terminal, &activity) == GHOSTTY_SUCCESS else {
            return endCompression()
        }
        // Between passes only a change in the library's token means there is new work. Mid-pass
        // the token has already been accounted for and the remaining steps still have to run.
        if !isCompressionPassOpen, activity == compressedActivity { return endCompression() }
        let now = ContinuousClock.now
        let sinceFeed = lastFeed.duration(to: now), sinceStep = lastStep.duration(to: now)
        if sinceFeed >= Self.compressionIdleDelay || sinceStep >= Self.compressionBusyInterval { return .zero }
        return min(Self.compressionIdleDelay - sinceFeed, Self.compressionBusyInterval - sinceStep)
    }

    /// Takes one bounded step and answers whether the loop should continue.
    private func compressionStep() -> Bool {
        var result = GHOSTTY_TERMINAL_COMPRESSION_RESULT_COMPLETE
        lastStep = .now
        compressionSteps &+= 1
        guard ghostty_terminal_compress(terminal, GHOSTTY_TERMINAL_COMPRESSION_MODE_INCREMENTAL,
                                        &result) == GHOSTTY_SUCCESS else {
            endCompression()
            return false
        }
        if result == GHOSTTY_TERMINAL_COMPRESSION_RESULT_PENDING {
            isCompressionPassOpen = true
            return true
        }
        // Complete, or unsupported on a target that cannot reclaim retained mappings. Either
        // way there is no continuation to schedule until the token moves again, so record the
        // token this pass finished against and let the next change start the following one.
        if result == GHOSTTY_TERMINAL_COMPRESSION_RESULT_UNSUPPORTED { compressionIsUnsupported = true }
        else { compressionPasses &+= 1 }
        _ = ghostty_terminal_compression_activity(terminal, &compressedActivity)
        endCompression()
        return false
    }

    /// Ends the maintenance loop. The nil return lets `compressionWait` say "nothing to wait
    /// for" and stop the loop in the same statement.
    @discardableResult
    private func endCompression() -> Duration? {
        compressionTask = nil
        isCompressionPassOpen = false
        compressionGeneration &+= 1
        return nil
    }

    /// Runs the same bounded steps the idle scheduler runs, back to back until the library
    /// reports no continuation, and answers how many it took. This is the shape a
    /// memory-warning handler wants — reclaim now rather than at the next quiet moment — and
    /// the shape a measurement can put a number on. The library's own full mode is deliberately
    /// not used: it is documented to stall on large scrollback, and this actor is shared by
    /// every session in the app.
    @discardableResult
    public func compressScrollbackNow(maximumSteps: Int = 4096) -> Int {
        guard !compressionIsUnsupported else { return 0 }
        var steps = 0
        while steps < maximumSteps {
            let more = compressionStep()
            steps += 1
            if !more { break }
        }
        return steps
    }

    /// Answers the terminal produced while parsing: device attributes, XTVERSION, size
    /// reports. A program that asked waits for these before it draws.
    private func flushReplies() {
        guard !replies.isEmpty else { return }
        let pending = replies
        replies.removeAll(keepingCapacity: true)
        for reply in pending { onOutput?(reply) }
    }

    /// Visible Kitty placements, mapped to what the renderer draws.
    ///
    /// Two kinds come through the one iterator. An ordinary placement has a position of its
    /// own and reports a rectangle. A virtual placement — the Unicode placeholder protocol —
    /// reports none by contract: the header says `ghostty_kitty_graphics_placement_rect`
    /// returns "GHOSTTY_NO_VALUE for virtual placements", because its position is wherever the
    /// U+10EEEE cells naming it happen to be, and those move with the text through wrapping,
    /// scrolling and reflow. Reading the rectangle and skipping what has none therefore
    /// dropped every placeholder image in silence (#18). They are resolved instead by decoding
    /// the placeholder cells out of the grid and synthesising one placement per cell, which is
    /// what `SwiftTermEngine` does through the same `KittyPlaceholderDecoder` and
    /// `KittyPlaceholderLayout`.
    private func placements() -> [TerminalImagePlacement] {
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
        /// The virtual placements seen this pass, in iteration order, each with the block of
        /// cells it reserves. A placeholder cell is matched against these below.
        var virtualPlacements: [(imageID: UInt32, prototype: KittyPlaceholderPrototype)] = []
        while ghostty_kitty_graphics_placement_next(iterator) {
            var imageID: UInt32 = 0, placementID: UInt32 = 0, zIndex: Int32 = 0
            var offsetX: UInt32 = 0, offsetY: UInt32 = 0
            var isVirtual = false
            _ = ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID, &imageID)
            _ = ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_PLACEMENT_ID, &placementID)
            _ = ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Z, &zIndex)
            _ = ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_X_OFFSET, &offsetX)
            _ = ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL, &isVirtual)
            _ = ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Y_OFFSET, &offsetY)
            if isVirtual {
                // Note what the placement reserves and nothing else: whether any of it is on
                // screen, and where, is a question about the cells, not about the placement.
                // Its pixels are only decoded if a cell turns out to ask for them, so a
                // placement left behind by a program that never drew costs nothing.
                var columns: UInt32 = 0, rows: UInt32 = 0
                guard let image = ghostty_kitty_graphics_image(storage, imageID),
                      ghostty_kitty_graphics_placement_grid_size(iterator, image, terminal, &columns, &rows) == GHOSTTY_SUCCESS,
                      columns > 0, rows > 0 else { continue }
                virtualPlacements.append((imageID, KittyPlaceholderPrototype(placementID: placementID,
                                                                            columns: Int(columns), rows: Int(rows),
                                                                            zIndex: Int(zIndex))))
                continue
            }
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

        if !virtualPlacements.isEmpty {
            result.append(contentsOf: placeholderPlacements(virtualPlacements, storage: storage))
        }

        // An image the program deleted, or one the library dropped from its own storage, would
        // otherwise leave its decoded copy here and its bytes counted against the workspace
        // forever. The cache is capped at `imageLimits.maximumImages` entries and is empty for
        // text-only output, so this costs nothing on the path that matters.
        if !imageCache.isEmpty {
            for id in Array(imageCache.keys) where ghostty_kitty_graphics_image(storage, id) == nil {
                removeImage(id)
            }
        }
        return result
    }

    /// One placement per placeholder cell on screen, each showing the single cell-sized tile of
    /// its image that the cell's diacritics name.
    ///
    /// This walks the viewport a second time, after `snapshot()` has already walked it for the
    /// cells, because the id lives in the cell's colour as the terminal stored it and a
    /// `TerminalCell` carries the resolved colour instead: a palette index has become an RGB
    /// triple by then, and the two mean different things here. The walk only happens for a
    /// screen that has a virtual placement on it, where the cost of reading the grid twice is
    /// nothing beside the cost of drawing the image.
    private func placeholderPlacements(_ virtualPlacements: [(imageID: UInt32, prototype: KittyPlaceholderPrototype)],
                                       storage: GhosttyKittyGraphics) -> [TerminalImagePlacement] {
        let columns = columns, rows = rows
        var result: [TerminalImagePlacement] = []
        // One decode per image rather than per cell: a full screen of placeholders is
        // thousands of cells naming the same one or two images.
        var decoded: [UInt32: (rgba: Data, width: Int, height: Int, generation: UInt64)?] = [:]
        for row in 0..<rows {
            // A sender may leave the row and column diacritics off a cell that continues the
            // one before it, so the decoder has to see every cell of the row in order, and a
            // fresh one starts each row. `SwiftTermEngine` drives it the same way.
            var decoder = KittyPlaceholderDecoder()
            for column in 0..<columns {
                let source = placeholderSource(column: column, row: row)
                guard let cell = decoder.decode(text: source.text, foreground: source.foreground,
                                                underlineColor: source.underlineColor,
                                                column: column, row: row),
                      result.count < Self.maximumPlaceholderCells else { continue }
                // A cell naming no placement id takes the most recent virtual placement of its
                // image, which is the rule `KittyGraphicsStore` applies to the same lookup.
                guard let match = virtualPlacements.last(where: {
                    $0.imageID == cell.imageID && (cell.placementID == 0 || $0.prototype.placementID == cell.placementID)
                }) else { continue }
                let pixels: (rgba: Data, width: Int, height: Int, generation: UInt64)?
                if let known = decoded[cell.imageID] { pixels = known }
                else {
                    pixels = ghostty_kitty_graphics_image(storage, cell.imageID).flatMap { rgba(for: cell.imageID, image: $0) }
                    decoded[cell.imageID] = pixels
                }
                guard let pixels,
                      let placement = KittyPlaceholderLayout.placement(
                        cell: cell, prototype: match.prototype,
                        imageWidth: pixels.width, imageHeight: pixels.height,
                        rgba: pixels.rgba, contentRevision: pixels.generation,
                        cellWidth: pixelWidth, cellHeight: pixelHeight) else { continue }
                result.append(placement)
            }
        }
        return result
    }

    /// What the placeholder decoder needs from one cell: its text, and its foreground and
    /// underline colours in the form the terminal stored them. Everything that is not a
    /// placeholder answers blank, which is what ends a run of continued cells.
    private func placeholderSource(column: Int, row: Int) -> (text: String, foreground: KittyPlaceholderColor,
                                                              underlineColor: KittyPlaceholderColor) {
        let blank = (" ", KittyPlaceholderColor.unset, KittyPlaceholderColor.unset)
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate = GhosttyPointCoordinate(x: UInt16(column), y: UInt32(row))
        var ref = GhosttyGridRef()
        guard ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS else { return blank }
        var packed: GhosttyCell = 0
        guard ghostty_grid_ref_cell(&ref, &packed) == GHOSTTY_SUCCESS else { return blank }
        var codepoint: UInt32 = 0
        _ = ghostty_cell_get(packed, GHOSTTY_CELL_DATA_CODEPOINT, &codepoint)
        // The diacritics are the rest of the grapheme cluster, so only a cell that starts with
        // the placeholder codepoint is worth assembling into a string.
        guard codepoint == 0x10EEEE else { return blank }
        var style = GhosttyStyle()
        style.size = MemoryLayout<GhosttyStyle>.size
        let text = cluster(codepoint: codepoint, packed: packed, ref: &ref)
        guard ghostty_grid_ref_style(&ref, &style) == GHOSTTY_SUCCESS else { return (text, .unset, .unset) }
        return (text, placeholderColor(style.fg_color), placeholderColor(style.underline_color))
    }

    /// Unlike `color(_:fallback:)` this must not resolve a palette index through the palette:
    /// the index is the low byte of the image id, and the colour it would paint is not.
    private func placeholderColor(_ value: GhosttyStyleColor) -> KittyPlaceholderColor {
        switch value.tag {
        case GHOSTTY_STYLE_COLOR_PALETTE: return .palette(Int(value.value.palette))
        case GHOSTTY_STYLE_COLOR_RGB: return .rgb(value.value.rgb.r, value.value.rgb.g, value.value.rgb.b)
        default: return .unset
        }
    }

    private func rgba(for id: UInt32, image: GhosttyKittyGraphicsImage) -> (rgba: Data, width: Int, height: Int, generation: UInt64)? {
        var generation: UInt64 = 0
        _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_GENERATION, &generation)
        if let cached = imageCache[id], cached.generation == generation {
            imageTick &+= 1
            imageCache[id]?.tick = imageTick
            // Drawing an image is what keeps it: the workspace evicts the entry nothing has
            // looked at for the longest, across every session sharing the budget.
            imageBudget?.touch(imageID: id, owner: self)
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
        let pixelsAvailable = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR, &pointer)
        _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN, &length)
        // What the library stores is always decoded and always inflated. The header says so
        // twice — compression is "Always GHOSTTY_KITTY_IMAGE_COMPRESSION_NONE; compressed
        // payloads are inflated before storage", format is "Never
        // GHOSTTY_KITTY_IMAGE_FORMAT_PNG" — and measuring this pin agrees: an `o=z` transfer
        // arrives here byte for byte identical to the same pixels sent uncompressed. So this
        // is a contract check and never a reason a compressed image failed to draw, which is
        // how #18 read it. It stays because if a later pin did hand over deflated bytes,
        // drawing nothing is better than drawing them as pixels.
        guard compression == GHOSTTY_KITTY_IMAGE_COMPRESSION_NONE else { return nil }
        // A chunked transfer is resident before it is complete: the header documents
        // GHOSTTY_NO_VALUE here as "the image metadata is resident but its pixel payload is
        // pending", with the length already reserved. Skipping it is right, and it is only for
        // this frame — the chunk that completes the payload is another write, which marks the
        // engine dirty and brings the next snapshot back here to find the pixels. Nothing is
        // cached for a pending image, so nothing has to be invalidated when it arrives.
        guard pixelsAvailable == GHOSTTY_SUCCESS, let pointer,
              width > 0, height > 0, length > 0 else { return nil }

        // The decoded size is known before a byte is allocated for it, so the oversized case
        // is refused rather than converted and then freed. A 4000x4000 image is 64MB of RGBA
        // on its own, which is the whole workspace ceiling (#26). `KittyGraphicsStore` applies
        // the same limits to the same effect on the other engine.
        let pixels = Int(width) * Int(height)
        let bytes = pixels * 4
        guard Int(width) <= imageLimits.maximumDimension, Int(height) <= imageLimits.maximumDimension,
              bytes <= imageLimits.maximumImageBytes else { return nil }
        var converted = Data(count: bytes)
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

        // From here to the store, every entry this drops is one this engine is displacing with
        // an image it has just decoded — its own older pixels, whether through the count cap
        // below or through the budget reaching back into this owner. A fresh snapshot is
        // already on its way, so none of it is announced. See `removeImage(_:)`.
        isMakingRoomForOwnImage = true
        defer { isMakingRoomForOwnImage = false }

        // Replacing the pixels of an id already held: give back the old bytes first, so the
        // budget never counts two generations of the same image at once.
        if imageCache[id] != nil { removeImage(id) }
        // Reserving before storing matters: making room can evict this engine's own entries,
        // and that eviction must not find a half-written cache. A refusal means the image is
        // larger than the workspace ceiling, so there is nothing to draw it from.
        guard imageBudget?.reserve(bytes: bytes, imageID: id, owner: self) ?? true else { return nil }
        // The count cap used to be `removeAll`, which meant a screen holding one image more
        // than the cap re-decoded every one of them on every frame. Drop the least recently
        // drawn entry instead.
        while imageCache.count >= imageLimits.maximumImages,
              let oldest = imageCache.min(by: { $0.value.tick < $1.value.tick })?.key {
            removeImage(oldest)
        }
        imageTick &+= 1
        imageCache[id] = CachedImage(generation: generation, rgba: converted,
                                     width: Int(width), height: Int(height), tick: imageTick)
        return (converted, Int(width), Int(height), generation)
    }

    /// True while this engine is displacing its own pixels with an image it has just decoded,
    /// so the budget calling back into it is not another session taking the memory away.
    private var isMakingRoomForOwnImage = false

    /// `TerminalImageBudgetOwner`: the budget evicting this engine's image. The budget has
    /// already removed its accounting entry.
    ///
    /// Announced unless this engine asked for the room itself. A memory warning, or another
    /// session's image displacing this one, is memory being taken away from a frame that may
    /// be the last one a hidden session ever draws — exactly what #26 was about. This engine
    /// making room for its own next frame is not, and announcing it once per frame is what
    /// made stepping through a video strobe.
    public func evictImage(_ id: UInt32) {
        if isMakingRoomForOwnImage { removeImage(id) } else { evictImageAnnouncing(id) }
    }

    /// Drops one image's pixels, its accounting, and the snapshot still holding them. Without
    /// the callback the published snapshot keeps the bytes alive in a hidden view's last frame
    /// and the eviction frees nothing — `onImageCacheInvalidated` was declared here and never
    /// called (#26).
    private func evictImageAnnouncing(_ id: UInt32) {
        guard removeImage(id) else { return }
        previous = nil
        onImageCacheInvalidated?()
        changed()
    }

    /// Drops one image's pixels and its accounting without asking the caller for anything.
    ///
    /// The announcement above costs a frame. `ConnectionModel` answers it by clearing the
    /// published snapshot and scheduling another, so the view draws its background colour once
    /// before the replacement arrives. That is the right trade for an eviction, where the whole
    /// point is to stop a frame already on screen from keeping the bytes alive.
    ///
    /// It is the wrong trade for bookkeeping. Reaping an entry whose image the library has
    /// already dropped, or replacing one generation of an image with the next, leaves the frame
    /// on screen still being the frame the terminal means, and nothing is waiting on its
    /// memory — the snapshot that replaces it is already being built. Announcing those made a
    /// repaint that deletes an image flash the terminal's background on this engine, which is
    /// the flicker choosing this engine is supposed to avoid.
    @discardableResult
    private func removeImage(_ id: UInt32) -> Bool {
        guard imageCache.removeValue(forKey: id) != nil else { return false }
        imageBudget?.release(imageID: id, owner: self)
        return true
    }

    private func releaseAllImages() {
        guard !imageCache.isEmpty else { return }
        imageCache.removeAll(keepingCapacity: true)
        imageBudget?.releaseAll(owner: self)
        previous = nil
        onImageCacheInvalidated?()
    }

    private func changed() {
        revision &+= 1
        onNeedsDisplay?()
    }

    /// Each key writes its own type through the void pointer, so reading one through a
    /// differently sized variable corrupts the stack around it. The header documents the type
    /// per key; these three cover the ones this engine reads.
    private func readCount(_ key: GhosttyTerminalData) -> Int? {
        var value: UInt16 = 0
        guard ghostty_terminal_get(terminal, key, &value) == GHOSTTY_SUCCESS else { return nil }
        return Int(value)
    }

    private func readFlag(_ key: GhosttyTerminalData) -> Bool? {
        var value = false
        guard ghostty_terminal_get(terminal, key, &value) == GHOSTTY_SUCCESS else { return nil }
        return value
    }

    private func readSize(_ key: GhosttyTerminalData) -> Int? {
        var value = 0
        guard ghostty_terminal_get(terminal, key, &value) == GHOSTTY_SUCCESS else { return nil }
        return value
    }

    private func cell(column: Int, row: Int) -> TerminalCell {
        let blank = TerminalCell(foreground: foreground, background: background)
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

        let text = codepoint == 0 ? " " : cluster(codepoint: codepoint, packed: packed, ref: &ref)
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

    /// The cell's primary codepoint carries the base character and nothing else. A character
    /// built from a base plus combining marks — which is how macOS hands over anything it has
    /// normalized, so how Japanese arrives from one — keeps the marks alongside it, and reading
    /// only the primary drops them: が becomes か (#21).
    private func cluster(codepoint: UInt32, packed: GhosttyCell, ref: inout GhosttyGridRef) -> String {
        let base = UnicodeScalar(codepoint).map(String.init) ?? " "
        var tag = GHOSTTY_CELL_CONTENT_CODEPOINT
        guard ghostty_cell_get(packed, GHOSTTY_CELL_DATA_CONTENT_TAG, &tag) == GHOSTTY_SUCCESS,
              tag == GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME else { return base }

        // The first call sizes the cluster; the library reports how much room it needs.
        var count = 0
        _ = ghostty_grid_ref_graphemes(&ref, nil, 0, &count)
        guard count > 1, count <= 32 else { return base }
        var codepoints = [UInt32](repeating: 0, count: count)
        guard ghostty_grid_ref_graphemes(&ref, &codepoints, count, &count) == GHOSTTY_SUCCESS else { return base }
        var scalars = String.UnicodeScalarView()
        for value in codepoints.prefix(count) {
            guard let scalar = UnicodeScalar(value) else { return base }
            scalars.append(scalar)
        }
        return String(scalars)
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
