import Observation
import SwiftData
import SwiftUI
import TerminalRender
import UIKit
import XCTest
@testable import SSHCore
@testable import iOSSH

final class TailscaleImportPresentationTests: XCTestCase {
    @MainActor
    func testImportWaitsForAuthenticationAndKeepsItsSheetWhenTheSelectedShellChanges() async throws {
        let inbox = TailscaleImportInbox.shared
        inbox.clear()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = try XCTUnwrap(scene.windows.first(where: \.isKeyWindow))
        let previousRoot = window.rootViewController
        let container = try ModelContainer(for: HostRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let transport = ImportPresentationTransport(marker: "first-shell", requiresTrust: true)
        let model = makeConnection(transport, name: "First")
        let selection = ImportPresentationSelection(model: model)
        let hosting = UIHostingController(rootView: ImportPresentationSurface(selection: selection).modelContainer(container))
        var otherModel: ConnectionModel?
        // Replace the host app's root while exercising the shared inbox, so its
        // ordinary empty host list cannot consume this test's incoming request.
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer {
            inbox.clear()
            transport.resumeHandshake()
            model.closeImmediately()
            otherModel?.closeImmediately()
            terminals(in: hosting.view).forEach { $0.stop() }
            window.rootViewController = previousRoot
            window.makeKeyAndVisible()
        }
        try await waitUntil("The fake transport should pause before requesting host-key confirmation") {
            transport.waitingForHandshake && model.phase == .connecting && !self.terminals(in: hosting.view).isEmpty
        }
        let terminal = try XCTUnwrap(terminals(in: hosting.view).first)
        let originalAttempt = model.connectionAttemptID
        let originalParser = ObjectIdentifier(model.terminal)
        XCTAssertFalse(model.needsAuthenticationAttention,
                       "An import must also wait during the handshake before any authentication prompt exists")

        try inbox.receive(hostnames: ["atlas.tail-example.ts.net"])
        let requestID = try XCTUnwrap(inbox.request?.id)
        transport.onData?(Data("handshake still pending\r\n".utf8))
        // A visible output update proves SwiftUI has processed the changed model
        // and inbox; a sleep alone could pass before the import was considered.
        try await waitUntil("The mounted terminal should render output while connecting") {
            terminal.accessibilityValue?.contains("handshake still pending") == true
        }
        XCTAssertNil(hosting.presentedViewController)
        XCTAssertTrue(inbox.needsPresentation)
        XCTAssertEqual(model.phase, .connecting)

        transport.resumeHandshake()
        try await waitUntil("Host-key confirmation must appear before the pending import") {
            model.trustPrompt != nil && hosting.presentedViewController != nil
        }
        XCTAssertTrue(inbox.needsPresentation)
        XCTAssertEqual(inbox.request?.id, requestID)
        XCTAssertNil(importUsername(in: hosting.presentedViewController?.view))
        let trust = try XCTUnwrap(model.trustPrompt)
        model.answerTrust(true, requestID: trust.id, attemptID: trust.attemptID)

        try await waitUntil("After authentication dismisses, the queued import should appear") {
            model.phase == .connected && self.importUsername(in: hosting.presentedViewController?.view) != nil
        }
        let importController = try XCTUnwrap(hosting.presentedViewController)
        XCTAssertFalse(inbox.needsPresentation)
        XCTAssertEqual(inbox.request?.id, requestID)
        XCTAssertEqual(model.connectionAttemptID, originalAttempt)
        XCTAssertEqual(ObjectIdentifier(model.terminal), originalParser)
        XCTAssertTrue(terminals(in: hosting.view).first === terminal)

        // Selecting another already connected shell updates the retained terminal
        // beneath the modal. It must not dismiss an import that the user is reviewing.
        let secondTransport = ImportPresentationTransport(marker: "second-shell", requiresTrust: false)
        let second = makeConnection(secondTransport, name: "Second")
        otherModel = second
        second.setVisible(false)
        await second.connect()
        XCTAssertEqual(second.phase, .connected)
        let secondAttempt = second.connectionAttemptID
        model.setVisible(false)
        second.setVisible(true)
        selection.model = second
        try await waitUntil("The retained terminal should switch to the other live shell") {
            terminal.accessibilityValue?.contains("second-shell") == true
        }
        XCTAssertTrue(hosting.presentedViewController === importController)
        XCTAssertNotNil(importUsername(in: importController.view))
        XCTAssertEqual(inbox.request?.id, requestID)
        XCTAssertEqual(model.connectionAttemptID, originalAttempt)
        XCTAssertEqual(second.connectionAttemptID, secondAttempt)
        XCTAssertEqual(ObjectIdentifier(model.terminal), originalParser)
        XCTAssertTrue(terminals(in: hosting.view).first === terminal)
        XCTAssertEqual(transport.trustDecisions, [true])
        for connection in [transport, secondTransport] {
            XCTAssertTrue(connection.isConnected)
            XCTAssertEqual(connection.connectCalls, 1)
            XCTAssertEqual(connection.disconnectCalls, 0)
            XCTAssertTrue(connection.writes.isEmpty, "Import presentation must not send shell commands")
        }
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<HostRecord>()), 0,
                       "Receiving and reviewing devices must not register them automatically")
    }

    @MainActor
    private func makeConnection(_ transport: ImportPresentationTransport, name: String) -> ConnectionModel {
        ConnectionModel(host: SSHHost(name: name, hostname: "\(name.lowercased()).example.test", username: "tester",
                                      authentication: .tailscale), dependencies: .init(
            makeTransport: { transport },
            loadCredential: { _ in XCTFail("Tailscale SSH must not open Keychain"); return nil },
            saveCredential: { _, _ in XCTFail("Import presentation must not save credentials") }
        ))
    }

    @MainActor
    private func waitUntil(_ message: String, condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail(message)
                throw PresentationWaitError.timedOut
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor
    private func importUsername(in view: UIView?) -> UITextField? {
        guard let view else { return nil }
        if let field = view as? UITextField,
           field.accessibilityIdentifier == "tailscaleImportUsername" || field.placeholder == "SSH username" { return field }
        return view.subviews.lazy.compactMap { self.importUsername(in: $0) }.first
    }

    @MainActor
    private func terminals(in view: UIView) -> [TerminalMetalView] {
        (view as? TerminalMetalView).map { [$0] } ?? view.subviews.flatMap { terminals(in: $0) }
    }

    private enum PresentationWaitError: Error { case timedOut }
}

@MainActor @Observable
private final class ImportPresentationSelection {
    var model: ConnectionModel
    init(model: ConnectionModel) { self.model = model }
}

private struct ImportPresentationSurface: View {
    let selection: ImportPresentationSelection
    var body: some View {
        TerminalScreen(model: selection.model, isWorkspace: true, onClose: {})
    }
}

@MainActor
private final class ImportPresentationTransport: ConnectionTransport {
    var onData: (@Sendable (Data) -> Void)?
    var isReadyForMore: (@Sendable () -> Bool)?
    var onDisconnect: (@MainActor (String?) -> Void)?
    var onAuthenticationBanner: (@MainActor (String) -> Void)?
    private(set) var isConnected = false
    private(set) var waitingForHandshake = false
    private(set) var connectCalls = 0
    private(set) var disconnectCalls = 0
    private(set) var trustDecisions: [Bool] = []
    private(set) var writes: [Data] = []
    private let marker: String
    private let requiresTrust: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private var resumed = false

    init(marker: String, requiresTrust: Bool) {
        self.marker = marker
        self.requiresTrust = requiresTrust
    }

    func connect(host: SSHHost, credential: SSHCredential, columns: Int, rows: Int,
                 pixelWidth: Int, pixelHeight: Int,
                 confirmHostKey: @escaping @Sendable (HostKeyChallenge) async -> Bool) async throws {
        connectCalls += 1
        if requiresTrust {
            waitingForHandshake = true
            if !resumed { await withCheckedContinuation { continuation = $0 } }
            try Task.checkCancellation()
            let challenge = HostKeyChallenge(hostname: host.hostname, port: host.port,
                                             algorithm: "ssh-ed25519", fingerprint: "SHA256:import-test")
            let trusted = await confirmHostKey(challenge)
            trustDecisions.append(trusted)
            guard trusted else { throw HostKeyError.rejected }
        }
        isConnected = true
        onData?(Data("\(marker) ready\r\n".utf8))
    }

    func resumeHandshake() {
        resumed = true
        let reply = continuation
        continuation = nil
        reply?.resume()
    }

    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws {}
    func write(_ data: Data) async throws { writes.append(data) }
    func checkConnection() async throws {}
    func disconnect() async { disconnectCalls += 1; isConnected = false }
}
