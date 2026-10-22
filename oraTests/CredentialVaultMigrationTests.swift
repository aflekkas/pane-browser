import Foundation
@testable import Ora
import Security
import Testing

final class FakeLegacyPasswordStore: LegacyPasswordStoring {
    var entries: [LegacyPasswordEntry]
    var deleteFails = false
    var deleted = 0
    init(_ entries: [LegacyPasswordEntry]) {
        self.entries = entries
    }

    func loadEntries() throws -> [LegacyPasswordEntry] {
        entries
    }

    func deleteEntry(_ entry: LegacyPasswordEntry) throws {
        if deleteFails {
            throw VaultError.keychain(errSecInternalError)
        }
        deleted += 1
        entries.removeAll { $0.persistentReference == entry.persistentReference }
    }
}

private func legacy(
    _ profile: UUID?,
    password: String = "legacy",
    origin: String? = "https://example.com"
) -> LegacyPasswordEntry {
    LegacyPasswordEntry(
        origin: origin,
        host: "example.com",
        username: "same",
        password: password,
        containerID: profile,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(),
        lastUsedAt: nil,
        persistentReference: Data(UUID().uuidString.utf8)
    )
}

struct CredentialVaultMigrationTests {
    @Test func verifiesSecretBeforeDeletionAndPreservesDates() throws {
        let backend = InMemoryVaultBackend()
        let vault = makeTestVault(backend)
        let profile = UUID()
        let store = FakeLegacyPasswordStore([legacy(profile)])
        var metadata: LegacyPasswordEntry?
        let migrator = LegacyPasswordMigrator(vault: vault, legacyStore: store) { entry, _ in
            #expect(backend.secretReads == 1)
            #expect(store.deleted == 0)
            metadata = entry
        }
        #expect(try migrator.migrate().migratedCount == 1)
        #expect(store.entries.isEmpty)
        #expect(metadata?.createdAt == Date(timeIntervalSince1970: 1))
        #expect(try migrator.migrate().isEmpty)
    }

    @Test func destinationConflictNeverOverwritesAndRetryPreservesNewerUpdate() throws {
        let backend = InMemoryVaultBackend()
        let vault = makeTestVault(backend)
        let profile = UUID()
        let store = FakeLegacyPasswordStore([legacy(profile)])
        store.deleteFails = true
        let migrator = LegacyPasswordMigrator(vault: vault, legacyStore: store) { _, _ in }
        #expect(try migrator.migrate().failedCount == 1)
        try vault.save(
            origin: "https://example.com",
            username: "same",
            password: "newer",
            profileID: profile.uuidString
        )
        store.deleteFails = false
        #expect(try migrator.migrate().skipped.count == 1)
        #expect(store.entries.count == 1)
        #expect(try vault.password(
            origin: "https://example.com",
            username: "same",
            profileID: profile.uuidString,
            reason: "test"
        ) == "newer")
    }

    @Test(arguments: [errSecUserCanceled, errSecInteractionNotAllowed, errSecInternalError])
    func verificationFailureRetainsSource(_ status: OSStatus) throws {
        let backend = InMemoryVaultBackend()
        backend.readStatus = status
        let store = FakeLegacyPasswordStore([legacy(UUID())])
        let migrator = LegacyPasswordMigrator(vault: makeTestVault(backend), legacyStore: store) { _, _ in }
        #expect(try migrator.migrate().failedCount == 1)
        #expect(store.entries.count == 1)
        #expect(store.deleted == 0)
    }

    @Test func attributeExistenceDoesNotVerifyWrongSecret() throws {
        let backend = InMemoryVaultBackend()
        backend.corruptNextSecret = true
        let store = FakeLegacyPasswordStore([legacy(UUID())])
        let migrator = LegacyPasswordMigrator(vault: makeTestVault(backend), legacyStore: store) { _, _ in }
        #expect(try migrator.migrate().failedCount == 1)
        #expect(store.deleted == 0)
        #expect(backend.items.count == 1)
    }

    @Test func collapsedLegacyAccountsAreRetainedAndUnassignedStaysAccessibleInLegacy() {
        let profile = UUID()
        let store = FakeLegacyPasswordStore([legacy(profile), legacy(profile, password: "other"), legacy(nil)])
        let vault = makeTestVault()
        let service = PasswordManagerService(
            vault: vault,
            metadataStore: InMemoryPasswordMetadataStore(),
            legacyStore: store
        )
        service.performLegacyMigrationIfNeeded()
        #expect(service.entries(for: profile).count == 1)
        #expect(service.lastMigrationReport?.migratedCount == 1)
        #expect(service.lastMigrationReport?.skipped.count == 2)
        #expect(store.entries.count == 2)
        #expect(store.entries.contains { $0.containerID == nil })
        #expect(vault.all(profileID: "").isEmpty)
    }

    @Test func failedAddAndInvalidOriginRetainSource() throws {
        let backend = InMemoryVaultBackend()
        backend.addStatus = errSecInternalError
        let store = FakeLegacyPasswordStore([legacy(UUID()), legacy(UUID(), origin: "http://example.com/secret-token")])
        let migrator = LegacyPasswordMigrator(vault: makeTestVault(backend), legacyStore: store) { _, _ in }
        let report = try migrator.migrate()
        #expect(report.failedCount == 1)
        #expect(report.skipped.count == 1)
        #expect(!report.skipped.joined().contains("secret-token"))
        #expect(store.deleted == 0)
    }
}
