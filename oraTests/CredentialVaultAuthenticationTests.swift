import Foundation
@testable import Ora
import Testing

@MainActor
struct CredentialVaultAuthenticationTests {
    @Test func capabilityFailureNeverUnlocksOrReads() async throws {
        let context = TestAuthenticationContext()
        context.capable = false
        let auth = CredentialVaultAuthentication { context }
        #expect(await !auth.authenticate(reason: "test"))
        var reads = 0
        #expect(throws: VaultError.self) { try auth.withAuthenticatedContext { _ in reads += 1 } }
        #expect(reads == 0)
    }

    @Test func lockBeforeCallbackRevokesPendingAttempt() async {
        let context = TestAuthenticationContext()
        let auth = CredentialVaultAuthentication { context }
        let task = Task { await auth.authenticate(reason: "test") }
        while context.callback == nil {
            await Task.yield()
        }
        auth.invalidate()
        context.callback?(true)
        #expect(await !task.value)
        #expect(!auth.isAuthenticated)
        #expect(context.invalidations == 1)
    }

    @Test func newestConcurrentAttemptOwnsSession() async {
        let first = TestAuthenticationContext()
        let second = TestAuthenticationContext()
        var attempts = 0
        let auth = CredentialVaultAuthentication { attempts += 1
            return attempts == 1 ? first : second
        }
        let task1 = Task { await auth.authenticate(reason: "first") }
        while first.callback == nil {
            await Task.yield()
        }
        let task2 = Task { await auth.authenticate(reason: "second") }
        while second.callback == nil {
            await Task.yield()
        }
        first.callback?(true)
        #expect(!auth.isAuthenticated)
        second.callback?(true)
        #expect(await !task1.value)
        #expect(await task2.value)
        #expect(auth.isAuthenticated)
        auth.invalidate()
        #expect(!auth.isAuthenticated)
    }

    @Test func repeatedCallbackCannotReauthorizeFailedAttempt() async {
        let context = TestAuthenticationContext()
        let auth = CredentialVaultAuthentication { context }
        let task = Task { await auth.authenticate(reason: "test") }
        while context.callback == nil {
            await Task.yield()
        }
        context.callback?(false)
        context.callback?(true)
        #expect(await !task.value)
        #expect(!auth.isAuthenticated)
    }

    @Test func lockDuringReadDiscardsSecretAndServiceRequiresSession() async throws {
        let context = TestAuthenticationContext()
        context.autoReply = true
        let auth = CredentialVaultAuthentication { context }
        let backend = InMemoryVaultBackend()
        let service = PasswordManagerService(
            vault: makeTestVault(backend),
            metadataStore: InMemoryPasswordMetadataStore(),
            legacyStore: nil,
            authentication: auth
        )
        try service.upsertCredential(
            for: #require(URL(string: "https://example.com")),
            username: "a",
            password: "pw",
            containerID: UUID()
        )
        let entry = try #require(service.entries.first)
        #expect(throws: PasswordManagerError.self) { try service.revealPassword(for: entry) }
        #expect(backend.secretReads == 0)
        #expect(await service.authenticate(reason: "test"))
        backend.beforeRead = { auth.invalidate() }
        #expect(throws: PasswordManagerError.self) { try service.revealPassword(for: entry) }
        #expect(!service.isAuthenticated)
    }
}
