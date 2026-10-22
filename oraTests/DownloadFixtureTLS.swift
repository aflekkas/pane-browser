import Foundation
import Network
import Security

/// Public test-only self-signed identity for fixture.invalid. Its private key
/// has no production use. No trust anchors or app TLS bypasses are installed.
enum DownloadFixtureTLS {
    static func options() throws -> NWProtocolTLS.Options {
        let data = Data(base64Encoded: identity, options: .ignoreUnknownCharacters)!
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase: "fixture"] as CFDictionary, &items)
        guard status == errSecSuccess,
              let values = items as? [[String: Any]],
              let value = values.first?[kSecImportItemIdentity as String]
        else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        guard CFGetTypeID(value as CFTypeRef) == SecIdentityGetTypeID() else { throw URLError(.secureConnectionFailed) }
        let identity = unsafeBitCast(value as CFTypeRef, to: SecIdentity.self)
        guard let securityIdentity = sec_identity_create(identity) else { throw URLError(.secureConnectionFailed) }
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, securityIdentity)
        return options
    }

    private static let identity = """
    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
    EA8RW/0+usf6yNfZaFhkzlwCAggA
    """
}
