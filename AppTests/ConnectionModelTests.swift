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
    var onAuthenticationBanner: (@MainActor (String) -> Void)?
    var isConnected = false
    var connectionSuspension: Suspension?
    var writeSuspension: Suspension?
    var resizeSuspension: Suspension?
    var checkSuspension: Suspension?
    var checkError: (any Error)?
    var disconnectWhileConnecting: String?
    var requiresTrust = false
    var authenticationBannerOnConnect: String?
    private(set) var receivedCredential: SSHCredential?
    private(set) var initialSize: [Int]?
    private(set) var sizes: [[Int]] = []
    private(set) var writes: [Data] = []
    private(set) var writeReturned = false
    private(set) var disconnectCalls = 0
    private(set) var connectCalls = 0
    private(set) var checkCalls = 0
    private(set) var trustDecisions: [Bool] = []

    func connect(host: SSHHost, credential: SSHCredential, columns: Int, rows: Int,
                 confirmHostKey: @escaping @Sendable (HostKeyChallenge) async -> Bool) async throws {
        connectCalls += 1
        initialSize = [columns, rows]
        receivedCredential = credential
        if let banner = authenticationBannerOnConnect { onAuthenticationBanner?(banner) }
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

    func checkConnection() async throws {
        checkCalls += 1
        let pause = checkSuspension
        checkSuspension = nil
        let error = checkError
        checkError = nil
        await pause?.wait()
        try Task.checkCancellation()
        guard isConnected else { throw SSHSessionError.disconnected }
        if let error { throw error }
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
    func screenLockRetainsTheTransportHistoryAndCursor() async throws {
        let transport = TestTransport()
        var credentialLoads = 0
        let model = ConnectionModel(host: host, dependencies: dependencies(transport) { _ in
            credentialLoads += 1
            return SSHCredential(password: "test")
        })
        await model.connect()
        transport.onData?(Data((String(repeating: "earlier output\r\n", count: 40) + "prompt> partial input").utf8))
        let before = model.engine.snapshot()
        let checking = Suspension()
        transport.checkSuspension = checking
        defer {
            checking.release()
            Task { await model.close() }
        }
        model.enterBackground()
        #expect(transport.isConnected)
        #expect(transport.disconnectCalls == 0)
        model.enterForeground()
        model.enterForeground() // Duplicate lifecycle notifications coalesce.
        model.connectOnFirstAppearance() // Reappearing under a sheet must not create a shell.
        try await waitUntil { checking.arrived }
        #expect(model.phase == .checking)
        #expect(transport.checkCalls == 1)
        #expect(transport.connectCalls == 1)
        #expect(credentialLoads == 1)
        checking.release()
        try await waitUntil { model.phase == .connected }
        let after = model.engine.snapshot()
        #expect(after.cells == before.cells)
        #expect(after.cursor == before.cursor)
        #expect(after.scrollbackCount == before.scrollbackCount)
        #expect(transport.writes.isEmpty)
        #expect(transport.disconnectCalls == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func foregroundFindsAClosedSessionAndReconnectsOnlyOnRequest() async throws {
        let transport = TestTransport()
        let model = ConnectionModel(host: host, dependencies: dependencies(transport))
        await model.connect()
        transport.onData?(Data("existing output".utf8))
        let before = model.engine.snapshot()
        model.enterBackground()
        transport.isConnected = false // Socket closure can precede delivery of its UI callback.
        model.enterForeground()
        try await waitUntil { model.phase == .disconnected }
        #expect(model.message?.contains("Reconnect") == true)
        #expect(transport.connectCalls == 1)
        #expect(transport.checkCalls == 0)
        #expect(model.engine.snapshot().cells == before.cells)
        model.enterForeground()
        model.connectOnFirstAppearance()
        await Task.yield()
        #expect(transport.connectCalls == 1)
        await model.connect()
        #expect(transport.connectCalls == 2)
        #expect(model.phase == .connected)
        await model.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func anotherScreenLockCancelsOnlyTheOldForegroundCheck() async throws {
        let transport = TestTransport()
        let model = ConnectionModel(host: host, dependencies: dependencies(transport))
        await model.connect()
        let first = Suspension()
        let second = Suspension()
        defer {
            first.release()
            second.release()
            Task { await model.close() }
        }
        transport.checkSuspension = first
        transport.checkError = SSHSessionError.connectionTimedOut
        model.enterBackground()
        model.enterForeground()
        try await waitUntil { first.arrived }
        model.enterBackground()
        transport.checkSuspension = second
        model.enterForeground()
        try await waitUntil { second.arrived }
        first.release()
        await Task.yield()
        #expect(model.phase == .checking)
        #expect(transport.disconnectCalls == 0)
        second.release()
        try await waitUntil { model.phase == .connected }
        #expect(transport.connectCalls == 1)
        #expect(transport.checkCalls == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func aLateCheckCannotCloseANewExplicitConnection() async throws {
        let firstTransport = TestTransport()
        let secondTransport = TestTransport()
        var count = 0
        var deps = dependencies(firstTransport)
        deps.makeTransport = {
            count += 1
            return count == 1 ? firstTransport : secondTransport
        }
        let model = ConnectionModel(host: host, dependencies: deps)
        await model.connect()
        let oldCheck = Suspension()
        firstTransport.checkSuspension = oldCheck
        firstTransport.checkError = SSHSessionError.connectionTimedOut
        defer {
            oldCheck.release()
            Task { await model.close() }
        }
        model.enterBackground()
        model.enterForeground()
        try await waitUntil { oldCheck.arrived }
        await model.close()
        await model.connect()
        oldCheck.release()
        await Task.yield()
        #expect(model.phase == .connected)
        #expect(secondTransport.isConnected)
        #expect(secondTransport.disconnectCalls == 0)
        #expect(count == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func remoteClosureDuringCheckKeepsTheRealDisconnectReason() async throws {
        let transport = TestTransport()
        let model = ConnectionModel(host: host, dependencies: dependencies(transport))
        await model.connect()
        let checking = Suspension()
        transport.checkSuspension = checking
        defer {
            checking.release()
            Task { await model.close() }
        }
        model.enterBackground()
        model.enterForeground()
        try await waitUntil { checking.arrived }
        transport.remoteDisconnect("The server ended this shell.")
        checking.release()
        await Task.yield()
        #expect(model.phase == .disconnected)
        #expect(model.message == "The server ended this shell.")
        #expect(transport.disconnectCalls == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func foregroundUsesTheLatestSizeEvenWhileItsResizeIsPending() async throws {
        let transport = TestTransport()
        let model = ConnectionModel(host: host, dependencies: dependencies(transport))
        await model.connect()
        let resizing = Suspension()
        defer {
            resizing.release()
            Task { await model.close() }
        }
        model.enterBackground()
        model.resize(columns: 100, rows: 30)
        #expect(transport.sizes.last == [80, 24])
        transport.resizeSuspension = resizing
        model.enterForeground()
        try await waitUntil { resizing.arrived }
        model.resize(columns: 120, rows: 35)
        resizing.release()
        try await waitUntil { model.phase == .connected }
        #expect(transport.sizes.last == [120, 35])
        #expect(transport.connectCalls == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingAuthenticationSurvivesLockAndRepeatedAppearances() async throws {
        let transport = TestTransport()
        transport.requiresTrust = true
        let model = ConnectionModel(host: host, dependencies: dependencies(transport))
        defer { Task { await model.close() } }
        model.connectOnFirstAppearance()
        model.connectOnFirstAppearance()
        try await waitUntil { model.trustPrompt != nil }
        let promptID = model.trustPrompt?.id
        model.enterBackground()
        model.enterForeground()
        model.connectOnFirstAppearance()
        #expect(model.trustPrompt?.id == promptID)
        #expect(model.phase == .connecting)
        #expect(transport.connectCalls == 1)
        #expect(transport.checkCalls == 0)
        #expect(transport.disconnectCalls == 0)
        model.answerTrust(true)
        try await waitUntil { model.phase == .connected }
        #expect(transport.trustDecisions == [true])
        #expect(transport.connectCalls == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func aNonresponsiveSessionShowsReconnectAfterTheForegroundGracePeriod() async throws {
        let transport = TestTransport()
        let model = ConnectionModel(host: host, dependencies: dependencies(transport))
        await model.connect()
        transport.checkError = SSHSessionError.connectionTimedOut
        model.enterBackground()
        model.enterForeground()
        try await waitUntil { model.phase == .disconnected }
        #expect(model.message?.contains("30 seconds") == true)
        #expect(transport.disconnectCalls == 1)
        #expect(transport.connectCalls == 1)
    }

    @Test(arguments: [false, true])
    func tailscaleConnectsWithoutLoadingOrPromptingForSecrets(enterCredential: Bool) async {
        let transport = TestTransport()
        var tailscaleHost = host
        tailscaleHost.authentication = .tailscale
        let model = ConnectionModel(host: tailscaleHost, dependencies: dependencies(transport) { _ in
            Issue.record("Tailscale SSH must not access saved passwords or keys")
            return nil
        })
        await model.connect(enterCredential: enterCredential)
        #expect(model.phase == .connected)
        #expect(!model.credentialPrompt)
        #expect(transport.receivedCredential == SSHCredential())
        await model.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func tailscaleApprovalAppearsWhileConnectingAndStaleBannersAreIgnored() async throws {
        let transport = TestTransport()
        let authentication = Suspension()
        transport.connectionSuspension = authentication
        transport.authenticationBannerOnConnect = "Authenticate at https://login.tailscale.com/a/test-approval"
        var tailscaleHost = host
        tailscaleHost.authentication = .tailscale
        let model = ConnectionModel(host: tailscaleHost, dependencies: dependencies(transport))
        let connecting = Task { await model.connect() }
        defer {
            authentication.release()
            connecting.cancel()
            Task { await model.close() }
        }
        try await waitUntil { authentication.arrived }
        #expect(model.phase == .connecting)
        #expect(model.authenticationURL?.absoluteString == "https://login.tailscale.com/a/test-approval")
        #expect(model.authenticationBanner.contains("Authenticate"))
        transport.onAuthenticationBanner?("Please complete the sign-in to continue.")
        #expect(model.authenticationURL?.absoluteString == "https://login.tailscale.com/a/test-approval")
        let staleBanner = transport.onAuthenticationBanner
        authentication.release()
        await connecting.value
        #expect(model.phase == .connected)
        #expect(model.authenticationURL == nil)
        #expect(model.authenticationBanner.isEmpty)
        await model.close()
        staleBanner?("https://login.tailscale.com/a/stale")
        #expect(model.authenticationBanner.isEmpty)
        #expect(model.authenticationURL == nil)
    }

    @Test
    func savedTailscaleHostPreservesItsAuthenticationMode() {
        let record = HostRecord(name: "Tailnet", hostname: "my-server", username: "developer", authentication: "tailscale")
        #expect(record.sshHost.authentication == .tailscale)
        #expect(record.sshHost.hostname == "my-server")
    }

    @Test
    func tailscaleSignInLinksRequireTheExpectedHTTPSOrigin() {
        #expect(TailscaleAuthentication.loginURL(in: "Visit https://login.tailscale.com/a/approval.")?.path == "/a/approval")
        for text in ["http://login.tailscale.com/a/approval", "https://tailscale.com.evil.test/a/approval",
                     "https://eviltailscale.com/a/approval", "https://user:password@login.tailscale.com/a/approval",
                     "https://login.tailscale.com:444/a/approval", "javascript:alert(1)"] {
            #expect(TailscaleAuthentication.loginURL(in: text) == nil)
        }
    }

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
