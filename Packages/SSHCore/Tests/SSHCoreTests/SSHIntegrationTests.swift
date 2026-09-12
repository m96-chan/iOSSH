import Foundation
import Testing
@testable import SSHCore

/// Opt-in: run against a disposable OpenSSH server that allows a PTY and an ordinary shell.
/// IOSSH_TEST_SSH_HOST, IOSSH_TEST_SSH_PORT, IOSSH_TEST_SSH_USER, IOSSH_TEST_SSH_KEY_PATH.
struct SSHIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["IOSSH_TEST_SSH_HOST"] != nil))
    @MainActor func realPTYResizeAndReconnect() async throws {
        let env = ProcessInfo.processInfo.environment
        let hostname = try #require(env["IOSSH_TEST_SSH_HOST"])
        let username = try #require(env["IOSSH_TEST_SSH_USER"])
        let keyPath = try #require(env["IOSSH_TEST_SSH_KEY_PATH"])
        let key = try String(contentsOfFile: keyPath, encoding: .utf8)
        let host = SSHHost(name: "Integration", hostname: hostname, port: Int(env["IOSSH_TEST_SSH_PORT"] ?? "22") ?? 22,
                           username: username, authentication: .privateKey)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("iossh-integration-\(UUID()).json")
        let credential = SSHCredential(privateKey: key)
        let session = SSHSession(knownHosts: KnownHostsStore(url: url))
        do {
            try await session.connect(host: host, credential: credential) { challenge in
                #expect(challenge.hostname == hostname)
                #expect(challenge.fingerprint.hasPrefix("SHA256:"))
                return true
            }
            #expect(session.isConnected)
            try await expectOutput(session, command: "printf 'iossh-%s\\n' 'integration-ok'\r", contains: "iossh-integration-ok")
            try await session.resize(columns: 111, rows: 41)
            try await expectOutput(session, command: "printf 'SIZE:'; stty size\r", contains: "SIZE:41 111")
            await session.disconnect()
            #expect(!session.isConnected)

            // A newly loaded store proves trust survives the original actor/session.
            let reconnect = SSHSession(knownHosts: KnownHostsStore(url: url))
            do {
                try await reconnect.connect(host: host, credential: credential) { _ in
                    Issue.record("Trusted host unexpectedly prompted again")
                    return false
                }
                try await expectOutput(reconnect, command: "printf 'iossh-%s\\n' 'reconnected'\r", contains: "iossh-reconnected")
                try await expectRemoteDisconnect(reconnect)
                #expect(!reconnect.isConnected)
            } catch { await reconnect.disconnect(); throw error }
        } catch { await session.disconnect(); throw error }
    }

    @MainActor private func expectRemoteDisconnect(_ session: SSHSession) async throws {
        let (stream, continuation) = AsyncThrowingStream<Void, Error>.makeStream()
        session.onDisconnect = { _ in continuation.yield(()); continuation.finish() }
        let timeout = Task {
            do {
                try await Task.sleep(for: .seconds(10))
                continuation.finish(throwing: SSHSessionError.connectionTimedOut)
            } catch {}
        }
        defer { timeout.cancel(); session.onDisconnect = nil; continuation.finish() }
        try await session.write(Data("exit\r".utf8))
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() != nil)
    }

    @MainActor private func expectOutput(_ session: SSHSession, command: String, contains expected: String) async throws {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        session.onData = { continuation.yield($0) }
        session.onDisconnect = { _ in continuation.finish(throwing: SSHSessionError.disconnected) }
        let timeout = Task {
            do {
                try await Task.sleep(for: .seconds(10))
                continuation.finish(throwing: SSHSessionError.connectionTimedOut)
            } catch {}
        }
        defer {
            timeout.cancel()
            session.onData = nil
            session.onDisconnect = nil
            continuation.finish()
        }
        // Data slices can retain a nonzero startIndex; input must preserve their exact bytes.
        let slicedInput = Data(("discard" + command).utf8).dropFirst(7)
        try await session.write(slicedInput)
        var output = Data()
        for try await chunk in stream {
            output.append(chunk)
            if String(decoding: output, as: UTF8.self).contains(expected) { return }
            guard output.count < 1_048_576 else { throw SSHSessionError.outputOverflow }
        }
        Issue.record("Expected terminal output was not received")
    }
}
