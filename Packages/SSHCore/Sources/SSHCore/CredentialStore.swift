import Foundation
import LocalAuthentication
import Security

public struct CredentialStoreError: LocalizedError, Sendable {
    public let status: OSStatus
    public var errorDescription: String? {
        "Keychain: " + ((SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)")
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
        guard status == errSecItemNotFound else { throw CredentialStoreError(status: status) }
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
