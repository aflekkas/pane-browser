import AppKit
import Foundation
import Security

// MARK: - Private helpers

extension PasswordManagerService {
    func storedCredential(for entry: SavedPasswordSummary) throws -> StoredCredential {
        if let credential = credentialBySummaryID[entry.id] {
            return credential
        }
        // Summaries constructed outside the adapter (tests, previews): derive
        // the identity from the display fields rather than failing.
        if let origin = entry.origin,
           let url = URL(string: origin),
           let originKey = CredentialVault.originKey(for: url)
        {
            return StoredCredential(
                origin: originKey,
                username: entry.username,
                profileID: entry.containerID?.uuidString ?? ""
            )
        }
        return StoredCredential(
            origin: entry.host,
            username: entry.username,
            profileID: entry.containerID?.uuidString ?? ""
        )
    }

    func recordMigratedMetadata(_ entry: LegacyPasswordEntry, originKey: String) {
        let displayOrigin = entry.origin ?? Self.displayOrigin(forVaultOrigin: originKey)
        metadataByKey[PasswordVaultMetadata.identityKey(
            vaultOrigin: originKey,
            username: entry.username,
            profileID: entry.profileID
        )] = PasswordVaultMetadata(
            vaultOrigin: originKey,
            username: entry.username,
            profileID: entry.profileID,
            displayOrigin: displayOrigin,
            host: entry.host,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
            lastUsedAt: entry.lastUsedAt
        )
        persistMetadata()
    }

    func scopedEntries(for containerID: UUID?) -> [SavedPasswordSummary] {
        guard let containerID else {
            return entries
        }
        return entries.filter { $0.containerID == containerID }
    }

    func persistMetadata() {
        metadataStore.saveRecords(Array(metadataByKey.values))
    }

    static func summaryID(for credential: StoredCredential) -> String {
        PasswordVaultMetadata.identityKey(
            vaultOrigin: credential.origin,
            username: credential.username,
            profileID: credential.profileID
        )
    }

    static func displayOrigin(forVaultOrigin originKey: String) -> String {
        originKey
    }

    static func hostPart(ofVaultOrigin originKey: String) -> String {
        URL(string: originKey)?.host ?? originKey
    }

    static func passwordManagerError(from vaultError: VaultError) -> PasswordManagerError {
        switch vaultError {
        case let .keychain(status):
            return .keychainStatus(status)
        case .userCancelled:
            return .keychainStatus(errSecUserCanceled)
        case .notFound:
            return .invalidStoredPassword
        case .accessControl, .invalidCredential:
            return .invalidCredentialOrigin
        }
    }

    func copyToPasteboard(_ value: String, clearingAfter timeout: TimeInterval?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)

        guard let timeout else {
            return
        }

        let expectedChangeCount = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            let currentPasteboard = NSPasteboard.general
            guard currentPasteboard.changeCount == expectedChangeCount,
                  currentPasteboard.string(forType: .string) == value
            else {
                return
            }

            currentPasteboard.clearContents()
        }
    }

    static func defaultPort(for scheme: String) -> Int {
        switch scheme {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return -1
        }
    }
}

enum PasswordManagerError: LocalizedError {
    case invalidStoredPassword
    case invalidCredentialOrigin
    case emptyUsername
    case keychainStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidStoredPassword:
            return "Pane couldn't decode the stored password."
        case .invalidCredentialOrigin:
            return "Pane can only save passwords for secure (https) web origins."
        case .emptyUsername:
            return "Pane can't save a password without a username."
        case let .keychainStatus(status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return message
            }
            return "Keychain error \(status)."
        }
    }
}
