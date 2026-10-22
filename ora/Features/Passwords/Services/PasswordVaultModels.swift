import Foundation

/// Metadata shape the UI and existing callers are built on. Kept stable by
/// the vault adapter: it is now assembled from the vault item's identity plus
/// the non-secret metadata sidecar (`PasswordVaultMetadata`), instead of a
/// JSON blob inside a synchronizable generic-password item.
struct SavedPasswordMetadata: Codable, Hashable {
    var id: String
    var origin: String?
    var host: String
    var username: String
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var containerID: UUID?
}

struct SavedPasswordSummary: Identifiable, Hashable {
    let metadata: SavedPasswordMetadata
    /// Opaque stable handle derived from the credential's vault identity.
    /// It is **not** a keychain persistent reference any more: vault items are
    /// addressed by (origin, username, profile), and nothing may hand this
    /// value to `SecItem*`. Kept so the type's shape — and every caller and
    /// test constructing it — is unchanged.
    let persistentReference: Data

    var id: String {
        metadata.id
    }

    var host: String {
        metadata.host
    }

    var origin: String? {
        metadata.origin
    }

    var username: String {
        metadata.username
    }

    var createdAt: Date {
        metadata.createdAt
    }

    var updatedAt: Date {
        metadata.updatedAt
    }

    var lastUsedAt: Date? {
        metadata.lastUsedAt
    }

    var containerID: UUID? {
        metadata.containerID
    }

    var displayUsername: String {
        username.isEmpty ? "No username" : username
    }
}

struct PasswordEmailSuggestion: Identifiable, Hashable {
    let email: String
    let host: String
    let lastUsedAt: Date?
    let updatedAt: Date

    var id: String {
        email.lowercased()
    }
}

/// Shared by the password window and Settings. Replacement revokes rendered secrets
/// immediately while allowing only its own initiating unlock attempt to finish.
struct PasswordVaultPresentation {
    private(set) var unlockAttempt: UUID?
    private(set) var isUnlocked = false
    private(set) var isAuthenticating = false
    var revealedPasswordIDs: [String: String] = [:]

    mutating func beginUnlock() -> UUID {
        revoke()
        let attempt = UUID()
        unlockAttempt = attempt
        isAuthenticating = true
        return attempt
    }

    mutating func revoke(replacement: UUID? = nil) {
        isUnlocked = false
        revealedPasswordIDs.removeAll()
        if replacement == nil || unlockAttempt != replacement {
            unlockAttempt = nil
            isAuthenticating = false
        }
    }

    @discardableResult
    mutating func finishUnlock(attempt: UUID, authenticated: Bool) -> Bool {
        guard unlockAttempt == attempt else { return false }
        unlockAttempt = nil
        isAuthenticating = false
        isUnlocked = authenticated
        return authenticated
    }
}
