import Foundation
import LocalAuthentication
import Security

public struct CredentialStoreError: LocalizedError, Sendable {
    public let status: OSStatus

    /// Whether the status describes a stored item that can no longer be unlocked, rather than an
    /// operation that failed for a reason the user could act on directly.
    ///
    /// Credentials are stored with `.biometryCurrentSet`, so iOS destroys the key behind them when the
    /// passcode is removed and re-added or a new face or fingerprint is enrolled; `docs/PRIVACY.md`
    /// documents that this is by design. The exact `OSStatus` the Keychain reports for an item in that
    /// state has not been reproduced on hardware here, so both statuses that plausibly describe it are
    /// treated the same: `errSecAuthFailed` for an item whose authorisation can no longer be satisfied,
    /// and `errSecInteractionNotAllowed` for one that cannot present the authentication it would need.
    /// The second can also mean a locked device, but the connect path waits for the app and device to be
    /// unlocked before it loads anything, so an invalidated item is the likelier reading there — and in
    /// either case a raw Keychain code tells the user nothing, while "enter it again" is the way out of
    /// both.
    var describesUnusableCredential: Bool {
        status == errSecAuthFailed || status == errSecInteractionNotAllowed
    }

    public var errorDescription: String? {
        if describesUnusableCredential {
            // The status is carried in the message on purpose: it is the one detail that would let a bug
            // report say which status an invalidated item really returns, which is still unconfirmed.
            return """
            The saved credential could not be unlocked. Changing the device passcode or enrolling a new \
            face or fingerprint invalidates saved credentials by design. Edit the host and enter the \
            password or key again to store a new one. (Keychain error \(status))
            """
        }
        if status == errSecUserCanceled {
            return "Authentication was cancelled, so the saved credential stayed locked."
        }
        return "Keychain: " + ((SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)")
    }
}

/// Credentials stay on this device and require the currently enrolled biometrics.
/// There is deliberately no unprotected fallback if a passcode/biometrics are unavailable.
public actor CredentialStore {
    private let service: String

    public init(service: String = "app.iossh.credentials") { self.service = service }

    public func save(_ credential: SSHCredential, for id: UUID) throws {
        let data = try JSONEncoder().encode(credential)
        let query = baseQuery(id)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard Self.updateFailureCallsForReplacement(status) else { throw CredentialStoreError(status: status) }
        try replaceItem(matching: query, with: data)
    }

    /// Decides what a failed `SecItemUpdate` means for a caller that is holding a freshly typed secret.
    ///
    /// A stored item can end up neither updatable nor absent. It is written with `.biometryCurrentSet`,
    /// so a passcode or biometric enrollment change destroys the key behind it while the row itself
    /// survives on the service + account primary key. Treating only `errSecItemNotFound` as "add it"
    /// left that state with no way out: any other status threw, and `errSecItemNotFound` fell through to
    /// a `SecItemAdd` that collided with the surviving row and returned `errSecDuplicateItem`. Which of
    /// the two an invalidated item actually reports has not been reproduced on a device here, so this
    /// deliberately names neither. Every failure is a replacement unless replacing would override
    /// something the user has just said.
    ///
    /// `errSecUserCanceled` is that exception. It means the user dismissed the authentication prompt,
    /// and deleting an item needs no authentication, so replacing on a cancellation would quietly carry
    /// out the write the user had just refused. A biometric check that fails or locks out reports
    /// `errSecAuthFailed` instead, and replacing is still right there: the caller supplied the whole
    /// credential, so writing it over the old row loses nothing.
    ///
    /// Every other status stays honest without being named, because the replacement path reports
    /// whatever the delete and the add return. A genuine failure — no passcode set, a missing
    /// entitlement, a malformed query — still reaches the caller as an error, and nothing retries.
    static func updateFailureCallsForReplacement(_ status: OSStatus) -> Bool {
        status != errSecUserCanceled
    }

    /// Replaces the stored item outright. The caller supplies the entire credential, so nothing in the
    /// old item is worth preserving, and deleting an item does not read its secret — that is what makes
    /// this work for an item whose key is gone.
    private func replaceItem(matching query: [CFString: Any], with data: Data) throws {
        let deleted = SecItemDelete(query as CFDictionary)
        // A delete that fails for any reason other than "there was nothing there" is reported as it is.
        // If the row survived, the add below would report errSecDuplicateItem and hide the real cause.
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
            throw CredentialStoreError(status: deleted)
        }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .biometryCurrentSet, &error
        ) else {
            if let error { throw error.takeRetainedValue() as Error }
            throw CredentialStoreError(status: errSecParam)
        }
        var item = query
        item[kSecValueData] = data
        item[kSecAttrAccessControl] = access
        let result = SecItemAdd(item as CFDictionary, nil)
        guard result == errSecSuccess else { throw CredentialStoreError(status: result) }
    }

    public func load(for id: UUID, prompt: String = "Unlock SSH credentials") throws -> SSHCredential? {
        var query = baseQuery(id)
        let context = LAContext()
        context.localizedReason = prompt
        query[kSecUseAuthenticationContext] = context
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        guard status != errSecItemNotFound else { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError(status: status) }
        guard let data = value as? Data else { throw CredentialStoreError(status: errSecDecode) }
        return try JSONDecoder().decode(SSHCredential.self, from: data)
    }

    public func delete(for id: UUID) throws {
        let status = SecItemDelete(baseQuery(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError(status: status)
        }
    }

    private func baseQuery(_ id: UUID) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: id.uuidString, kSecAttrSynchronizable: false]
    }
}
