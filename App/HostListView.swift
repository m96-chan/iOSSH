import SSHCore
import SwiftData
import SwiftUI

struct HostListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \HostRecord.createdAt) private var hosts: [HostRecord]
    @State private var editingHost: HostRecord?
    @State private var showingNewHost = false
    @State private var showingSettings = false
    @State private var connection: SSHHost?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if hosts.isEmpty {
                    ContentUnavailableView {
                        Label("Your terminal, anywhere", systemImage: "terminal")
                    } description: {
                        Text("Add a host to open a secure shell on your server.")
                    } actions: {
                        Button("Add Host", systemImage: "plus") { showingNewHost = true }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("addFirstHost")
                    }
                } else {
                    List {
                        Section {
                            ForEach(hosts) { host in
                                Button { connection = host.sshHost } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: "terminal.fill")
                                            .font(.title2)
                                            .foregroundStyle(.mint)
                                            .frame(width: 40, height: 44)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(host.name).font(.headline).foregroundStyle(.primary)
                                            Text("\(host.username)@\(host.hostname)\(host.port == 22 ? "" : ":\(host.port)")")
                                                .font(.subheadline.monospaced())
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption.bold()).foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, 7)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("host-\(host.name)")
                                .swipeActions(edge: .leading) {
                                    Button("Edit", systemImage: "pencil") { editingHost = host }.tint(.blue)
                                }
                                .contextMenu {
                                    Button("Connect", systemImage: "terminal") { connection = host.sshHost }
                                    Button("Edit", systemImage: "pencil") { editingHost = host }
                                }
                            }
                            .onDelete(perform: delete)
                        } footer: {
                            Text("Credentials stay in Keychain on this device.")
                        }
                    }
                }
            }
            .navigationTitle("iOSSH")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add Host", systemImage: "plus") { showingNewHost = true }
                        .accessibilityIdentifier("addHost")
                }
            }
            .sheet(isPresented: $showingNewHost) { HostEditorView() }
            .sheet(item: $editingHost) { HostEditorView(host: $0) }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .fullScreenCover(item: $connection) { TerminalScreen(host: $0) }
            .alert("Couldn’t remove host", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
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
