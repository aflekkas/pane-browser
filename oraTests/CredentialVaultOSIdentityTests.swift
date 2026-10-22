import Foundation
@testable import Ora
import Security
import Testing

/// This test creates and deletes its OWN temporary keychain file. It never uses the login keychain,
/// enumerates other namespaces, invokes production defaults, or sets the default/search list.
/// The OS may register/remove this temporary keychain during create/delete; cleanup is asserted.
private final class DisposableCredentialKeychain: CredentialVaultKeychainBackend {
    let keychain: SecKeychain
    let directory: URL
    let allowedNamespace: String
    private let live = KeychainCredentialVaultBackend()

    init(namespace: String) throws {
        allowedNamespace = namespace
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CredentialVaultOS-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var created: SecKeychain?
        let password = UUID().uuidString
        let keychainPath = directory.appendingPathComponent("isolated.keychain-db").path
        let status = password.withCString { secret in
            SecKeychainCreate(
                keychainPath,
                UInt32(password.utf8.count),
                secret,
                false,
                nil,
                &created
            )
        }
        guard status == errSecSuccess, let created else { throw VaultError.keychain(status) }
        keychain = created
    }

    func cleanup() throws {
        let status = SecKeychainDelete(keychain)
        try FileManager.default.removeItem(at: directory)
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }

    private func confined(_ query: [String: Any], add: Bool = false) -> [String: Any] {
        precondition(query[kSecAttrSecurityDomain as String] as? String == allowedNamespace)
        precondition(query[kSecUseDataProtectionKeychain as String] as? Bool == false)
        var query = query
        if add {
            query[kSecUseKeychain as String] = keychain
        } else {
            query[kSecMatchSearchList as String] = [keychain]
        }
        return query
    }

    func addItem(_ query: [String: Any]) -> OSStatus {
        if query[kSecUseDataProtectionKeychain as String] as? Bool == true {
            return errSecMissingEntitlement
        }
        return live.addItem(confined(query, add: true))
    }

    func updateItem(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        live.updateItem(confined(query), attributes: attributes)
    }

    func copyItems(_ query: [String: Any]) -> (status: OSStatus, items: [[String: Any]]) {
        if query[kSecUseDataProtectionKeychain as String] as? Bool == true {
            return (errSecMissingEntitlement, [])
        }
        return live.copyItems(confined(query))
    }

    func copySecret(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        live.copySecret(confined(query))
    }

    func deleteItem(_ query: [String: Any]) -> OSStatus {
        live.deleteItem(confined(query))
    }

    func makeUserPresenceAccessControl() -> (control: SecAccessControl?, error: String?) {
        live.makeUserPresenceAccessControl()
    }
}

struct CredentialVaultOSIdentityTests {
    @Test func realInternetPasswordPrimaryKeyProfilesUpdateAndLabelCollision() throws {
        let namespace = "CredentialVaultOS.tests.\(UUID())"
        let backend = try DisposableCredentialKeychain(namespace: namespace)
        defer {
            do { try backend.cleanup() } catch { Issue.record(error) }
        }
        let vault = CredentialVault(backend: backend, service: namespace)
        for profile in ["one", "two"] {
            try vault.save(origin: "https://isolated.invalid", username: "same", password: profile, profileID: profile)
        }
        #expect(vault.allCredentials().count == 2)
        try vault.save(origin: "https://isolated.invalid", username: "same", password: "updated", profileID: "one")
        #expect(try vault.password(
            origin: "https://isolated.invalid",
            username: "same",
            profileID: "one",
            reason: "test"
        ) == "updated")
        #expect(try vault.password(
            origin: "https://isolated.invalid",
            username: "same",
            profileID: "two",
            reason: "test"
        ) == "two")
        #expect(vault.delete(origin: "https://isolated.invalid", username: "same", profileID: "one"))
        #expect(vault.allCredentials().count == 1)
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecUseDataProtectionKeychain as String: false,
            kSecAttrSecurityDomain as String: namespace,
            kSecAttrServer as String: "https://isolated.invalid",
            kSecAttrAccount as String: "same",
            kSecAttrPath as String: "/pane-vault-v2/profile/" + Data("two".utf8)
                .base64EncodedString(),
            kSecAttrLabel as String: "different-label",
            kSecValueData as String: Data("must-not-replace".utf8)
        ]
        #expect(backend.addItem(query) == errSecDuplicateItem)
        query[kSecAttrPath as String] = "/unrelated-item"
        #expect(backend.addItem(query) == errSecSuccess)
        #expect(vault.allCredentials().count == 1)
        #expect(vault.delete(origin: "https://isolated.invalid", username: "same", profileID: "two"))
        query.removeValue(forKey: kSecValueData as String)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        #expect(backend.copySecret(query).data == Data("must-not-replace".utf8))
    }
}
