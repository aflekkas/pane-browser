import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

@MainActor
func openPasswordsWindow() {
    PasswordsWindowController.shared.show()
}

@MainActor
private final class PasswordsWindowController: NSObject, NSWindowDelegate {
    static let shared = PasswordsWindowController()

    private let sharedModelContainer = try? ModelConfiguration.createOraContainer(isPrivate: false)
    private var windowController: NSWindowController?

    func show() {
        if let window = windowController?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let rootView = if let sharedModelContainer {
            AnyView(
                PasswordsWindowView()
                    .modelContainer(sharedModelContainer)
                    .withTheme()
            )
        } else {
            AnyView(
                PasswordsWindowUnavailableView()
                    .withTheme()
            )
        }

        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Passwords"
        window.minSize = CGSize(width: 960, height: 480)
        window.center()
        window.delegate = self
        window.contentViewController = hostingController
        window.setFrameAutosaveName("PasswordsWindow")

        let controller = NSWindowController(window: window)
        windowController = controller
        controller.showWindow(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === windowController?.window
        else {
            return
        }

        PasswordManagerService.shared.invalidateAuthenticatedContext()
        windowController = nil
    }
}

private struct PasswordsWindowUnavailableView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.background
                .ignoresSafeArea()

            Text("Passwords are unavailable because the shared data store could not be opened.")
                .foregroundStyle(.secondary)
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(minWidth: 960, minHeight: 480)
    }
}

struct PasswordsWindowView: View {
    @Query(sort: \TabContainer.lastAccessedAt, order: .reverse) var containers: [TabContainer]

    @Environment(\.theme) var theme
    @StateObject var passwordManager = PasswordManagerService.shared

    @State var vaultPresentation = PasswordVaultPresentation()
    @State var searchText = ""
    @State var selectedContainerId: UUID?
    @State var pendingDelete: SavedPasswordSummary?
    @State var importTask: Task<Void, Never>?
    @State var isImporting = false
    @State var importReport: CredentialImportReport?

    var selectedContainer: TabContainer? {
        containers.first { $0.id == selectedContainerId } ?? containers.first
    }

    var visibleEntries: [SavedPasswordSummary] {
        passwordManager.entries(for: selectedContainer?.id)
    }

    var filteredEntries: [SavedPasswordSummary] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return visibleEntries }

        return visibleEntries.filter { entry in
            entry.host.localizedCaseInsensitiveContains(query)
                || entry.username.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ZStack {
            theme.background
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                header

                if containers.isEmpty {
                    emptyState(message: "Create a space to start storing passwords.")
                } else if vaultPresentation.isUnlocked {
                    spacePickerRow

                    TextField("Search saved passwords", text: $searchText)
                        .textFieldStyle(.roundedBorder)

                    if filteredEntries.isEmpty {
                        emptyState(message: searchText
                            .isEmpty ? "No saved passwords yet." : "No saved passwords match that search.")
                    } else {
                        passwordsTable
                    }
                } else {
                    lockedVaultState
                }
            }
            .padding(20)
        }
        .frame(minWidth: 960, minHeight: 480)
        .onAppear {
            if selectedContainerId == nil {
                selectedContainerId = containers.first?.id
            }
        }
        .onChange(of: containers.map(\.id)) { _, containerIDs in
            guard let selectedContainerId else {
                self.selectedContainerId = containerIDs.first
                return
            }

            if !containerIDs.contains(selectedContainerId) {
                self.selectedContainerId = containerIDs.first
            }
        }
        .onDisappear {
            lockVault()
        }
        .onReceive(passwordManager.$authenticationRevision.dropFirst()) { revision in
            clearVaultState(replacement: revision)
        }
        .alert("Delete saved password?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: {
                if !$0 {
                    pendingDelete = nil
                }
            }
        )) {
            Button("Delete", role: .destructive) {
                if let pendingDelete {
                    try? passwordManager.delete(pendingDelete)
                }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            if let pendingDelete {
                Text("Remove the saved credential for \(pendingDelete.displayUsername) on \(pendingDelete.host)?")
            }
        }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved Passwords")
                        .font(.title2.weight(.semibold))
                    Text("\(visibleEntries.count) item\(visibleEntries.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if vaultPresentation.isUnlocked {
                    Button(isImporting ? "Importing…" : "Import Passwords…") {
                        importPasswords()
                    }
                    .disabled(isImporting)
                    Button("Migrate Legacy Passwords…") {
                        passwordManager.performLegacyMigrationIfNeeded()
                    }
                    .disabled(isImporting)
                    Button("Lock") {
                        lockVault()
                    }
                }
            }

            protectionStatus
            migrationNotice
            if let importReport {
                Text("Last import: \(importReport.importedCount) saved; \(importReport.skipped.count) skipped. "
                    + importReport.skipped.prefix(3).joined(separator: " "))
                    .font(.caption)
            }
        }
    }

    /// ADR 0007: the vault's actual protection is stated wherever the vault
    /// is surfaced. The degraded state is prominent, never quiet, and this
    /// view never claims Touch ID protection the probe did not confirm.
    var protectionStatus: some View {
        let protection = passwordManager.vaultProtection
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: protection == .userPresence ? "touchid" : "exclamationmark.triangle.fill")
                .foregroundStyle(protection == .userPresence ? Color.secondary : Color.orange)
            Text(protection.userFacingDescription)
                .font(.caption)
                .foregroundStyle(protection == .userPresence ? Color.secondary : Color.primary)
        }
        .padding(protection == .userPresence ? 0 : 8)
        .background(
            protection == .userPresence
                ? Color.clear
                : Color.orange.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    @ViewBuilder
    var migrationNotice: some View {
        if let report = passwordManager.lastMigrationReport, !report.isEmpty {
            Text(
                "\(report.skipped.count) skipped; \(report.failedCount) failed. Legacy passwords retained where uncertain: "
                    + report.skipped.prefix(3).joined(separator: "; ")
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    var spacePickerRow: some View {
        HStack {
            Text("Space")
                .font(.subheadline.weight(.medium))

            Spacer()

            Picker(
                "",
                selection: Binding(
                    get: { selectedContainerId ?? containers.first?.id },
                    set: { selectedContainerId = $0 }
                )
            ) {
                ForEach(containers) { container in
                    Text(containerLabel(for: container)).tag(Optional(container.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 260, alignment: .trailing)
        }
    }

    var lockedVaultState: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.fill")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(theme.mutedForeground.opacity(0.75))

            VStack(spacing: 8) {
                Text("Passwords Are Locked")
                    .font(.title3.weight(.semibold))

                Text("Use Touch ID or your Mac password to unlock your saved passwords.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            OraButton(
                label: vaultPresentation.isAuthenticating ? "Unlocking..." : "Unlock Passwords",
                variant: .outline,
                isDisabled: vaultPresentation.isAuthenticating,
                leadingIcon: passwordManager.canUseBiometricAuthentication() ? "touchid" : "lock.open"
            ) {
                unlockVault()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    func unlockVault() {
        let attempt = vaultPresentation.beginUnlock()
        Task {
            guard vaultPresentation.unlockAttempt == attempt else { return }
            let authenticated = await passwordManager.authenticate(
                reason: "Unlock your saved passwords in Pane", attemptID: attempt
            )
            await MainActor.run {
                if vaultPresentation.finishUnlock(
                    attempt: attempt, authenticated: authenticated && passwordManager.isAuthenticated
                ) {
                    passwordManager.refresh()
                }
            }
        }
    }

    func lockVault() {
        clearVaultState()
        passwordManager.invalidateAuthenticatedContext()
    }

    func clearVaultState(replacement: UUID? = nil) {
        vaultPresentation.revoke(replacement: replacement)
        importTask?.cancel()
        searchText = ""
    }

    /// File read and parsing are bounded and cancellable off the UI actor. Lock/close cancels both.
    func importPasswords() {
        guard !isImporting, let target = selectedContainer, vaultPresentation.isUnlocked else { return }
        let panel = NSOpenPanel()
        panel.message = "Choose a Safari, Chrome or 1Password export. Existing passwords are retained on conflict."
        panel.allowedContentTypes = [.commaSeparatedText, UTType(filenameExtension: "1pux") ?? .data]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let targetID = target.id
        isImporting = true
        importTask = Task { @MainActor in
            defer { isImporting = false
                importTask = nil
            }
            let parsing = Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer {
                    if scoped {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    let data = try CredentialImport.readFile(url, cancelled: { Task.isCancelled })
                    return CredentialImport.parse(
                        data,
                        filename: url.lastPathComponent,
                        cancelled: { Task.isCancelled }
                    )
                } catch {
                    return CredentialImport
                        .Result(skipped: ["File could not be read, was cancelled or exceeds limits."])
                }
            }
            let parsed = await withTaskCancellationHandler {
                await parsing.value
            } onCancel: { parsing.cancel() }
            guard !Task.isCancelled, vaultPresentation.isUnlocked, passwordManager.isAuthenticated else { return }
            importReport = await passwordManager.importCredentials(parsed: parsed, containerID: targetID)
        }
    }

    func toggleReveal(_ entry: SavedPasswordSummary) {
        if vaultPresentation.revealedPasswordIDs[entry.id] != nil {
            vaultPresentation.revealedPasswordIDs[entry.id] = nil
            return
        }

        if let password = try? passwordManager.revealPassword(for: entry) {
            vaultPresentation.revealedPasswordIDs[entry.id] = password
        }
    }

    func copyPassword(_ entry: SavedPasswordSummary) {
        if let password = try? passwordManager.revealPassword(for: entry) {
            passwordManager.copySensitiveToPasteboard(password)
        }
    }

    func containerLabel(for container: TabContainer) -> String {
        "\(container.emoji) \(container.name)"
    }
}
