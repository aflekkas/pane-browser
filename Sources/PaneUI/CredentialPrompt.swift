// spec: §7
import AppKit
import PaneCore

/// spec §7 — the native save prompt and the autofill picker.
///
/// spec §1 — AppKit. Never rendered into the page: a credential UI drawn by the
/// renderer could be forged by the page it is protecting the user from.
@MainActor
public enum CredentialPrompt {

    /// Offered after a submit when the credential is new or changed. Never on
    /// every submit — being asked to save the same password repeatedly is how
    /// users learn to dismiss the prompt without reading it.
    public static func offerToSave(origin: String, username: String,
                                   isUpdate: Bool, window: NSWindow?) -> Bool {
        let alert = NSAlert()
        alert.messageText = isUpdate
            ? "Update the saved password for \(origin)?"
            : "Save this password for \(origin)?"

        var body = "Username: \(username)"
        // The protection level is stated at the moment of the decision, not
        // buried in a settings pane. If reads are not gated by Touch ID the
        // user is entitled to know that BEFORE they hand over a secret
        // (ADR 0007).
        if CredentialVault.availableProtection == .deviceUnlockedOnly {
            body += "\n\nThis build cannot use Touch ID — saved passwords are "
                + "readable by Pane whenever your Mac is unlocked. They stay on "
                + "this Mac and are never synced."
        } else {
            body += "\n\nReading it later will require Touch ID."
        }
        alert.informativeText = body
        alert.addButton(withTitle: isUpdate ? "Update" : "Save")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Never for This Site")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The picker, when more than one credential exists for an origin. With
    /// exactly one, the caller fills directly — a menu of one is a speed bump.
    public static func chooseCredential(_ options: [StoredCredential],
                                        origin: String) -> StoredCredential? {
        guard options.count > 1 else { return options.first }
        let alert = NSAlert()
        alert.messageText = "Sign in to \(origin)"
        alert.informativeText = "Choose an account."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        popup.addItems(withTitles: options.map(\.username))
        alert.accessoryView = popup
        alert.addButton(withTitle: "Fill")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let i = popup.indexOfSelectedItem
        return i >= 0 && i < options.count ? options[i] : nil
    }
}
