import Combine
import Foundation
@testable import Ora
import Testing

@MainActor
struct CredentialVaultReplacementTests {
    @MainActor
    private final class Surfaces {
        var window = PasswordVaultPresentation()
        var settings = PasswordVaultPresentation()
        var notifications = 0

        func revoke(_ revision: UUID) {
            MainActor.preconditionIsolated()
            notifications += 1
            window.revoke(replacement: revision)
            settings.revoke(replacement: revision)
        }
    }

    @Test(arguments: [false, true])
    func replacementClearsBothSurfacesAndKeepsOnlyItsOwnAttempt(succeeds: Bool) async throws {
        let first = TestAuthenticationContext()
        let second = TestAuthenticationContext()
        var count = 0
        let authentication = CredentialVaultAuthentication {
            count += 1
            return count == 1 ? first : second
        }
        let backend = InMemoryVaultBackend()
        let service = PasswordManagerService(
            vault: makeTestVault(backend), metadataStore: InMemoryPasswordMetadataStore(),
            legacyStore: nil, authentication: authentication
        )
        try service.upsertCredential(
            for: #require(URL(string: "https://example.com")), username: "a",
            password: "fixture secret", containerID: UUID()
        )
        let entry = try #require(service.entries.first)
        let surfaces = Surfaces()
        let subscription = service.$authenticationRevision.dropFirst().sink { surfaces.revoke($0) }
        defer { subscription.cancel() }

        let firstAttempt = surfaces.window.beginUnlock()
        let initial = Task { await service.authenticate(reason: "window", attemptID: firstAttempt) }
        while first.callback == nil {
            await Task.yield()
        }
        #expect(surfaces.window.isAuthenticating)
        first.callback?(true)
        #expect(await surfaces.window.finishUnlock(attempt: firstAttempt, authenticated: initial.value))
        surfaces.window.revealedPasswordIDs[entry.id] = try service.revealPassword(for: entry)
        #expect(surfaces.window.revealedPasswordIDs[entry.id] == "fixture secret")

        let replacementAttempt = surfaces.settings.beginUnlock()
        let replacement = Task {
            await service.authenticate(reason: "settings", attemptID: replacementAttempt)
        }
        while second.callback == nil {
            await Task.yield()
        }
        #expect(first.invalidations == 1)
        #expect(!service.isAuthenticated)
        #expect(surfaces.notifications == 2)
        #expect(!surfaces.window.isUnlocked)
        #expect(surfaces.window.revealedPasswordIDs.isEmpty)
        #expect(surfaces.settings.isAuthenticating)
        #expect(surfaces.settings.unlockAttempt == replacementAttempt)
        first.callback?(true) // Obsolete native completion cannot restore the old session.
        #expect(!service.isAuthenticated)
        second.callback?(succeeds)
        let accepted = await replacement.value
        #expect(accepted == succeeds)
        let replacementUnlocked = surfaces.settings.finishUnlock(attempt: replacementAttempt, authenticated: accepted)
        #expect(replacementUnlocked == succeeds)
        #expect(surfaces.settings.isUnlocked == succeeds)
        if succeeds {
            surfaces.settings.revealedPasswordIDs[entry.id] = try service.revealPassword(for: entry)
            #expect(surfaces.settings.revealedPasswordIDs[entry.id] == "fixture secret")
        } else {
            let reads = backend.secretReads
            #expect(throws: PasswordManagerError.self) { try service.revealPassword(for: entry) }
            #expect(backend.secretReads == reads)
        }
        service.invalidateAuthenticatedContext()
        #expect(surfaces.notifications == 3)
        #expect(surfaces.settings.revealedPasswordIDs.isEmpty)
        #expect(!surfaces.settings.isUnlocked)
        #expect(!surfaces.window.isUnlocked)
        second.callback?(true)
        #expect(!service.isAuthenticated)
    }

    @Test func lockCancelsReplacementAndLateCompletionCannotUnlockSurface() async {
        let context = TestAuthenticationContext()
        let service = PasswordManagerService(
            vault: makeTestVault(InMemoryVaultBackend()), metadataStore: InMemoryPasswordMetadataStore(),
            legacyStore: nil, authentication: CredentialVaultAuthentication { context }
        )
        let surfaces = Surfaces()
        let subscription = service.$authenticationRevision.dropFirst().sink { surfaces.revoke($0) }
        defer { subscription.cancel() }
        let attempt = surfaces.settings.beginUnlock()
        let pending = Task { await service.authenticate(reason: "settings", attemptID: attempt) }
        while context.callback == nil {
            await Task.yield()
        }
        service.invalidateAuthenticatedContext()
        context.callback?(true)
        #expect(await !pending.value)
        let lateUnlock = surfaces.settings.finishUnlock(attempt: attempt, authenticated: true)
        #expect(!lateUnlock)
        #expect(!surfaces.settings.isAuthenticating)
        #expect(!surfaces.settings.isUnlocked)
        #expect(surfaces.notifications == 2)
    }
}
