import Foundation
import Security
import Testing
@testable import SSHCore

/// These cover the decision and the message that `CredentialStore` wraps around the Keychain, not the
/// Keychain calls themselves. Every item this store writes carries an access control, and `SecItemAdd`
/// refuses that from an SPM test binary with `errSecMissingEntitlement` (-34018) because the binary has
/// no keychain entitlement; reaching the state this fix is about needs more still — a real passcode and
/// a biometric enrollment change on a device. Standing in a fake Keychain would only test the fake, so
/// what is covered here is the logic that is actually ours: which failed update becomes a replacement,
/// and what every call site ends up showing the user.
struct CredentialStoreTests {
    /// The statuses an invalidated item might plausibly report, plus the ones the old two-branch write
    /// path turned into dead ends. All of them have to reach the replace path, because which one comes
    /// back from a destroyed `.biometryCurrentSet` key is not confirmed.
    @Test func everyUpdateFailureExceptCancellationIsReplaced() {
        for status: OSStatus in [errSecAuthFailed, errSecInteractionNotAllowed, errSecItemNotFound,
                                 errSecDuplicateItem, errSecDecode, errSecMissingEntitlement, errSecParam] {
            #expect(CredentialStore.updateFailureCallsForReplacement(status),
                    "status \(status) should replace the stored item rather than fail")
        }
    }

    /// Deleting an item needs no authentication, so replacing after a cancellation would perform the
    /// write the user had just refused.
    @Test func cancellingAuthenticationDoesNotReplaceTheStoredItem() {
        #expect(!CredentialStore.updateFailureCallsForReplacement(errSecUserCanceled))
    }

    @Test func invalidatedCredentialIsExplainedInsteadOfShownAsAKeychainCode() throws {
        for status: OSStatus in [errSecAuthFailed, errSecInteractionNotAllowed] {
            let message = try #require(CredentialStoreError(status: status).errorDescription)
            #expect(!message.hasPrefix("Keychain: "))
            #expect(message.contains("enrolling a new face or fingerprint"))
            #expect(message.contains("enter the password or key again"))
            // Carried so a bug report can say which status an invalidated item really returns.
            #expect(message.contains("\(status)"))
        }
    }

    @Test func cancellingAuthenticationIsNotReportedAsAnInvalidatedCredential() throws {
        let message = try #require(CredentialStoreError(status: errSecUserCanceled).errorDescription)
        #expect(message.contains("cancelled"))
        #expect(!message.contains("enter the password or key again"))
    }

    /// Statuses with no reading of their own keep the Keychain's own text rather than being guessed at.
    @Test func unrecognisedStatusKeepsTheKeychainText() throws {
        let message = try #require(CredentialStoreError(status: errSecDuplicateItem).errorDescription)
        #expect(message.hasPrefix("Keychain: "))
    }

    /// `HostEditorView` and `ConnectionModel` both render `error.localizedDescription`, so the mapping is
    /// only worth anything if it survives that bridging.
    @Test func callSitesRenderTheMappedMessage() {
        let error: any Error = CredentialStoreError(status: errSecAuthFailed)
        #expect(error.localizedDescription == CredentialStoreError(status: errSecAuthFailed).errorDescription)
    }
}
