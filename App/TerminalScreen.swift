import SSHCore
import SwiftUI
import TerminalCore
import TerminalRender

struct TerminalScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("terminal.fontSize") private var fontSize: Double = 14
    @AppStorage("terminal.theme") private var themeName = "dark"
    @State private var model: ConnectionModel
    @State private var showingSettings = false

    init(host: SSHHost) { _model = State(initialValue: ConnectionModel(host: host)) }
    private var theme: TerminalTheme { themeName == "light" ? .light : .dark }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.phase != .connected {
                    HStack(spacing: 10) {
                        if model.phase == .connecting { ProgressView().controlSize(.small) }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.phase == .connecting ? "Connecting…" : "Disconnected")
                                .font(.subheadline.weight(.medium))
                            if let message = model.message { Text(message).font(.caption).textSelection(.enabled) }
                        }
                        Spacer(minLength: 8)
                        if model.phase != .connecting {
                            Button("Reconnect") { Task { await model.connect() } }
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .padding(12)
                    .background(.bar)
                }
                TerminalView(snapshot: model.snapshot,
                             configuration: TerminalConfiguration(fontSize: fontSize, theme: theme),
                             onInput: { model.send($0) },
                             onResize: { model.resize(columns: $0, rows: $1) },
                             onKey: { model.engine.sendKey($0) },
                             onPaste: { model.engine.paste($0) },
                             onScroll: { model.engine.scroll(by: $0) },
                             onCellSize: { model.engine.setCellSize(width: $0, height: $1) },
                             onCopySelection: { model.engine.text(in: $0) })
                    .accessibilityIdentifier("terminal")
            }
            .navigationTitle(model.host.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close", systemImage: "xmark") {
                        Task { await model.close(); dismiss() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Appearance", systemImage: "textformat.size") { showingSettings = true }
                        Button("Scroll to Bottom", systemImage: "arrow.down.to.line") { model.engine.scrollToBottom() }
                        if model.phase == .connected {
                            Button("Disconnect", systemImage: "network.slash") { Task { await model.close() } }
                        } else if model.phase != .connecting {
                            Button("Enter Credentials", systemImage: "key") { Task { await model.connect(enterCredential: true) } }
                        }
                    } label: { Label("Terminal options", systemImage: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(isPresented: $model.credentialPrompt, onDismiss: { model.credentialSheetDidDismiss() }) {
                CredentialPromptView(host: model.host) { model.submitCredential($0) }
            }
            .alert("Trust this server?", isPresented: Binding(get: { model.trustPrompt != nil }, set: { _ in })) {
                Button("Cancel", role: .cancel) { model.answerTrust(false) }
                Button("Trust and Connect") { model.answerTrust(true) }
            } message: {
                if let challenge = model.trustPrompt?.challenge {
                    Text("First connection to \(challenge.hostname):\(challenge.port).\n\n\(challenge.algorithm)\n\(challenge.fingerprint)\n\nCompare this fingerprint with your server administrator before trusting it.")
                }
            }
            .task {
                model.apply(theme: theme)
                await model.connect()
            }
            .onChange(of: themeName) { _, _ in model.apply(theme: theme) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    Task { await model.close(message: "The app entered the background. Reconnect to open a new shell.") }
                }
            }
            .onDisappear { Task { await model.close() } }
        }
    }
}

private struct CredentialPromptView: View {
    let host: SSHHost
    let answer: (ConnectionModel.CredentialAnswer?) -> Void
    @State private var password = ""
    @State private var key = ""
    @State private var passphrase = ""
    @State private var save = false

    var body: some View {
        NavigationStack {
            Form {
                Section { Text("\(host.username)@\(host.hostname)").font(.subheadline.monospaced()) }
                Section("Credential") {
                    if host.authentication == .privateKey {
                        TextEditor(text: $key)
                            .font(.system(.caption, design: .monospaced)).frame(minHeight: 160)
                            .accessibilityLabel("Private key").privacySensitive()
                        SecureField("Key passphrase (if required)", text: $passphrase)
                    } else {
                        SecureField("Password", text: $password).textContentType(.password)
                    }
                }
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                Section {
                    Toggle("Save in Keychain", isOn: $save)
                } footer: { Text("Saved credentials require Face ID or Touch ID and remain on this device.") }
            }
            .navigationTitle("Connect to \(host.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { answer(nil) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        let credential = SSHCredential(password: host.authentication == .password ? password : nil,
                                                       privateKey: host.authentication == .privateKey ? key : nil,
                                                       passphrase: passphrase.isEmpty ? nil : passphrase)
                        answer(.init(credential: credential, save: save))
                    }
                    .disabled(host.authentication == .privateKey ? key.isEmpty : password.isEmpty)
                }
            }
        }
    }
}
