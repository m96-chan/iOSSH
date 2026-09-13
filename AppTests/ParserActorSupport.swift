import TerminalCore

/// Runs terminal-parser work in its own isolation. Renderer and view tests live on the main
/// actor and drive a parser to build fixtures, so they hop here and carry back a snapshot.
@TerminalParserActor func onParser<T: Sendable>(_ body: @TerminalParserActor () throws -> T) rethrows -> T {
    try body()
}
