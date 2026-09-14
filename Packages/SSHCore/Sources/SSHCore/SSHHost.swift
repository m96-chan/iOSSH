import Foundation

public enum SSHAuthentication: String, Codable, CaseIterable, Sendable {
    case password, privateKey, keyboardInteractive
    /// Uses the identity of the already-connected Tailscale network; no SSH secret is sent.
    case tailscale
}

public struct SSHHost: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var hostname: String
    public var port: Int
    public var username: String
    public var authentication: SSHAuthentication
    public var terminalType: String
    /// Sent as `LANG` when set. Empty means send nothing, which leaves the shell wherever the
    /// host puts it. There is no value that is right everywhere: a shell left in the C locale
    /// makes macOS `ls` replace the bytes of a Japanese filename with question marks (#21),
    /// while a locale the host has not generated makes it complain on every command. Whoever
    /// knows the host decides.
    public var locale: String

    public init(id: UUID = UUID(), name: String, hostname: String, port: Int = 22,
                username: String, authentication: SSHAuthentication = .password,
                terminalType: String = "xterm-256color", locale: String = "") {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.authentication = authentication
        self.terminalType = terminalType
        self.locale = locale
    }

    public func validate() throws {
        guard !hostname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !hostname.contains(where: { $0.isWhitespace || $0 == "\0" }),
              (1...65535).contains(port), !username.isEmpty,
              !username.contains("\0"), !terminalType.isEmpty,
              terminalType.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            throw SSHSessionError.invalidConfiguration
        }
    }
}

/// Secrets are deliberately separate from host settings; persist only in CredentialStore.
public struct SSHCredential: Codable, Sendable, Equatable {
    public var password: String?
    public var privateKey: String?
    public var passphrase: String?

    public init(password: String? = nil, privateKey: String? = nil, passphrase: String? = nil) {
        self.password = password
        self.privateKey = privateKey
        self.passphrase = passphrase
    }
}

public enum SSHSessionError: Error, LocalizedError, Equatable, Sendable {
    case invalidConfiguration, missingCredential, unsupportedKeyboardInteractive
    case unsupportedPrivateKey, notConnected, alreadyConnecting, requestRejected
    case connectionTimedOut, outputOverflow, disconnected

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Enter a valid hostname, port (1–65535), username, and terminal type."
        case .missingCredential: "The authentication credential is missing."
        case .unsupportedKeyboardInteractive: "Keyboard-interactive authentication is not supported by the current SSH dependency."
        case .unsupportedPrivateKey: "Use an OpenSSH Ed25519 private key, or an unencrypted ECDSA PEM private key."
        case .notConnected: "The SSH terminal is not connected."
        case .alreadyConnecting: "An SSH connection is already open or connecting."
        case .requestRejected: "The server refused the terminal or shell request."
        case .connectionTimedOut: "The SSH server did not respond in time."
        case .outputOverflow: "Terminal output exceeded the receive buffer; the connection was closed to avoid losing bytes."
        case .disconnected: "The SSH connection closed."
        }
    }
}
