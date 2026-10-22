import AppKit
import Foundation
import LocalAuthentication
import Security

extension PasswordManagerService {
    func generateStrongPassword() -> String {
        Self.generateStrongPassword()
    }

    static func generateStrongPassword() -> String {
        if #available(macOS 11.0, *),
           let generated = SecCreateSharedWebCredentialPassword() as String?
        {
            return generated
        }

        let uppercase = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
        let lowercase = Array("abcdefghijkmnopqrstuvwxyz")
        let digits = Array("3456789")
        let symbols = Array("!@#$%^&*")
        let allCharacters = uppercase + lowercase + digits + symbols

        var password = [
            uppercase.randomElement(),
            lowercase.randomElement(),
            digits.randomElement(),
            symbols.randomElement()
        ].compactMap { $0 }

        while password.count < 20 {
            if let character = allCharacters.randomElement() {
                password.append(character)
            }
        }

        return String(password.shuffled())
    }

    func canUseBiometricAuthentication() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    func currentAccountDisplayName() -> String {
        NSFullUserName()
    }

    static func normalizeHost(_ host: String) -> String {
        PasswordOriginNormalization.normalizeHost(host)
    }

    static func normalizedHost(from url: URL) -> String? {
        guard let host = url.host, !host.isEmpty else {
            return nil
        }
        return normalizeHost(host)
    }

    /// Full display origin (`scheme://host[:port]`), for both http and https.
    /// Display/matching helper only — whether an origin may be stored or
    /// offered is `CredentialVault.originKey`'s decision, not this one's.
    static func normalizedOrigin(from url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = normalizedHost(from: url)
        else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host

        if let port = url.port, port != defaultPort(for: scheme) {
            components.port = port
        }

        return components.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func looksLikeEmail(_ value: String) -> Bool {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty,
              let atIndex = trimmedValue.firstIndex(of: "@")
        else {
            return false
        }

        let localPart = trimmedValue[..<atIndex]
        let domainStart = trimmedValue.index(after: atIndex)
        guard domainStart < trimmedValue.endIndex else {
            return false
        }

        let domainPart = trimmedValue[domainStart...]
        return !localPart.isEmpty
            && domainPart.contains(".")
            && !domainPart.hasPrefix(".")
            && !domainPart.hasSuffix(".")
    }
}
