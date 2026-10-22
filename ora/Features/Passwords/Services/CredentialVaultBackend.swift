import Foundation
import Security

protocol CredentialVaultKeychainBackend {
    func addItem(_ query: [String: Any]) -> OSStatus
    func updateItem(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func copyItems(_ query: [String: Any]) -> (status: OSStatus, items: [[String: Any]])
    func copySecret(_ query: [String: Any]) -> (status: OSStatus, data: Data?)
    func deleteItem(_ query: [String: Any]) -> OSStatus
    func makeUserPresenceAccessControl() -> (control: SecAccessControl?, error: String?)
}

struct KeychainCredentialVaultBackend: CredentialVaultKeychainBackend {
    func addItem(_ query: [String: Any]) -> OSStatus {
        SecItemAdd(query as CFDictionary, nil)
    }

    func updateItem(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func copyItems(_ query: [String: Any]) -> (status: OSStatus, items: [[String: Any]]) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? [[String: Any]] ?? [])
    }

    func copySecret(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func deleteItem(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }

    func makeUserPresenceAccessControl() -> (control: SecAccessControl?, error: String?) {
        var error: Unmanaged<CFError>?
        let control = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &error
        )
        return (control, (error?.takeRetainedValue() as Error?)?.localizedDescription)
    }
}

extension CredentialVault {
    /// Corrects ADR 0007: WhenUnlockedThisDeviceOnly does not protect file-keychain items.
    /// TN3137 distinguishes the backends. Only missing entitlement permits the explicit legacy fallback.
    /// https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains
    /// https://developer.apple.com/documentation/security/ksecattraccessible
    enum Protection: String, Sendable {
        case userPresence
        case legacyKeychain
        case dataProtection
        case unknown
        case unavailable

        var userFacingDescription: String {
            switch self {
            case .userPresence:
                return "New passwords use user-presence protection (Touch ID or your Mac password). "
                    + "Existing passwords keep their original protection. Updates may request authentication."
            case .legacyKeychain:
                return "Legacy macOS keychain: no per-item Touch ID guarantee. Access follows keychain lock and ACL "
                    + "settings, not screen lock. Pane does not enable sync; device-only backup protection is not guaranteed."
            case .dataProtection:
                return "Stored in the data protection keychain. Existing per-item authentication requirements apply."
            case .unknown:
                return "Stored protection is unknown."
            case .unavailable:
                return "Keychain protection could not be established. New passwords cannot be saved."
            }
        }
    }
}
