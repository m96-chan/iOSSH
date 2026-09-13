import Foundation
import Observation
import SSHCore
import TerminalCore
import TerminalRender

@MainActor
protocol ConnectionTransport: AnyObject {
    var onData: (@MainActor (Data) -> Void)? { get set }
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
    let engine: any TerminalEngine
    /// The rendered cell size. Programs that draw images read the terminal's pixel size from
    /// the remote tty, so every window size sent to the PTY carries it. Zero until the view
    /// has measured a cell, which is the protocol's "unknown".
    private var cellPixelWidth = 0
    private var cellPixelHeight = 0
    private(set) var phase: Phase = .idle
    private(set) var snapshot: TerminalSnapshot?
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
    /// When the shell last handed over output, used to draw between batches of a repaint.
    @ObservationIgnored private var lastOutputArrival: ContinuousClock.Instant?
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

    init(host: SSHHost, dependencies: Dependencies = .live, imageBudget: TerminalImageBudget? = nil) {
        self.host = host
        self.dependencies = dependencies
        engine = SwiftTermEngine(columns: 80, rows: 24, imageBudget: imageBudget)
        engine.onOutput = { [weak self] data in self?.send(data) }
        engine.onNeedsDisplay = { [weak self] in self?.scheduleSnapshot() }
        engine.onImageCacheInvalidated = { [weak self] in
            self?.snapshot = nil
            self?.scheduleSnapshot()
        }
        snapshot = engine.snapshot()
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
            transport.onData = { [weak self] data in
                guard let self, self.attempt == token else { return }
                self.lastOutputArrival = .now
                self.engine.feed(data)
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
            engine.reset()
            startWriter(transport: transport, token: token)
            try await transport.connect(host: host, credential: credential,
                                        columns: engine.columns, rows: engine.rows,
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
                let columns = engine.columns
                let rows = engine.rows
                let pixels = pixelSize
                try await transport.resize(columns: columns, rows: rows,
                                           pixelWidth: pixels.width, pixelHeight: pixels.height)
                guard attempt == token, transport.isConnected, !Task.isCancelled else { return }
                if columns == engine.columns, rows == engine.rows, pixels == pixelSize { break }
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
            snapshot = engine.snapshot()
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
        // Keep the shell, terminal engine, credentials, and any pending trust/authentication.
        // iOS may suspend this process; no background execution entitlement is needed.
    }

    func enterForeground() {
        isInBackground = false
        if isVisible { snapshot = engine.snapshot() }
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
                let columns = engine.columns
                let rows = engine.rows
                let pixels = pixelSize
                try await transport.resize(columns: columns, rows: rows,
                                           pixelWidth: pixels.width, pixelHeight: pixels.height)
                guard isCurrentForegroundCheck(token: token, checkID: checkID) else { return }
                if columns == engine.columns, rows == engine.rows, pixels == pixelSize { break }
            }
            guard transport.isConnected else { throw SSHSessionError.disconnected }
            phase = .connected
            if isVisible { snapshot = engine.snapshot() }
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
    /// Protocol replies generated by a hidden engine still use `send` directly.
    func sendUserInput(_ data: Data, attemptID: UUID) {
        guard acceptsUserInput(attemptID: attemptID), !data.isEmpty else { return }
        enqueue(.data(data, userInputGeneration: inputGeneration))
    }

    func sendUserKey(_ key: TerminalKey, attemptID: UUID) {
        guard acceptsUserInput(attemptID: attemptID) else { return }
        isSendingUserInput = true
        defer { isSendingUserInput = false }
        engine.sendKey(key)
    }

    func pasteUserInput(_ text: String, attemptID: UUID) {
        guard acceptsUserInput(attemptID: attemptID) else { return }
        isSendingUserInput = true
        defer { isSendingUserInput = false }
        engine.paste(text)
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
        guard engine.columns != columns || engine.rows != rows else { return }
        engine.resize(columns: columns, rows: rows)
        sendSizeToShell()
    }

    /// The measured size of one cell in device pixels. Changing the font keeps the grid size
    /// but changes the terminal's pixel size, so the shell is told about that on its own.
    func setCellSize(width: Int, height: Int) {
        engine.setCellSize(width: width, height: height)
        guard cellPixelWidth != width || cellPixelHeight != height else { return }
        cellPixelWidth = width
        cellPixelHeight = height
        sendSizeToShell()
    }

    private var pixelSize: (width: Int, height: Int) {
        (min(65535, engine.columns * cellPixelWidth), min(65535, engine.rows * cellPixelHeight))
    }

    private func sendSizeToShell() {
        guard phase == .connected, !isInBackground else { return }
        // Use the same queue as keyboard/paste bytes, so the remote PTY sees
        // its new dimensions before any input from the newly measured view.
        enqueue(.resize)
    }

    func apply(theme: TerminalTheme) {
        engine.setColors(foreground: theme.coreForeground, background: theme.coreBackground, palette: theme.corePalette)
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
                        try await transport.resize(columns: self.engine.columns, rows: self.engine.rows,
                                                   pixelWidth: self.pixelSize.width,
                                                   pixelHeight: self.pixelSize.height)
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

    /// Output arrives in network-sized batches, so a program repainting the whole screen
    /// lands over several of them. Drawing between batches shows that repaint in progress,
    /// which reads as the picture being wiped from the top down. Wait for a gap in the
    /// output before drawing, and draw anyway once the deadline passes so a continuous
    /// stream still updates.
    private func scheduleSnapshot() {
        guard isVisible, !isInBackground, snapshotTask == nil else { return }
        snapshotTask = Task { [weak self] in
            let deadline = ContinuousClock.now.advanced(by: Self.maximumSnapshotDelay)
            while true {
                try? await Task.sleep(for: Self.snapshotInterval)
                guard !Task.isCancelled, let self, self.isVisible, !self.isInBackground else { return }
                guard ContinuousClock.now < deadline, let arrival = self.lastOutputArrival,
                      arrival.duration(to: .now) < Self.snapshotInterval else { break }
            }
            guard !Task.isCancelled, let self, self.isVisible, !self.isInBackground else { return }
            self.snapshot = self.engine.snapshot()
            self.snapshotTask = nil
        }
    }

    private static let snapshotInterval = Duration.milliseconds(8)
    private static let maximumSnapshotDelay = Duration.milliseconds(48)
}
