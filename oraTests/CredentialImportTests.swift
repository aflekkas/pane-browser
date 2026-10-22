import Foundation
@testable import Ora
import Security
import Testing

struct CredentialImportTests {
    @Test func safariChromeAndExactQuotedSecrets() {
        let csv = "\u{FEFF}Title,URL,Username,Password,Notes,OTPAuth\r\nsite,https://example.com/login,a,\"one,\"\"two\"\"\r\nthree\",,\r\n"
        let parsed = CredentialImport.parseCSV(csv)
        #expect(parsed.format == "Safari CSV")
        #expect(parsed.entries.first?.password == "one,\"two\"\r\nthree")
        #expect(parsed.entries.first?.origin == "https://example.com")
        #expect(parsed.skipped.isEmpty)
        #expect(CredentialImport.parseCSV("name,url,username,password\nsite,example.com,a,pw").entries.count == 1)
    }

    @Test(arguments: ["p\"w", "\"pw\"junk", "\"unterminated", "\"pw\" \n"])
    func malformedTailInvalidatesEntireInputAndPreservesDestination(_ password: String) throws {
        let backend = InMemoryVaultBackend()
        let vault = makeTestVault(backend)
        let profile = UUID()
        try vault.save(origin: "https://example.com", username: "a", password: "old", profileID: profile.uuidString)
        let service = PasswordManagerService(
            vault: vault,
            metadataStore: InMemoryPasswordMetadataStore(),
            legacyStore: nil
        )
        let csv = "url,username,password\nhttps://example.com,a,new\nhttps://other.com,b,\(password)"
        let report = service.importCredentials(
            data: Data(csv.utf8),
            filename: "x.csv",
            containerID: profile,
            isPrivate: false
        )
        #expect(report.importedCount == 0)
        #expect(backend.updates == 0)
        #expect(try vault.password(
            origin: "https://example.com",
            username: "a",
            profileID: profile.uuidString,
            reason: "test"
        ) == "old")
        #expect(vault.allCredentials().count == 1)
    }

    @Test func diagnosticsNeverEchoRawHeadersURLsOrValues() {
        let header = CredentialImport.parseCSV("secret-header,user,password\nsecret-url,a,secret-value")
        let url = CredentialImport.parseCSV("url,username,password\nhttp://example.com/secret-token,a,secret-value")
        #expect(!header.skipped.joined().contains("secret"))
        #expect(!url.skipped.joined().contains("secret"))
    }

    @Test func limitsRejectWholeInputBeforeMutation() {
        let oversized = String(repeating: "x", count: CredentialImport.maximumFieldBytes + 1)
        #expect(CredentialImport.parseCSV("url,username,password\nexample.com,a,\(oversized)").entries.isEmpty)
        let rows = String(repeating: "example.com,a,pw\n", count: CredentialImport.maximumCSVRows + 1)
        #expect(CredentialImport.parseCSV("url,username,password\n" + rows).entries.isEmpty)
        let columns = String(repeating: "x,", count: 65)
        #expect(CredentialImport.parseCSV("url,username,password\n" + columns).entries.isEmpty)
        #expect(CredentialImport.parseCSV("url,username,password\nexample.com,a,pw", cancelled: { true }).entries
            .isEmpty)
    }

    @Test func boundedFileReaderRejectsOversizedSparseFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CredentialImport-\(UUID()).csv")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(CredentialImport.maximumCSVBytes + 1))
        try handle.close()
        #expect(throws: CredentialImport.ImportFailure.self) { try CredentialImport.readFile(url) }
    }

    @Test func batchImportUsesOneMetadataSaveAndNoOverwrite() throws {
        let backend = InMemoryVaultBackend()
        let vault = makeTestVault(backend)
        let metadata = InMemoryPasswordMetadataStore()
        let service = PasswordManagerService(vault: vault, metadataStore: metadata, legacyStore: nil)
        let profile = UUID()
        let rows = (0 ..< 200).map { "https://example.com,user\($0),pw" }.joined(separator: "\n")
        let report = service.importCredentials(
            data: Data(("url,username,password\n" + rows).utf8),
            filename: "x.csv",
            containerID: profile,
            isPrivate: false
        )
        #expect(report.importedCount == 200)
        #expect(metadata.writes == 1)
        // Two exact-identity lookups per row and one profile-wide refresh; not a full reload per row.
        #expect(backend.listCalls <= 405)
        let retry = service.importCredentials(
            data: Data("url,username,password\nhttps://example.com,user0,changed".utf8),
            filename: "x.csv",
            containerID: profile,
            isPrivate: false
        )
        #expect(retry.importedCount == 0)
        #expect(retry.skipped.count == 1)
        #expect(backend.updates == 0)
        #expect(try vault.password(
            origin: "https://example.com",
            username: "user0",
            profileID: profile.uuidString,
            reason: "test"
        ) == "pw")
        #expect(service.entries(for: profile).count == 200)
        #expect(service.entries(for: UUID()).isEmpty)
    }

    @Test func privateAndUnassignedTargetsRejected() {
        let backend = InMemoryVaultBackend()
        let service = PasswordManagerService(
            vault: makeTestVault(backend),
            metadataStore: InMemoryPasswordMetadataStore(),
            legacyStore: nil
        )
        for (profile, isPrivate) in [(UUID(), true), (nil, false)] as [(UUID?, Bool)] {
            let report = service.importCredentials(
                data: Data("url,username,password\nexample.com,a,pw".utf8),
                filename: "x.csv",
                containerID: profile,
                isPrivate: isPrivate
            )
            #expect(report.importedCount == 0)
            #expect(backend.items.isEmpty)
        }
    }

    @Test @MainActor func cancelledWriterDoesNotMutate() async {
        let backend = InMemoryVaultBackend()
        let context = TestAuthenticationContext()
        context.autoReply = true
        let auth = CredentialVaultAuthentication { context }
        let service = PasswordManagerService(
            vault: makeTestVault(backend),
            metadataStore: InMemoryPasswordMetadataStore(),
            legacyStore: nil,
            authentication: auth
        )
        #expect(await auth.authenticate(reason: "test"))
        let parsed = CredentialImport.parseCSV("url,username,password\nexample.com,a,pw")
        let task = Task { @MainActor in await service.importCredentials(parsed: parsed, containerID: UUID()) }
        task.cancel()
        #expect(await task.value.importedCount == 0)
        #expect(backend.items.isEmpty)
    }
}
