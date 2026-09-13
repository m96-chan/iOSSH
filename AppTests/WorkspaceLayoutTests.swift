import SSHCore
import SwiftData
import SwiftUI
import TerminalRender
import UIKit
import XCTest
@testable import iOSSH

final class WorkspaceLayoutTests: XCTestCase {
    @MainActor
    func testNarrowWindowRotationAndTabSelectionKeepLiveShellsAndOneRenderer() async throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("Native iPad workspace layout") }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let container = try ModelContainer(for: HostRecord.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let savedHost = HostRecord(name: "Development", hostname: "dev.example.test", username: "tester")
        container.mainContext.insert(savedHost)
        try container.mainContext.save()

        let fixture = LayoutConnectionFixture()
        let workspace = fixture.makeWorkspace()
        defer { for id in workspace.sessions.map(\.id) { workspace.close(id: id) } }
        // Duplicate saved hosts deliberately have independent shells and parser state.
        for _ in 0..<3 {
            XCTAssertTrue(workspace.open(host: savedHost.sshHost, newSession: true))
            try await waitUntil("A fake SSH connection should finish") {
                workspace.selectedSession?.phase == .connected
            }
        }
        let sessionIDs = workspace.sessions.map(\.id)
        let attempts = workspace.sessions.map(\.connectionAttemptID)
        let engineIDs = workspace.sessions.map { ObjectIdentifier($0.terminal) }
        let selected = try XCTUnwrap(workspace.selectedSession)
        let originalSelection = selected.id

        let window = UIWindow(windowScene: scene)
        let parent = UIViewController()
        let hosting = UIHostingController(rootView: HostListView(workspace: workspace).modelContainer(container))
        window.rootViewController = parent
        parent.loadViewIfNeeded()
        parent.addChild(hosting)
        parent.view.addSubview(hosting.view)
        hosting.didMove(toParent: parent)
        window.makeKeyAndVisible()
        defer {
            terminals(in: hosting.view).forEach { $0.stop() }
            hosting.willMove(toParent: nil)
            hosting.view.removeFromSuperview()
            hosting.removeFromParent()
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKeyAndVisible()
        }

        @MainActor func layout(_ size: CGSize, marker: String) async throws -> TerminalMetalView {
            hosting.traitOverrides.horizontalSizeClass = size.width < 700 ? .compact : .regular
            hosting.view.frame = CGRect(origin: .zero, size: size)
            hosting.view.setNeedsLayout()
            parent.view.setNeedsLayout()
            var lastGeometry: String?
            var stablePasses = 0
            try await waitUntil("Workspace should settle at \(size), displaying \(marker)") {
                window.layoutIfNeeded()
                parent.view.layoutIfNeeded()
                hosting.view.layoutIfNeeded()
                // These frames emulate independent window sizes inside one scene.
                // Keep its real docked keyboard from imposing the scene's fixed
                // screen coordinates; keyboard/rotation interaction has UI coverage.
                hosting.view.endEditing(true)
                let native = self.terminals(in: hosting.view)
                guard native.count == 1, let terminal = native.first,
                      terminal.window === window, terminal.bounds.width > 100, terminal.bounds.height > 50,
                      terminal.accessibilityValue?.contains(marker) == true,
                      let model = workspace.selectedSession,
                      let transport = fixture.transport(for: marker),
                      transport.lastSize == CGSize(width: model.columns, height: model.rows) else {
                    stablePasses = 0
                    return false
                }
                let geometry = "\(terminal.frame)|\(model.columns)x\(model.rows)"
                stablePasses = geometry == lastGeometry ? stablePasses + 1 : 0
                lastGeometry = geometry
                return stablePasses >= 3
            }
            return try XCTUnwrap(terminals(in: hosting.view).first)
        }

        let wide = try await layout(CGSize(width: 1000, height: 700), marker: "shell-3")
        let wideColumns = selected.columns
        let wideWidth = wide.bounds.width
        XCTAssertGreaterThan(wideColumns, 20)
        let hiddenSizes = workspace.sessions.prefix(2).map { CGSize(width: $0.columns, height: $0.rows) }

        let compact = try await layout(CGSize(width: 600, height: 700), marker: "shell-3")
        let compactWidth = compact.bounds.width
        XCTAssertLessThan(compact.bounds.width, wideWidth)
        XCTAssertLessThan(selected.columns, wideColumns)
        XCTAssertEqual(workspace.selectedID, originalSelection)
        XCTAssertEqual(workspace.sessions.prefix(2).map { CGSize(width: $0.columns, height: $0.rows) }, hiddenSizes)
        if compact !== wide { XCTAssertNil(wide.delegate, "A replaced native terminal must release its renderer") }

        // Switch repeatedly at the same narrow width. The native input view should
        // remain attached while its content and callbacks move to the selected shell.
        let first = workspace.sessions[0]
        workspace.select(id: first.id)
        let firstTerminal = try await layout(CGSize(width: 600, height: 700), marker: "shell-1")
        XCTAssertTrue(firstTerminal === compact)
        let firstSize = CGSize(width: first.columns, height: first.rows)
        workspace.select(id: selected.id)
        let selectedTerminal = try await layout(CGSize(width: 600, height: 700), marker: "shell-3")
        XCTAssertTrue(selectedTerminal === compact)
        XCTAssertEqual(CGSize(width: first.columns, height: first.rows), firstSize)

        let expanded = try await layout(CGSize(width: 1000, height: 700), marker: "shell-3")
        XCTAssertGreaterThan(expanded.bounds.width, compactWidth)
        XCTAssertEqual(selected.columns, wideColumns)
        let landscapeRows = selected.rows
        _ = try await layout(CGSize(width: 760, height: 1000), marker: "shell-3")
        XCTAssertGreaterThan(selected.rows, landscapeRows)
        XCTAssertLessThan(selected.columns, wideColumns)
        _ = try await layout(CGSize(width: 1000, height: 700), marker: "shell-3")
        XCTAssertEqual(selected.columns, wideColumns)

        XCTAssertEqual(workspace.sessions.map(\.id), sessionIDs)
        XCTAssertEqual(workspace.sessions.map(\.connectionAttemptID), attempts)
        XCTAssertEqual(workspace.sessions.map { ObjectIdentifier($0.terminal) }, engineIDs)
        XCTAssertEqual(workspace.selectedID, originalSelection)
        XCTAssertEqual(workspace.sessions.filter(\.isVisible).map(\.id), [originalSelection])
        XCTAssertEqual(fixture.transports.count, 3)
        XCTAssertEqual(fixture.credentialLoads, 3)
        XCTAssertTrue(fixture.transports.allSatisfy { $0.connectCalls == 1 && $0.disconnectCalls == 0 && $0.isConnected })
        XCTAssertTrue(fixture.transports.allSatisfy { $0.writes.isEmpty }, "Layout and tab changes must not send shell input")
        XCTAssertEqual(terminals(in: hosting.view).count, 1)
    }

    @MainActor
    private func waitUntil(_ description: String, condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail(description)
                throw LayoutWaitError.timedOut
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private enum LayoutWaitError: Error { case timedOut }

    @MainActor
    private func terminals(in view: UIView) -> [TerminalMetalView] {
        (view as? TerminalMetalView).map { [$0] } ?? view.subviews.flatMap { terminals(in: $0) }
    }

}

@MainActor
private final class LayoutConnectionFixture {
    private(set) var transports: [LayoutTransport] = []
    private(set) var credentialLoads = 0

    func makeWorkspace() -> WorkspaceSessionStore {
        WorkspaceSessionStore { host in
            let transport = LayoutTransport(marker: "shell-\(self.transports.count + 1)")
            self.transports.append(transport)
            return ConnectionModel(host: host, dependencies: .init(
                makeTransport: { transport },
                loadCredential: { _ in
                    self.credentialLoads += 1
                    return SSHCredential(password: "test-only")
                },
                saveCredential: { _, _ in XCTFail("Layout must not save credentials") }
            ))
        }
    }

    func transport(for marker: String) -> LayoutTransport? { transports.first { $0.marker == marker } }
}

@MainActor
private final class LayoutTransport: ConnectionTransport {
    let marker: String
    var onData: (@MainActor (Data) -> Void)?
    var onDisconnect: (@MainActor (String?) -> Void)?
    var onAuthenticationBanner: (@MainActor (String) -> Void)?
    private(set) var isConnected = false
    private(set) var connectCalls = 0
    private(set) var disconnectCalls = 0
    private(set) var lastSize = CGSize.zero
    private(set) var writes: [Data] = []

    init(marker: String) { self.marker = marker }

    func connect(host: SSHHost, credential: SSHCredential, columns: Int, rows: Int,
                 pixelWidth: Int, pixelHeight: Int,
                 confirmHostKey: @escaping @Sendable (HostKeyChallenge) async -> Bool) async throws {
        connectCalls += 1
        isConnected = true
        onData?(Data("\(marker) ready\r\n".utf8))
    }

    func resize(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) async throws { lastSize = CGSize(width: columns, height: rows) }
    func write(_ data: Data) async throws { writes.append(data) }
    func checkConnection() async throws {}
    func disconnect() async { disconnectCalls += 1; isConnected = false }
}
