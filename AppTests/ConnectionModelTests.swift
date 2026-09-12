import Foundation
import Testing
@testable import SSHCore
@testable import iOSSH

@MainActor
private final class Suspension {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var arrived = false
    private var released = false

    func wait() async {
        arrived = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        let reply = continuation
        continuation = nil
        reply?.resume()
    }
}

@MainActor
private final class TestTransport: ConnectionTransport {
    var onData: (@MainActor (Data) -> Void)?
    var onDisconnect: (@MainActor (String?) -> Void)?
    var isConnected = false
    var connectionSuspension: Suspension?
    var writeSuspension: Suspension?
    var resizeSuspension: Suspension?
    var disconnectWhileConnecting: String?
    var requiresTrust = false
    private(set) var initialSize: [Int]?
    private(set) var sizes: [[Int]] = []
    private(set) var writes: [Data] = []
    private(set) var writeReturned = false
    private(set) var disconnectCalls = 0
    private(set) var trustDecisions: [Bool] = []

    func connect(host: SSHHost, credential: SSHCredential, columns: Int, rows: Int,
                 confirmHostKey: @escaping @Sendable (HostKeyChallenge) async -> Bool) async throws {
        initialSize = [columns, rows]
        await connectionSuspension?.wait()
        if requiresTrust {
            let challenge = HostKeyChallenge(hostname: host.hostname, port: host.port,
                                             algorithm: "ssh-ed25519", fingerprint: "SHA256:test-fingerprint")
            let trusted = await confirmHostKey(challenge)
            trustDecisions.append(trusted)
            guard trusted else { throw HostKeyError.rejected }
        }
        isConnected = true
        if let reason = disconnectWhileConnecting { remoteDisconnect(reason) }
    }

    func write(_ data: Data) async throws {
        writes.append(data)
        await writeSuspension?.wait()
        defer { writeReturned = true }
        guard isConnected else { throw SSHSessionError.notConnected }
    }

    func resize(columns: Int, rows: Int) async throws {
        guard isConnected else { throw SSHSessionError.notConnected }
        sizes.append([columns, rows])
        let pause = resizeSuspension
        resizeSuspension = nil
        await pause?.wait()
    }

    func disconnect() async {
        disconnectCalls += 1
        isConnected = false
    }

    func remoteDisconnect(_ reason: String) {
        isConnected = false
        onDisconnect?(reason)
    }
}

@MainActor
struct ConnectionModelTests {
    private var host: SSHHost {
        SSHHost(name: "Test", hostname: "example.test", username: "tester")
    }

    private func dependencies(_ transport: TestTransport,
                              load: @escaping @MainActor (UUID) async throws -> SSHCredential? = { _ in SSHCredential(password: "test") }) -> ConnectionModel.Dependencies {
        .init(makeTransport: { transport }, loadCredential: load, saveCredential: { _, _ in
            Issue.record("Lifecycle test unexpectedly attempted to save a credential")
        })
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw WaitError.timedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private enum WaitError: Error { case timedOut }

    @Test(.timeLimit(.minutes(1)))
    func canceledCredentialPromptCannotChangeNewAttemptsPhase() async throws {
        let transport = TestTransport()
        let newLoad = Suspension()
        let model = ConnectionModel(host: host, dependencies: dependencies(transport) { _ in
            await newLoad.wait()
            return SSHCredential(password: "test")
        })
        let oldAttempt = Task { await model.connect(enterCredential: true) }
        defer {
            newLoad.release()
            oldAttempt.cancel()
            Task { await model.close() }
        }
        try await waitUntil { model.credentialPrompt }
        await model.close()

        // The new connect starts synchronously on the main actor before its credential load yields.
        // The old nil response then resumes while the new attempt is already connecting.
        let inspect = Task {
            defer { newLoad.release() }
            try await waitUntil { newLoad.arrived }
            await oldAttempt.value
            #expect(model.phase == .connecting)
            newLoad.release()
        }
        await model.connect()
        try await inspect.value
        #expect(model.phase == .connected)
        await model.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func resizeDuringAuthenticationReachesTheNewPTY() async throws {
        let transport = TestTransport()
        let authentication = Suspension()
        transport.connectionSuspension = authentication
        let model = ConnectionModel(host: host, dependencies: dependencies(transport))
        let connecting = Task { await model.connect() }
        defer {
            authentication.release()
            connecting.cancel()
            Task { await model.close() }
        }
        try await waitUntil { authentication.arrived }
        #expect(transport.initialSize == [80, 24])
        model.resize(columns: 119, rows: 37)
        #expect(transport.sizes.isEmpty)
        authentication.release()
        await connecting.value
        #expect(transport.sizes.last == [119, 37])
        #expect(model.phase == .connected)
        await model.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func resizeWhileInitialWindowChangeIsPendingAlsoReachesThePTY() async throws {
        let transport = TestTransport()
        let initialWindowChange = Suspension()
        transport.resizeSuspension = initialWindowChange
        let model = ConnectionModel(host: host, dependencies: dependencies(transport))
        let connecting = Task { await model.connect() }
        defer {
            initialWindowChange.release()
            connecting.cancel()
            Task { await model.close() }
        }
        try await waitUntil { initialWindowChange.arrived }
        model.resize(columns: 103, rows: 31)
        initialWindowChange.release()
        await connecting.value
        #expect(transport.sizes.last == [103, 31])
        #expect(model.phase == .connected)
        await model.close()
    }

    @Test
    func immediateRemoteExitIsNotOverwrittenAsConnected() async {
        let transport = TestTransport()
        transport.disconnectWhileConnecting = "The remote shell exited immediately."
        let model = ConnectionModel(host: host, dependencies: dependencies(transport))
        await model.connect()
        #expect(model.phase == .disconnected)
        #expect(model.message == "The remote shell exited immediately.")
        #expect(transport.sizes.isEmpty)
        await model.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func remoteDisconnectReasonSurvivesCanceledPendingWrite() async throws {
        let transport = TestTransport()
        let pendingWrite = Suspension()
        transport.writeSuspension = pendingWrite
        let model = ConnectionModel(host: host, dependencies: dependencies(transport))
        defer {
            pendingWrite.release()
            Task { await model.close() }
        }
        await model.connect()
        model.send(Data("command\r".utf8))
        try await waitUntil { pendingWrite.arrived }
        transport.remoteDisconnect("The peer closed the connection.")
        pendingWrite.release() // The outstanding socket write now fails after writer cancellation.
        try await waitUntil { transport.writeReturned }
        await Task.yield()
        #expect(model.phase == .disconnected)
        #expect(model.message == "The peer closed the connection.")
        #expect(transport.disconnectCalls == 0)
        await model.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func explicitTrustAcceptanceConnectsAndResumesOnlyOnce() async throws {
        let transport = TestTransport()
        transport.requiresTrust = true
        let model = ConnectionModel(host: host, dependencies: dependencies(transport))
        let connecting = Task { await model.connect() }
        defer {
            model.answerTrust(false)
            connecting.cancel()
            Task { await model.close() }
        }
        try await waitUntil { model.trustPrompt != nil }
        #expect(model.trustPrompt?.challenge.hostname == host.hostname)
        #expect(!transport.isConnected)
        model.answerTrust(true)
        model.answerTrust(false) // A later dismissal must not revoke the completed answer.
        await connecting.value
        #expect(transport.trustDecisions == [true])
        #expect(model.trustPrompt == nil)
        #expect(model.phase == .connected)
        await model.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func explicitTrustCancellationBlocksConnection() async throws {
        let transport = TestTransport()
        transport.requiresTrust = true
        let model = ConnectionModel(host: host, dependencies: dependencies(transport))
        let connecting = Task { await model.connect() }
        defer {
            model.answerTrust(false)
            connecting.cancel()
            Task { await model.close() }
        }
        try await waitUntil { model.trustPrompt != nil }
        model.answerTrust(false)
        await connecting.value
        #expect(transport.trustDecisions == [false])
        #expect(model.trustPrompt == nil)
        #expect(!transport.isConnected)
        #expect(model.phase == .failed)
        #expect(model.message == HostKeyError.rejected.localizedDescription)
        await model.close()
    }
}
