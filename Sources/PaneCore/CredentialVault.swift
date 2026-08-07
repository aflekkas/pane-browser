// spec: §7
import Foundation
import Security
import LocalAuthentication

/// spec §7 — the password vault.
///
/// **Security-critical, so nothing here is inferred.** Every attribute is the
/// one §7 names, and where a choice was open it is argued in a comment rather
/// than left to look arbitrary:
///
/// - `kSecClassInternetPassword`, one item per credential.
/// - `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — never leaves this Mac,
///   never syncs, unreadable while locked.
/// - `SecAccessControlCreateWithFlags(.userPresence)` so a **read** requires
///   Touch ID or the login password. Writes deliberately do not: prompting to
///   save a password the user just typed is friction with no security value,
///   because the secret is already in the page.
/// - `kSecAttrServer` = origin host, `kSecAttrAccount` = username,
///   `kSecAttrLabel` = profile UUID, so vaults are per-profile.
///
/// There is no way to read Safari's or the system's existing web credentials —
/// `ASSavePasswordRequest` is `API_UNAVAILABLE(macos)` and
/// `ASCredentialIdentityStore` returns only our own index. See
/// `docs/research/2026-08-07-credentials.md`.
public struct StoredCredential: Sendable, Equatable {
    public let origin: String
    public let username: String
    public let profileID: String

    public init(origin: String, username: String, profileID: String) {
        self.origin = origin
        self.username = username
        self.profileID = profileID
    }
}

public enum VaultError: Error, CustomStringConvertible {
    case keychain(OSStatus)
    case accessControl(String)
    case userCancelled
    case notFound

    public var description: String {
        switch self {
        case .keychain(let s):
            let msg = SecCopyErrorMessageString(s, nil) as String? ?? "unknown"
            return "keychain error \(s): \(msg)"
        case .accessControl(let m): return "access control: \(m)"
        case .userCancelled: return "cancelled by the user"
        case .notFound: return "no such credential"
        }
    }
}

public struct CredentialVault: Sendable {
    /// Namespaced so vault items are never confused with anything else this
    /// app or another might store.
    static let service = "com.aflekkas.pane.vault"

    /// How strongly items are actually protected **right now**.
    ///
    /// `SecAccessControl(.userPresence)` and the data-protection keychain both
    /// require `keychain-access-groups`, which needs a real signing identity —
    /// ad-hoc signing is rejected with `errSecMissingEntitlement (-34018)`,
    /// measured on this host. So a development build genuinely cannot gate
    /// reads on Touch ID.
    ///
    /// The response is to make that **loud**, not to degrade silently. A vault
    /// the user believes is biometrically protected but is not is worse than
    /// one that says so.
    public enum Protection: String, Sendable {
        /// Reads require Touch ID / Watch / login password. Requires signing.
        case userPresence
        /// Readable by this app whenever the Mac is unlocked. No biometric
        /// gate. Development only — the UI must say so.
        case deviceUnlockedOnly
    }

    /// Probed once, by attempting a real access-controlled write to a throwaway
    /// item. Asking the keychain is the only reliable answer; inspecting the
    /// binary's entitlements would not tell you whether the OS honours them.
    public static let availableProtection: Protection = {
        var err: Unmanaged<CFError>?
        guard let ac = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &err) else {
            return .deviceUnlockedOnly
        }
        let probe: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: "pane-protection-probe.invalid",
            kSecAttrAccount as String: "probe",
            kSecAttrService as String: CredentialVault.service,
            kSecAttrAccessControl as String: ac,
            kSecValueData as String: Data("probe".utf8),
        ]
        SecItemDelete(probe as CFDictionary)
        let status = SecItemAdd(probe as CFDictionary, nil)
        SecItemDelete(probe as CFDictionary)
        return status == errSecSuccess ? .userPresence : .deviceUnlockedOnly
    }()

    public init() {}

    // MARK: - Write

    /// Saving does **not** require Touch ID. The user just typed the secret
    /// into the page; demanding biometrics to store it adds friction and
    /// protects nothing that is not already exposed.
    public func save(origin: String, username: String, password: String,
                     profileID: String) throws {
        guard !origin.isEmpty, !username.isEmpty else { throw VaultError.notFound }

        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: origin,
            kSecAttrAccount as String: username,
            kSecAttrLabel as String: profileID,
            kSecAttrService as String: Self.service,
            kSecValueData as String: Data(password.utf8),
        ]

        if Self.availableProtection == .userPresence {
            var error: Unmanaged<CFError>?
            // .userPresence = Touch ID, Watch, or the login password. NOT
            // .biometryCurrentSet: that invalidates every item the moment the
            // user adds a fingerprint, which would silently destroy the vault.
            guard let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &error) else {
                throw VaultError.accessControl(
                    (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "unknown")
            }
            query[kSecAttrAccessControl as String] = access
        } else {
            // Degraded, and the UI says so. Still device-only and still
            // unreadable while locked — just not biometrically gated.
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        // Deleting first rather than SecItemUpdate: updating an item guarded by
        // an access control would prompt for Touch ID to read the old value,
        // and a password change should not require authentication.
        SecItemDelete(deleteQuery(origin: origin, username: username, profileID: profileID) as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        query.removeAll()
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }

    // MARK: - Read

    /// Reading **does** require Touch ID — this is the point of the vault.
    /// `context` is passed so a caller can present one prompt for a batch
    /// rather than one per item.
    public func password(origin: String, username: String, profileID: String,
                         reason: String, context: LAContext? = nil) throws -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: origin,
            kSecAttrAccount as String: username,
            kSecAttrLabel as String: profileID,
            kSecAttrService as String: Self.service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseOperationPrompt as String: reason,
        ]
        if let context { query[kSecUseAuthenticationContext as String] = context }

        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        switch status {
        case errSecSuccess:
            guard let data = out as? Data, let s = String(data: data, encoding: .utf8) else {
                throw VaultError.notFound
            }
            return s
        case errSecUserCanceled, errSecAuthFailed:
            throw VaultError.userCancelled
        case errSecItemNotFound:
            throw VaultError.notFound
        default:
            throw VaultError.keychain(status)
        }
    }

    /// Listing does NOT return secrets and therefore does NOT prompt. The
    /// autofill popover needs to show which usernames exist before the user has
    /// chosen one; prompting to render a menu would be absurd.
    public func credentials(origin: String, profileID: String) -> [StoredCredential] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: origin,
            kSecAttrLabel as String: profileID,
            kSecAttrService as String: Self.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { attrs in
            guard let account = attrs[kSecAttrAccount as String] as? String else { return nil }
            return StoredCredential(origin: origin, username: account, profileID: profileID)
        }
    }

    /// Every credential in a profile, for the management UI. Attributes only.
    public func all(profileID: String) -> [StoredCredential] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrLabel as String: profileID,
            kSecAttrService as String: Self.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { attrs in
            guard let account = attrs[kSecAttrAccount as String] as? String,
                  let server = attrs[kSecAttrServer as String] as? String else { return nil }
            return StoredCredential(origin: server, username: account, profileID: profileID)
        }
    }

    @discardableResult
    public func delete(origin: String, username: String, profileID: String) -> Bool {
        let status = SecItemDelete(
            deleteQuery(origin: origin, username: username, profileID: profileID) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func deleteQuery(origin: String, username: String, profileID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: origin,
            kSecAttrAccount as String: username,
            kSecAttrLabel as String: profileID,
            kSecAttrService as String: Self.service,
        ]
    }

    /// The origin key. **Host only, and scheme is checked by the caller**:
    /// a credential saved on https must never be offered to the same host over
    /// http, because an attacker who can serve plaintext could then harvest it.
    public static func originKey(for url: URL) -> String? {
        guard let host = url.host, url.scheme == "https" || host == "127.0.0.1" || host == "localhost"
        else { return nil }
        if let port = url.port, port != 443 { return "\(host):\(port)" }
        return host
    }
}
