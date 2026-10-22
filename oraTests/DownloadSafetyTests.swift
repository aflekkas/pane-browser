import CoreServices
import Darwin
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

        // A sandboxed writer can inherit quarantine immediately. Establish a
        // known absent state explicitly before testing the writer branch.
        _ = removexattr(file.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        #expect(DownloadSafety.rawQuarantine(file) == nil)
        let outcome = DownloadSafety.applyQuarantine(
            to: file,
            source: URL(string: "https://example.com/payload.bin"),
            page: URL(string: "https://example.com/get")
        )
        #expect(outcome.verified)
        #expect(DownloadSafety.hasQuarantine(file))
        #expect(DownloadSafety.rawQuarantine(file)?.isEmpty == false)
        #expect(!outcome.preservedExisting)
    }

    @Test func existingQuarantineIsPreservedNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadSafetyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("payload.bin")
        try Data("payload".utf8).write(to: file)

        let stronger = Data("0083;12345678;Fixture Browser;11111111-1111-1111-1111-111111111111".utf8)
        let setResult = stronger.withUnsafeBytes {
            setxattr(file.path, "com.apple.quarantine", $0.baseAddress, stronger.count, 0, XATTR_NOFOLLOW)
        }
        try #require(setResult == 0)
        try #require(DownloadSafety.rawQuarantine(file) == stronger)
        let outcome = DownloadSafety.applyQuarantine(to: file, source: URL(string: "https://b.example/y"), page: nil)
        #expect(outcome.verified)
        #expect(outcome.preservedExisting)
        #expect(DownloadSafety.rawQuarantine(file) == stronger)
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

extension DownloadSafetyTests {
    @Test func danglingSymlinkAndUncreatedReservationsAreOccupiedDestinations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadSymlink-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appendingPathComponent("payload.bin")
        let outside = directory.deletingLastPathComponent().appendingPathComponent("missing-\(UUID())")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(!FileManager.default.fileExists(atPath: link.path))
        let reserved = directory.appendingPathComponent("payload (1).bin")
        let candidate = DownloadSafety.uniqueDestination(
            in: directory,
            suggestedFilename: "../../payload.bin",
            reserved: [reserved]
        )
        #expect(candidate.lastPathComponent == "payload (2).bin")
        #expect(DownloadSafety.isContained(candidate, in: directory))
        #expect(!FileManager.default.fileExists(atPath: outside.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == outside.path)
    }
}
