import Foundation
import Crypto
@preconcurrency import Citadel
@preconcurrency import NIOSSH
import NIOCore

enum Authentication {
    static func factory(host: SSHHost, credential: SSHCredential) throws -> @Sendable () -> SSHAuthenticationMethod {
        let username = host.username
        switch host.authentication {
        case .password:
            guard let password = credential.password else { throw SSHSessionError.missingCredential }
            return { .passwordBased(username: username, password: password) }
        case .keyboardInteractive:
            throw SSHSessionError.unsupportedKeyboardInteractive
        case .privateKey:
            guard let text = credential.privateKey, !text.isEmpty else { throw SSHSessionError.missingCredential }
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") {
                guard try SSHKeyDetection.detectPrivateKeyType(from: normalized) == .ed25519 else {
                    throw SSHSessionError.unsupportedPrivateKey
                }
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: normalized,
                                                          decryptionKey: credential.passphrase.map { Data($0.utf8) })
                return { .ed25519(username: username, privateKey: key) }
            }
            // Crypto validates the curve and PEM structure; encrypted ECDSA PEM is unsupported.
            if let key = try? P256.Signing.PrivateKey(pemRepresentation: normalized) {
                return { .p256(username: username, privateKey: key) }
            }
            if let key = try? P384.Signing.PrivateKey(pemRepresentation: normalized) {
                return { .p384(username: username, privateKey: key) }
            }
            if let key = try? P521.Signing.PrivateKey(pemRepresentation: normalized) {
                return { .p521(username: username, privateKey: key) }
            }
            throw SSHSessionError.unsupportedPrivateKey
        }
    }
}

struct PersistentHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let hostname: String
    let port: Int
    let store: KnownHostsStore
    let confirm: @Sendable (HostKeyChallenge) async -> Bool

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fields = String(openSSHPublicKey: hostKey).split(separator: " ")
        guard fields.count >= 2, let key = Data(base64Encoded: String(fields[1])) else {
            validationCompletePromise.fail(HostKeyError.invalidKey)
            return
        }
        let algorithm = String(fields[0])
        Task {
            do {
                try await store.verify(hostname: hostname, port: port, algorithm: algorithm, key: key, confirm: confirm)
                validationCompletePromise.succeed(())
            } catch {
                validationCompletePromise.fail(error)
            }
        }
    }
}
