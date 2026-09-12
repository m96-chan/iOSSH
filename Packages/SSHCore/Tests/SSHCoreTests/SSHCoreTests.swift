import Foundation
import Testing
import Crypto
@testable import SSHCore

private actor Confirmations {
    var count = 0
    func accept() -> Bool { count += 1; return true }
}

struct SSHCoreTests {
    private func temporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("known-hosts.json")
    }

    @Test func hostRoundTripKeepsIdentityAndExcludesSecrets() throws {
        let host = SSHHost(name: "Development", hostname: "example.com", username: "alice")
        let encoded = try JSONEncoder().encode(host)
        #expect(try JSONDecoder().decode(SSHHost.self, from: encoded) == host)
        #expect(host.terminalType == "xterm-256color")
        #expect(!String(decoding: encoded, as: UTF8.self).contains("privateKey"))
        try host.validate()
        var invalid = host
        invalid.port = 65536
        #expect(throws: SSHSessionError.invalidConfiguration) { try invalid.validate() }
        invalid = host
        invalid.hostname = "example.com\nmalicious"
        #expect(throws: SSHSessionError.invalidConfiguration) { try invalid.validate() }
    }

    @Test func tofuPersistsAndReusesTrustForSameEndpoint() async throws {
        let url = try temporaryStoreURL()
        let store = KnownHostsStore(url: url)
        let confirmations = Confirmations()
        let key = Data("host-key".utf8)
        try await store.verify(hostname: "Example.COM", port: 22, algorithm: "ssh-ed25519", key: key) { _ in
            await confirmations.accept()
        }
        let reopened = KnownHostsStore(url: url)
        try await reopened.verify(hostname: "example.com.", port: 22, algorithm: "ssh-ed25519", key: key) { _ in
            await confirmations.accept()
        }
        #expect(await confirmations.count == 1)
        try await reopened.verify(hostname: "example.com", port: 2222, algorithm: "ssh-ed25519", key: key) { _ in
            await confirmations.accept()
        }
        #expect(await confirmations.count == 2)
    }

    @Test func changedKeyBlocksWithoutAskingAndDoesNotReplaceTrust() async throws {
        let url = try temporaryStoreURL()
        let store = KnownHostsStore(url: url)
        let original = Data([1, 2, 3])
        try await store.verify(hostname: "host", port: 22, algorithm: "ssh-ed25519", key: original) { _ in true }
        let confirmations = Confirmations()
        do {
            try await store.verify(hostname: "host", port: 22, algorithm: "ssh-ed25519", key: Data([4])) { _ in
                await confirmations.accept()
            }
            Issue.record("Changed key was accepted")
        } catch let error as HostKeyError {
            guard case .changed = error else { Issue.record("Expected changed-key error"); return }
        }
        #expect(await confirmations.count == 0)
        try await store.verify(hostname: "host", port: 22, algorithm: "ssh-ed25519", key: original) { _ in false }
    }

    @Test func declinedKeyIsNeverPersisted() async throws {
        let url = try temporaryStoreURL()
        let store = KnownHostsStore(url: url)
        await #expect(throws: HostKeyError.rejected) {
            try await store.verify(hostname: "host", port: 22, algorithm: "ssh-ed25519", key: Data([1])) { _ in false }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func corruptKnownHostsFailsClosed() async throws {
        let url = try temporaryStoreURL()
        try Data("broken".utf8).write(to: url)
        let store = KnownHostsStore(url: url)
        let confirmations = Confirmations()
        await #expect(throws: (any Error).self) {
            try await store.verify(hostname: "host", port: 22, algorithm: "ssh-ed25519", key: Data([1])) { _ in
                await confirmations.accept()
            }
        }
        #expect(await confirmations.count == 0)
    }

    @Test func fingerprintMatchesOpenSSHStyle() {
        #expect(KnownHostsStore.fingerprint(of: Data("abc".utf8)) == "SHA256:ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0")
    }

    @Test func unavailableAuthenticationFailsBeforeNetworking() throws {
        let host = SSHHost(name: "Host", hostname: "example.com", username: "user", authentication: .keyboardInteractive)
        #expect(throws: SSHSessionError.unsupportedKeyboardInteractive) {
            try Authentication.factory(host: host, credential: SSHCredential())
        }
        var password = host
        password.authentication = .password
        #expect(throws: SSHSessionError.missingCredential) {
            try Authentication.factory(host: password, credential: SSHCredential())
        }
    }

    @Test func acceptsECDSAPEMKeys() throws {
        let host = SSHHost(name: "Host", hostname: "example.com", username: "user", authentication: .privateKey)
        _ = try Authentication.factory(host: host, credential: SSHCredential(privateKey: P256.Signing.PrivateKey().pemRepresentation))
        _ = try Authentication.factory(host: host, credential: SSHCredential(privateKey: P384.Signing.PrivateKey().pemRepresentation))
        _ = try Authentication.factory(host: host, credential: SSHCredential(privateKey: P521.Signing.PrivateKey().pemRepresentation))
    }
}
