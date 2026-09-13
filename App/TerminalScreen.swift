import SSHCore
import SafariServices
import SwiftUI
import TerminalCore
import TerminalRender

/// The workspace owns the connection; this view only presents the selected session.
struct TerminalScreen: View {
    @AppStorage("terminal.fontSize") private var fontSize = Double(TerminalConfiguration.defaultFontSize)
    @AppStorage(TerminalFontLibrary.selectionKey) private var selectedFontName = TerminalFont.postScriptName
    @AppStorage("terminal.theme") private var themeName = "dark"
    let model: ConnectionModel
    var isWorkspace = false
    var allowsAuthentication = true
    var focusRequest: UUID?
    let onClose: () -> Void
    var onWorkspaceCommand: (@MainActor (TerminalWorkspaceCommand) -> Void)?
    @State private var activeSheet: TerminalSheet?
    @State private var lastSheet: TerminalSheet?
    @State private var localFocusRequest = UUID()
    @State private var tailscaleInbox = TailscaleImportInbox.shared

    private var theme: TerminalTheme { themeName == "light" ? .light : .dark }

    var body: some View {
        VStack(spacing: 0) {
            // The single-session screen floats these over the grid instead. Leaving
            // them in the layout makes the terminal grow by one row the moment a
            // connection succeeds and the row disappears.
            if isWorkspace { connectionHeaders }
            surface
        }
        // The single-session screen gives the whole display to the grid: its controls
        // float over the terminal instead of reserving a navigation bar row, and the
        // terminal colour runs under the status bar.
        .background { if !isWorkspace { color(theme.background).ignoresSafeArea() } }
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(isWorkspace ? nil : themeName == "light" ? .light : .dark)
        .sheet(item: $activeSheet, onDismiss: sheetDidDismiss) { item in
            switch item.content {
            case .settings: SettingsView()
            case .tailscaleImport: TailscaleImportView()
            case .credential(let connection, let requestID, let attemptID):
                CredentialPromptView(host: connection.host, later: isWorkspace ? {
                    connection.deferAuthentication(attemptID: attemptID)
                    activeSheet = nil
                } : nil) { answer in
                    connection.submitCredential(answer, requestID: requestID, attemptID: attemptID)
                    activeSheet = nil
                }
                .interactiveDismissDisabled()
            case .trust(let connection, let prompt):
                TrustPromptView(host: connection.host, challenge: prompt.challenge, later: isWorkspace ? {
                    connection.deferAuthentication(attemptID: prompt.attemptID)
                    activeSheet = nil
                } : nil) { trusted in
                    connection.answerTrust(trusted, requestID: prompt.id, attemptID: prompt.attemptID)
                    activeSheet = nil
                }
                .interactiveDismissDisabled()
            case .browser(_, _, let url): AuthenticationBrowser(url: url)
            }
        }
        .onAppear { model.apply(theme: theme); model.connectOnFirstAppearance(); presentAuthentication(); presentTailscaleImportIfNeeded() }
        .onChange(of: tailscaleInbox.request?.id) { _, _ in presentTailscaleImportIfNeeded() }
        .onChange(of: model.id) { _, _ in
            if let previous = activeSheet, previous.isAuthentication { previous.deferAuthentication(); activeSheet = nil }
            model.apply(theme: theme)
            localFocusRequest = UUID()
            presentAuthentication()
            presentTailscaleImportIfNeeded()
        }
        .onChange(of: themeName) { _, _ in model.apply(theme: theme) }
        .onChange(of: model.credentialPrompt) { _, _ in presentAuthentication() }
        .onChange(of: model.credentialRequestID) { _, _ in presentAuthentication() }
        .onChange(of: model.trustPrompt?.id) { _, _ in presentAuthentication() }
        .onChange(of: model.isAuthenticationDeferred) { _, _ in presentAuthentication() }
        .onChange(of: allowsAuthentication) { _, allowed in
            if allowed { localFocusRequest = UUID(); presentAuthentication(); presentTailscaleImportIfNeeded() }
        }
        .onChange(of: focusRequest) { _, _ in localFocusRequest = UUID() }
        .onChange(of: model.phase) { _, phase in
            if phase != .connecting, activeSheet?.isAuthentication == true { activeSheet = nil }
            presentTailscaleImportIfNeeded()
        }
    }

    @ViewBuilder private var surface: some View {
        let inputAttempt = model.connectionAttemptID
        let terminal = TerminalView(snapshot: model.snapshot,
                         configuration: TerminalConfiguration(fontSize: fontSize,
                            fontName: TerminalFontLibrary.shared.resolvedFontName(selectedFontName), theme: theme),
                         onInput: { model.sendUserInput($0, attemptID: inputAttempt) },
                         onResize: { model.resize(columns: $0, rows: $1) },
                         onKey: { model.sendUserKey($0, attemptID: inputAttempt) },
                         onPaste: { model.pasteUserInput($0, attemptID: inputAttempt) },
                         onScroll: { model.engine.scroll(by: $0) },
                         onCellSize: { model.engine.setCellSize(width: $0, height: $1) },
                         onCopySelection: { model.engine.text(in: $0) },
                         inputIdentity: TerminalInputIdentity(sessionID: model.id, attemptID: model.connectionAttemptID),
                         focusRequest: allowsAuthentication && activeSheet == nil ? localFocusRequest : nil,
                         onWorkspaceCommand: terminalWorkspaceCommand)
                .accessibilityIdentifier("terminal")

        if isWorkspace {
            terminal
                // Keep the rectangular character grid inside the rounded surface.
                .padding(6)
                .background(color(theme.background))
                // The surface ends level with the sidebar's Settings row, at the bottom of
                // the safe area, rather than leaving a strip of window background above it
                // or running under the home indicator.
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 6)
                .padding(.top, 6)
        } else {
            terminal.overlay(alignment: .top) {
                VStack(spacing: 8) {
                    floatingControls
                    VStack(spacing: 0) { connectionHeaders }
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
                        .padding(.horizontal, 10)
                }
            }
        }
    }

    @ViewBuilder private var connectionHeaders: some View {
        status
        if model.phase == .connecting, model.isAuthenticationDeferred, model.needsAuthenticationAttention {
            HStack {
                Label("This session needs your attention", systemImage: "exclamationmark.circle")
                    .font(.subheadline)
                Spacer()
                Button("Continue") { model.resumeAuthentication(); presentAuthentication() }
                    .accessibilityIdentifier("resumeAuthentication")
            }
            .padding(12).background(.bar)
        } else if model.phase == .connecting, !model.authenticationBanner.isEmpty {
            authenticationBanner
        }
    }

    /// Floating chrome for the single-session screen: the session badge and the
    /// controls sit over the grid instead of reserving a navigation bar row.
    private var floatingControls: some View {
        HStack(spacing: 0) {
            sessionBadge
            // Output starts at the left of every row, so the controls sit
            // together in the trailing corner.
            Spacer(minLength: 8)
            Button(action: onClose) { floatingControlChrome("xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("closeSession")
            Menu {
                Button("Appearance", systemImage: "textformat.size") { present(.settings) }
                Button("Import from Tailscale", systemImage: "arrow.down.circle") { present(.tailscaleImport) }
                Button("Scroll to Bottom", systemImage: "arrow.down.to.line") { model.engine.scrollToBottom() }
                if model.phase == .connected || model.phase == .checking {
                    Button("Disconnect", systemImage: "network.slash") { Task { await model.close() } }
                } else if model.phase != .connecting, model.host.authentication != .tailscale {
                    Button("Enter Credentials", systemImage: "key") { Task { await model.connect(enterCredential: true) } }
                }
            } label: { floatingControlChrome("ellipsis") }
            .buttonStyle(.plain)
            .accessibilityLabel("Terminal options")
            .accessibilityIdentifier("terminalOptions")
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    /// A round control drawn inside a full 44-point target. `Menu` only hit-tests
    /// its label, so the frame and shape have to live in the label itself.
    private func floatingControlChrome(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(color(theme.foreground))
            .frame(width: 44, height: 44)
            .background {
                Circle().fill(color(theme.background, opacity: 0.86))
                    .overlay(Circle().fill(color(theme.foreground, opacity: 0.13)))
                    .overlay(Circle().strokeBorder(color(theme.foreground, opacity: 0.14)))
                    .shadow(color: .black.opacity(0.22), radius: 5, y: 1)
                    .padding(4)
            }
            .contentShape(Circle())
    }

    private var sessionBadge: some View {
        HStack(spacing: 7) {
            Circle().fill(badgeTint).frame(width: 7, height: 7)
            Text(model.phase == .checking ? "Checking connection…" : model.host.name)
                .font(.footnote.weight(.semibold)).lineLimit(1)
        }
        .foregroundStyle(color(theme.foreground))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background {
            Capsule().fill(color(theme.background, opacity: 0.86))
                .overlay(Capsule().fill(color(theme.foreground, opacity: 0.13)))
        }
        .overlay(Capsule().strokeBorder(color(theme.foreground, opacity: 0.14)))
        .accessibilityIdentifier("sessionBadge")
    }

    private var badgeTint: Color {
        switch model.phase {
        case .connected: .green
        case .connecting, .checking, .idle: .orange
        case .disconnected, .failed: .red
        }
    }

    private func color(_ value: UInt32, opacity: Double = 1) -> Color {
        Color(.sRGB,
              red: Double((value >> 16) & 255) / 255,
              green: Double((value >> 8) & 255) / 255,
              blue: Double(value & 255) / 255,
              opacity: opacity)
    }

    private var terminalWorkspaceCommand: (@MainActor (TerminalWorkspaceCommand) -> Void)? {
        guard let handler = onWorkspaceCommand else { return nil }
        return { command in
            guard activeSheet == nil, lastSheet == nil, allowsAuthentication else { return }
            handler(command)
        }
    }

    @ViewBuilder private var status: some View {
        if isWorkspace, model.phase == .checking {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking connection…").font(.subheadline.weight(.medium))
                Spacer()
            }
            .padding(12).background(.bar)
        } else if model.phase != .connected, model.phase != .checking {
            HStack(spacing: 10) {
                if model.phase == .connecting { ProgressView().controlSize(.small) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.phase == .connecting ? "Connecting…" : "Disconnected").font(.subheadline.weight(.medium))
                    if let message = model.message { Text(message).font(.caption).textSelection(.enabled) }
                }
                Spacer(minLength: 8)
                if model.phase != .connecting {
                    Button("Reconnect") { Task { await model.connect() } }.font(.subheadline.weight(.semibold))
                } else if model.isAuthenticationDeferred {
                    Button("Cancel") { Task { await model.close() } }
                }
            }
            .padding(12).background(.bar)
        }
    }

    private var authenticationBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                Text(model.authenticationBanner).font(.footnote).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 112)
            HStack {
                if let url = model.authenticationURL {
                    Button("Sign in at \(url.host ?? "Tailscale")", systemImage: "arrow.up.right.square") {
                        present(.browser(model, model.connectionAttemptID, url))
                    }
                    .accessibilityIdentifier("tailscaleSignIn")
                }
                Spacer()
                if isWorkspace {
                    Button("Later") { model.deferAuthentication(attemptID: model.connectionAttemptID) }
                }
                Button("Cancel") { Task { await model.close() } }
            }
        }
        .padding(12).background(.bar).accessibilityIdentifier("authenticationBanner")
    }

    private func present(_ content: TerminalSheet.Content) {
        guard activeSheet == nil, lastSheet == nil, allowsAuthentication else { return }
        let item = TerminalSheet(content: content)
        lastSheet = item
        activeSheet = item
    }

    private func presentAuthentication() {
        guard model.isVisible, !model.isAuthenticationDeferred, model.phase == .connecting else { return }
        if model.credentialPrompt, let requestID = model.credentialRequestID {
            present(.credential(model, requestID, model.connectionAttemptID))
        } else if let prompt = model.trustPrompt {
            present(.trust(model, prompt))
        }
    }

    private func presentTailscaleImportIfNeeded() {
        guard model.isVisible, tailscaleInbox.needsPresentation, activeSheet == nil, lastSheet == nil,
              allowsAuthentication, model.phase != .connecting, !model.needsAuthenticationAttention else { return }
        tailscaleInbox.markPresented()
        present(.tailscaleImport)
    }

    private func sheetDidDismiss() {
        if case .credential(let connection, let requestID, let attemptID) = lastSheet?.content {
            connection.credentialSheetDidDismiss(requestID: requestID, attemptID: attemptID)
        }
        lastSheet = nil
        localFocusRequest = UUID()
        presentAuthentication()
        presentTailscaleImportIfNeeded()
    }
}

private struct TerminalSheet: Identifiable {
    enum Content {
        case settings
        case tailscaleImport
        case credential(ConnectionModel, UUID, UUID)
        case trust(ConnectionModel, ConnectionModel.TrustPrompt)
        case browser(ConnectionModel, UUID, URL)
    }
    let id = UUID()
    let content: Content
    var isAuthentication: Bool {
        switch content {
        case .settings, .tailscaleImport: false
        default: true
        }
    }

    @MainActor func deferAuthentication() {
        switch content {
        case .credential(let connection, _, let attempt), .browser(let connection, let attempt, _):
            connection.deferAuthentication(attemptID: attempt)
        case .trust(let connection, let prompt): connection.deferAuthentication(attemptID: prompt.attemptID)
        case .settings, .tailscaleImport: break
        }
    }
}

private struct AuthenticationBrowser: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let browser = SFSafariViewController(url: url)
        browser.dismissButtonStyle = .done
        browser.delegate = context.coordinator
        return browser
    }
    func updateUIViewController(_ browser: SFSafariViewController, context: Context) {}
    @MainActor final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let dismiss: DismissAction
        init(dismiss: DismissAction) { self.dismiss = dismiss }
        nonisolated func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            Task { @MainActor in self.dismiss() }
        }
    }
}

private struct TrustPromptView: View {
    let host: SSHHost
    let challenge: HostKeyChallenge
    let later: (() -> Void)?
    let answer: (Bool) -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section("Connect to \(host.name)") {
                    Text("\(challenge.hostname):\(challenge.port)")
                    Text(challenge.algorithm)
                    Text(challenge.fingerprint).font(.callout.monospaced()).textSelection(.enabled)
                }
                Section {
                    Text("First connection to this server. Compare this fingerprint with your server administrator before trusting it.")
                    Button("Trust and Connect") { answer(true) }
                    if let later { Button("Later", action: later) }
                }
            }
            .navigationTitle("Trust this server?").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { answer(false) } }
            }
        }
    }
}

private struct CredentialPromptView: View {
    let host: SSHHost
    let later: (() -> Void)?
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
                        TextEditor(text: $key).font(.system(.caption, design: .monospaced)).frame(minHeight: 160)
                            .accessibilityLabel("Private key").privacySensitive()
                        SecureField("Key passphrase (if required)", text: $passphrase)
                    } else {
                        SecureField("Password", text: $password).textContentType(.password)
                    }
                }
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                Section { Toggle("Save in Keychain", isOn: $save) } footer: {
                    Text("Saved credentials require Face ID or Touch ID and remain on this device.")
                }
                if let later {
                    Section { Button("Later", action: later).accessibilityIdentifier("deferAuthentication") } footer: {
                        Text("Keep this request pending while you use another session.")
                    }
                }
            }
            .navigationTitle("Connect to \(host.name)").navigationBarTitleDisplayMode(.inline)
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
