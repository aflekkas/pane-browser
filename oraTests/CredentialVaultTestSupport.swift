import Foundation
import LocalAuthentication
@testable import Ora
import Security

/// Models Apple's composite Internet Password primary key, not the vault's query dictionary.
/// Unsupported service is rejected; label is filterable but deliberately excluded from identity.
final class InMemoryVaultBackend: CredentialVaultKeychainBackend {
    struct Item { var attributes: [String: Any]
        var data: Data?
    }

    var items: [Item] = []
    var adds: [[String: Any]] = []
    var updates = 0
    var deletes = 0
    var secretReads = 0
    var listCalls = 0
    var addStatus: OSStatus = errSecSuccess
    var updateStatus: OSStatus = errSecSuccess
    var deleteStatus: OSStatus = errSecSuccess
    var readStatus: OSStatus = errSecSuccess
    var listStatus: OSStatus = errSecSuccess
    var dataProtectionStatus: OSStatus = errSecSuccess
    var corruptNextSecret = false
    var makeControlFails = false
    var beforeRead: (() -> Void)?

    private let identityKeys = [
        kSecClass,
        kSecAttrAccount,
        kSecAttrSecurityDomain,
        kSecAttrServer,
        kSecAttrProtocol,
        kSecAttrAuthenticationType,
        kSecAttrPort,
        kSecAttrPath,
        kSecAttrAccessGroup,
        kSecAttrSynchronizable,
        kSecUseDataProtectionKeychain
    ]
    .map { $0 as String }

    private func value(_ key: String, _ attributes: [String: Any]) -> String {
        if key == kSecAttrSynchronizable as String || key == kSecUseDataProtectionKeychain as String {
            return (attributes[key] as? Bool ?? false) ? "1" : "0"
        }
        return attributes[key].map { String(describing: $0) } ?? ""
    }

    private func identical(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        identityKeys.allSatisfy { value($0, lhs) == value($0, rhs) }
    }

    private func matches(_ item: Item, _ query: [String: Any]) -> Bool {
        let filters = identityKeys + [kSecAttrLabel as String]
        return filters.allSatisfy { query[$0] == nil || value($0, item.attributes) == value($0, query) }
    }

    private func validate(_ query: [String: Any]) -> OSStatus {
        if query[kSecAttrService as String] != nil {
            return errSecParam
        }
        if query[kSecUseDataProtectionKeychain as String] as? Bool == true {
            return dataProtectionStatus
        }
        if query[kSecAttrAccessible as String] != nil || query[kSecAttrAccessControl as String] !=
            nil
        {
            return errSecParam
        }
        return errSecSuccess
    }

    func makeUserPresenceAccessControl() -> (control: SecAccessControl?, error: String?) {
        if makeControlFails {
            return (nil, "test")
        }
        return (
            SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, nil),
            nil
        )
    }

    func addItem(_ query: [String: Any]) -> OSStatus {
        adds.append(query)
        let validation = validate(query)
        guard validation == errSecSuccess else { return validation }
        guard addStatus == errSecSuccess else { return addStatus }
        guard !items.contains(where: { identical($0.attributes, query) }) else { return errSecDuplicateItem }
        var attributes = query
        var data = attributes.removeValue(forKey: kSecValueData as String) as? Data
        if query[kSecAttrAccessControl as String] != nil {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
        if corruptNextSecret, query[kSecAttrServer as String] as? String != "https://probe.invalid" {
            data = Data("wrong".utf8)
            corruptNextSecret = false
        }
        items.append(Item(attributes: attributes, data: data))
        return errSecSuccess
    }

    func updateItem(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        updates += 1
        guard updateStatus == errSecSuccess else { return updateStatus }
        guard let index = items.firstIndex(where: { matches($0, query) }) else { return errSecItemNotFound }
        items[index].data = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func copyItems(_ query: [String: Any]) -> (status: OSStatus, items: [[String: Any]]) {
        listCalls += 1
        let status = validate(query)
        guard status == errSecSuccess else { return (status, []) }
        guard listStatus == errSecSuccess else { return (listStatus, []) }
        let results = items.filter { matches($0, query) }.map(\.attributes)
        return (results.isEmpty ? errSecItemNotFound : errSecSuccess, results)
    }

    func copySecret(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        secretReads += 1
        beforeRead?()
        guard readStatus == errSecSuccess else { return (readStatus, nil) }
        guard let item = items.first(where: { matches($0, query) }) else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, item.data)
    }

    func deleteItem(_ query: [String: Any]) -> OSStatus {
        deletes += 1
        guard deleteStatus == errSecSuccess else { return deleteStatus }
        let count = items.count
        items.removeAll { matches($0, query) }
        return count == items.count ? errSecItemNotFound : errSecSuccess
    }
}

final class InMemoryPasswordMetadataStore: PasswordMetadataStoring {
    var records: [PasswordVaultMetadata] = []
    var writes = 0
    func loadRecords() -> [PasswordVaultMetadata] {
        records
    }

    func saveRecords(_ records: [PasswordVaultMetadata]) {
        self.records = records
        writes += 1
    }
}

final class TestAuthenticationContext: CredentialAuthenticationContext {
    var keychainContext: LAContext? {
        nil
    }

    var capable = true
    var autoReply: Bool?
    private let stateLock = NSLock()
    private var reply: ((Bool) -> Void)?
    private var invalidationCount = 0
    var callback: ((Bool) -> Void)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return reply
    }

    var invalidations: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return invalidationCount
    }

    func canAuthenticate() -> Bool {
        capable
    }

    func evaluate(reason: String, reply: @escaping (Bool) -> Void) {
        stateLock.lock()
        self.reply = reply
        stateLock.unlock()
        if let autoReply {
            reply(autoReply)
        }
    }

    func invalidate() {
        stateLock.lock()
        invalidationCount += 1
        stateLock.unlock()
    }
}

func makeTestVault(_ backend: CredentialVaultKeychainBackend = InMemoryVaultBackend()) -> CredentialVault {
    CredentialVault(backend: backend, service: "com.aflekkas.pane.vault.tests.\(UUID().uuidString)")
}
