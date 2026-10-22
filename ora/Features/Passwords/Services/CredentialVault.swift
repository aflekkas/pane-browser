// spec: §7; corrections to the old plan are intentional (see CredentialVaultBackend.swift).
import Foundation
import LocalAuthentication
import Security

struct StoredCredential: Sendable, Equatable {
    let origin: String
    let username: String
    let profileID: String
    var protection: CredentialVault.Protection = .unknown
    var accessibility: String?
    var hasAccessControl = false

    var protectionDescription: String {
        guard protection == .dataProtection else { return protection.userFacingDescription }
        let accessibilityText = accessibility == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
            ? "WhenUnlockedThisDeviceOnly" : "accessibility not verified"
        return "Data protection keychain: \(accessibilityText); "
            + (hasAccessControl ? "item access control present." : "no item access control reported.")
    }
}

enum VaultError: Error {
    case keychain(OSStatus)
    case accessControl(String)
    case userCancelled
    case notFound
    case invalidCredential
}

final class CredentialVault {
    static let defaultService = "com.aflekkas.pane.vault"
    let service: String
    private let backend: CredentialVaultKeychainBackend
    private let lock = NSRecursiveLock()
    private var selectedProtection: Swift.Result<Protection, Error>?

    init(
        backend: CredentialVaultKeychainBackend = KeychainCredentialVaultBackend(),
        service: String = CredentialVault.defaultService
    ) {
        self.backend = backend
        self.service = service
    }

    /// Capability for NEW items only. An update preserves the existing item's backend and ACL.
    var protection: Protection {
        lock.lock()
        defer { lock.unlock() }
        return (try? writeProtection()) ?? .unavailable
    }

    private func writeProtection() throws -> Protection {
        if let selectedProtection {
            return try selectedProtection.get()
        }
        let result = Swift.Result { try probeProtection() }
        selectedProtection = result
        return try result.get()
    }

    private func probeProtection() throws -> Protection {
        guard let control = backend.makeUserPresenceAccessControl().control else {
            throw VaultError.accessControl("Unable to create user-presence access control")
        }
        // A unique identity, never a delete-before-add and never a user credential.
        let probeID = UUID().uuidString
        let identity = query(
            dataProtection: true,
            origin: "https://probe.invalid",
            username: probeID,
            profileID: probeID
        )
        var probe = identity
        probe[kSecAttrAccessControl as String] = control
        probe[kSecValueData as String] = Data(probeID.utf8)
        let status = backend.addItem(probe)
        if status == errSecMissingEntitlement {
            return .legacyKeychain
        }
        try check(status)
        // A failed cleanup is an error, not evidence of a weaker security capability.
        try check(backend.deleteItem(identity))
        return .userPresence
    }

    /// Atomic update: failure/cancellation preserves the old item. Updating an ACL item MAY prompt.
    /// This deliberately corrects the old spec's unsafe delete/add/no-prompt requirement.
    func save(origin: String, username: String, password: String, profileID: String, insertOnly: Bool = false) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let url = URL(string: origin), Self.originKey(for: url) == origin, !username.isEmpty else {
            throw VaultError.invalidCredential
        }
        let existing = try locations(origin: origin, username: username, profileID: profileID)
        guard existing.count <= 1 else { throw VaultError.keychain(errSecDuplicateItem) }
        if let location = existing.first {
            guard !insertOnly else { throw VaultError.keychain(errSecDuplicateItem) }
            let identity = query(dataProtection: location, origin: origin, username: username, profileID: profileID)
            try check(backend.updateItem(identity, attributes: [kSecValueData as String: Data(password.utf8)]))
            return
        }
        let protection = try writeProtection()
        var item = query(
            dataProtection: protection == .userPresence,
            origin: origin,
            username: username,
            profileID: profileID
        )
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrLabel as String] = profileID // display only, never identity
        if protection == .userPresence {
            guard let control = backend.makeUserPresenceAccessControl().control else {
                throw VaultError.accessControl("Unable to create user-presence access control")
            }
            item[kSecAttrAccessControl as String] = control
        }
        // Add, including a racing duplicate, never falls back to replacement.
        try check(backend.addItem(item))
    }

    func password(
        origin: String,
        username: String,
        profileID: String,
        reason: String,
        context: LAContext? = nil
    ) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        let locations = try locations(origin: origin, username: username, profileID: profileID)
        guard locations.count == 1, let location = locations.first else { throw VaultError.notFound }
        var request = query(dataProtection: location, origin: origin, username: username, profileID: profileID)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        let authentication = context ?? LAContext()
        authentication.localizedReason = reason
        request[kSecUseAuthenticationContext as String] = authentication
        let (status, data) = backend.copySecret(request)
        try check(status)
        guard let data, let password = String(data: data, encoding: .utf8) else { throw VaultError.notFound }
        return password
    }

    func contains(origin: String, username: String, profileID: String) -> Bool {
        credentials(origin: origin, profileID: profileID).contains { $0.username == username }
    }

    func credentials(origin: String, profileID: String) -> [StoredCredential] {
        list(origin: origin, profileID: profileID)
    }

    func all(profileID: String) -> [StoredCredential] {
        list(profileID: profileID)
    }

    func allCredentials() -> [StoredCredential] {
        list()
    }

    private func list(origin: String? = nil, profileID: String? = nil) -> [StoredCredential] {
        lock.lock()
        defer { lock.unlock() }
        return [false, true].flatMap { location -> [StoredCredential] in
            let request = query(dataProtection: location, origin: origin, profileID: profileID)
            guard let attributes = try? attributes(request, allowMissingEntitlement: location) else { return [] }
            return attributes.compactMap { item -> StoredCredential? in
                guard let origin = item[kSecAttrServer as String] as? String,
                      let username = item[kSecAttrAccount as String] as? String,
                      let path = item[kSecAttrPath as String] as? String,
                      path.hasPrefix(Self.profilePathPrefix),
                      let data = Data(base64Encoded: String(path.dropFirst(Self.profilePathPrefix.count))),
                      let profileID = String(data: data, encoding: .utf8) else { return nil }
                return StoredCredential(
                    origin: origin,
                    username: username,
                    profileID: profileID,
                    protection: location ? .dataProtection : .legacyKeychain,
                    accessibility: item[kSecAttrAccessible as String] as? String,
                    hasAccessControl: item[kSecAttrAccessControl as String] != nil
                )
            }
        }
    }

    @discardableResult
    func delete(origin: String, username: String, profileID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        do {
            let locations = try locations(origin: origin, username: username, profileID: profileID)
            guard locations.count <= 1 else { return false }
            for location in locations {
                try check(backend.deleteItem(query(
                    dataProtection: location,
                    origin: origin,
                    username: username,
                    profileID: profileID
                )))
            }
            return true
        } catch { return false }
    }

    private func locations(origin: String, username: String, profileID: String) throws -> [Bool] {
        try [false, true].filter { location in
            let items = try attributes(
                query(
                    dataProtection: location,
                    origin: origin,
                    username: username,
                    profileID: profileID
                ),
                allowMissingEntitlement: location
            )
            guard items.count <= 1 else { throw VaultError.keychain(errSecDuplicateItem) }
            return !items.isEmpty
        }
    }

    private func attributes(_ identity: [String: Any], allowMissingEntitlement: Bool) throws -> [[String: Any]] {
        var request = identity
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitAll
        let (status, items) = backend.copyItems(request)
        if status == errSecItemNotFound || (allowMissingEntitlement && status == errSecMissingEntitlement) {
            return []
        }
        try check(status)
        return items
    }

    private static let profilePathPrefix = "/pane-vault-v2/profile/"

    /// Apple Internet Password primary key includes security domain AND path; service is unsupported,
    /// label is not unique. Use the namespace as security domain and profile as path on EVERY operation.
    /// https://developer.apple.com/documentation/security/ksecclassinternetpassword
    private func query(
        dataProtection: Bool,
        origin: String? = nil,
        username: String? = nil,
        profileID: String? = nil
    ) -> [String: Any] {
        var result: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrSecurityDomain as String: service,
            kSecUseDataProtectionKeychain as String: dataProtection
        ]
        if dataProtection {
            result[kSecAttrSynchronizable as String] = false
        }
        if let origin {
            result[kSecAttrServer as String] = origin
        }
        if let username {
            result[kSecAttrAccount as String] = username
        }
        if let profileID {
            result[kSecAttrPath as String] = Self.profilePathPrefix + Data(profileID.utf8).base64EncodedString()
        }
        return result
    }

    private func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess: return
        case errSecUserCanceled, errSecAuthFailed: throw VaultError.userCancelled
        case errSecItemNotFound: throw VaultError.notFound
        default: throw VaultError.keychain(status)
        }
    }

    /// Scheme + host + effective port. Only HTTP loopback is exempt from HTTPS; never FTP loopback.
    static func originKey(for url: URL) -> String? {
        guard let rawHost = url.host, !rawHost.isEmpty,
              let scheme = url.scheme?.lowercased(), url.user == nil, url.password == nil else { return nil }
        let host = PasswordOriginNormalization.normalizeHost(rawHost)
        let loopback = host == "localhost" || host == "127.0.0.1"
        guard !host.isEmpty, scheme == "https" || (scheme == "http" && loopback) else { return nil }
        let defaultPort = scheme == "https" ? 443 : 80
        let port = url.port ?? defaultPort
        guard (1 ... 65535).contains(port) else { return nil }
        return "\(scheme)://\(host)" + (port == defaultPort ? "" : ":\(port)")
    }
}

enum PasswordOriginNormalization {
    static func normalizeHost(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}
