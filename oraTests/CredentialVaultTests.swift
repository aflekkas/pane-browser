import Foundation
@testable import Ora
import Security
import Testing

struct CredentialVaultTests {
    @Test func profileIdentityAndUnrelatedNamespace() throws {
        let backend = InMemoryVaultBackend()
        let vault = makeTestVault(backend)
        let other = makeTestVault(backend)
        for profile in ["p1", "p2"] {
            try vault.save(origin: "https://example.com", username: "same", password: profile, profileID: profile)
        }
        try other.save(origin: "https://example.com", username: "same", password: "unrelated", profileID: "p1")
        try vault.save(origin: "https://example.com", username: "same", password: "updated", profileID: "p1")
        #expect(vault.allCredentials().count == 2)
        #expect(vault.all(profileID: "p2").count == 1)
        #expect(try vault
            .password(origin: "https://example.com", username: "same", profileID: "p1", reason: "test") == "updated")
        #expect(vault.delete(origin: "https://example.com", username: "same", profileID: "p1"))
        #expect(try vault
            .password(origin: "https://example.com", username: "same", profileID: "p2", reason: "test") == "p2")
        #expect(try other
            .password(origin: "https://example.com", username: "same", profileID: "p1", reason: "test") == "unrelated")
        #expect(backend.adds.allSatisfy { $0[kSecAttrService as String] == nil })
    }

    @Test(arguments: [errSecInternalError, errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed])
    func failedUpdateNeverDeletesOldSecret(_ status: OSStatus) throws {
        let backend = InMemoryVaultBackend()
        let vault = makeTestVault(backend)
        try vault.save(origin: "https://example.com", username: "a", password: "old", profileID: "p")
        let deletes = backend.deletes
        backend.updateStatus = status
        #expect(throws: VaultError.self) {
            try vault.save(origin: "https://example.com", username: "a", password: "new", profileID: "p")
        }
        #expect(backend.deletes == deletes)
        #expect(try vault
            .password(origin: "https://example.com", username: "a", profileID: "p", reason: "test") == "old")
        backend.deleteStatus = status
        #expect(!vault.delete(origin: "https://example.com", username: "a", profileID: "p"))
        #expect(vault.allCredentials().count == 1)
    }

    @Test func failedAddAndConflictPreserveExisting() throws {
        let backend = InMemoryVaultBackend()
        let vault = makeTestVault(backend)
        try vault.save(origin: "https://example.com", username: "a", password: "old", profileID: "p")
        backend.addStatus = errSecInternalError
        #expect(throws: VaultError.self) {
            try vault.save(origin: "https://example.com", username: "b", password: "new", profileID: "p")
        }
        #expect(throws: VaultError.self) {
            try vault.save(
                origin: "https://example.com",
                username: "a",
                password: "new",
                profileID: "p",
                insertOnly: true
            )
        }
        #expect(backend.updates == 0)
        #expect(vault.allCredentials().count == 1)
    }

    @Test func entitlementFallbackIsExplicitAndOldItemsStayLegacy() throws {
        let backend = InMemoryVaultBackend()
        backend.dataProtectionStatus = errSecMissingEntitlement
        let vault = makeTestVault(backend)
        #expect(vault.protection == .legacyKeychain)
        try vault.save(origin: "https://example.com", username: "a", password: "old", profileID: "p")
        let written = try #require(backend.adds.last)
        #expect(written[kSecUseDataProtectionKeychain as String] as? Bool == false)
        #expect(written[kSecAttrAccessible as String] == nil)
        #expect(written[kSecAttrSynchronizable as String] == nil)
        backend.dataProtectionStatus = errSecSuccess
        let signed = CredentialVault(backend: backend, service: vault.service)
        #expect(signed.protection == .userPresence)
        try signed.save(origin: "https://example.com", username: "a", password: "updated", profileID: "p")
        #expect(signed.allCredentials().first?.protection == .legacyKeychain)
        #expect(CredentialVault.Protection.userPresence.userFacingDescription.contains("Existing passwords"))
    }

    @Test(arguments: [errSecInternalError, errSecNotAvailable, errSecInteractionNotAllowed, errSecUserCanceled])
    func unexpectedProbeErrorsNeverDegrade(_ status: OSStatus) {
        let backend = InMemoryVaultBackend()
        backend.addStatus = status
        let vault = makeTestVault(backend)
        #expect(vault.protection == .unavailable)
        #expect(throws: VaultError.self) {
            try vault.save(origin: "https://example.com", username: "a", password: "pw", profileID: "p")
        }
        #expect(backend.items.isEmpty)
    }

    @Test func invalidControlAndFailedProbeCleanupAreNotCapabilityFallbacks() {
        for failControl in [true, false] {
            let backend = InMemoryVaultBackend()
            backend.makeControlFails = failControl
            backend.deleteStatus = errSecInternalError
            let vault = makeTestVault(backend)
            #expect(vault.protection == .unavailable)
            #expect(throws: VaultError.self) {
                try vault.save(origin: "https://example.com", username: "a", password: "pw", profileID: "p")
            }
            #expect(backend.items
                .allSatisfy { $0.attributes[kSecAttrServer as String] as? String == "https://probe.invalid" })
        }
    }

    @Test func listErrorsCannotTurnAnUpdateIntoAnAdd() throws {
        let backend = InMemoryVaultBackend()
        let vault = makeTestVault(backend)
        try vault.save(origin: "https://example.com", username: "a", password: "old", profileID: "p")
        let additions = backend.adds.count
        backend.listStatus = errSecNotAvailable
        #expect(throws: VaultError.self) {
            try vault.save(origin: "https://example.com", username: "a", password: "new", profileID: "p")
        }
        #expect(backend.adds.count == additions)
        #expect(backend.updates == 0)
        backend.listStatus = errSecSuccess
        #expect(try vault
            .password(origin: "https://example.com", username: "a", profileID: "p", reason: "test") == "old")
    }

    @Test func listIsAttributeOnlyAndProtectionIsPerItem() throws {
        let backend = InMemoryVaultBackend()
        let vault = makeTestVault(backend)
        try vault.save(origin: "https://example.com", username: "a", password: "pw", profileID: "p")
        #expect(vault.allCredentials().first?.protection == .dataProtection)
        #expect(backend.secretReads == 0)
        let item = try #require(backend.items.first)
        #expect(item.attributes[kSecAttrAccessControl as String] != nil)
        #expect(item
            .attributes[kSecAttrAccessible as String] as? String ==
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect(item.attributes[kSecAttrSynchronizable as String] as? Bool == false)
    }

    @Test(arguments: [
        "ftp://localhost",
        "ftp://127.0.0.1",
        "http://example.com",
        "https://user:secret@example.com",
        "file:///tmp/a"
    ])
    func unsafeOriginsRejected(_ raw: String) throws {
        #expect(try CredentialVault.originKey(for: #require(URL(string: raw))) == nil)
    }

    @Test func exactSchemeHostAndPort() throws {
        func key(_ raw: String) throws -> String? {
            try CredentialVault.originKey(for: #require(URL(string: raw)))
        }
        #expect(try key("https://Example.COM.:443/a") == "https://example.com")
        #expect(try key("http://localhost:443") != key("https://localhost:443"))
        #expect(try key("http://localhost:80") == "http://localhost")
        #expect(try key("https://www.example.com") != key("https://example.com"))
        #expect(try key("https://sub.example.com") != key("https://example.com"))
    }
}
