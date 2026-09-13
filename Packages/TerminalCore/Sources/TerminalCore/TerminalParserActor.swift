/// The isolation domain that owns VT parsing, terminal buffers, and decoded image state.
///
/// Parsing a full-screen repaint costs tens of milliseconds, so running it on the main actor
/// made input handling, layout, and the render loop wait behind the shell's output. Everything
/// here is off the main actor instead, and hands the UI immutable `TerminalSnapshot` values.
///
/// One shared actor serves every session rather than one per session: the sessions in a
/// workspace share a decoded-image budget that evicts across stores, and eviction has to reach
/// another session's state synchronously. Only the selected terminal is drawn, and hidden
/// sessions already parsed on the same thread as the visible one before this existed.
@globalActor public actor TerminalParserActor {
    public static let shared = TerminalParserActor()
}
