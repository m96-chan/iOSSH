import Foundation
import Darwin
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH

/// One authenticated interactive shell. Reconnect by calling connect again with freshly unlocked
/// credentials after disconnect; a reconnect always creates a new shell and revalidates the host key.
@MainActor
public final class SSHSession {
    public var onData: (@MainActor (Data) -> Void)?
    public var onDisconnect: (@MainActor (String?) -> Void)?
    /// Informational server text during authentication, including Tailscale check-mode links.
    /// Treat it as untrusted text; this callback never opens a URL or approves authentication.
    public var onAuthenticationBanner: (@MainActor (String) -> Void)?
    public private(set) var isConnected = false
    private let knownHosts: KnownHostsStore
    private var transport: Channel?
    private var shell: Channel?
    private var readTask: Task<Void, Never>?
    private var generation = UUID()
    private var connecting = false
    private var connectionLifetime: SSHConnectionLifetime?
    private var pendingProbe: EventLoopFuture<Void>?

    public init(knownHosts: KnownHostsStore) { self.knownHosts = knownHosts }

    deinit {
        connectionLifetime?.invalidate()
        readTask?.cancel()
        transport?.close(promise: nil)
    }

    public func connect(host: SSHHost, credential: SSHCredential, columns: Int = 80, rows: Int = 24,
                        pixelWidth: Int = 0, pixelHeight: Int = 0,
                        confirmHostKey: @escaping @Sendable (HostKeyChallenge) async -> Bool) async throws {
        let attempt = UUID()
        let lifetime = SSHConnectionLifetime()
        try await withTaskCancellationHandler {
            try await connect(host: host, credential: credential, columns: columns, rows: rows,
                              pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                              confirmHostKey: confirmHostKey, attempt: attempt, lifetime: lifetime)
        } onCancel: {
            // Invalidate synchronously so queued banner callbacks cannot outlive cancellation.
            lifetime.invalidate()
            Task { @MainActor [weak self] in
                guard let self, self.generation == attempt else { return }
                await self.disconnect()
            }
        }
    }

    private func connect(host: SSHHost, credential: SSHCredential, columns: Int, rows: Int,
                         pixelWidth: Int, pixelHeight: Int,
                         confirmHostKey: @escaping @Sendable (HostKeyChallenge) async -> Bool,
                         attempt: UUID, lifetime: SSHConnectionLifetime) async throws {
        guard !connecting, !isConnected else { throw SSHSessionError.alreadyConnecting }
        try Task.checkCancellation()
        try host.validate()
        try Self.validateSize(columns: columns, rows: rows, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        connecting = true
        generation = attempt
        connectionLifetime = lifetime
        defer { if generation == attempt { connecting = false } }
        do {
            // Parsing an encrypted key can be expensive; keep it off the main actor.
            let authentication = try await Task.detached {
                try Authentication.factory(host: host, credential: credential)
            }.value
            try ensureCurrent(attempt)
            let eventLoop = MultiThreadedEventLoopGroup.singleton.next()
            let authenticated = eventLoop.makePromise(of: Void.self)
            let validator = PersistentHostKeyValidator(hostname: host.hostname, port: host.port,
                                                       store: knownHosts, confirm: confirmHostKey)
            let onBanner: @Sendable (String) -> Void = { [weak self] message in
                Task { @MainActor [weak self] in
                    guard lifetime.isActive, let self, self.generation == attempt,
                          self.connecting, !self.isConnected else { return }
                    self.onAuthenticationBanner?(message)
                }
            }
            let channel = try await ClientBootstrap(group: eventLoop)
                .connectTimeout(.seconds(30))
                .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
                .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
                // TCP keepalive detects vanished peers without executing commands in the user's shell.
                .channelOption(ChannelOptions.tcpOption(.init(rawValue: TCP_KEEPALIVE)), value: 30)
                .channelOption(ChannelOptions.tcpOption(.init(rawValue: TCP_KEEPINTVL)), value: 10)
                .channelOption(ChannelOptions.tcpOption(.init(rawValue: TCP_KEEPCNT)), value: 3)
                .channelInitializer { channel in
                    // Citadel supplies the authentication delegate and key parsing. Installing the
                    // transport here avoids its fixed ten-second timeout during the host trust UI.
                    do {
                        try channel.pipeline.syncOperations.addHandlers(
                            NIOSSHHandler(role: .client(.init(userAuthDelegate: authentication(), serverAuthDelegate: validator)),
                                          allocator: channel.allocator,
                                          inboundChildChannelInitializer: { child, _ in
                                              child.eventLoop.makeFailedFuture(SSHSessionError.requestRejected)
                                          }),
                            SSHHandshakeHandler(authenticated: authenticated, onBanner: onBanner)
                        )
                        return channel.eventLoop.makeSucceededVoidFuture()
                    } catch { return channel.eventLoop.makeFailedFuture(error) }
                }
                .connect(host: host.hostname, port: host.port).get()
            guard generation == attempt, !Task.isCancelled else {
                try? await channel.close()
                throw CancellationError()
            }
            transport = channel
            let authenticationTimeout = eventLoop.scheduleTask(in: Authentication.timeout(for: host.authentication)) {
                authenticated.fail(SSHSessionError.connectionTimedOut)
                channel.close(promise: nil)
            }
            do { try await authenticated.futureResult.get() }
            catch { authenticationTimeout.cancel(); throw error }
            authenticationTimeout.cancel()
            try ensureCurrent(attempt)

            let ready = channel.eventLoop.makePromise(of: Void.self)
            let handler = PTYHandler(term: host.terminalType, columns: columns, rows: rows,
                                     pixelWidth: pixelWidth, pixelHeight: pixelHeight, ready: ready)
            let output = handler.output
            let child: Channel = try await channel.eventLoop.flatSubmit {
                let created = channel.eventLoop.makePromise(of: Channel.self)
                do {
                    let ssh = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                    // Disabling autoRead makes the shell deliver output only when asked. While the
                    // terminal is behind, the SSH window closes and the server waits instead of
                    // queueing unbounded output on this device.
                    ssh.createChannel(created) { child, _ in
                        child.setOption(ChannelOptions.autoRead, value: false)
                            .flatMap { child.pipeline.addHandler(handler) }
                    }
                } catch { created.fail(error) }
                let timeout = channel.eventLoop.scheduleTask(in: .seconds(15)) {
                    created.fail(SSHSessionError.connectionTimedOut)
                    channel.close(promise: nil)
                }
                created.futureResult.whenComplete { _ in timeout.cancel() }
                return created.futureResult
            }.get()
            try ensureCurrent(attempt)
            shell = child
            let timeout = channel.eventLoop.scheduleTask(in: .seconds(15)) {
                ready.fail(SSHSessionError.connectionTimedOut)
                child.close(promise: nil)
            }
            do { try await ready.futureResult.get() }
            catch { timeout.cancel(); throw error }
            timeout.cancel()
            try ensureCurrent(attempt)
            isConnected = true
            readTask = Task { [weak self] in
                do {
                    // Request the first batch, then one more each time output reaches the terminal.
                    // `read` is safe from this actor; it hops to the channel's event loop.
                    child.read()
                    for try await data in output {
                        guard !Task.isCancelled, let self, self.generation == attempt else { return }
                        self.onData?(data)
                        child.read()
                    }
                    await self?.ended(attempt: attempt, error: nil)
                } catch {
                    await self?.ended(attempt: attempt, error: error)
                }
            }
        } catch {
            if generation == attempt { await disconnect() }
            throw error
        }
    }

    public func write(_ data: Data) async throws {
        guard isConnected, let shell else { throw SSHSessionError.notConnected }
        guard !data.isEmpty else { return }
        // Keep each outbound packet bounded for large pastes.
        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: min(16_384, data.distance(from: offset, to: data.endIndex)))
            let buffer = ByteBuffer(bytes: data[offset..<end])
            try await shell.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buffer)))
            offset = end
        }
    }

    public func resize(columns: Int, rows: Int, pixelWidth: Int = 0, pixelHeight: Int = 0) async throws {
        try Self.validateSize(columns: columns, rows: rows, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        guard isConnected, let shell else { throw SSHSessionError.notConnected }
        try await shell.triggerUserOutboundEvent(SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: columns, terminalRowHeight: rows,
            terminalPixelWidth: pixelWidth, terminalPixelHeight: pixelHeight))
    }

    /// Checks the retained SSH transport on foreground return without creating a new shell.
    /// Cancellation stops this check, not the connection; explicit disconnect remains separate.
    public func checkConnection() async throws {
        guard isConnected, let transport, let shell else { throw SSHSessionError.notConnected }
        let attempt = generation
        guard transport.isActive, shell.isActive else { throw SSHSessionError.disconnected }
        let response: EventLoopFuture<Void>
        if let pendingProbe {
            response = pendingProbe
        } else {
            response = SSHConnectionProbe.start(on: transport)
            pendingProbe = response
            response.whenComplete { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == attempt, self.pendingProbe === response else { return }
                    self.pendingProbe = nil
                }
            }
        }
        try await SSHConnectionProbe.wait(for: response)
        try ensureCurrent(attempt)
        guard isConnected, transport.isActive, shell.isActive else { throw SSHSessionError.disconnected }
    }

    public func disconnect() async {
        connectionLifetime?.invalidate()
        connectionLifetime = nil
        pendingProbe = nil
        generation = UUID()
        connecting = false
        isConnected = false
        readTask?.cancel()
        readTask = nil
        let channel = transport
        transport = nil
        shell = nil
        try? await channel?.close()
    }

    private func ended(attempt: UUID, error: Error?) async {
        guard generation == attempt else { return }
        await disconnect()
        onDisconnect?(error?.localizedDescription)
    }

    private func ensureCurrent(_ attempt: UUID) throws {
        guard generation == attempt else { throw CancellationError() }
        try Task.checkCancellation()
    }

    /// Zero pixels is the protocol's "unknown" value, so a caller that has not measured a cell
    /// yet stays valid; anything reported must still fit the window-size fields.
    private static func validateSize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) throws {
        guard (1...65535).contains(columns), (1...65535).contains(rows),
              (0...65535).contains(pixelWidth), (0...65535).contains(pixelHeight) else {
            throw SSHSessionError.invalidConfiguration
        }
    }
}

/// Shared only to synchronously suppress banner delivery when a connection task is canceled.
/// The channel and all session state remain confined to their event loop/main actor.
private final class SSHConnectionLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    var isActive: Bool { lock.withLock { active } }
    func invalidate() { lock.withLock { active = false } }
}
