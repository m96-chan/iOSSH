import Foundation

/// Serial access to one terminal's parser from outside `TerminalParserActor`.
///
/// The parser and its buffers never leave that actor. Callers hand over work here and receive
/// immutable snapshots, so a repaint costing tens of milliseconds cannot hold up input, layout,
/// or drawing. Every command runs in the order it was submitted, which keeps typed bytes,
/// resizes, and the output they interleave with in the order the shell and the user produced
/// them; queries answer after the work queued ahead of them.
public final class TerminalPipeline: Sendable {
    private enum Command: Sendable {
        case data(Data)
        case key(TerminalKey, origin: UUID?)
        case paste(String, origin: UUID?)
        case resize(columns: Int, rows: Int)
        case scroll(lines: Int)
        case scrollToBottom
        case cellSize(width: Int, height: Int)
        case colors(foreground: TerminalColor, background: TerminalColor, palette: [TerminalColor])
        case reset
        case snapshot(@Sendable (TerminalSnapshot) -> Void)
        case snapshotIfDrained(@Sendable (TerminalSnapshot?) -> Void)
        case text(TerminalSelection, @Sendable (String) -> Void)
    }

    private let commands: AsyncStream<Command>.Continuation
    private let task: Task<Void, Never>
    /// Output submitted but not parsed yet. A program repainting the screen sends one frame as
    /// several batches, so drawing while this is above zero shows a repaint in progress.
    private let unparsed: Counter

    /// Builds the parser this pipeline drives. Supplying one selects a different engine;
    /// the default is the SwiftTerm adapter the app ships with.
    public typealias EngineFactory = @TerminalParserActor @Sendable (_ columns: Int, _ rows: Int, _ imageBudget: TerminalImageBudget?) -> any TerminalEngine

    public init(columns: Int = 80, rows: Int = 24, imageBudget: TerminalImageBudget? = nil,
                makeEngine: EngineFactory? = nil,
                onOutput: @escaping @Sendable (Data, UUID?) -> Void,
                onNeedsDisplay: @escaping @Sendable () -> Void,
                onImageCacheInvalidated: @escaping @Sendable () -> Void,
                onTitleChange: @escaping @Sendable (String) -> Void) {
        // Commands are small and already bounded by what one shell and one person can produce.
        // Dropping any of them would lose typed bytes or leave the grid at a stale size.
        let (stream, continuation) = AsyncStream<Command>.makeStream(bufferingPolicy: .unbounded)
        commands = continuation
        let unparsed = Counter()
        self.unparsed = unparsed
        task = Task { @TerminalParserActor in
            let engine = makeEngine?(columns, rows, imageBudget)
                ?? SwiftTermEngine(columns: columns, rows: rows, imageBudget: imageBudget)
            // A key or a paste produces its bytes synchronously inside the command that asked
            // for it, so the caller's token identifies what the person typed. Anything else the
            // parser writes is a reply to the shell and carries no token.
            let origin = OriginBox()
            engine.onOutput = { data in onOutput(data, origin.value) }
            engine.onNeedsDisplay = onNeedsDisplay
            engine.onImageCacheInvalidated = onImageCacheInvalidated
            engine.onTitleChange = onTitleChange
            onNeedsDisplay()
            for await command in stream {
                switch command {
                case .data(let data):
                    engine.feed(data)
                    unparsed.decrement()
                case .key(let key, let token):
                    origin.value = token
                    engine.sendKey(key)
                    origin.value = nil
                case .paste(let text, let token):
                    origin.value = token
                    engine.paste(text)
                    origin.value = nil
                case .resize(let columns, let rows): engine.resize(columns: columns, rows: rows)
                case .scroll(let lines): engine.scroll(by: lines)
                case .scrollToBottom: engine.scrollToBottom()
                case .cellSize(let width, let height): engine.setCellSize(width: width, height: height)
                case .colors(let foreground, let background, let palette):
                    engine.setColors(foreground: foreground, background: background, palette: palette)
                case .reset: engine.reset()
                case .snapshot(let answer): answer(engine.snapshot())
                case .snapshotIfDrained(let answer):
                    answer(unparsed.isZero ? engine.snapshot() : nil)
                case .text(let selection, let answer): answer(engine.text(in: selection))
                }
            }
        }
    }

    deinit {
        commands.finish()
        task.cancel()
    }

    public func feed(_ data: Data) {
        unparsed.increment()
        commands.yield(.data(data))
    }
    /// `origin` marks bytes the person typed, so a caller can drop them if the shell they were
    /// meant for has gone away. Parser replies arrive without one.
    public func sendKey(_ key: TerminalKey, origin: UUID? = nil) { commands.yield(.key(key, origin: origin)) }
    public func paste(_ text: String, origin: UUID? = nil) { commands.yield(.paste(text, origin: origin)) }
    public func resize(columns: Int, rows: Int) { commands.yield(.resize(columns: columns, rows: rows)) }
    /// Positive values move into history; negative values move toward the live screen.
    public func scroll(by lines: Int) { commands.yield(.scroll(lines: lines)) }
    public func scrollToBottom() { commands.yield(.scrollToBottom) }
    public func setCellSize(width: Int, height: Int) { commands.yield(.cellSize(width: width, height: height)) }
    public func setColors(foreground: TerminalColor, background: TerminalColor, palette: [TerminalColor]) {
        commands.yield(.colors(foreground: foreground, background: background, palette: palette))
    }
    public func reset() { commands.yield(.reset) }

    /// The grid as it stands once everything submitted before this call has been parsed.
    public func snapshot() async -> TerminalSnapshot {
        await withCheckedContinuation { continuation in
            commands.yield(.snapshot { continuation.resume(returning: $0) })
        }
    }

    /// The grid once nothing else is waiting to be parsed, or `nil` while output is still
    /// arriving. Drawing only complete work keeps a repaint from appearing half-finished.
    public func snapshotIfDrained() async -> TerminalSnapshot? {
        await withCheckedContinuation { continuation in
            commands.yield(.snapshotIfDrained { continuation.resume(returning: $0) })
        }
    }

    public func text(in selection: TerminalSelection) async -> String {
        await withCheckedContinuation { continuation in
            commands.yield(.text(selection) { continuation.resume(returning: $0) })
        }
    }
}


/// Mutable only inside `TerminalParserActor`, where the command loop sets it around the one
/// call that can produce typed bytes.
@TerminalParserActor private final class OriginBox {
    var value: UUID?
}


/// Counts work submitted from any isolation against work finished inside the parser.
private final class Counter: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    func decrement() {
        lock.lock()
        value -= 1
        lock.unlock()
    }

    var isZero: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value == 0
    }
}
