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
                 confirmHostKey: @escaping @Sendable (HostKeyChallenge) async -> Bool) async throws
    func write(_ data: Data) async throws
    func resize(columns: Int, rows: Int) async throws
    func disconnect() async
}

extension SSHSession: ConnectionTransport {}

@MainActor @Observable
final class ConnectionModel {
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

    enum Phase: String { case idle, connecting, connected, disconnected, failed }
    struct TrustPrompt: Identifiable {
        let id = UUID()
        let challenge: HostKeyChallenge
    }
    struct CredentialAnswer {
        let credential: SSHCredential
        let save: Bool
    }

    let host: SSHHost
    let engine: any TerminalEngine
    private(set) var phase: Phase = .idle
    private(set) var snapshot: TerminalSnapshot?
    private(set) var message: String?
    private(set) var authenticationBanner = ""
    private(set) var authenticationURL: URL?
    var credentialPrompt = false
    var trustPrompt: TrustPrompt?
    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private var session: (any ConnectionTransport)?
    @ObservationIgnored private var credentialReply: CheckedContinuation<CredentialAnswer?, Never>?
    @ObservationIgnored private var pendingCredentialAnswer: CredentialAnswer?
    @ObservationIgnored private var trustReply: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var snapshotTask: Task<Void, Never>?
    @ObservationIgnored private var writerTask: Task<Void, Never>?
    @ObservationIgnored private var input: AsyncStream<Data>.Continuation?
    @ObservationIgnored private var attempt = UUID()

    init(host: SSHHost, dependencies: Dependencies = .live) {
        self.host = host
        self.dependencies = dependencies
        engine = SwiftTermEngine(columns: 80, rows: 24)
        engine.onOutput = { [weak self] data in self?.send(data) }
        engine.onNeedsDisplay = { [weak self] in self?.scheduleSnapshot() }
        snapshot = engine.snapshot()
    }

    func connect(enterCredential: Bool = false) async {
        guard phase != .connecting, phase != .connected else { return }
        let token = UUID()
        attempt = token
        phase = .connecting
        message = nil
        authenticationBanner = ""
        authenticationURL = nil
        do {
            var credential: SSHCredential?
            if host.authentication == .tailscale {
                credential = SSHCredential()
            } else if !enterCredential {
                credential = try await dependencies.loadCredential(host.id)
            }
            guard attempt == token, !Task.isCancelled else { return }
            if credential == nil {
                let reply = await askForCredential()
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
                }
            }
            transport.onData = { [weak self] data in
                guard let self, self.attempt == token else { return }
                self.engine.feed(data)
            }
            transport.onDisconnect = { [weak self] reason in
                guard let self, self.attempt == token else { return }
                self.phase = .disconnected
                self.message = reason ?? "The remote session ended."
                self.authenticationBanner = ""
                self.authenticationURL = nil
                self.input?.finish()
                self.writerTask?.cancel()
            }
            engine.reset()
            startWriter(transport: transport, token: token)
            try await transport.connect(host: host, credential: credential,
                                        columns: engine.columns, rows: engine.rows) { [weak self] challenge in
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
                try await transport.resize(columns: columns, rows: rows)
                guard attempt == token, transport.isConnected, !Task.isCancelled else { return }
                if columns == engine.columns, rows == engine.rows { break }
            }
            phase = .connected
            authenticationBanner = ""
            authenticationURL = nil
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
        attempt = UUID()
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
        let oldSession = session
        session = nil
        await oldSession?.disconnect()
    }

    func send(_ data: Data) {
        guard !data.isEmpty, session?.isConnected == true, let input else { return }
        if case .dropped = input.yield(data) {
            Task { await close(message: "The connection could not keep up with keyboard input. Reconnect to continue.") }
        }
    }

    func resize(columns: Int, rows: Int) {
        guard engine.columns != columns || engine.rows != rows else { return }
        engine.resize(columns: columns, rows: rows)
        if phase == .connected, let transport = session {
            let token = attempt
            Task {
                guard attempt == token else { return }
                do { try await transport.resize(columns: columns, rows: rows) }
                catch {
                    guard attempt == token else { return }
                    await close(message: error.localizedDescription)
                }
            }
        }
    }

    func apply(theme: TerminalTheme) {
        engine.setColors(foreground: theme.coreForeground, background: theme.coreBackground, palette: theme.corePalette)
    }

    func answerCredential(_ answer: CredentialAnswer?) {
        let reply = credentialReply
        credentialReply = nil
        pendingCredentialAnswer = nil
        credentialPrompt = false
        reply?.resume(returning: answer)
    }

    func submitCredential(_ answer: CredentialAnswer?) {
        pendingCredentialAnswer = answer
        credentialPrompt = false
    }

    func credentialSheetDidDismiss() {
        // Resume after dismissal so the host-key confirmation can present reliably.
        answerCredential(pendingCredentialAnswer)
    }

    func answerTrust(_ trusted: Bool) {
        let reply = trustReply
        trustReply = nil
        trustPrompt = nil
        reply?.resume(returning: trusted)
    }

    private func askForCredential() async -> CredentialAnswer? {
        await withCheckedContinuation { reply in
            credentialReply = reply
            credentialPrompt = true
        }
    }

    private func askForTrust(_ challenge: HostKeyChallenge, token: UUID) async -> Bool {
        guard token == attempt else { return false }
        return await withCheckedContinuation { reply in
            trustReply = reply
            trustPrompt = TrustPrompt(challenge: challenge)
        }
    }

    private func startWriter(transport: any ConnectionTransport, token: UUID) {
        input?.finish()
        writerTask?.cancel()
        let stream = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(256))
        input = stream.continuation
        writerTask = Task { [weak self] in
            do {
                for await data in stream.stream {
                    guard !Task.isCancelled else { return }
                    try await transport.write(data)
                }
            } catch {
                guard !Task.isCancelled, let self, self.attempt == token else { return }
                await self.close(message: error.localizedDescription)
            }
        }
    }

    private func scheduleSnapshot() {
        guard snapshotTask == nil else { return }
        snapshotTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(8))
            guard !Task.isCancelled, let self else { return }
            self.snapshot = self.engine.snapshot()
            self.snapshotTask = nil
        }
    }
}
