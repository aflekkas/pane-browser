import Foundation
@testable import Ora
import Testing

struct CredentialImportZIPTests {
    private func fixtures() throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("CredentialImportZIPFixtures.json")
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    }

    @Test func officialDirectItemsAcrossAccountsAndVaults() throws {
        let fixtures = try fixtures()
        for name in ["valid-stored", "valid-deflated"] {
            let encoded = try #require(fixtures[name])
            let data = try #require(Data(base64Encoded: encoded))
            let result = CredentialImport.parse(data, filename: "export.1pux")
            #expect(result.entries.count == 3, "\(name)")
            #expect(result.entries.allSatisfy { $0.password == "pw" && $0.origin == "https://example.com" })
            #expect(result.skipped.count == 1) // unsupported category, not silent structural noise
        }
    }

    @Test func adversarialArchivesFailWithoutPrefixImportOrCrashes() throws {
        for (name, encoded) in try fixtures() where !name.hasPrefix("valid-") {
            let result = try CredentialImport.parse(#require(Data(base64Encoded: encoded)), filename: "export.1pux")
            #expect(result.entries.isEmpty, "\(name)")
            #expect(!result.skipped.isEmpty, "\(name)")
        }
    }

    @Test func allTruncatedPrefixesReject() throws {
        let encoded = try #require(fixtures()["valid-deflated"])
        let data = try #require(Data(base64Encoded: encoded))
        for length in 0 ..< data.count {
            let result = CredentialImport.parse(Data(data.prefix(length)), filename: "export.1pux")
            #expect(result.entries.isEmpty)
            #expect(!result.skipped.isEmpty)
        }
    }
}
