import AppKit
import Combine
import Foundation
import LocalAuthentication
import Security

/// The password service the coordinator, overlay, passwords window and
/// settings are built on. Its public API is unchanged; its storage is now
/// Pane's spec §7 vault (`CredentialVault`, InternetPassword items, probed
/// `.userPresence` access control, strict https origin keys) instead of
/// synchronizable generic-password items gated only at app level.
///
/// Per-profile scoping uses the Internet Password primary-key path attribute.
/// A nil container remains unassigned; legacy unassigned credentials are retained. Dates and display origins live in
/// the non-secret
/// sidecar (`PasswordMetadataStoring`); secrets exist only inside vault items
/// and in memory between a keychain read and its caller.
final class PasswordManagerService: ObservableObject {
    static let shared = PasswordManagerService()

    @Published private(set) var authenticationRevision = UUID()
    @Published private(set) var entries: [SavedPasswordSummary] = []
    @Published private(set) var lastErrorMessage: String?
    /// Most recent legacy-store migration outcome (counts and host-named skip
    /// reasons only; never usernames, never passwords).
    @Published private(set) var lastMigrationReport: LegacyMigrationReport?

    let vault: CredentialVault
    let metadataStore: PasswordMetadataStoring
    private let legacyStore: LegacyPasswordStoring?
    var metadataByKey: [String: PasswordVaultMetadata] = [:]
    var credentialBySummaryID: [String: StoredCredential] = [:]
    private var didRunLegacyMigration = false
    private let authentication: CredentialVaultAuthentication
    var isAuthenticated: Bool {
        authentication.isAuthenticated
    }

    var defersMetadataRefresh = false

    init(
        vault: CredentialVault = CredentialVault(),
        metadataStore: PasswordMetadataStoring = UserDefaultsPasswordMetadataStore(),
        legacyStore: LegacyPasswordStoring? = KeychainLegacyPasswordStore(),
        authentication: CredentialVaultAuthentication = CredentialVaultAuthentication()
    ) {
        self.authentication = authentication
        self.vault = vault
        self.metadataStore = metadataStore
        self.legacyStore = legacyStore
        metadataByKey = Dictionary(
            metadataStore.loadRecords().map { ($0.identityKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        refresh()
    }

    /// Capability for new writes only. Existing items retain their own backend and ACL;
    /// use storedProtectionDescription for their observed attributes.
    var vaultProtection: CredentialVault.Protection {
        vault.protection
    }

    func refresh() {
        let stored = vault.allCredentials()
        var backfilledMetadata = false
        credentialBySummaryID = [:]

        let summaries = stored.map { credential -> SavedPasswordSummary in
            let key = PasswordVaultMetadata.identityKey(
                vaultOrigin: credential.origin,
                username: credential.username,
                profileID: credential.profileID
            )
            let record: PasswordVaultMetadata
            if let existing = metadataByKey[key] {
                record = existing
            } else {
                // First sight of a credential written outside the adapter
                // (e.g. an older Pane vault item under the same service):
                // dates are unknown, so they start now rather than claiming
                // a false history.
                record = PasswordVaultMetadata(
                    vaultOrigin: credential.origin,
                    username: credential.username,
                    profileID: credential.profileID,
                    displayOrigin: Self.displayOrigin(forVaultOrigin: credential.origin),
                    host: Self.hostPart(ofVaultOrigin: credential.origin),
                    createdAt: Date(),
                    updatedAt: Date(),
                    lastUsedAt: nil
                )
                metadataByKey[key] = record
                backfilledMetadata = true
            }

            let summaryID = Self.summaryID(for: credential)
            credentialBySummaryID[summaryID] = credential
            return SavedPasswordSummary(
                metadata: SavedPasswordMetadata(
                    id: summaryID,
                    origin: record.displayOrigin,
                    host: record.host,
                    username: record.username,
                    createdAt: record.createdAt,
                    updatedAt: record.updatedAt,
                    lastUsedAt: record.lastUsedAt,
                    containerID: UUID(uuidString: record.profileID)
                ),
                persistentReference: Data(summaryID.utf8)
            )
        }

        if backfilledMetadata {
            persistMetadata()
        }

        entries = summaries.sorted {
            if $0.host != $1.host {
                return $0.host.localizedCaseInsensitiveCompare($1.host) == .orderedAscending
            }
            return $0.displayUsername.localizedCaseInsensitiveCompare($1.displayUsername) == .orderedAscending
        }
        lastErrorMessage = nil
    }

    func revealPassword(for entry: SavedPasswordSummary) throws -> String {
        let credential = try storedCredential(for: entry)
        do {
            // The read is what prompts (Touch ID via the item's access
            // control on signed builds). The authenticated context from the
            // app-level gate is handed in so the user sees one prompt total.
            return try authentication.withAuthenticatedContext { context in
                try vault.password(
                    origin: credential.origin,
                    username: credential.username,
                    profileID: credential.profileID,
                    reason: "Read saved password",
                    context: context
                )
            }
        } catch let error as VaultError {
            throw Self.passwordManagerError(from: error)
        }
    }

    func upsertCredential(for url: URL, username: String, password: String) throws {
        try upsertCredential(for: url, username: username, password: password, containerID: nil)
    }

    func upsertCredential(for url: URL, username: String, password: String, containerID: UUID?) throws {
        // Non-https (non-loopback) origins cannot be stored at all under the
        // vault policy; callers that prompt first (the coordinator) guard on
        // the same key so this throw is a backstop, not the user experience.
        guard let originKey = CredentialVault.originKey(for: url),
              let normalizedHost = Self.normalizedHost(from: url)
        else {
            throw PasswordManagerError.invalidCredentialOrigin
        }

        try saveVaultCredential(
            originKey: originKey,
            displayOrigin: Self.normalizedOrigin(from: url) ?? Self.displayOrigin(forVaultOrigin: originKey),
            host: normalizedHost,
            username: username,
            password: password,
            profileID: containerID?.uuidString ?? ""
        )
    }

    /// Saves one already-keyed credential. Import and migration land here:
    /// their origins were keyed by `CredentialVault.originKey` during parsing,
    /// so no URL reconstruction (and no scheme guessing) happens at save time.
    func saveVaultCredential(
        originKey: String,
        displayOrigin: String,
        host: String,
        username: String,
        password: String,
        profileID: String,
        insertOnly: Bool = false
    ) throws {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty else {
            throw PasswordManagerError.emptyUsername
        }

        do {
            try vault.save(
                origin: originKey,
                username: trimmedUsername,
                password: password,
                profileID: profileID,
                insertOnly: insertOnly
            )
        } catch let error as VaultError {
            throw Self.passwordManagerError(from: error)
        }

        let key = PasswordVaultMetadata.identityKey(
            vaultOrigin: originKey,
            username: trimmedUsername,
            profileID: profileID
        )
        let now = Date()
        if var existing = metadataByKey[key] {
            existing.displayOrigin = displayOrigin
            existing.host = host
            existing.updatedAt = now
            metadataByKey[key] = existing
        } else {
            metadataByKey[key] = PasswordVaultMetadata(
                vaultOrigin: originKey,
                username: trimmedUsername,
                profileID: profileID,
                displayOrigin: displayOrigin,
                host: host,
                createdAt: now,
                updatedAt: now,
                lastUsedAt: nil
            )
        }
        if !defersMetadataRefresh {
            persistMetadata()
            refresh()
        }
    }

    func markUsed(_ entry: SavedPasswordSummary) {
        // Metadata only: marking use must never read the secret and never
        // prompt, so it touches the sidecar, not the vault item.
        guard let credential = credentialBySummaryID[entry.id] else {
            return
        }
        let key = PasswordVaultMetadata.identityKey(
            vaultOrigin: credential.origin,
            username: credential.username,
            profileID: credential.profileID
        )
        guard var record = metadataByKey[key] else {
            return
        }
        record.lastUsedAt = Date()
        metadataByKey[key] = record
        persistMetadata()
        refresh()
    }

    func delete(_ entry: SavedPasswordSummary) throws {
        let credential = try storedCredential(for: entry)
        guard vault.delete(
            origin: credential.origin,
            username: credential.username,
            profileID: credential.profileID
        ) else {
            throw PasswordManagerError.keychainStatus(errSecInternalError)
        }

        metadataByKey.removeValue(forKey: PasswordVaultMetadata.identityKey(
            vaultOrigin: credential.origin,
            username: credential.username,
            profileID: credential.profileID
        ))
        persistMetadata()
        refresh()
    }

    func deleteEntries(for containerID: UUID) throws {
        let profileID = containerID.uuidString

        defer {
            refresh()
        }

        do {
            for credential in vault.all(profileID: profileID) {
                guard vault.delete(
                    origin: credential.origin,
                    username: credential.username,
                    profileID: profileID
                ) else {
                    throw PasswordManagerError.keychainStatus(errSecInternalError)
                }
                metadataByKey.removeValue(forKey: PasswordVaultMetadata.identityKey(
                    vaultOrigin: credential.origin,
                    username: credential.username,
                    profileID: profileID
                ))
            }
            persistMetadata()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
            throw error
        }
    }

    /// One-time migration of the app's own legacy generic-password items
    /// into the vault. Triggered explicitly by the unlocked window's migration button,
    /// never at service creation or app launch. Verification may request authentication. Safe to call repeatedly: after
    /// a successful run the legacy
    /// store is empty, and any entry that failed or was skipped keeps its
    /// legacy item for the next attempt.
    func performLegacyMigrationIfNeeded() {
        guard !didRunLegacyMigration, let legacyStore else {
            return
        }
        didRunLegacyMigration = true

        let migrator = LegacyPasswordMigrator(
            vault: vault,
            legacyStore: legacyStore,
            recordMetadata: { [weak self] entry, originKey in
                self?.recordMigratedMetadata(entry, originKey: originKey)
            }
        )
        do {
            let report = try migrator.migrate()
            if !report.isEmpty {
                lastMigrationReport = report
            }
            refresh()
        } catch {
            // Loading the legacy store failed: leave the one-time flag clear
            // so a later trigger can retry, and say so in the usual place.
            didRunLegacyMigration = false
            lastErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    func authenticate(reason: String, attemptID: UUID = UUID()) async -> Bool {
        // Revoke synchronously before publishing. Subscribers clear old plaintext but
        // retain the initiating surface's matching attempt. Begin runs on this actor,
        // so a concurrent caller cannot reorder notification and context replacement.
        authentication.invalidate()
        authenticationRevision = attemptID
        let accepted = await authentication.authenticate(reason: reason)
        return accepted && authenticationRevision == attemptID && authentication.isAuthenticated
    }

    @MainActor
    func invalidateAuthenticatedContext() {
        authentication.invalidate()
        authenticationRevision = UUID()
    }

    func storedProtectionDescription(for entry: SavedPasswordSummary) -> String {
        credentialBySummaryID[entry.id]?.protectionDescription ?? CredentialVault.Protection.unknown
            .userFacingDescription
    }

    func copyToPasteboard(_ value: String) {
        copyToPasteboard(value, clearingAfter: nil)
    }

    func copySensitiveToPasteboard(_ value: String) {
        copyToPasteboard(value, clearingAfter: 90)
    }
}
