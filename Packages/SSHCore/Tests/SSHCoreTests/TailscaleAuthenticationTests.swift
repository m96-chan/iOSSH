import Foundation
import Testing
import NIOCore
import NIOEmbedded
@preconcurrency import NIOSSH
@testable import SSHCore

struct TailscaleAuthenticationTests {
    @Test(arguments: [UInt8(7), 0, 2, 1])
    @MainActor func offersNoneWithoutReadingSecrets(availableMethodBits: UInt8) throws {
        let host = SSHHost(name: "Tailnet", hostname: "devbox", username: "alice", authentication: .tailscale)
        // A stale credential from another auth mode must never be parsed or sent to this peer.
        let factory = try Authentication.factory(host: host, credential: SSHCredential(
            password: "must-not-send", privateKey: "not even a valid key", passphrase: "must-not-use"))
        let delegate = factory()
        let loop = EmbeddedEventLoop()
        let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .init(rawValue: availableMethodBits), nextChallengePromise: promise)
        let offer = try #require(try promise.futureResult.wait())
        #expect(offer.username == "alice")
        guard case .none = offer.offer else { Issue.record("Tailscale offered a secret-based method"); return }

        // A rejection exhausts this method, even if the peer subsequently advertises passwords.
        let rejected = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .all, nextChallengePromise: rejected)
        #expect(throws: (any Error).self) { try rejected.futureResult.wait() }
    }

    @Test @MainActor func reconnectGetsFreshNoneOfferWithoutCredentials() throws {
        let host = SSHHost(name: "Tailnet", hostname: "devbox.example.ts.net", username: "alice", authentication: .tailscale)
        let factory = try Authentication.factory(host: host, credential: SSHCredential())
        let loop = EmbeddedEventLoop()
        for _ in 0..<2 {
            let promise = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
            factory().nextAuthenticationType(availableMethods: [], nextChallengePromise: promise)
            let offer = try #require(try promise.futureResult.wait())
            guard case .none = offer.offer else { Issue.record("Reconnect did not offer none"); return }
        }
        #expect(try JSONDecoder().decode(SSHHost.self, from: JSONEncoder().encode(host)) == host)
    }

    @Test @MainActor func customDelegateCannotRetryNoneForever() throws {
        let delegate = TailscaleAuthenticationDelegate(username: "alice")
        let loop = EmbeddedEventLoop()
        let first = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .all, nextChallengePromise: first)
        #expect(try first.futureResult.wait() != nil)
        let second = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        delegate.nextAuthenticationType(availableMethods: .all, nextChallengePromise: second)
        #expect(try second.futureResult.wait() == nil)
    }

    @Test func checkModeTimeoutDoesNotExtendOtherAuthenticationModes() {
        #expect(Authentication.timeout(for: .tailscale) == .seconds(300))
        for authentication in [SSHAuthentication.password, .privateKey, .keyboardInteractive] {
            #expect(Authentication.timeout(for: authentication) == .seconds(120))
        }
    }

    @Test @MainActor func canceledConnectDoesNotStartAuthentication() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("iossh-canceled-\(UUID()).json")
        let session = SSHSession(knownHosts: KnownHostsStore(url: url))
        let host = SSHHost(name: "Tailnet", hostname: "devbox", username: "alice", authentication: .tailscale)
        session.onAuthenticationBanner = { _ in Issue.record("Canceled connection delivered a banner") }
        let connect = Task {
            try await session.connect(host: host, credential: SSHCredential()) { _ in
                Issue.record("Canceled connection started host verification")
                return false
            }
        }
        connect.cancel()
        do {
            try await connect.value
            Issue.record("Canceled connection succeeded")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(!session.isConnected)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
