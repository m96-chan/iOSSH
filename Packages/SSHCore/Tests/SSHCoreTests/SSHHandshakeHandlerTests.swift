import Foundation
import Testing
import NIOCore
import NIOEmbedded
@preconcurrency import NIOSSH
@testable import SSHCore

// Used synchronously only on the test's embedded event loop/main actor.
private final class HandshakeEvents: @unchecked Sendable {
    var banners: [String] = []
    var result: Result<Void, Error>?
}

struct SSHHandshakeHandlerTests {
    @Test @MainActor func bannerDoesNotAuthenticateAndStopsAfterSuccess() throws {
        let channel = EmbeddedChannel()
        let events = HandshakeEvents()
        let ready = channel.eventLoop.makePromise(of: Void.self)
        ready.futureResult.whenComplete { events.result = $0 }
        try channel.pipeline.syncOperations.addHandler(SSHHandshakeHandler(authenticated: ready) {
            events.banners.append($0)
        })
        let message = "Authenticate at https://login.tailscale.com/a/example\n確認してください"
        channel.pipeline.fireUserInboundEventTriggered(NIOUserAuthBannerEvent(message: message, languageTag: "en"))
        #expect(events.banners == [message])
        #expect(events.result == nil)
        channel.pipeline.fireUserInboundEventTriggered(UserAuthSuccessEvent())
        guard case .success = events.result else { Issue.record("Verified success was ignored"); return }
        channel.pipeline.fireUserInboundEventTriggered(NIOUserAuthBannerEvent(message: "late", languageTag: "en"))
        #expect(events.banners == [message])
        _ = try channel.finish()
    }

    @Test @MainActor func bannersHavePerMessageAndPerHandshakeUTF8Bounds() throws {
        let channel = EmbeddedChannel()
        let events = HandshakeEvents()
        let ready = channel.eventLoop.makePromise(of: Void.self)
        try channel.pipeline.syncOperations.addHandler(SSHHandshakeHandler(authenticated: ready) {
            events.banners.append($0)
        })
        let largeMessage = String(repeating: "界", count: 10_000)
        for _ in 0..<32 {
            channel.pipeline.fireUserInboundEventTriggered(NIOUserAuthBannerEvent(message: largeMessage, languageTag: "ja"))
        }
        #expect(!events.banners.isEmpty)
        #expect(events.banners.allSatisfy { $0.utf8.count <= 4_096 && !$0.contains("\u{fffd}") })
        #expect(events.banners.reduce(0) { $0 + $1.utf8.count } <= 16_384)
        #expect(events.banners.joined().unicodeScalars.allSatisfy { $0 == "界" })
        channel.pipeline.fireUserInboundEventTriggered(UserAuthSuccessEvent())
        _ = try ready.futureResult.wait()
        _ = try channel.finish()
    }

    @Test @MainActor func manySmallBannersCannotFloodTheMainActor() throws {
        let channel = EmbeddedChannel()
        let events = HandshakeEvents()
        let ready = channel.eventLoop.makePromise(of: Void.self)
        try channel.pipeline.syncOperations.addHandler(SSHHandshakeHandler(authenticated: ready) {
            events.banners.append($0)
        })
        for _ in 0..<100 {
            channel.pipeline.fireUserInboundEventTriggered(NIOUserAuthBannerEvent(message: "a", languageTag: "en"))
        }
        #expect(events.banners.count == 16)
        channel.pipeline.fireUserInboundEventTriggered(UserAuthSuccessEvent())
        _ = try ready.futureResult.wait()
        _ = try channel.finish()
    }

    @Test @MainActor func closedHandshakeFailsAndSuppressesLateBanners() throws {
        let channel = EmbeddedChannel()
        let events = HandshakeEvents()
        let ready = channel.eventLoop.makePromise(of: Void.self)
        ready.futureResult.whenComplete { events.result = $0 }
        try channel.pipeline.syncOperations.addHandler(SSHHandshakeHandler(authenticated: ready) {
            events.banners.append($0)
        })
        channel.pipeline.fireChannelInactive()
        channel.pipeline.fireUserInboundEventTriggered(NIOUserAuthBannerEvent(message: "late", languageTag: "en"))
        channel.pipeline.fireUserInboundEventTriggered(UserAuthSuccessEvent())
        #expect(events.banners.isEmpty)
        guard case .failure(let error) = events.result else { Issue.record("Closed handshake did not fail"); return }
        #expect(error as? SSHSessionError == .disconnected)
        _ = try channel.finish()
    }
}
