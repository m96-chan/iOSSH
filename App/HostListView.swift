import SSHCore
import SwiftData
import SwiftUI
import TerminalRender

struct HostListView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \HostRecord.createdAt) private var hosts: [HostRecord]
    @State private var workspace: WorkspaceSessionStore
    @State private var sheet: HostSheet?
    @State private var hasPresentedSheet = false
    @State private var errorMessage: String?
    @State private var showingLimit = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var compactColumn: NavigationSplitViewColumn = .detail
    @State private var terminalFocusRequest = UUID()
    @State private var tailscaleInbox = TailscaleImportInbox.shared

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    init(workspace: WorkspaceSessionStore? = nil) {
        _workspace = State(initialValue: workspace ?? WorkspaceSessionStore(maximumSessions: UIDevice.current.userInterfaceIdiom == .pad ? 4 : 1))
    }

    var body: some View {
        Group {
            if isPad {
                GeometryReader { geometry in
                    let compact = geometry.size.width < 700
                    NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
                        catalog.navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
                    } detail: {
                        workspaceDetail(compact: compact)
                    }
                    .navigationSplitViewStyle(.balanced)
                    .onChange(of: compact, initial: true) { _, narrow in
                        columnVisibility = narrow ? .detailOnly : .all
                        compactColumn = .detail
                    }
                }
            } else {
                NavigationStack { catalog }
                    .fullScreenCover(isPresented: Binding(
                        get: { workspace.selectedSession != nil },
                        set: { if !$0, let id = workspace.selectedID { workspace.close(id: id) } }
                    )) {
                        NavigationStack {
                            if let model = workspace.selectedSession { terminal(model) }
                        }
                        .interactiveDismissDisabled()
                    }
            }
        }
        .sheet(item: $sheet, onDismiss: {
            hasPresentedSheet = sheet != nil
            terminalFocusRequest = UUID()
            presentTailscaleImportIfNeeded()
        }) { item in
            Group {
                switch item {
                case .newHost: HostEditorView()
                case .editHost(let host): HostEditorView(host: host)
                case .settings: SettingsView()
                case .hosts(let newSession): hostPicker(newSession: newSession)
                case .tailscaleImport: TailscaleImportView()
                }
            }
            .onAppear { hasPresentedSheet = true }
        }
        .alert("Couldn’t remove host", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .alert("Four sessions are already open", isPresented: $showingLimit) {
            Button("OK", role: .cancel) {}
        } message: { Text("Select an existing session or close a tab before opening another.") }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { workspace.enterBackground() }
            else if phase == .active { workspace.enterForeground() }
        }
        .onChange(of: tailscaleInbox.request?.id, initial: true) { _, _ in presentTailscaleImportIfNeeded() }
        .onChange(of: workspace.selectedID) { _, _ in presentTailscaleImportIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            workspace.imageBudget.removeAll()
        }
    }

    private var catalog: some View {
        Group {
            if hosts.isEmpty {
                ContentUnavailableView {
                    Label("Your terminal, anywhere", systemImage: "terminal")
                } description: {
                    Text("Add a host to open a secure shell on your server.")
                } actions: {
                    Button("Add Host", systemImage: "plus") { sheet = .newHost }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("addFirstHost")
                }
            } else {
                List {
                    Section {
                        ForEach(hosts) { host in
                            Button { open(host.sshHost) } label: { hostLabel(host) }
                                .buttonStyle(.plain).accessibilityIdentifier("host-\(host.name)")
                                .swipeActions(edge: .leading) {
                                    Button("Edit", systemImage: "pencil") { sheet = .editHost(host) }.tint(.blue)
                                }
                                .contextMenu {
                                    Button("Connect", systemImage: "terminal") { open(host.sshHost) }
                                    if isPad {
                                        Button("New Session", systemImage: "plus.square") { open(host.sshHost, newSession: true) }
                                    }
                                    Button("Edit", systemImage: "pencil") { sheet = .editHost(host) }
                                }
                        }
                        .onDelete(perform: delete)
                    } footer: { Text("Credentials stay in Keychain on this device.") }
                }
            }
        }
        .navigationTitle("iOSSH")
        .navigationBarTitleDisplayMode(isPad ? .inline : .automatic)
        .toolbar(removing: .sidebarToggle)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isPad {
                Button { sheet = .settings } label: {
                    Label("Settings", systemImage: "gearshape")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("workspaceSettings")
                .keyboardShortcut(",", modifiers: .command)
                .padding(.horizontal, 20).padding(.vertical, 6)
                .background(.bar)
            }
        }
        .toolbar {
            if !isPad {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { sheet = .settings }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add Host", systemImage: "plus") { sheet = .newHost }.accessibilityIdentifier("addHost")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Import from Tailscale", systemImage: "arrow.down.circle") { sheet = .tailscaleImport }
                    .accessibilityIdentifier("importTailscaleHosts")
            }
        }
    }

    private func hostLabel(_ host: HostRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal.fill").font(.title2).foregroundStyle(.mint).frame(width: 32, height: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text(host.name).font(.headline).foregroundStyle(.primary)
                Text("\(host.username)@\(host.hostname)\(host.port == 22 ? "" : ":\(host.port)")")
                    .font(.subheadline.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if !isPad { Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary) }
        }
        .padding(.vertical, 7).contentShape(Rectangle())
    }

    private func workspaceDetail(compact: Bool) -> some View {
        VStack(spacing: 0) {
            workspaceHeader(compact: compact)
            if let model = workspace.selectedSession {
                terminal(model)
            } else {
                ContentUnavailableView {
                    Label("Open a terminal", systemImage: "terminal")
                } description: {
                    Text(hosts.isEmpty ? "Add your first host to get started." : "Choose a host to start a session. Open up to four connections in tabs.")
                } actions: {
                    Button(hosts.isEmpty ? "Add Host" : "Choose Host", systemImage: "plus") {
                        sheet = hosts.isEmpty ? .newHost : .hosts(newSession: true)
                    }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("openWorkspaceHost")
                    .keyboardShortcut("t", modifiers: .command)
                }
            }
        }
        // The tab row is the detail's header, so a navigation title/bar must not
        // reserve another row above it when the software keyboard is visible.
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(removing: .sidebarToggle)
    }

    private func workspaceHeader(compact: Bool) -> some View {
        HStack(spacing: 0) {
            if compact {
                Button { sheet = .hosts(newSession: false) } label: {
                    Image(systemName: "server.rack").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Hosts").accessibilityIdentifier("workspaceHosts")
                Spacer(minLength: 0)
                sessionPicker.frame(minHeight: 44).padding(.horizontal, 8)
            } else {
                Button {
                    withAnimation { columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly }
                } label: {
                    Image(systemName: "sidebar.left").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel(columnVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar")
                .accessibilityIdentifier("workspaceSidebarToggle")
                SessionTabBar(workspace: workspace, onNew: newSession)
            }
            if let model = workspace.selectedSession { sessionOptions(model) }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .frame(minHeight: 56)
        .background(.bar)
    }

    private func sessionOptions(_ model: ConnectionModel) -> some View {
        Menu {
            Button("Scroll to Bottom", systemImage: "arrow.down.to.line") { model.engine.scrollToBottom() }
            if model.phase == .connected || model.phase == .checking {
                Button("Disconnect", systemImage: "network.slash") { Task { await model.close() } }
            } else if model.phase != .connecting, model.host.authentication != .tailscale {
                Button("Enter Credentials", systemImage: "key") { Task { await model.connect(enterCredential: true) } }
            }
            Button("Close Session", systemImage: "xmark") { workspace.close(id: model.id) }
        } label: {
            Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
        }
        .accessibilityLabel("Terminal options").accessibilityIdentifier("terminalOptions")
    }

    private func terminal(_ model: ConnectionModel) -> some View {
        TerminalScreen(model: model, isWorkspace: isPad, allowsAuthentication: sheet == nil && !hasPresentedSheet,
                       focusRequest: terminalFocusRequest, onClose: { workspace.close(id: model.id) },
                       onWorkspaceCommand: isPad ? handleCommand : nil)
    }

    private var sessionPicker: some View {
        Menu {
            ForEach(workspace.sessions) { model in
                Section(workspace.tabTitle(for: model)) {
                    Button { workspace.select(id: model.id) } label: {
                        Label(model.sessionStatus, systemImage: model.id == workspace.selectedID ? "checkmark" : "terminal")
                    }
                    Button("Close \(workspace.tabTitle(for: model))", systemImage: "xmark") { workspace.close(id: model.id) }
                }
            }
            Divider()
            Button("New Session", systemImage: "plus") { newSession() }
        } label: {
            Label(workspace.selectedSession.map { workspace.tabTitle(for: $0) } ?? "Sessions (0)",
                  systemImage: "rectangle.on.rectangle")
                .lineLimit(1).truncationMode(.middle)
        }
        .accessibilityLabel("Sessions (\(workspace.sessions.count))")
        .accessibilityValue(workspace.selectedSession.map { "\(workspace.tabTitle(for: $0)), \($0.sessionStatus)" } ?? "No session selected")
        .accessibilityIdentifier("sessionPicker")
    }

    private func hostPicker(newSession: Bool) -> some View {
        NavigationStack {
            List {
                if hosts.isEmpty { Text("Add a host to open your first session.") }
                ForEach(hosts) { host in
                    Button {
                        sheet = nil
                        open(host.sshHost, newSession: newSession)
                    } label: { hostLabel(host) }
                    .accessibilityIdentifier("pickHost-\(host.name)")
                    .contextMenu {
                        Button("Edit Host", systemImage: "pencil") { sheet = .editHost(host) }
                    }
                }
                Section {
                    Button("Import from Tailscale", systemImage: "arrow.down.circle") { sheet = .tailscaleImport }
                    Button("Settings", systemImage: "gearshape") { sheet = .settings }
                        .accessibilityIdentifier("hostPickerSettings")
                }
            }
            .navigationTitle(newSession ? "New Session" : "Hosts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { sheet = nil } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Host", systemImage: "plus") { sheet = .newHost }
                }
            }
        }
    }

    private func open(_ host: SSHHost, newSession: Bool = false) {
        if !workspace.open(host: host, newSession: newSession) { showingLimit = true }
        compactColumn = .detail
    }

    private func presentTailscaleImportIfNeeded() {
        // A visible terminal owns its sheets, including pending authentication.
        guard tailscaleInbox.needsPresentation, sheet == nil, !hasPresentedSheet, workspace.selectedSession == nil else { return }
        tailscaleInbox.markPresented()
        sheet = .tailscaleImport
    }

    private func newSession() {
        if workspace.canOpenSession { sheet = .hosts(newSession: true) }
        else { showingLimit = true }
    }

    private func handleCommand(_ command: TerminalWorkspaceCommand) {
        guard sheet == nil else { return }
        switch command {
        case .newSession: newSession()
        case .closeSession:
            if let id = workspace.selectedID { workspace.close(id: id) }
        case .previousSession: selectAdjacent(-1)
        case .nextSession: selectAdjacent(1)
        case .selectSession(let index):
            if workspace.sessions.indices.contains(index) { workspace.select(id: workspace.sessions[index].id) }
        case .settings: sheet = .settings
        }
    }

    private func selectAdjacent(_ offset: Int) {
        guard let index = workspace.sessions.firstIndex(where: { $0.id == workspace.selectedID }) else { return }
        let next = (index + offset + workspace.sessions.count) % workspace.sessions.count
        workspace.select(id: workspace.sessions[next].id)
    }

    private func delete(at offsets: IndexSet) {
        let records = offsets.map { hosts[$0] }
        Task {
            do {
                for host in records {
                    try await CredentialStore().delete(for: host.id)
                    context.delete(host)
                }
                try context.save()
            } catch {
                context.rollback()
                errorMessage = error.localizedDescription
            }
        }
    }
}

private enum HostSheet: Identifiable {
    case newHost, editHost(HostRecord), settings, hosts(newSession: Bool), tailscaleImport
    var id: String {
        switch self {
        case .newHost: "newHost"
        case .editHost(let host): "edit-\(host.id)"
        case .settings: "settings"
        case .hosts(let new): "hosts-\(new)"
        case .tailscaleImport: "tailscaleImport"
        }
    }
}

extension ConnectionModel {
    var sessionStatus: String {
        if needsAuthenticationAttention { return "Needs attention" }
        switch phase {
        case .idle, .connecting: return "Connecting"
        case .connected: return "Connected"
        case .checking: return "Checking"
        case .disconnected, .failed: return "Disconnected"
        }
    }

    var sessionSymbol: String {
        if needsAuthenticationAttention { return "exclamationmark.circle" }
        switch phase {
        case .idle, .connecting, .checking: return "clock"
        case .connected: return "terminal"
        case .disconnected, .failed: return "network.slash"
        }
    }
}

extension WorkspaceSessionStore {
    func tabTitle(for model: ConnectionModel) -> String {
        let sameHost = sessions.filter { $0.host.id == model.host.id }
        guard sameHost.count > 1, let index = sameHost.firstIndex(where: { $0.id == model.id }) else { return model.host.name }
        return "\(model.host.name) (\(index + 1))"
    }
}

private struct SessionTabBar: View {
    let workspace: WorkspaceSessionStore
    let onNew: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(workspace.sessions) { model in
                            HStack(spacing: 0) {
                                Button { workspace.select(id: model.id) } label: {
                                    Label(workspace.tabTitle(for: model), systemImage: model.sessionSymbol)
                                        .font(.subheadline).lineLimit(1)
                                        .frame(maxWidth: 240)
                                        .padding(.leading, 12).padding(.trailing, 4).frame(minHeight: 44)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityLabel("\(workspace.tabTitle(for: model)), \(model.sessionStatus)")
                                .accessibilityValue(model.id == workspace.selectedID ? "Selected" : "")
                                .accessibilityIdentifier("sessionTab-\(workspace.tabTitle(for: model))")
                                Button { workspace.close(id: model.id) } label: {
                                    Image(systemName: "xmark").font(.caption.weight(.semibold))
                                        .frame(width: 44, height: 44).contentShape(Rectangle())
                                }
                                .accessibilityLabel("Close \(workspace.tabTitle(for: model))")
                            }
                            .buttonStyle(.plain)
                            .background(model.id == workspace.selectedID ? Color.accentColor.opacity(0.15) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 9))
                            .overlay(alignment: .bottom) {
                                if model.id == workspace.selectedID { Capsule().fill(.tint).frame(height: 2).padding(.horizontal, 10) }
                            }
                            .contextMenu {
                                Button("Close Session", systemImage: "xmark") { workspace.close(id: model.id) }
                            }
                            .id(model.id)
                        }
                    }
                    .padding(6)
                }
                .scrollIndicators(.hidden)
                .onChange(of: workspace.selectedID, initial: true) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            Button(action: onNew) { Image(systemName: "plus").frame(width: 44, height: 44).contentShape(Rectangle()) }
                .accessibilityLabel("New Session").accessibilityIdentifier("newSession").padding(.trailing, 6)
        }
    }
}
