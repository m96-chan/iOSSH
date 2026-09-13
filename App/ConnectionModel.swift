import Foundation
import Observation
import SSHCore
import GhosttyEngine
import TerminalCore
import TerminalRender

@MainActor
protocol ConnectionTransport: AnyObject {
    var onData: (@Sendable (Data) -> Void)? { get set }
    var onDisconnect: (@MainActor (String?) -> Void)? { get set }
    var onAuthenticationBanner: (@MainActor (String) -> Void)? { get set }
    var isConnected: Bool { get }
    func connect(host: SSHHost, credential: SSHCredential, columns: Int, rows: Int,
                 pixelWidth: Int, pixelHeight: Int,
                 confirmHostKey: @escaping @Sendable (HostKeyChallenge) async -> Bool) async throws
    func write(_ data: Data) async throws
    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws
    func checkConnection() async throws
    func disconnect() async
}

extension SSHSession: ConnectionTransport {}

/// Temporary instrumentation for the frame-rate work. `commit` is how long a cycle took from
/// the parser asking for a repaint to the snapshot being published; `gap` is the time between
/// one snapshot being published and the next repaint request arriving, which is where the
/// renderer and SwiftUI show up. Remove once the question is settled.
@MainActor fileprivate struct FrameLog {
    private var frames = 0
    private var commit = 0.0
    private var gap = 0.0
    private var published: ContinuousClock.Instant?
    private var window = ContinuousClock.now

    mutating func record(start: ContinuousClock.Instant) {
        let now = ContinuousClock.now
        frames += 1
        commit += Self.milliseconds(start.duration(to: now))
        if let published { gap += Self.milliseconds(published.duration(to: start)) }
        published = now
        let elapsed = Self.milliseconds(window.duration(to: now))
        guard elapsed >= 1000 else { return }
        print(String(format: "FRAMES %.1f/s commit=%.1fms gap=%.1fms",
                     Double(frames) * 1000 / elapsed, commit / Double(frames), gap / Double(frames)))
        frames = 0
        commit = 0
        gap = 0
        window = now
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}

/// Temporary instrumentation for the frame-rate work. Records where SSH output arrives, which
/// is off the main actor, so it takes a lock. Remove once the question is settled.
private let inputLog = ByteLog()

private final class ByteLog: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    private var chunks = 0
    private var window = ContinuousClock.now

    func record(_ count: Int) {
        lock.lock()
        bytes += count
        chunks += 1
        let now = ContinuousClock.now
        let elapsed = Double(window.duration(to: now).components.seconds) * 1000
            + Double(window.duration(to: now).components.attoseconds) / 1e15
        guard elapsed >= 1000 else { lock.unlock(); return }
        let line = String(format: "INPUT %.0f KB/s chunks=%.0f/s mean=%d bytes",
                          Double(bytes) / elapsed, Double(chunks) * 1000 / elapsed,
                          bytes / max(chunks, 1))
        bytes = 0
        chunks = 0
        window = now
        lock.unlock()
        print(line)
    }
}

/// Open until the attempt that installed it is replaced or closed.
private final class OutputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true

    var isOpen: Bool { lock.withLock { open } }
    func close() { lock.withLock { open = false } }
}

/// Lets the parser's callbacks reach the model without the model escaping its own init.
@MainActor private final class WeakModel: Sendable {
    weak var model: ConnectionModel?
}

@MainActor @Observable
final class ConnectionModel: Identifiable {
    @MainActor struct Dependencies {
        var makeTransport: @MainActor () throws -> any ConnectionTransport
        var loadCredential: @MainActor (UUID) async throws -> SSHCredential?
        var saveCredential: @MainActor (SSHCredential, UUID) async throws -> Void

        static let live = Self(
            makeTransport: { SSHSession(knownHosts: KnownHostsStore(url: try KnownHostsStore.defaultURL())) },
            loadCredential: { try await CredentialStore().load(for: $0) },
            saveCredential: { try await CredentialStore().save($0, for: $1) }
        )
    }

    enum Phase: String { case idle, connecting, connected, checking, disconnected, failed }
    struct TrustPrompt: Identifiable {
        let id = UUID()
        let attemptID: UUID
        let challenge: HostKeyChallenge
    }
    struct CredentialAnswer {
        let credential: SSHCredential
        let save: Bool
    }
    private enum WriteOperation: Sendable {
        case data(Data, userInputGeneration: UUID?)
        case resize
    }

    /// A shell's identity is independent of its saved host, which can have multiple shells.
    let id = UUID()
    let host: SSHHost
    /// Serial access to this session's parser, which runs off the main actor. The UI only ever
    /// sees the snapshots it hands back.
    @ObservationIgnored let terminal: TerminalPipeline
    /// The grid the parser was last asked for. Mirrored here because the PTY size is decided on
    /// this side and the parser is no longer readable without awaiting it.
    private(set) var columns = 80
    private(set) var rows = 24
    /// The rendered cell size. Programs that draw images read the terminal's pixel size from
    /// the remote tty, so every window size sent to the PTY carries it. Zero until the view
    /// has measured a cell, which is the protocol's "unknown".
    private var cellPixelWidth = 0
    private var cellPixelHeight = 0
    private(set) var phase: Phase = .idle
    /// Deliberately not observable: it reaches the view through `surface`, so publishing a
    /// frame does not re-evaluate the screen's body. Kept for the code here that reads it.
    @ObservationIgnored private(set) var snapshot: TerminalSnapshot? {
        didSet { surface.publish(snapshot) }
    }
    /// The channel the Metal view reads snapshots from.
    @ObservationIgnored let surface = TerminalSurface()
    private(set) var message: String?
    private(set) var authenticationBanner = ""
    private(set) var authenticationURL: URL?
    var credentialPrompt = false
    var trustPrompt: TrustPrompt?
    private(set) var credentialRequestID: UUID?
    private(set) var isWaitingForCredentialUnlock = false
    private(set) var isAuthenticationDeferred = false
    private(set) var isVisible = true
    var connectionAttemptID: UUID { attempt }
    var needsAuthenticationAttention: Bool {
        phase == .connecting && (isWaitingForCredentialUnlock || credentialRequestID != nil || trustPrompt != nil || authenticationURL != nil)
    }
    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private var session: (any ConnectionTransport)?
    @ObservationIgnored private var credentialReply: CheckedContinuation<CredentialAnswer?, Never>?
    @ObservationIgnored private var credentialUnlockReply: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var pendingCredentialAnswer: CredentialAnswer?
    @ObservationIgnored private var hasPendingCredentialSubmission = false
    @ObservationIgnored private var trustReply: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var writerTask: Task<Void, Never>?
    @ObservationIgnored private var input: AsyncStream<WriteOperation>.Continuation?
    @ObservationIgnored private var inputGeneration = UUID()
    @ObservationIgnored private var isSendingUserInput = false
    @ObservationIgnored private var attempt = UUID()
    @ObservationIgnored private var initialConnectionTask: Task<Void, Never>?
    @ObservationIgnored private var foregroundCheck: Task<Void, Never>?
    @ObservationIgnored private var foregroundCheckID = UUID()
    @ObservationIgnored private var isInBackground = false
    @ObservationIgnored private var needsConnectionCheck = false
    /// Shuts off a superseded session's output. Read from the SSH read loop, which no
    /// longer runs on the main actor, so it cannot consult `attempt` directly.
    @ObservationIgnored private var outputGate: OutputGate?
    /// When the last snapshot reached the view, so the next is paced against it.
    @ObservationIgnored fileprivate var published: ContinuousClock.Instant?
    /// Temporary, for the frame-rate work: prints to the device console once a second.
    @ObservationIgnored fileprivate static var frames = FrameLog()

    /// Trial for #10: the libghostty-vt parser, chosen in Settings. It parses about twelve
    /// times faster than the shipping engine but does not carry history navigation, selection
    /// text, or Kitty graphics yet, so it stays off by default.
    static var experimentalEngineFactory: TerminalPipeline.EngineFactory? {
        guard UserDefaults.standard.string(forKey: "terminal.engine") == "ghostty" else { return nil }
        return { columns, rows, _ in GhosttyEngine(columns: columns, rows: rows) }
    }

    init(host: SSHHost, dependencies: Dependencies = .live, imageBudget: TerminalImageBudget? = nil) {
        self.host = host
        self.dependencies = dependencies
        let box = WeakModel()
        terminal = TerminalPipeline(columns: 80, rows: 24, imageBudget: imageBudget,
                                    makeEngine: ConnectionModel.experimentalEngineFactory,
                                    onOutput: { data, origin in
            Task { @MainActor in box.model?.parserDidWrite(data, origin: origin) }
        }, onNeedsDisplay: {
            Task { @MainActor in box.model?.scheduleSnapshot() }
        }, onImageCacheInvalidated: {
            Task { @MainActor in
                box.model?.snapshot = nil
                box.model?.scheduleSnapshot()
            }
        }, onTitleChange: { _ in })
        box.model = self
    }

    /// Owned by the model so presenting a sheet cannot cancel pending authentication.
    func connectOnFirstAppearance() {
        guard phase == .idle, initialConnectionTask == nil else { return }
        initialConnectionTask = Task { [weak self] in
            guard !Task.isCancelled, let self, self.phase == .idle else { return }
            await self.connect()
        }
    }

    func connect(enterCredential: Bool = false) async {
        guard !Task.isCancelled, phase != .connecting, phase != .connected, phase != .checking else { return }
        let token = UUID()
        attempt = token
        needsConnectionCheck = false
        phase = .connecting
        message = nil
        authenticationBanner = ""
        authenticationURL = nil
        isAuthenticationDeferred = false
        do {
            var credential: SSHCredential?
            if host.authentication == .tailscale {
                credential = SSHCredential()
            } else if !enterCredential {
                // Keychain can present Face ID/Touch ID. A tab hidden before its
                // connect task starts must wait for its explicit attention action.
                while !isVisible {
                    guard await waitForCredentialUnlock(token: token), attempt == token, !Task.isCancelled else { return }
                }
                credential = try await dependencies.loadCredential(host.id)
            }
            guard attempt == token, !Task.isCancelled else { return }
            if credential == nil {
                let reply = await askForCredential(token: token)
                guard attempt == token, !Task.isCancelled else { return }
                guard let answer = reply else {
                    phase = .disconnected
                    return
                }
                credential = answer.credential
                if answer.save { try await dependencies.saveCredential(answer.credential, host.id) }
            }
            guard attempt == token, !Task.isCancelled, let credential else { return }
            let transport = try dependencies.makeTransport()
            session = transport
            transport.onAuthenticationBanner = { [weak self] banner in
                guard let self, self.attempt == token, self.phase == .connecting else { return }
                let separator = self.authenticationBanner.isEmpty ? "" : "\n"
                self.authenticationBanner = String((self.authenticationBanner + separator + banner).prefix(16_384))
                if self.host.authentication == .tailscale {
                    self.authenticationURL = TailscaleAuthentication.loginURL(in: self.authenticationBanner)
                    if !self.isVisible { self.isAuthenticationDeferred = true }
                }
            }
            // Output arrives off the main actor now, so the check that used to compare `attempt`
            // has to be readable from there. `prepareClose` shuts the gate synchronously, which
            // keeps bytes from a superseded session out of the grid its replacement is drawing.
            outputGate?.close()
            let gate = OutputGate()
            outputGate = gate
            transport.onData = { [pipeline = terminal] data in
                guard gate.isOpen else { return }
                inputLog.record(data.count)
                pipeline.feed(data)
            }
            transport.onDisconnect = { [weak self] reason in
                guard let self, self.attempt == token else { return }
                self.cancelForegroundCheck()
                self.phase = .disconnected
                self.message = reason ?? "The remote session ended."
                self.authenticationBanner = ""
                self.authenticationURL = nil
                self.finishCredentialUnlock(false)
                self.answerCredential(nil)
                self.answerTrust(false)
                self.isAuthenticationDeferred = false
                self.input?.finish()
                self.writerTask?.cancel()
            }
            terminal.reset()
            startWriter(transport: transport, token: token)
            lastSentSize = (columns, rows, pixelSize.width, pixelSize.height)
            try await transport.connect(host: host, credential: credential,
                                        columns: columns, rows: rows,
                                        pixelWidth: pixelSize.width,
                                        pixelHeight: pixelSize.height) { [weak self] challenge in
                guard let self else { return false }
                return await self.askForTrust(challenge, token: token)
            }
            guard attempt == token, !Task.isCancelled else {
                await transport.disconnect()
                return
            }
            guard transport.isConnected else { return }
            // Layout can change while authentication or the trust prompt is in progress.
            while true {
                let sent = [columns, rows]
                let pixels = pixelSize
                lastSentSize = (columns, rows, pixels.width, pixels.height)
                try await transport.resize(columns: columns, rows: rows,
                                           pixelWidth: pixels.width, pixelHeight: pixels.height)
                guard attempt == token, transport.isConnected, !Task.isCancelled else { return }
                if sent == [columns, rows], pixels == pixelSize { break }
            }
            phase = .connected
            authenticationBanner = ""
            authenticationURL = nil
            isAuthenticationDeferred = false
            if !isInBackground, needsConnectionCheck { enterForeground() }
        } catch {
            guard attempt == token else { return }
            answerTrust(false)
            await session?.disconnect()
            guard attempt == token else { return }
            input?.finish()
            writerTask?.cancel()
            phase = .failed
            message = error.localizedDescription
            authenticationURL = nil
        }
    }

    func close(message: String? = nil) async {
        let oldSession = prepareClose(message: message)
        await oldSession?.disconnect()
    }

    /// Invalidate callbacks before the workspace removes a tab, then close its socket.
    @discardableResult
    func closeImmediately(message: String? = nil) -> Task<Void, Never> {
        let oldSession = prepareClose(message: message)
        return Task { await oldSession?.disconnect() }
    }

    private func prepareClose(message: String?) -> (any ConnectionTransport)? {
        attempt = UUID()
        outputGate?.close()
        outputGate = nil
        initialConnectionTask?.cancel()
        initialConnectionTask = nil
        cancelForegroundCheck()
        needsConnectionCheck = false
        finishCredentialUnlock(false)
        answerCredential(nil)
        answerTrust(false)
        input?.finish()
        writerTask?.cancel()
        snapshotTask?.cancel()
        snapshotTask = nil
        phase = .disconnected
        self.message = message
        authenticationBanner = ""
        authenticationURL = nil
        isAuthenticationDeferred = false
        let oldSession = session
        session = nil
        return oldSession
    }

    /// Hidden terminals keep parsing output and retain their last measured PTY size.
    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        inputGeneration = UUID()
        isVisible = visible
        if visible, !isInBackground {
            scheduleSnapshot()
        } else {
            snapshotTask?.cancel()
            snapshotTask = nil
            if !visible { deferAuthentication() }
        }
    }

    func enterBackground() {
        isInBackground = true
        needsConnectionCheck = true
        cancelForegroundCheck()
        snapshotTask?.cancel()
        snapshotTask = nil
        // Keep the shell, parser state, credentials, and any pending trust/authentication.
        // iOS may suspend this process; no background execution entitlement is needed.
    }

    func enterForeground() {
        isInBackground = false
        if isVisible { scheduleSnapshot() }
        guard phase == .connected || phase == .checking else { return }
        guard foregroundCheck == nil else { return }
        guard needsConnectionCheck, let transport = session else { return }
        needsConnectionCheck = false
        let token = attempt
        let checkID = UUID()
        foregroundCheckID = checkID
        phase = .checking
        let task = Task<Void, Never> { [weak self] in
            await self?.checkRetainedConnection(transport, token: token, checkID: checkID)
        }
        foregroundCheck = task
    }

    private func checkRetainedConnection(_ transport: any ConnectionTransport, token: UUID, checkID: UUID) async {
        defer { if foregroundCheckID == checkID { foregroundCheck = nil } }
        guard isCurrentForegroundCheck(token: token, checkID: checkID) else { return }
        do {
            guard transport.isConnected else { throw SSHSessionError.disconnected }
            try await transport.checkConnection()
            guard isCurrentForegroundCheck(token: token, checkID: checkID) else { return }
            // Changes while locked/checking are sent to the existing PTY, never a new shell.
            while true {
                guard transport.isConnected else { throw SSHSessionError.disconnected }
                let sent = [columns, rows]
                let pixels = pixelSize
                lastSentSize = (columns, rows, pixels.width, pixels.height)
                try await transport.resize(columns: columns, rows: rows,
                                           pixelWidth: pixels.width, pixelHeight: pixels.height)
                guard isCurrentForegroundCheck(token: token, checkID: checkID) else { return }
                if sent == [columns, rows], pixels == pixelSize { break }
            }
            guard transport.isConnected else { throw SSHSessionError.disconnected }
            phase = .connected
            if isVisible { scheduleSnapshot() }
        } catch is CancellationError {
            // Another background transition or explicit close owns the current state.
        } catch {
            guard isCurrentForegroundCheck(token: token, checkID: checkID) else { return }
            let reason = error as? SSHSessionError == .connectionTimedOut
                ? "The existing SSH session did not respond for 30 seconds. Reconnect to open a new shell."
                : "The existing SSH session closed. Reconnect to open a new shell."
            await close(message: reason)
        }
    }

    private func isCurrentForegroundCheck(token: UUID, checkID: UUID) -> Bool {
        attempt == token && foregroundCheckID == checkID && !isInBackground
            && phase == .checking && !Task.isCancelled
    }

    private func cancelForegroundCheck() {
        foregroundCheckID = UUID()
        foregroundCheck?.cancel()
        foregroundCheck = nil
    }

    func send(_ data: Data) {
        guard !data.isEmpty, session?.isConnected == true else { return }
        enqueue(.data(data, userInputGeneration: isSendingUserInput ? inputGeneration : nil))
    }

    /// UI callbacks must capture the attempt before asynchronous paste/loading.
    /// Protocol replies generated by a hidden parser still use `send` directly.
    func sendUserInput(_ data: Data, attemptID: UUID) {
        guard acceptsUserInput(attemptID: attemptID), !data.isEmpty else { return }
        enqueue(.data(data, userInputGeneration: inputGeneration))
    }

    func sendUserKey(_ key: TerminalKey, attemptID: UUID) {
        guard acceptsUserInput(attemptID: attemptID) else { return }
        terminal.sendKey(key, origin: inputGeneration)
    }

    func pasteUserInput(_ text: String, attemptID: UUID) {
        guard acceptsUserInput(attemptID: attemptID) else { return }
        terminal.paste(text, origin: inputGeneration)
    }

    /// Bytes the parser produced: a key or a paste carries the generation it was typed in, and
    /// anything else is a reply to the shell.
    private func parserDidWrite(_ data: Data, origin: UUID?) {
        guard !data.isEmpty, session?.isConnected == true else { return }
        guard let origin else {
            enqueue(.data(data, userInputGeneration: nil))
            return
        }
        guard acceptsUserInput(attemptID: attempt), inputGeneration == origin else { return }
        enqueue(.data(data, userInputGeneration: origin))
    }

    private func acceptsUserInput(attemptID: UUID) -> Bool {
        attempt == attemptID && isVisible && !isInBackground
            && (phase == .connected || phase == .checking) && session?.isConnected == true
    }

    private func enqueue(_ operation: WriteOperation) {
        guard let input else { return }
        if case .dropped = input.yield(operation) {
            let token = attempt
            Task { [weak self] in
                guard let self, self.attempt == token else { return }
                await self.close(message: "The connection could not keep up with keyboard input. Reconnect to continue.")
            }
        }
    }

    func resize(columns: Int, rows: Int) {
        guard isVisible else { return }
        let columns = min(1000, max(2, columns)), rows = min(1000, max(1, rows))
        guard self.columns != columns || self.rows != rows else { return }
        self.columns = columns
        self.rows = rows
        terminal.resize(columns: columns, rows: rows)
        sendSizeToShell()
    }

    /// The measured size of one cell in device pixels. Changing the font keeps the grid size
    /// but changes the terminal's pixel size, so the shell is told about that on its own.
    func setCellSize(width: Int, height: Int) {
        terminal.setCellSize(width: width, height: height)
        guard cellPixelWidth != width || cellPixelHeight != height else { return }
        cellPixelWidth = width
        cellPixelHeight = height
        sendSizeToShell()
    }

    private var pixelSize: (width: Int, height: Int) {
        (min(65535, columns * cellPixelWidth), min(65535, rows * cellPixelHeight))
    }

    /// What the PTY was last told, for the size report in the session menu.
    private(set) var lastSentSize: (columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int)?

    /// Writes the sizes this session is working with into the terminal itself. Nothing is sent
    /// to the shell: the line is fed to the local parser, so it reads like output that arrived.
    func reportSizeIntoTerminal() {
        let pixels = pixelSize
        let sent = lastSentSize.map { "\($0.columns)x\($0.rows) cells, \($0.pixelWidth)x\($0.pixelHeight) px" } ?? "nothing yet"
        let lines = [
            "iOSSH size report",
            "  grid        \(columns)x\(rows)",
            "  cell        \(cellPixelWidth)x\(cellPixelHeight) px",
            "  would send  \(pixels.width)x\(pixels.height) px",
            "  last sent   \(sent)",
            "  TERM        \(host.terminalType)",
            "  state       \(phase)"
        ]
        terminal.feed(Data((lines.joined(separator: "\r\n") + "\r\n").utf8))
    }

    private func sendSizeToShell() {
        guard phase == .connected, !isInBackground else { return }
        // Use the same queue as keyboard/paste bytes, so the remote PTY sees
        // its new dimensions before any input from the newly measured view.
        enqueue(.resize)
    }

    func apply(theme: TerminalTheme) {
        terminal.setColors(foreground: theme.coreForeground, background: theme.coreBackground, palette: theme.corePalette)
    }

    func answerCredential(_ answer: CredentialAnswer?) {
        let reply = credentialReply
        credentialReply = nil
        pendingCredentialAnswer = nil
        hasPendingCredentialSubmission = false
        credentialRequestID = nil
        credentialPrompt = false
        isAuthenticationDeferred = false
        reply?.resume(returning: answer)
    }

    func submitCredential(_ answer: CredentialAnswer?) {
        guard credentialRequestID != nil else { return }
        pendingCredentialAnswer = answer
        hasPendingCredentialSubmission = true
        credentialPrompt = false
    }

    func submitCredential(_ answer: CredentialAnswer?, requestID: UUID, attemptID: UUID) {
        guard isVisible, !isAuthenticationDeferred,
              isCurrentCredentialRequest(requestID: requestID, attemptID: attemptID) else { return }
        submitCredential(answer)
    }

    func credentialSheetDidDismiss() {
        guard !isAuthenticationDeferred, credentialRequestID != nil else { return }
        // Resume after dismissal so the host-key confirmation can present reliably.
        answerCredential(pendingCredentialAnswer)
    }

    func credentialSheetDidDismiss(requestID: UUID, attemptID: UUID) {
        guard isCurrentCredentialRequest(requestID: requestID, attemptID: attemptID) else { return }
        credentialSheetDidDismiss()
    }

    private func isCurrentCredentialRequest(requestID: UUID, attemptID: UUID) -> Bool {
        attempt == attemptID && credentialRequestID == requestID && credentialReply != nil
    }

    func answerTrust(_ trusted: Bool) {
        let reply = trustReply
        trustReply = nil
        trustPrompt = nil
        isAuthenticationDeferred = false
        reply?.resume(returning: trusted)
    }

    func answerTrust(_ trusted: Bool, requestID: UUID, attemptID: UUID) {
        guard isVisible, !isAuthenticationDeferred, attempt == attemptID, trustPrompt?.id == requestID else { return }
        answerTrust(trusted)
    }

    func deferAuthentication() {
        guard needsAuthenticationAttention, !hasPendingCredentialSubmission else { return }
        isAuthenticationDeferred = true
        credentialPrompt = false
    }

    func deferAuthentication(attemptID: UUID) {
        guard attempt == attemptID else { return }
        deferAuthentication()
    }

    func resumeAuthentication() {
        guard isVisible, needsAuthenticationAttention else { return }
        isAuthenticationDeferred = false
        credentialPrompt = credentialRequestID != nil
        finishCredentialUnlock(true)
    }

    private func waitForCredentialUnlock(token: UUID) async -> Bool {
        guard token == attempt else { return false }
        return await withCheckedContinuation { reply in
            credentialUnlockReply = reply
            isWaitingForCredentialUnlock = true
            isAuthenticationDeferred = true
        }
    }

    private func finishCredentialUnlock(_ proceed: Bool) {
        let reply = credentialUnlockReply
        credentialUnlockReply = nil
        isWaitingForCredentialUnlock = false
        reply?.resume(returning: proceed)
    }

    private func askForCredential(token: UUID) async -> CredentialAnswer? {
        guard token == attempt, phase == .connecting else { return nil }
        return await withCheckedContinuation { reply in
            credentialReply = reply
            credentialRequestID = UUID()
            isAuthenticationDeferred = !isVisible
            credentialPrompt = isVisible
        }
    }

    private func askForTrust(_ challenge: HostKeyChallenge, token: UUID) async -> Bool {
        guard token == attempt, phase == .connecting else { return false }
        return await withCheckedContinuation { reply in
            trustReply = reply
            trustPrompt = TrustPrompt(attemptID: token, challenge: challenge)
            isAuthenticationDeferred = !isVisible
        }
    }

    private func startWriter(transport: any ConnectionTransport, token: UUID) {
        input?.finish()
        writerTask?.cancel()
        let stream = AsyncStream<WriteOperation>.makeStream(bufferingPolicy: .bufferingOldest(256))
        input = stream.continuation
        writerTask = Task { [weak self] in
            do {
                for await operation in stream.stream {
                    guard !Task.isCancelled, let self, self.attempt == token else { return }
                    switch operation {
                    case .resize:
                        // A lock/check may have superseded a queued layout event.
                        guard !self.isInBackground, self.phase == .connected else { continue }
                        let pixels = self.pixelSize
                        self.lastSentSize = (self.columns, self.rows, pixels.width, pixels.height)
                        try await transport.resize(columns: self.columns, rows: self.rows,
                                                   pixelWidth: pixels.width, pixelHeight: pixels.height)
                    case .data(let data, let generation):
                        if let generation {
                            // Foreground validation sends the latest size itself.
                            // Keep this input queued until that existing PTY is ready.
                            while self.phase == .checking, let check = self.foregroundCheck {
                                await check.value
                                guard !Task.isCancelled, self.attempt == token else { return }
                            }
                            guard self.acceptsUserInput(attemptID: token), self.inputGeneration == generation else { continue }
                        }
                        try await transport.write(data)
                    }
                }
            } catch {
                guard !Task.isCancelled, let self, self.attempt == token else { return }
                await self.close(message: error.localizedDescription)
            }
        }
    }

    /// A program repainting the whole screen sends one frame as a dozen network batches, and
    /// erases each line before painting it. Drawing between those batches shows the erase
    /// without the paint, which reads as the picture being wiped downward from the top.
    ///
    /// Draw only what the parser has finished, which for a program that pauses between frames
    /// means whole frames. A stream that never pauses would otherwise never draw, so the
    /// deadline gives up waiting and draws whatever is there.
    private func scheduleSnapshot() {
        guard isVisible, !isInBackground, snapshotTask == nil else { return }
        let started = ContinuousClock.now
        snapshotTask = Task { [weak self] in
            // The screen can show about 60 snapshots a second and the parser finishes work far
            // more often than that. Publishing every time does not put more on the screen: the
            // extra ones pay for update(_:) and are replaced before they are drawn, and the
            // damage they carried is dropped rather than accumulated, which leaves the renderer
            // redrawing more than it should. Hold publication to one display frame.
            if let previous = await self?.published {
                let due = previous.advanced(by: Self.presentationInterval)
                if ContinuousClock.now < due { try? await Task.sleep(until: due, clock: .continuous) }
                guard !Task.isCancelled else { return }
            }
            let deadline = ContinuousClock.now.advanced(by: Self.maximumSnapshotDelay)
            while true {
                guard !Task.isCancelled, let self, self.isVisible, !self.isInBackground else { return }
                if let value = await self.terminal.snapshotIfDrained() {
                    guard !Task.isCancelled, self.isVisible, !self.isInBackground else { return }
                    self.snapshot = value
                    break
                }
                guard ContinuousClock.now < deadline else {
                    let value = await self.terminal.snapshot()
                    guard !Task.isCancelled, self.isVisible, !self.isInBackground else { return }
                    self.snapshot = value
                    break
                }
                // Only wait once the parser is known to be behind. Sleeping first cost every
                // frame the interval whether or not there was anything to wait for.
                try? await Task.sleep(for: Self.snapshotInterval)
            }
            self?.published = ContinuousClock.now
            ConnectionModel.frames.record(start: started)
            self?.snapshotTask = nil
        }
    }

    /// One frame on this panel.
    private static let presentationInterval = Duration.milliseconds(16)
    private static let snapshotInterval = Duration.milliseconds(8)
    /// Output that never pauses never drains, so this deadline decides the frame rate while a
    /// program is writing continuously. One display frame keeps that at 60fps; longer values
    /// hide the parser's speed entirely behind the wait.
    private static let maximumSnapshotDelay = Duration.milliseconds(16)
}
