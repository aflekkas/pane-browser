import Foundation

extension PasswordAutofillCoordinator {
    static func savePromptDetails(
        for pageURL: URL,
        username: String,
        normalizedHost: String,
        isUpdate: Bool,
        protection: CredentialVault.Protection = .legacyKeychain
    ) -> PasswordSavePromptDetails {
        let accountLabel = username.isEmpty ? normalizedHost : username
        let isInsecurePage = pageURL.scheme?.localizedCaseInsensitiveCompare("http") == .orderedSame

        if isInsecurePage {
            let actionTitle = isUpdate ? "Update Password on Insecure Page" : "Save Password on Insecure Page"
            let buttonTitle = isUpdate ? "Update Anyway" : "Save Anyway"
            let actionVerb = isUpdate ? "update" : "save"
            return PasswordSavePromptDetails(
                title: actionTitle,
                message: "This page uses an insecure connection (http://), so other people on the network may be able to read the password. Do you still want to \(actionVerb) the password for \(accountLabel)?",
                confirmButtonTitle: buttonTitle,
                neverButtonTitle: "Never on This Site",
                showsSecurityWarning: true,
                protectionNote: protection.userFacingDescription
            )
        }

        let title = isUpdate ? "Update Password" : "Save Password"
        let message = isUpdate
            ? "Update the saved password for \(accountLabel)?"
            : "Save the password for \(accountLabel)?"

        return PasswordSavePromptDetails(
            title: title,
            message: message,
            confirmButtonTitle: title,
            neverButtonTitle: "Never on This Site",
            showsSecurityWarning: false,
            protectionNote: protection.userFacingDescription
        )
    }

    static func resolveSuggestions(
        for focus: PasswordBridgeFocusPayload,
        matchingEntries: [SavedPasswordSummary],
        emailSuggestions: [PasswordEmailSuggestion],
        generatedPassword: String?
    ) -> PasswordAutofillOverlayState {
        let savedPasswordEntries: [SavedPasswordSummary]
        let filteredEmailSuggestions: [PasswordEmailSuggestion]
        let filteredGeneratedPassword: String?

        switch (focus.action, focus.fieldKind) {
        case (.createAccount, .password):
            savedPasswordEntries = []
            filteredEmailSuggestions = []
            filteredGeneratedPassword = generatedPassword
        case (.createAccount, .email):
            savedPasswordEntries = []
            filteredEmailSuggestions = emailSuggestions
            filteredGeneratedPassword = nil
        case (.createAccount, .username):
            savedPasswordEntries = []
            filteredEmailSuggestions = []
            filteredGeneratedPassword = nil
        case (.login, _):
            savedPasswordEntries = matchingEntries
            filteredEmailSuggestions = []
            filteredGeneratedPassword = nil
        }

        return PasswordAutofillOverlayState(
            focus: focus,
            savedPasswordEntries: savedPasswordEntries,
            emailSuggestions: filteredEmailSuggestions,
            generatedPassword: filteredGeneratedPassword,
            selectedSuggestionIndex: (savedPasswordEntries.isEmpty && filteredEmailSuggestions
                .isEmpty && filteredGeneratedPassword == nil) ? -1 : 0
        )
    }
}
