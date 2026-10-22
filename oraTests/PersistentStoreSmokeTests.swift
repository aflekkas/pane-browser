import Foundation
@testable import Ora
import SwiftData
import Testing

/// Persistent-store smoke test: proves an on-disk SwiftData container can
/// be created in a prepared directory, written, and reopened with its data
/// intact — without touching the production store location (tests run
/// against a temp directory, and the app's shared configuration stays
/// in-memory under XCTest; see `ModelConfiguration.isRunningUnitTests`).
struct PersistentStoreSmokeTests {
    @Test func persistentStoreRoundTripsAcrossReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistentStoreSmoke-\(UUID().uuidString)", isDirectory: true)
        let storeURL = directory.appendingPathComponent("Ora/OraData.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let containerID = UUID()
        do {
            let container = try ModelConfiguration.createOraContainer(at: storeURL)
            let context = ModelContext(container)
            context.insert(TabContainer(id: containerID, name: "Smoke", emoji: "S"))
            try context.save()
        }
        #expect(FileManager.default.fileExists(atPath: storeURL.path))

        let reopened = try ModelConfiguration.createOraContainer(at: storeURL)
        let reopenedContext = ModelContext(reopened)
        let fetched = try reopenedContext.fetch(FetchDescriptor<TabContainer>())
        #expect(fetched.contains { $0.id == containerID && $0.name == "Smoke" })
    }

    @Test func sharedConfigurationStaysInMemoryUnderTests() {
        #expect(ModelConfiguration.isRunningUnitTests)
        #expect(ModelConfiguration.oraDatabase().isStoredInMemoryOnly)
    }
}
