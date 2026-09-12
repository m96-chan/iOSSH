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
    public private(set) var isConnected = false
    private let knownHosts: KnownHostsStore
    private var transport: Channel?
    private var shell: Channel?
    private var readTask: Task<Void, Never>?
    private var generation = UUID()
    private var connecting = false

    public init(knownHosts: KnownHostsStore) { self.knownHosts = knownHosts }

    deinit {
        readTask?.cancel()
        transport?.close(promise: nil)
    }

    public func connect(host: SSHHost, credential: SSHCredential, columns: Int = 80, rows: Int = 24,
                        confirmHostKey: @escaping @Sendable (HostKeyChallenge) async -> Bool) async throws {
        guard !connecting, !isConnected else { throw SSHSessionError.alreadyConnecting }
        try host.validate()
        try Self.validateSize(columns: columns, rows: rows)
        connecting = true
        let attempt = UUID()
        generation = attempt
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
                            SSHHandshakeHandler(authenticated: authenticated)
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
            let authenticationTimeout = eventLoop.scheduleTask(in: .seconds(120)) {
                authenticated.fail(SSHSessionError.connectionTimedOut)
                channel.close(promise: nil)
            }
            do { try await authenticated.futureResult.get() }
            catch { authenticationTimeout.cancel(); throw error }
            authenticationTimeout.cancel()
            try ensureCurrent(attempt)

            let (output, continuation) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
            let ready = channel.eventLoop.makePromise(of: Void.self)
            let handler = PTYHandler(term: host.terminalType, columns: columns, rows: rows,
                                     ready: ready, output: continuation)
            let child: Channel = try await channel.eventLoop.flatSubmit {
                let created = channel.eventLoop.makePromise(of: Channel.self)
                do {
                    let ssh = try channel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                    ssh.createChannel(created) { child, _ in child.pipeline.addHandler(handler) }
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
                    for try await data in output {
                        guard !Task.isCancelled, let self, self.generation == attempt else { return }
                        self.onData?(data)
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

    public func resize(columns: Int, rows: Int) async throws {
        try Self.validateSize(columns: columns, rows: rows)
        guard isConnected, let shell else { throw SSHSessionError.notConnected }
        try await shell.triggerUserOutboundEvent(SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: columns, terminalRowHeight: rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0))
    }

    public func disconnect() async {
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

    private static func validateSize(columns: Int, rows: Int) throws {
        guard (1...65535).contains(columns), (1...65535).contains(rows) else {
            throw SSHSessionError.invalidConfiguration
        }
    }
}
