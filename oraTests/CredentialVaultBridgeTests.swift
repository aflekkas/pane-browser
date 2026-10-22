#if CREDENTIAL_VAULT_HARNESS
    import Foundation
    @testable import Ora
    import Testing

    /// Coordinator sequencing tests with injected auth/secret operations and a fake tab.
    /// The real WKWebView/isolated-world tests remain the parent app CI's responsibility.
    @MainActor struct CredentialVaultBridgeTests {
        @Test func staleContextIsCheckedBeforeSecretRead() async throws {
            let backend = InMemoryVaultBackend()
            let service = PasswordManagerService(
                vault: makeTestVault(backend),
                metadataStore: InMemoryPasswordMetadataStore(),
                legacyStore: nil
            )
            let tab = Tab()
            try service.upsertCredential(
                for: #require(URL(string: "https://example.com")),
                username: "a",
                password: "pw",
                containerID: tab.container.id
            )
            let entry = try #require(service.entries.first)
            let captured = PasswordDocumentContext(documentToken: "old")
            tab.browserPage?.context = PasswordDocumentContext(documentToken: "navigated")
            let focus = PasswordBridgeFocusPayload(
                fieldID: "pw",
                hostname: "example.com",
                action: .login,
                fieldKind: .password,
                usernameFieldID: "user",
                passwordFieldIDs: ["pw"],
                rect: PasswordBridgeRect(
                    originX: 0,
                    originY: 0,
                    width: 10,
                    height: 10
                )
            )
            let overlay = PasswordAutofillOverlayState(
                focus: focus,
                savedPasswordEntries: [entry],
                emailSuggestions: [],
                generatedPassword: nil,
                selectedSuggestionIndex: 0,
                fillContext: captured
            )
            let coordinator = PasswordAutofillCoordinator(
                tab: tab,
                passwordManager: service,
                authenticate: { _ in true },
                revealPassword: { _ in Issue.record("Stale document must not trigger a secret read")
                    return "secret"
                },
                markUsed: { _ in Issue.record("Stale document must not count as used") }
            )
            await coordinator.autofill(entry, for: overlay).value
            #expect(!tab.scripts.contains { $0.contains("fillCredentials") })
            #expect(backend.secretReads == 0)
        }
    }
#endif
