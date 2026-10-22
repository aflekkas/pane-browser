import AppKit
import Foundation

final class PasswordAutofillCoordinator {
    weak var tab: Tab?

    let passwordManager: PasswordManagerService
    let providers = PasswordManagerProviderRegistry.shared
    let settings = SettingsStore.shared
    private let decoder = JSONDecoder()
    private let operations: PasswordAutofillOperations

    private var dismissWorkItem: DispatchWorkItem?

    init(
        tab: Tab,
        passwordManager: PasswordManagerService = .shared,
        authenticate: @escaping @Sendable (String) async -> Bool = PasswordAutofillOperations.live.authenticate,
        revealPassword: @escaping @Sendable (SavedPasswordSummary) throws -> String = PasswordAutofillOperations.live
            .revealPassword,
        markUsed: @escaping @Sendable (SavedPasswordSummary) -> Void = PasswordAutofillOperations.live.markUsed
    ) {
        self.tab = tab
        self.passwordManager = passwordManager
        operations = PasswordAutofillOperations(
            authenticate: authenticate,
            revealPassword: revealPassword,
            markUsed: markUsed
        )
    }

    func handleMessage(_ messageBody: String, pageURL: URL?) {
        guard let data = messageBody.data(using: .utf8),
              let message = try? decoder.decode(PasswordBridgeEvent.self, from: data)
        else {
            return
        }

        // The payload's hostname is page-supplied and untrusted. It must
        // match the host WebKit natively reports for the page; a mismatch
        // means a forged or stale (pre-navigation) message — drop it whole.
        let payloadHostname = message.focus?.hostname ?? message.submit?.hostname
        if let payloadHostname {
            guard let pageURL,
                  let nativeHost = PasswordManagerService.normalizedHost(from: pageURL),
                  payloadHostname.lowercased() == nativeHost
            else {
                return
            }
        }

        switch message.type {
        case "focus":
            dismissWorkItem?.cancel()
            if let focus = message.focus {
                presentOverlay(for: focus, pageURL: pageURL)
            }
        case "blur":
            scheduleDismissOverlay()
        case "rect":
            if let fieldID = message.fieldID, let rect = message.rect {
                updateOverlayRect(for: fieldID, rect: rect)
            }
        case "keyCommand":
            if let command = message.keyCommand {
                handleKeyCommand(command)
            }
        case "submit":
            clearAutofillState()
            if let submit = message.submit {
                handleSubmit(submit, pageURL: pageURL)
            }
        default:
            break
        }
    }

    func dismissOverlay() {
        dismissWorkItem?.cancel()
        tab?.passwordOverlayState = nil
        setOverlayKeyboardActive(false)
    }

    func clearAutofillState() {
        dismissWorkItem?.cancel()
        tab?.passwordOverlayState = nil
        tab?.passwordTriggerOverlayState = nil
        setOverlayKeyboardActive(false)
    }

    func presentTriggerOverlay() {
        dismissWorkItem?.cancel()
        guard let overlay = tab?.passwordTriggerOverlayState else { return }
        tab?.passwordOverlayState = overlay
        setOverlayKeyboardActive(true)
    }

    @discardableResult
    func autofill(
        _ entry: SavedPasswordSummary,
        for overlay: PasswordAutofillOverlayState
    ) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }

            let authenticated = await operations.authenticate(
                "Autofill the saved password for \(entry.displayUsername) on \(entry.host)"
            )
            guard authenticated else { return }
            await MainActor.run {
                // Revalidate BEFORE reading a secret as well as before dispatching it.
                guard self.isFillContextValid(for: overlay),
                      let password = try? self.operations.revealPassword(entry),
                      self.isFillContextValid(for: overlay)
                else {
                    self.clearAutofillState()
                    return
                }
                let request = PasswordFillRequest(
                    usernameFieldID: overlay.focus.usernameFieldID,
                    passwordFieldIDs: overlay.focus.passwordFieldIDs,
                    username: entry.username.isEmpty ? nil : entry.username,
                    password: password,
                    highlightColor: "#E8F5E9",
                    submitAfterFill: overlay.focus.action == .login && self.settings.passwordAutofillSubmitEnabled,
                    documentToken: overlay.fillContext?.documentToken ?? ""
                )

                self.evaluate(scriptMethod: "fillCredentials", payload: request)
                self.operations.markUsed(entry)
                self.dismissOverlay()
            }
        }
    }

    func fillGeneratedPassword(for overlay: PasswordAutofillOverlayState) {
        guard isFillContextValid(for: overlay) else {
            clearAutofillState()
            return
        }
        guard let generatedPassword = overlay.generatedPassword else {
            return
        }

        guard tab?.browserPage != nil else {
            return
        }

        let request = PasswordFillRequest(
            usernameFieldID: nil,
            passwordFieldIDs: overlay.focus.passwordFieldIDs,
            username: nil,
            password: generatedPassword,
            highlightColor: "#FFF4CC",
            submitAfterFill: false,
            documentToken: overlay.fillContext?.documentToken ?? ""
        )

        evaluate(scriptMethod: "fillCredentials", payload: request)
        dismissOverlay()
    }

    func fillEmailSuggestion(_ suggestion: PasswordEmailSuggestion, for overlay: PasswordAutofillOverlayState) {
        guard isFillContextValid(for: overlay) else {
            clearAutofillState()
            return
        }
        guard overlay.focus.fieldKind == .email else {
            return
        }

        guard tab?.browserPage != nil else {
            return
        }

        let request = PasswordFillRequest(
            usernameFieldID: overlay.focus.fieldID,
            passwordFieldIDs: [],
            username: suggestion.email,
            password: "",
            highlightColor: "#E8F1FF",
            submitAfterFill: false,
            documentToken: overlay.fillContext?.documentToken ?? ""
        )

        evaluate(scriptMethod: "fillCredentials", payload: request)
        dismissOverlay()
    }

    @MainActor
    func openPasswordsManager() {
        openPasswordsWindow()
        dismissOverlay()
    }

    private func presentOverlay(for focus: PasswordBridgeFocusPayload, pageURL: URL?) {
        let provider = providers.descriptor(for: settings.passwordManagerProvider)
        guard settings.passwordsEnabled,
              settings.passwordAutofillEnabled,
              provider.usesBuiltInOverlay,
              tab?.isPrivate == false,
              let pageURL,
              let normalizedHost = PasswordManagerService.normalizedHost(from: pageURL),
              // Vault policy: nothing is offered on origins the vault cannot
              // key (http off loopback). The vault would return no matches
              // anyway; ending here also withholds generated-password and
              // email suggestions that imply a save will follow.
              CredentialVault.originKey(for: pageURL) != nil
        else {
            clearAutofillState()
            return
        }

        let suggestions = Self.resolveSuggestions(
            for: focus,
            matchingEntries: passwordManager.matchingEntries(for: pageURL, containerID: tab?.container.id),
            emailSuggestions: passwordManager.emailSuggestions(for: tab?.container.id),
            generatedPassword: focus.action == .createAccount ? passwordManager.generateStrongPassword() : nil
        )

        guard !suggestions.savedPasswordEntries.isEmpty
            || !suggestions.emailSuggestions.isEmpty
            || suggestions.generatedPassword != nil
        else {
            clearAutofillState()
            return
        }

        let overlayState = PasswordAutofillOverlayState(
            focus: PasswordBridgeFocusPayload(
                fieldID: focus.fieldID,
                hostname: normalizedHost,
                action: focus.action,
                fieldKind: focus.fieldKind,
                usernameFieldID: focus.usernameFieldID,
                passwordFieldIDs: focus.passwordFieldIDs,
                rect: focus.rect
            ),
            savedPasswordEntries: suggestions.savedPasswordEntries,
            emailSuggestions: suggestions.emailSuggestions,
            generatedPassword: suggestions.generatedPassword,
            selectedSuggestionIndex: suggestions.selectedSuggestionIndex,
            fillContext: tab?.browserPage?.currentPasswordContext()
        )

        tab?.passwordTriggerOverlayState = overlayState
        tab?.passwordOverlayState = overlayState
        setOverlayKeyboardActive(true)
    }

    private func updateOverlayRect(for fieldID: String, rect: PasswordBridgeRect) {
        if let triggerOverlay = tab?.passwordTriggerOverlayState,
           triggerOverlay.focus.fieldID == fieldID
        {
            tab?.passwordTriggerOverlayState = overlayState(triggerOverlay, updatingRectTo: rect)
        }

        if let overlay = tab?.passwordOverlayState,
           overlay.focus.fieldID == fieldID
        {
            tab?.passwordOverlayState = overlayState(overlay, updatingRectTo: rect)
        }
    }

    private func scheduleDismissOverlay() {
        dismissWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.clearAutofillState()
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func overlayState(
        _ overlay: PasswordAutofillOverlayState,
        updatingRectTo rect: PasswordBridgeRect
    ) -> PasswordAutofillOverlayState {
        PasswordAutofillOverlayState(
            focus: PasswordBridgeFocusPayload(
                fieldID: overlay.focus.fieldID,
                hostname: overlay.focus.hostname,
                action: overlay.focus.action,
                fieldKind: overlay.focus.fieldKind,
                usernameFieldID: overlay.focus.usernameFieldID,
                passwordFieldIDs: overlay.focus.passwordFieldIDs,
                rect: rect
            ),
            savedPasswordEntries: overlay.savedPasswordEntries,
            emailSuggestions: overlay.emailSuggestions,
            generatedPassword: overlay.generatedPassword,
            selectedSuggestionIndex: overlay.selectedSuggestionIndex,
            fillContext: overlay.fillContext
        )
    }

    private func overlayState(
        _ overlay: PasswordAutofillOverlayState,
        updatingSelectionIndexTo selectionIndex: Int
    ) -> PasswordAutofillOverlayState {
        PasswordAutofillOverlayState(
            focus: overlay.focus,
            savedPasswordEntries: overlay.savedPasswordEntries,
            emailSuggestions: overlay.emailSuggestions,
            generatedPassword: overlay.generatedPassword,
            selectedSuggestionIndex: selectionIndex,
            fillContext: overlay.fillContext
        )
    }

    private func evaluate(scriptMethod: String, payload: some Encodable) {
        guard let data = try? JSONEncoder().encode(payload),
              let payloadString = String(data: data, encoding: .utf8)
        else {
            return
        }

        let script = """
        if (window.__oraPasswordManager && typeof window.__oraPasswordManager.\(scriptMethod) === 'function') {
            window.__oraPasswordManager.\(scriptMethod)(\(payloadString));
        }
        """
        tab?.evaluatePasswordJavaScript(script)
    }

    /// Exact-context re-check at fill time (called again after the async
    /// auth prompt in `autofill`): the same BrowserPage instance must still
    /// show the same document — same generation, full origin, URL, and
    /// isolated-world token — that the overlay was captured against.
    /// Clearing the overlay alone is not the guard; this equality is.
    private func isFillContextValid(for overlay: PasswordAutofillOverlayState) -> Bool {
        guard let captured = overlay.fillContext,
              let current = tab?.browserPage?.currentPasswordContext()
        else {
            return false
        }
        return captured == current
    }

    private func setOverlayKeyboardActive(_ isActive: Bool) {
        guard tab?.browserPage != nil else { return }
        evaluate(scriptMethod: "setOverlayKeyboardActive", payload: isActive)
    }
}

// MARK: - Overlay keyboard selection

extension PasswordAutofillCoordinator {
    func updateSelection(to index: Int, for overlay: PasswordAutofillOverlayState) {
        let boundedIndex = boundedSelectionIndex(index, for: overlay)
        applySelectionIndex(boundedIndex, forFieldID: overlay.focus.fieldID)
    }

    private func handleKeyCommand(_ command: PasswordAutofillKeyCommand) {
        switch command {
        case .moveUp:
            moveSelection(by: -1)
        case .moveDown:
            moveSelection(by: 1)
        case .activate:
            activateCurrentSelection()
        case .dismiss:
            dismissOverlay()
        }
    }

    func moveSelection(by delta: Int) {
        guard let overlay = tab?.passwordOverlayState else { return }
        let suggestionCount = overlay.suggestions.count
        guard suggestionCount > 0 else { return }

        let nextIndex = min(max(overlay.selectedSuggestionIndex + delta, 0), suggestionCount - 1)
        applySelectionIndex(nextIndex, forFieldID: overlay.focus.fieldID)
    }

    func activateCurrentSelection() {
        guard let overlay = tab?.passwordOverlayState,
              overlay.suggestions.indices.contains(overlay.selectedSuggestionIndex)
        else {
            return
        }

        switch overlay.suggestions[overlay.selectedSuggestionIndex] {
        case .generatedPassword:
            fillGeneratedPassword(for: overlay)
        case let .savedCredential(entry):
            autofill(entry, for: overlay)
        case let .email(suggestion):
            fillEmailSuggestion(suggestion, for: overlay)
        }
    }

    private func applySelectionIndex(_ selectionIndex: Int, forFieldID fieldID: String) {
        if let overlay = tab?.passwordOverlayState,
           overlay.focus.fieldID == fieldID
        {
            tab?.passwordOverlayState = overlayState(overlay, updatingSelectionIndexTo: selectionIndex)
        }

        if let triggerOverlay = tab?.passwordTriggerOverlayState,
           triggerOverlay.focus.fieldID == fieldID
        {
            tab?.passwordTriggerOverlayState = overlayState(triggerOverlay, updatingSelectionIndexTo: selectionIndex)
        }
    }

    private func boundedSelectionIndex(_ selectionIndex: Int, for overlay: PasswordAutofillOverlayState) -> Int {
        let suggestionCount = overlay.suggestions.count
        guard suggestionCount > 0 else { return -1 }
        return min(max(selectionIndex, 0), suggestionCount - 1)
    }
}
