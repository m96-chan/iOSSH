import Foundation
import Observation
import SSHCore
import TerminalCore
import UIKit

/// How the store asks iOS for the time it needs, and gives it back.
@MainActor struct BackgroundAssertions {
    var begin: @MainActor (@escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier
    var end: @MainActor (UIBackgroundTaskIdentifier) -> Void

    static let live = BackgroundAssertions(
        begin: { expired in
            UIApplication.shared.beginBackgroundTask(withName: "Keep the SSH session open", expirationHandler: expired)
        },
        end: { UIApplication.shared.endBackgroundTask($0) }
    )
}

/// Owns live shells independently of navigation, sheet presentation, and window size.
@MainActor @Observable
final class WorkspaceSessionStore {
    private(set) var sessions: [ConnectionModel] = []
    private(set) var selectedID: UUID?
    let maximumSessions: Int
    let imageBudget: TerminalImageBudget
    var selectedSession: ConnectionModel? { sessions.first { $0.id == selectedID } }
    var canOpenSession: Bool { sessions.count < maximumSessions }

    @ObservationIgnored private let makeConnection: @MainActor (SSHHost) -> ConnectionModel
    @ObservationIgnored private var selectionHistory: [UUID] = []
    @ObservationIgnored private var isInBackground = false
    @ObservationIgnored private var backgroundAssertion = UIBackgroundTaskIdentifier.invalid
    /// Injected so a test can watch the assertion without a real one: failing to end one is how
    /// an app gets killed, so "it was ended" is the part worth asserting on.
    @ObservationIgnored var backgroundAssertions: BackgroundAssertions = .live

    init(maximumSessions: Int = 4,
         makeConnection: (@MainActor (SSHHost) -> ConnectionModel)? = nil) {
        self.maximumSessions = max(1, maximumSessions)
        let imageBudget = TerminalImageBudget()
        self.imageBudget = imageBudget
        self.makeConnection = makeConnection ?? { ConnectionModel(host: $0, imageBudget: imageBudget) }
    }

    /// Sidebar selection reuses the most recently selected shell for this host.
    /// An explicit New Session always creates a shell, up to the visible tab limit.
    @discardableResult
    func open(host: SSHHost, newSession: Bool = false) -> Bool {
        if !newSession,
           let existingID = selectionHistory.first(where: { id in
               sessions.contains { $0.id == id && $0.host.id == host.id }
           }) {
            select(id: existingID)
            return true
        }
        guard canOpenSession else { return false }
        let model = makeConnection(host)
        model.setVisible(false)
        if isInBackground { model.enterBackground() }
        sessions.append(model)
        select(id: model.id)
        model.connectOnFirstAppearance()
        return true
    }

    func select(id: UUID) {
        guard let selected = sessions.first(where: { $0.id == id }) else { return }
        for model in sessions where model.id != id { model.setVisible(false) }
        selectedID = id
        selectionHistory.removeAll { $0 == id }
        selectionHistory.insert(id, at: 0)
        selected.setVisible(true)
    }

    /// Removes this shell immediately; disconnect completion cannot affect another tab.
    func close(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let removed = sessions[index]
        removed.setVisible(false)
        removed.closeImmediately()
        sessions.remove(at: index)
        selectionHistory.removeAll { $0 == id }
        if selectedID == id {
            selectedID = nil
            if let nextID = selectionHistory.first { select(id: nextID) }
        }
    }

    func enterBackground() {
        isInBackground = true
        sessions.forEach { $0.enterBackground() }
        holdBackgroundAssertion()
    }

    /// Asks iOS not to suspend the app immediately, so a live shell survives a glance at another
    /// app, a notification, or a lock and unlock a few seconds later (#46).
    ///
    /// A suspended process cannot service its socket, which is how the session dies — nothing
    /// here hangs up. The assertion buys around thirty seconds, which is not a fix for leaving
    /// the app for an hour and is not meant to be: no entitlement iOS grants an SSH client keeps
    /// a TCP session alive indefinitely, and `README.md` already points at a remote multiplexer
    /// for continuity across a real disconnection.
    ///
    /// Taken only when there is something to keep alive. Asking for background time to do
    /// nothing is both wasteful and the kind of thing that gets noticed.
    private func holdBackgroundAssertion() {
        guard backgroundAssertion == .invalid,
              sessions.contains(where: { $0.phase == .connected || $0.phase == .checking }) else { return }
        backgroundAssertion = backgroundAssertions.begin { [weak self] in
            // iOS calls this when the time is up and will kill the app if the task is still held.
            self?.releaseBackgroundAssertion()
        }
    }

    private func releaseBackgroundAssertion() {
        guard backgroundAssertion != .invalid else { return }
        backgroundAssertions.end(backgroundAssertion)
        backgroundAssertion = .invalid
    }

    func enterForeground() {
        releaseBackgroundAssertion()
        isInBackground = false
        sessions.forEach { $0.enterForeground() }
    }
}
