import Foundation
import Testing
import SSHCore
@testable import iOSSH

@MainActor
private final class WorkspaceTransport: ConnectionTransport {
    var onData: (@Sendable (Data) -> Void)?
    var isReadyForMore: (@Sendable () -> Bool)?
    var onDisconnect: (@MainActor (String?) -> Void)?
    var onAuthenticationBanner: (@MainActor (String) -> Void)?
    var isConnected = false
    private(set) var connectCalls = 0
    private(set) var checkCalls = 0
    private(set) var disconnectCalls = 0
    private(set) var writes: [Data] = []

    func connect(host: SSHHost, credential: SSHCredential, columns: Int, rows: Int,
                 pixelWidth: Int, pixelHeight: Int,
                 confirmHostKey: @escaping @Sendable (HostKeyChallenge) async -> Bool) async throws {
        connectCalls += 1
        isConnected = true
    }

    func write(_ data: Data) async throws { writes.append(data) }
    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {}
    func checkConnection() async throws { checkCalls += 1 }
    func disconnect() async {
        disconnectCalls += 1
        isConnected = false
    }
}

@MainActor
private final class WorkspaceFixture {
    var transports: [WorkspaceTransport] = []
    var credentialLoads = 0

    func makeStore(maximumSessions: Int = 4) -> WorkspaceSessionStore {
        WorkspaceSessionStore(maximumSessions: maximumSessions) { host in
            let transport = WorkspaceTransport()
            self.transports.append(transport)
            return ConnectionModel(host: host, dependencies: .init(
                makeTransport: { transport },
                loadCredential: { _ in
                    self.credentialLoads += 1
                    return SSHCredential(password: "test")
                },
                saveCredential: { _, _ in Issue.record("Unexpected credential save") }
            ))
        }
    }
}

@MainActor
struct WorkspaceSessionStoreTests {
    private func host(_ name: String) -> SSHHost {
        SSHHost(name: name, hostname: "\(name).example.test", username: "tester")
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw WaitError.timedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private enum WaitError: Error { case timedOut }

    private func closeAll(_ store: WorkspaceSessionStore) {
        for id in store.sessions.map(\.id) { store.close(id: id) }
    }

    @Test(.timeLimit(.minutes(1)))
    func sidebarReusesMostRecentlySelectedDuplicateWhileNewSessionCreatesAnotherShell() async throws {
        let fixture = WorkspaceFixture()
        let store = fixture.makeStore()
        let sameHost = host("dev")
        defer { closeAll(store) }
        #expect(store.open(host: sameHost))
        let first = try #require(store.selectedSession)
        try await waitUntil { first.phase == .connected }
        #expect(first.id != sameHost.id)
        #expect(store.open(host: sameHost, newSession: true))
        let second = try #require(store.selectedSession)
        try await waitUntil { second.phase == .connected }
        #expect(first.id != second.id)
        #expect(first.host.id == second.host.id)
        #expect(store.sessions.count == 2)
        store.select(id: first.id)
        #expect(store.open(host: host("logs"), newSession: true))
        try await waitUntil { store.selectedSession?.phase == .connected }
        #expect(store.open(host: sameHost))
        #expect(store.selectedID == first.id)
        #expect(store.sessions.count == 3)
        #expect(store.sessions.filter(\.isVisible).map(\.id) == [first.id])
        try await waitUntil { store.sessions.allSatisfy { $0.phase == .connected } }
        #expect(fixture.transports.allSatisfy { $0.connectCalls == 1 })
        #expect(fixture.credentialLoads == 3)
    }

    @Test(.timeLimit(.minutes(1)))
    func fourTabLimitIncludesDisconnectedShellsAndNeverEvictsTheSelectedSession() async throws {
        let fixture = WorkspaceFixture()
        let store = fixture.makeStore()
        defer { closeAll(store) }
        for index in 0..<4 {
            #expect(store.open(host: host("host\(index)"), newSession: true))
            try await waitUntil { store.selectedSession?.phase == .connected }
        }
        try await waitUntil { store.sessions.allSatisfy { $0.phase == .connected } }
        let selected = try #require(store.selectedSession)
        let first = try #require(store.sessions.first)
        await first.close()
        let originalIDs = store.sessions.map(\.id)
        #expect(!store.canOpenSession)
        #expect(!store.open(host: host("fifth"), newSession: true))
        #expect(store.sessions.map(\.id) == originalIDs)
        #expect(store.selectedID == selected.id)
        #expect(fixture.transports[1...].allSatisfy { $0.disconnectCalls == 0 })
        #expect(store.open(host: first.host)) // Existing tabs remain selectable at the limit.
        #expect(store.selectedID == first.id)
        #expect(first.phase == .disconnected) // Sidebar selection is not an implicit reconnect.
    }

    @Test(.timeLimit(.minutes(1)))
    func closingInvalidatesOnlyThatShellImmediatelyAndSelectsTheMostRecentSurvivor() async throws {
        let fixture = WorkspaceFixture()
        let store = fixture.makeStore()
        defer { closeAll(store) }
        #expect(store.open(host: host("dev")))
        let first = try #require(store.selectedSession)
        try await waitUntil { first.phase == .connected }
        #expect(store.open(host: host("logs")))
        let second = try #require(store.selectedSession)
        try await waitUntil { store.sessions.allSatisfy { $0.phase == .connected } }
        let oldAttempt = second.connectionAttemptID
        let staleOutput = fixture.transports[1].onData
        let oldCells = await second.terminal.snapshot().cells
        store.close(id: second.id)
        #expect(second.connectionAttemptID != oldAttempt)
        #expect(second.phase == .disconnected)
        #expect(store.sessions.map(\.id) == [first.id])
        #expect(store.selectedID == first.id)
        #expect(first.isVisible)
        staleOutput?(Data("late data".utf8))
        #expect(await second.terminal.snapshot().cells == oldCells)
        try await waitUntil { fixture.transports[1].disconnectCalls == 1 }
        #expect(fixture.transports[0].isConnected)
        #expect(fixture.transports[0].disconnectCalls == 0)
        store.close(id: first.id)
        #expect(store.sessions.isEmpty)
        #expect(store.selectedSession == nil)
        #expect(store.canOpenSession)
    }

    @Test(.timeLimit(.minutes(1)))
    func screenLockChecksEveryRetainedShellIncludingHiddenTabs() async throws {
        let fixture = WorkspaceFixture()
        let store = fixture.makeStore()
        defer { closeAll(store) }
        for index in 0..<4 {
            #expect(store.open(host: host("host\(index)"), newSession: true))
            try await waitUntil { store.selectedSession?.phase == .connected }
        }
        try await waitUntil { store.sessions.allSatisfy { $0.phase == .connected } }
        let originalIDs = store.sessions.map(\.id)
        let originalSelection = store.selectedID
        store.enterBackground()
        store.enterForeground()
        store.enterForeground()
        try await waitUntil { store.sessions.allSatisfy { $0.phase == .connected } }
        #expect(store.sessions.map(\.id) == originalIDs)
        #expect(store.selectedID == originalSelection)
        #expect(fixture.transports.allSatisfy { $0.checkCalls == 1 && $0.connectCalls == 1 && $0.disconnectCalls == 0 })
        #expect(fixture.credentialLoads == 4)
        #expect(store.sessions.filter(\.isVisible).count == 1)
    }

    @Test
    func phoneCanKeepItsSingleSessionLimit() {
        let fixture = WorkspaceFixture()
        let store = fixture.makeStore(maximumSessions: 1)
        defer { closeAll(store) }
        let savedHost = host("phone")
        #expect(store.open(host: savedHost))
        #expect(store.open(host: savedHost))
        #expect(!store.open(host: savedHost, newSession: true))
        #expect(store.sessions.count == 1)
    }
}
