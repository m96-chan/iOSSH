import SwiftData
import SwiftUI

struct TailscaleImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var inbox = TailscaleImportInbox.shared
    @State private var username = ""
    @State private var selectedIDs: Set<String> = []
    @State private var search = ""
    @State private var result: TailscaleHostImportResult?
    @State private var saveError: String?
    @State private var showingSetup = false

    private var devices: [TailscaleDeviceCandidate] { inbox.request?.devices ?? [] }
    private var visibleDevices: [TailscaleDeviceCandidate] {
        guard !search.isEmpty else { return devices }
        return devices.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.hostname.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("Fetch Devices", systemImage: "arrow.down.circle") { fetch() }
                        .accessibilityIdentifier("fetchTailscaleDevices")
                    Button("Set Up Shortcut", systemImage: "shortcuts") { showingSetup = true }
                        .accessibilityIdentifier("setupTailscaleShortcut")
                } footer: {
                    Text("Tailscale’s Find Devices shortcut sends its device list here. Keep the Tailscale app connected.")
                }

                if let message = inbox.message {
                    Section { Text(message).foregroundStyle(.secondary) }
                }

                if inbox.request != nil {
                    if devices.isEmpty {
                        Section {
                            ContentUnavailableView("No devices received", systemImage: "network",
                                                   description: Text("Check your Tailscale account and the shortcut’s Find Devices filters, then fetch again."))
                        }
                    } else {
                        Section {
                            TextField("SSH username", text: $username)
                                .autocorrectionDisabled().textInputAutocapitalization(.never)
                                .textContentType(.username).accessibilityIdentifier("tailscaleImportUsername")
                        } footer: {
                            Text("Use the account name on your servers. Selected devices are saved with Tailscale SSH on port 22. You can import another group with a different username.")
                        }

                        Section {
                            TextField("Search devices", text: $search)
                                .autocorrectionDisabled().textInputAutocapitalization(.never)
                            HStack {
                                Text("\(selectedIDs.count) selected").foregroundStyle(.secondary)
                                Spacer()
                                Button("Select All") { selectedIDs.formUnion(visibleDevices.map(\.id)) }
                                    .disabled(visibleDevices.isEmpty)
                                Button("Clear") { selectedIDs.removeAll() }.disabled(selectedIDs.isEmpty)
                            }
                            .font(.subheadline)
                            ForEach(visibleDevices) { device in
                                Button {
                                    if !selectedIDs.insert(device.id).inserted { selectedIDs.remove(device.id) }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: selectedIDs.contains(device.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selectedIDs.contains(device.id) ? Color.accentColor : .secondary)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(device.name).foregroundStyle(.primary)
                                            Text(device.hostname).font(.caption.monospaced()).foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("tailscaleDevice-\(device.id)")
                                .accessibilityValue(selectedIDs.contains(device.id) ? "Selected" : "Not selected")
                            }
                        } header: { Text("Devices") } footer: {
                            Text("Choose servers with Tailscale SSH enabled. Being listed does not confirm SSH access. Existing hosts with the same destination, port, and username are skipped.")
                        }
                    }
                }
                if let saveError {
                    Section { Text(saveError).foregroundStyle(.red).accessibilityIdentifier("tailscaleImportError") }
                }
            }
            .navigationTitle("Import from Tailscale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { inbox.clear(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(selectedIDs.count)") { save() }
                        .disabled(selectedIDs.isEmpty || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("saveTailscaleHosts")
                }
            }
            .onChange(of: inbox.request?.id, initial: true) { _, _ in
                inbox.markPresented()
                selectedIDs.removeAll()
                search = ""
                saveError = nil
                result = nil
            }
            .sheet(isPresented: $showingSetup) { TailscaleShortcutSetupView() }
            .alert("Hosts Imported", isPresented: Binding(get: { result != nil }, set: { if !$0 { result = nil } })) {
                Button("Done") { inbox.clear(); dismiss() }
            } message: {
                if let result { Text("Added \(result.added). Skipped \(result.skipped) already registered.") }
            }
        }
    }

    private func fetch() {
        saveError = nil
        openURL(inbox.shortcutURL()) { accepted in
            if !accepted { inbox.message = "Couldn’t open Shortcuts. Set up Import Tailscale Hosts in the Shortcuts app, then try again." }
        }
    }

    private func save() {
        do {
            result = try TailscaleHostImport.register(devices.filter { selectedIDs.contains($0.id) }, username: username, in: context)
            saveError = nil
        } catch { saveError = error.localizedDescription }
    }
}

private struct TailscaleShortcutSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                if let file = Bundle.main.url(forResource: TailscaleImportInbox.shortcutName, withExtension: "shortcut") {
                    Section {
                        ShareLink(item: file, preview: SharePreview(TailscaleImportInbox.shortcutName, image: Image(systemName: "shortcuts"))) {
                            Label("Save Shortcut File", systemImage: "square.and.arrow.up")
                        }
                        .accessibilityIdentifier("shareTailscaleShortcut")
                        Text("Choose Save to Files, open the saved .shortcut file, then tap Add Shortcut. Keep the name Import Tailscale Hosts.")
                    } footer: {
                        Text("Install Tailscale and connect to your tailnet first. After adding the shortcut, return here and tap Fetch Devices. Allow access when Shortcuts asks.")
                    }
                }
                Section {
                    DisclosureGroup("Create Manually") {
                        Text("Create a shortcut named Import Tailscale Hosts with these actions:")
                        Label("Tailscale → Find Devices", systemImage: "1.circle")
                        Label("iOSSH → Review Tailscale Hosts", systemImage: "2.circle")
                        Text("For Hostnames, choose the MagicDNS Address property of the Devices result. You can use IPv4 Address or IPv6 Address instead.")
                        Text("Leave Find Devices unfiltered to list all devices. iOSSH lets you choose which ones to save.")
                    }
                }
                Section {
                    Button("Open Shortcuts", systemImage: "arrow.up.forward.app") { openURL(URL(string: "shortcuts://")!) }
                    Link("Tailscale shortcut documentation", destination: URL(string: "https://tailscale.com/docs/features/mac-ios-shortcuts")!)
                }
            }
            .navigationTitle("Set Up Shortcut")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
