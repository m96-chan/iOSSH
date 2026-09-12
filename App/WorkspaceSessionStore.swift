import Foundation
import Observation
import SSHCore
import TerminalCore

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
    }

    func enterForeground() {
        isInBackground = false
        sessions.forEach { $0.enterForeground() }
    }
}
