import Foundation

/// Non-secret metadata for vault credentials: display origin, host and the
/// dates Ora's ranking and management UI are built on (`createdAt`,
/// `updatedAt`, `lastUsedAt`).
///
/// The vault item itself (spec §7) has no room for these — `kSecAttrServer`,
/// `kSecAttrAccount`, security domain and profile path are the credential's identity — so
/// they live in this sidecar, keyed by that identity. It contains **no
/// secrets**: never a password, never a keychain reference. It does reveal
/// which sites a user has accounts on to anyone who can read it, which is
/// the accepted trade-off for keeping Ora's email suggestions and
/// `lastUsedAt` ranking (port plan §6.4, option b); the passwords window and
/// settings surfaces remain behind the unlock gate.
struct PasswordVaultMetadata: Codable, Equatable {
    var vaultOrigin: String
    var username: String
    /// Vault profile label: a container `uuidString`, or `""` when unscoped.
    var profileID: String
    /// Full display origin, retained for compatibility. Vault v2 identities also include scheme.
    var displayOrigin: String
    var host: String
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?

    var identityKey: String {
        Self.identityKey(vaultOrigin: vaultOrigin, username: username, profileID: profileID)
    }

    static func identityKey(vaultOrigin: String, username: String, profileID: String) -> String {
        [profileID, vaultOrigin, username].map { Data($0.utf8).base64EncodedString() }.joined(separator: ":")
    }
}

/// Storage for the sidecar. The production store is `UserDefaults`; tests
/// inject an in-memory store so no user defaults (and no keychain) are touched.
protocol PasswordMetadataStoring: AnyObject {
    func loadRecords() -> [PasswordVaultMetadata]
    func saveRecords(_ records: [PasswordVaultMetadata])
}

final class UserDefaultsPasswordMetadataStore: PasswordMetadataStoring {
    private let defaults: UserDefaults
    private let key = "com.aflekkas.pane.passwords.metadata.v1"
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadRecords() -> [PasswordVaultMetadata] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: key),
              let records = try? JSONDecoder().decode([PasswordVaultMetadata].self, from: data)
        else {
            return []
        }
        return records
    }

    func saveRecords(_ records: [PasswordVaultMetadata]) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(records) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}
