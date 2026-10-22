import Foundation
@testable import Ora
import SwiftData
import Testing

/// Schema migration fixture: a store written with the pre-lifecycle
/// schema (no `TabSessionSnapshot`, no `Tab.isDiscarded`) must open under
/// the current schema with its existing rows intact. Uses synthetic
/// non-secret data in a temp directory — never a real user store.
struct SchemaMigrationTests {
    @Test func preLifecycleStoreOpensUnderCurrentSchema() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchemaMigration-\(UUID().uuidString)", isDirectory: true)
        let storeURL = directory.appendingPathComponent("OraData.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let containerID = UUID()
        do {
            let oldSchema = Schema([TabContainer.self, History.self, Download.self])
            let oldConfig = ModelConfiguration("OraData", schema: oldSchema, url: storeURL)
            let oldContainer = try ModelContainer(
                for: TabContainer.self, History.self, Download.self,
                configurations: oldConfig
            )
            let context = ModelContext(oldContainer)
            context.insert(TabContainer(id: containerID, name: "Legacy", emoji: "L"))
            try context.save()
        }

        let migrated = try ModelConfiguration.createOraContainer(at: storeURL)
        let migratedContext = ModelContext(migrated)
        let containers = try migratedContext.fetch(FetchDescriptor<TabContainer>())
        #expect(containers.contains { $0.id == containerID && $0.name == "Legacy" })

        // The new entity is usable in the migrated store.
        migratedContext.insert(TabSessionSnapshot(
            tabID: UUID(),
            containerID: containerID,
            interactionState: Data([0x01, 0x02])
        ))
        try migratedContext.save()
        let snapshots = try migratedContext.fetch(FetchDescriptor<TabSessionSnapshot>())
        #expect(snapshots.count == 1)
    }
}
