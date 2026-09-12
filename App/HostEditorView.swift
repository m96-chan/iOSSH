import SSHCore
import SwiftData
import SwiftUI

struct HostEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    private let host: HostRecord?
    @State private var name: String
    @State private var hostname: String
    @State private var port: String
    @State private var username: String
    @State private var authentication: String
    @State private var terminalType: String
    @State private var password = ""
    @State private var privateKey = ""
    @State private var passphrase = ""
    @State private var saving = false
    @State private var errorMessage: String?

    init(host: HostRecord? = nil) {
        self.host = host
        _name = State(initialValue: host?.name ?? "")
        _hostname = State(initialValue: host?.hostname ?? "")
        _port = State(initialValue: String(host?.port ?? 22))
        _username = State(initialValue: host?.username ?? "")
        _authentication = State(initialValue: host?.authentication ?? "password")
        _terminalType = State(initialValue: host?.terminalType ?? "xterm-256color")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Host") {
                    TextField("Name", text: $name).accessibilityIdentifier("hostName")
                    TextField("Hostname or IP address", text: $hostname)
                        .keyboardType(.URL).accessibilityIdentifier("hostAddress")
                    TextField("Port", text: $port).keyboardType(.numberPad).accessibilityIdentifier("hostPort")
                    TextField("Username", text: $username)
                        .textContentType(.username).accessibilityIdentifier("hostUsername")
                }
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

                Section {
                    Picker("Authentication", selection: $authentication) {
                        Text("Password").tag("password")
                        Text("Private key").tag("privateKey")
                        Text("Tailscale SSH").tag("tailscale")
                    }
                    .accessibilityIdentifier("hostAuthentication")
                    if authentication == "password" {
                        SecureField("Password (optional)", text: $password)
                            .textContentType(.password)
                    } else if authentication == "privateKey" {
                        VStack(alignment: .leading) {
                            Text("Private key").font(.subheadline)
                            TextEditor(text: $privateKey)
                                .font(.system(.caption, design: .monospaced))
                                .frame(minHeight: 120)
                                .accessibilityLabel("Private key")
                                .privacySensitive()
                        }
                        SecureField("Key passphrase (if required)", text: $passphrase)
                    }
                } footer: {
                    if authentication == "tailscale" {
                        Text("Connect the Tailscale app first, then enter your server's device name or Tailscale IP and its username. Tailscale SSH uses your tailnet identity; no password or private key is needed.")
                        Text("Use port 22 with Tailscale SSH enabled on the server. Any additional sign-in approval will appear when connecting.")
                    } else {
                        Text(host == nil
                             ? "A supplied credential is saved in Keychain with biometric protection. Leave it empty to enter it when connecting."
                             : "Leave the credential empty to keep the saved one. New credentials replace it in Keychain.")
                        Text("Keyboard-interactive authentication is not supported yet.")
                    }
                    if authentication == "privateKey" {
                        Text("Use an Ed25519 key in OpenSSH format or an unencrypted ECDSA key in PEM format. RSA keys are not supported yet.")
                    }
                }
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

                Section {
                    TextField("TERM", text: $terminalType)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                } header: { Text("Terminal") } footer: {
                    Text("Use xterm-256color for broad compatibility. Kitty graphics work without advertising full xterm-kitty compatibility.")
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red).accessibilityIdentifier("hostSaveError") }
                }
            }
            .navigationTitle(host == nil ? "Add Host" : "Edit Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { Task { await save() } }
                        .disabled(!valid || saving).accessibilityIdentifier("saveHost")
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private var valid: Bool {
        !trim(name).isEmpty && !trim(hostname).isEmpty && !trim(username).isEmpty
            && (1...65535).contains(Int(port) ?? 0) && !trim(terminalType).isEmpty
            && !trim(hostname).contains(where: \.isWhitespace)
    }

    private func trim(_ string: String) -> String { string.trimmingCharacters(in: .whitespacesAndNewlines) }

    @MainActor private func save() async {
        saving = true
        defer { saving = false }
        let id = host?.id ?? UUID()
        do {
            let hasCredential = (authentication == "password" && !password.isEmpty)
                || (authentication == "privateKey" && !trim(privateKey).isEmpty)
            try SSHHost(name: trim(name), hostname: trim(hostname), port: Int(port) ?? 0,
                        username: trim(username), authentication: SSHAuthentication(rawValue: authentication) ?? .password,
                        terminalType: trim(terminalType)).validate()
            if hasCredential {
                let credential = SSHCredential(password: authentication == "password" ? password : nil,
                                               privateKey: authentication == "privateKey" ? privateKey : nil,
                                               passphrase: passphrase.isEmpty ? nil : passphrase)
                try await CredentialStore().save(credential, for: id)
            } else if let host, host.authentication != authentication {
                try await CredentialStore().delete(for: id)
            }
            let record = host ?? HostRecord(id: id, name: trim(name), hostname: trim(hostname), username: trim(username))
            record.name = trim(name)
            record.hostname = trim(hostname)
            record.port = Int(port) ?? 22
            record.username = trim(username)
            record.authentication = authentication
            record.terminalType = trim(terminalType)
            if host == nil { context.insert(record) }
            try context.save()
            password = ""
            privateKey = ""
            passphrase = ""
            dismiss()
        } catch {
            context.rollback()
            errorMessage = error.localizedDescription
        }
    }
}
