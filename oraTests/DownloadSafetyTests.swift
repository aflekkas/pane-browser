import CoreServices
import Foundation
@testable import Ora
import Testing

struct DownloadSafetyTests {
    @Test func sanitizesTraversalToSingleComponent() {
        #expect(DownloadSafety.sanitizedFilename("../../etc/passwd") == "passwd")
        #expect(DownloadSafety.sanitizedFilename("..\\..\\evil.exe") == "evil.exe")
        #expect(DownloadSafety.sanitizedFilename("/absolute/path/report.pdf") == "report.pdf")
        #expect(!DownloadSafety.sanitizedFilename("a/b/c.txt").contains("/"))
    }

    @Test func sanitizesEmptyHiddenAndControlNames() {
        #expect(DownloadSafety.sanitizedFilename("") == "download")
        #expect(DownloadSafety.sanitizedFilename(nil) == "download")
        #expect(DownloadSafety.sanitizedFilename("..") == "download")
        #expect(DownloadSafety.sanitizedFilename("...") == "download")
        #expect(DownloadSafety.sanitizedFilename(".env") == "env")
        #expect(DownloadSafety.sanitizedFilename("a\u{0000}b\u{0007}.txt") == "ab.txt")
        #expect(DownloadSafety.sanitizedFilename("name.") == "name")
    }

    @Test func truncatedNamePreservesExtensionAndByteLimit() {
        let longName = String(repeating: "a", count: 300) + ".pdf"
        let result = DownloadSafety.sanitizedFilename(longName)
        #expect(result.utf8.count <= DownloadSafety.maxFilenameBytes)
        #expect(result.hasSuffix(".pdf"))
    }

    @Test func destinationStaysInsideDirectoryAndUniquifies() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadSafetyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = DownloadSafety.uniqueDestination(in: dir, suggestedFilename: "../../evil.txt")
        #expect(first.lastPathComponent == "evil.txt")
        #expect(DownloadSafety.isContained(first, in: dir))

        try Data("x".utf8).write(to: first)
        let second = DownloadSafety.uniqueDestination(in: dir, suggestedFilename: "evil.txt")
        #expect(second.lastPathComponent == "evil (1).txt")
        #expect(DownloadSafety.isContained(second, in: dir))
    }

    @Test func containmentRejectsSiblingPrefixEscape() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadSafetyTests-\(UUID().uuidString)")
        let dir = base.appendingPathComponent("downloads")
        let sibling = base.appendingPathComponent("downloads-evil/file.txt")
        #expect(!DownloadSafety.isContained(sibling, in: dir))
        #expect(DownloadSafety.isContained(dir.appendingPathComponent("file.txt"), in: dir))
    }

    @Test func quarantineRoundTripVerifiesByReadBack() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadSafetyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("payload.bin")
        try Data("payload".utf8).write(to: file)

        let outcome = DownloadSafety.applyQuarantine(
            to: file,
            source: URL(string: "https://example.com/payload.bin"),
            page: URL(string: "https://example.com/get")
        )
        #expect(outcome.verified)
        #expect(DownloadSafety.hasQuarantine(file))
        #expect(DownloadSafety.quarantineType(file) == (kLSQuarantineTypeWebDownload as String))
    }

    @Test func existingQuarantineIsPreservedNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadSafetyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("payload.bin")
        try Data("payload".utf8).write(to: file)

        let first = DownloadSafety.applyQuarantine(to: file, source: URL(string: "https://a.example/x"), page: nil)
        #expect(first.verified)
        #expect(!first.preservedExisting)

        let second = DownloadSafety.applyQuarantine(to: file, source: URL(string: "https://b.example/y"), page: nil)
        #expect(second.verified)
        #expect(second.preservedExisting)
        #expect(DownloadSafety.hasQuarantine(file))
    }

    @Test func resumeRequiresMatchingProfileScope() {
        #expect(DownloadSafety.canResume(downloadProfileID: "space-1", taskProfileID: "space-1"))
        #expect(!DownloadSafety.canResume(downloadProfileID: "space-1", taskProfileID: "space-2"))
        // Fail closed: record has a profile, resuming task cannot prove its own.
        #expect(!DownloadSafety.canResume(downloadProfileID: "space-1", taskProfileID: nil))
        // No profile recorded (legacy/unscoped download): nothing to mismatch.
        #expect(!DownloadSafety.canResume(downloadProfileID: nil, taskProfileID: "space-2"))
    }

    @Test func onceCompletionFiresExactlyOnce() {
        var values: [Int] = []
        let once = OnceCompletion<Int> { values.append($0) }
        once.call(1)
        once.call(2)
        #expect(values == [1])
        #expect(once.hasFired)
    }
}
