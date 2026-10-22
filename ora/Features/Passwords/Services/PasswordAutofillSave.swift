import AppKit
import Foundation

extension PasswordAutofillCoordinator {
    func handleSubmit(_ payload: PasswordBridgeSubmitPayload, pageURL: URL?) {
        let provider = providers.descriptor(for: settings.passwordManagerProvider)
        guard settings.passwordsEnabled,
              settings.passwordSavePromptsEnabled,
              provider.usesBuiltInVault,
              tab?.isPrivate == false,
              let pageURL,
              let normalizedHost = PasswordManagerService.normalizedHost(from: pageURL)
        else {
            return
        }

        guard settings.allowsPasswordSavePrompts(for: normalizedHost) else {
            return
        }

        // Vault policy: http (off loopback) gets no save prompt and no save.
        // The insecure-page warning copy in `savePromptDetails` stays for
        // compatibility, but under this policy it is unreachable from here —
        // there is no "Save Anyway" into the vault.
        guard CredentialVault.originKey(for: pageURL) != nil else {
            return
        }

        let trimmedUsername = payload.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = payload.password

        guard payload.action == .login || payload.action == .createAccount,
              !password.isEmpty
        else {
            return
        }

        let matchingEntry = passwordManager
            .matchingEntries(for: pageURL, containerID: tab?.container.id)
            .first { $0.username == trimmedUsername }

        // Existence decides save-vs-update, not a secret comparison: reading
        // the stored password to compare would demand Touch ID (the item's
        // access control) on every login submit. Pane's flow accepts the
        // occasional redundant "Update" prompt as the price of never reading
        // a secret the user did not ask to use.
        let prompt = Self.savePromptDetails(
            for: pageURL,
            username: trimmedUsername,
            normalizedHost: normalizedHost,
            isUpdate: matchingEntry != nil,
            protection: passwordManager.vaultProtection
        )

        let containerID = tab?.container.id
        let saveAction: () -> Void = {
            _ = try? self.passwordManager.upsertCredential(
                for: pageURL,
                username: trimmedUsername,
                password: password,
                containerID: containerID
            )
        }

        Task { @MainActor [weak self] in
            self?.presentSavePrompt(
                prompt,
                normalizedHost: normalizedHost,
                saveAction: saveAction
            )
        }
    }

    @MainActor
    private func presentSavePrompt(
        _ prompt: PasswordSavePromptDetails,
        normalizedHost: String,
        saveAction: @escaping () -> Void
    ) {
        guard let window = presentationWindow() else {
            return
        }

        let alert = NSAlert()
        alert.alertStyle = prompt.showsSecurityWarning ? .warning : .informational
        alert.messageText = prompt.title
        alert.informativeText = prompt.protectionNote.isEmpty
            ? prompt.message
            : "\(prompt.message)\n\n\(prompt.protectionNote)"
        alert.addButton(withTitle: prompt.confirmButtonTitle)
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: prompt.neverButtonTitle)
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn:
                saveAction()
            case .alertThirdButtonReturn:
                self.settings.suppressPasswordSavePrompts(for: normalizedHost)
            default:
                break
            }
        }
    }

    @MainActor
    private func presentationWindow() -> NSWindow? {
        if let window = tab?.pageWindow {
            return window
        }

        if let appDelegate = NSApp.delegate as? AppDelegate {
            return appDelegate.getWindow()
        }

        return NSApp.keyWindow
            ?? NSApp.windows.first(where: { $0.isVisible })
            ?? NSApp.windows.first
    }
}
