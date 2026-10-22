import Foundation
import Security

/// One credential from the previous vault: the synchronizable
/// `kSecClassGenericPassword` store the rebranded app used before the spec §7
/// InternetPassword vault (`PasswordManagerService`'s legacy service).
///
/// This is the app's **own** legacy store and the only keychain service the
/// migration ever reads. Nothing here reads Ora's, Safari's, Chrome's or
/// Apple Passwords' items, and no other app's namespace is enumerated.
struct LegacyPasswordEntry {
    /// Stored full origin (`https://host[:port]`) when the legacy item had
    /// one; older host-only items have `nil` and are assumed https.
    let origin: String?
    let host: String
    let username: String
    /// In memory only, between the legacy read and the vault write. Never
    /// logged, never written to the metadata sidecar, never put in a report.
    let password: String
    let containerID: UUID?
    let createdAt: Date
    let updatedAt: Date
    let lastUsedAt: Date?
    /// Opaque handle the production store deletes by. Fakes ignore it.
    let persistentReference: Data

    var profileID: String {
        containerID?.uuidString ?? ""
    }
}

/// The legacy store surface migration needs, behind a protocol so tests run
/// the real migration logic against fakes. Tests must never load the real
/// store: it reads actual user secrets.
protocol LegacyPasswordStoring {
    func loadEntries() throws -> [LegacyPasswordEntry]
    func deleteEntry(_ entry: LegacyPasswordEntry) throws
}

/// Outcome of a migration run. Counts and skip reasons only — reasons name
/// a host (metadata), never a username and never a password.
struct LegacyMigrationReport: Equatable {
    var migratedCount = 0
    var failedCount = 0
    var skipped: [String] = []

    var isEmpty: Bool {
        migratedCount == 0 && failedCount == 0 && skipped.isEmpty
    }
}

/// Copy only into an absent destination; verify the intended secret before deleting the legacy item.
/// A duplicate (including a retry after failed deletion) retains the source for manual resolution.
/// Never replace a newer destination, merge accounts, or infer durability from attribute existence.
struct LegacyPasswordMigrator {
    let vault: CredentialVault
    let legacyStore: LegacyPasswordStoring
    /// Records preserved dates/display origin for a migrated credential.
    /// Called only after the vault write is verified, before legacy deletion.
    let recordMetadata: (LegacyPasswordEntry, String) -> Void

    func migrate() throws -> LegacyMigrationReport {
        var report = LegacyMigrationReport()
        for entry in try legacyStore.loadEntries() {
            migrate(entry, report: &report)
        }
        return report
    }

    private func migrate(_ entry: LegacyPasswordEntry, report: inout LegacyMigrationReport) {
        guard entry.containerID != nil else {
            report.skipped.append("Unassigned legacy password retained; choose a destination space before migration.")
            return
        }
        let candidateURL = entry.origin.map { URL(string: $0) } ?? URL(string: "https://\(entry.host)")
        guard let candidateURL, let originKey = CredentialVault.originKey(for: candidateURL) else {
            report.skipped.append("Legacy password retained: unsupported origin.")
            return
        }
        guard !entry.password.isEmpty else {
            report.failedCount += 1
            return
        }
        do {
            try vault.save(
                origin: originKey,
                username: entry.username,
                password: entry.password,
                profileID: entry.profileID,
                insertOnly: true
            )
            let saved = try vault.password(
                origin: originKey,
                username: entry.username,
                profileID: entry.profileID,
                reason: "Verify migrated password before removing its legacy copy"
            )
            guard saved == entry.password else {
                report.failedCount += 1
                return
            }
        } catch VaultError.keychain(errSecDuplicateItem) {
            report.skipped.append("Legacy password retained: destination already exists; resolve manually.")
            return
        } catch {
            report.failedCount += 1
            return
        }
        recordMetadata(entry, originKey)
        do {
            try legacyStore.deleteEntry(entry)
            report.migratedCount += 1
        } catch {
            // The vault copy is verified and stays; the legacy item also
            // stays, so a later attempt reports a conflict without overwriting either copy. Losing neither
            // copy is the correct failure mode for a credential migration.
            report.failedCount += 1
        }
    }
}

/// Production legacy store: generic-password items under the app's own
/// previous service name. Loaded once, on the migration trigger, never as
/// part of normal browsing.
final class KeychainLegacyPasswordStore: LegacyPasswordStoring {
    /// The service the previous `PasswordManagerService` vault wrote to.
    /// Renamed here (not referenced from the service) so the adapter has a
    /// single, auditable place that names the legacy namespace.
    static let legacyService = "com.aflekkas.pane.passwords"

    private let decoder = JSONDecoder()

    func loadEntries() throws -> [LegacyPasswordEntry] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.legacyService,
            // Legacy items were written synchronizable; migration must see
            // them to move them. The new vault never writes synchronizable
            // items, so this `Any` cannot leak into the new store.
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PasswordManagerError.keychainStatus(status)
        }
        guard let records = result as? [[String: Any]] else {
            return []
        }

        return records.compactMap { record -> LegacyPasswordEntry? in
            guard let persistentReference = record[kSecValuePersistentRef as String] as? Data,
                  let passwordData = record[kSecValueData as String] as? Data,
                  let password = String(data: passwordData, encoding: .utf8)
            else {
                return nil
            }
            if let genericData = record[kSecAttrGeneric as String] as? Data,
               let metadata = try? decoder.decode(SavedPasswordMetadata.self, from: genericData)
            {
                return LegacyPasswordEntry(
                    origin: metadata.origin,
                    host: metadata.host,
                    username: metadata.username,
                    password: password,
                    containerID: metadata.containerID,
                    createdAt: metadata.createdAt,
                    updatedAt: metadata.updatedAt,
                    lastUsedAt: metadata.lastUsedAt,
                    persistentReference: persistentReference
                )
            }
            guard let host = record[kSecAttrLabel as String] as? String else {
                return nil
            }
            return LegacyPasswordEntry(
                origin: nil,
                host: host,
                username: record[kSecAttrComment as String] as? String ?? "",
                password: password,
                containerID: nil,
                createdAt: Date.distantPast,
                updatedAt: Date.distantPast,
                lastUsedAt: nil,
                persistentReference: persistentReference
            )
        }
    }

    func deleteEntry(_ entry: LegacyPasswordEntry) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecValuePersistentRef as String: entry.persistentReference
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PasswordManagerError.keychainStatus(status)
        }
    }
}
