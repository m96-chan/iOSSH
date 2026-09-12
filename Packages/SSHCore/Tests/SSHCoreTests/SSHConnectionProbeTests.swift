import Crypto
import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
@preconcurrency import NIOSSH
import Testing
@testable import SSHCore

// Fixtures are accessed synchronously on one EmbeddedEventLoop/main actor.
private final class ProbeServer: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { [] }
    var rejectNewChannels = false
    var channels: [Channel] = []
    var shellRequests = 0

    func requestReceived(request: NIOSSHUserAuthenticationRequest,
                         responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        if case .none = request.request { responsePromise.succeed(.success) }
        else { responsePromise.succeed(.failure) }
    }
}

private struct ProbeHostValidator: NIOSSHClientServerAuthenticationDelegate {
    let expectedKey: NIOSSHPublicKey
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if hostKey == expectedKey { validationCompletePromise.succeed(()) }
        else { validationCompletePromise.fail(HostKeyError.invalidKey) }
    }
}

private final class ProbeRequestRecorder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    let server: ProbeServer
    init(server: ProbeServer) { self.server = server }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is SSHChannelRequestEvent.ShellRequest || event is SSHChannelRequestEvent.ExecRequest
            || event is SSHChannelRequestEvent.PseudoTerminalRequest {
            server.shellRequests += 1
        }
        context.fireUserInboundEventTriggered(event)
    }
}

private final class ProbeResult: @unchecked Sendable {
    var result: Result<Void, Error>?
}

private final class ProbePeers {
    let loop = EmbeddedEventLoop()
    let client: EmbeddedChannel
    let server: EmbeddedChannel
    let peer = ProbeServer()

    init() throws {
        client = EmbeddedChannel(loop: loop)
        server = EmbeddedChannel(loop: loop)
        let key = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        try client.pipeline.syncOperations.addHandler(NIOSSHHandler(
            role: .client(.init(userAuthDelegate: TailscaleAuthenticationDelegate(username: "tester"),
                                serverAuthDelegate: ProbeHostValidator(expectedKey: key.publicKey))),
            allocator: client.allocator, inboundChildChannelInitializer: nil))
        try server.pipeline.syncOperations.addHandler(NIOSSHHandler(
            role: .server(.init(hostKeys: [key], userAuthDelegate: peer)), allocator: server.allocator,
            inboundChildChannelInitializer: { [peer] child, _ in
                if peer.rejectNewChannels { return child.eventLoop.makeFailedFuture(SSHSessionError.requestRejected) }
                peer.channels.append(child)
                return child.pipeline.addHandler(ProbeRequestRecorder(server: peer))
            }))
        try client.connect(to: .init(unixDomainSocketPath: "/test-client")).wait()
        try server.connect(to: .init(unixDomainSocketPath: "/test-server")).wait()
        try exchange()
    }

    func sendClientPackets() throws {
        loop.run()
        while let packet = try client.readOutbound(as: IOData.self) {
            _ = try server.writeInbound(packet)
            loop.run()
        }
    }

    func exchange() throws {
        for _ in 0..<100 {
            loop.run()
            let toServer = try client.readOutbound(as: IOData.self)
            let toClient = try server.readOutbound(as: IOData.self)
            if let toServer { _ = try server.writeInbound(toServer) }
            if let toClient { _ = try client.writeInbound(toClient) }
            if toServer == nil, toClient == nil { return }
        }
        Issue.record("SSH fixture did not become idle")
    }

    func openExistingChannel() throws -> Channel {
        let opened = loop.makePromise(of: Channel.self)
        let handler = try client.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
        handler.createChannel(opened) { child, _ in child.eventLoop.makeSucceededVoidFuture() }
        try exchange()
        return try opened.futureResult.wait()
    }

    func finish() throws {
        _ = try client.finish(acceptAlreadyClosed: true)
        _ = try server.finish(acceptAlreadyClosed: true)
        try loop.syncShutdownGracefully()
    }
}

struct SSHConnectionProbeTests {
    @Test @MainActor func waitsForPeerAcknowledgmentAndPreservesTheExistingChannel() throws {
        let peers = try ProbePeers()
        defer { try? peers.finish() }
        let existing = try peers.openExistingChannel()
        let result = ProbeResult()
        let response = SSHConnectionProbe.start(on: peers.client)
        response.whenComplete { result.result = $0 }
        peers.loop.run()
        #expect(result.result == nil)
        try peers.sendClientPackets() // Server created the channel; its response is withheld.
        #expect(peers.peer.channels.count == 2)
        #expect(result.result == nil)
        #expect(existing.isActive)
        try peers.exchange()
        guard case .success = result.result else { Issue.record("Peer acknowledgment did not finish probe"); return }
        #expect(existing.isActive)
        #expect(peers.peer.channels[0].isActive)
        #expect(!peers.peer.channels[1].isActive)
        #expect(peers.peer.shellRequests == 0)
    }

    @Test @MainActor func refusingAnExtraChannelStillProvesThePeerIsAlive() throws {
        let peers = try ProbePeers()
        defer { try? peers.finish() }
        let existing = try peers.openExistingChannel()
        peers.peer.rejectNewChannels = true
        let response = SSHConnectionProbe.start(on: peers.client)
        try peers.exchange()
        _ = try response.wait()
        #expect(existing.isActive)
        #expect(peers.client.isActive)
        #expect(peers.peer.shellRequests == 0)
    }

    @Test func cancellationStopsOnlyTheObserver() async throws {
        let eventLoop = MultiThreadedEventLoopGroup.singleton.next()
        let response = eventLoop.makePromise(of: Void.self)
        let observer = Task { try await SSHConnectionProbe.wait(for: response.futureResult) }
        observer.cancel()
        do {
            try await observer.value
            Issue.record("Canceled observer succeeded")
        } catch { #expect(error is CancellationError) }
        // A later foreground observer can still consume the same protocol response.
        response.succeed(())
        try await SSHConnectionProbe.wait(for: response.futureResult)
    }

    @Test func timeoutDoesNotCancelTheSharedProtocolResponse() async throws {
        let eventLoop = MultiThreadedEventLoopGroup.singleton.next()
        let response = eventLoop.makePromise(of: Void.self)
        await #expect(throws: SSHSessionError.connectionTimedOut) {
            try await SSHConnectionProbe.wait(for: response.futureResult, timeout: .milliseconds(10))
        }
        response.succeed(())
        try await SSHConnectionProbe.wait(for: response.futureResult)
    }
}
