import CoreData
import Foundation
@testable import Ora
import SwiftData
import Testing

@MainActor
struct LifecycleRepairMigrationTests {
    @Test func genuinePR1ModelsMigrateRowsRelationshipsAndPinIntent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("OraData.sqlite")
        let tabID = UUID(), containerID = UUID(), downloadID = UUID()
        let url = try #require(URL(string: "https://pr1-fixture.invalid/a"))
        try writeLegacyStore(at: storeURL, tabID: tabID, containerID: containerID, downloadID: downloadID, url: url)
        // Read on-disk metadata before opening with the new models. Entity
        // names must be PR1 names, not a parallel set named LegacyTab, etc.
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            ofType: NSSQLiteStoreType, at: storeURL
        )
        let hashes = try #require(metadata[NSStoreModelVersionHashesKey] as? [String: Data])
        #expect(Set(hashes.keys) == Set(["Tab", "TabContainer", "Folder", "History", "Download"]))

        let current = try ModelConfiguration.createOraContainer(at: storeURL)
        let context = ModelContext(current)
        let tab = try #require(context.fetch(FetchDescriptor<Tab>()).first)
        #expect(tab.id == tabID && tab.url == url && tab.savedURL == url)
        #expect(tab.title == "PR1 pinned tab" && tab.order == 7 && tab.type == .pinned)
        #expect(tab.container.id == containerID && tab.container.tabs.contains { $0.id == tabID })
        #expect(tab.container.folders.first?.name == "PR1 folder")
        #expect(tab.container.history.first?.visitCount == 4)
        #expect(tab.isDiscarded == false)
        #expect(tab.lifecycleExplicitPinIntent == nil)
        #expect(tab.userPinnedExplicitly)
        let download = try #require(context.fetch(FetchDescriptor<Download>()).first)
        #expect(download.id == downloadID && download.originalURL == url)
        #expect(download.fileSize == 4096 && download.downloadedBytes == 2048)
        #expect(download.status == .failed && download.progress == 0.5)
        #expect(download.error == "synthetic interrupted transfer")
        #expect(download.quarantineVerified == false && download.resumeData == nil)
        #expect(try context.fetch(FetchDescriptor<TabSessionSnapshot>()).isEmpty)
        tab.userPinnedExplicitly = false
        try context.save()
        let reopened = try ModelConfiguration.createOraContainer(at: storeURL)
        let reopenedTab = try #require(ModelContext(reopened).fetch(FetchDescriptor<Tab>()).first)
        #expect(reopenedTab.userPinnedExplicitly == false)
    }

    private func writeLegacyStore(
        at url: URL, tabID: UUID, containerID: UUID, downloadID: UUID, url pageURL: URL
    ) throws {
        // PR1 used an unversioned Schema. These frozen declarations are also
        // exposed as VersionedSchema for inspection, but use its model list
        // here to reproduce the actual original unversioned store configuration.
        let schema = Schema(LifecycleRepairLegacySchema.models)
        let tabEntity = try #require(schema.entities.first { $0.name == "Tab" })
        #expect(!tabEntity.properties.contains { $0.name == "isDiscarded" })
        #expect(!tabEntity.properties.contains { $0.name == "lifecycleExplicitPinIntent" })
        let downloadEntity = try #require(schema.entities.first { $0.name == "Download" })
        #expect(!downloadEntity.properties.contains { $0.name == "quarantineVerified" })
        let container = try ModelContainer(
            for: schema, configurations: ModelConfiguration("OraData", schema: schema, url: url)
        )
        let context = ModelContext(container)
        let space = LifecycleRepairLegacySchema.TabContainer(id: containerID)
        context.insert(space)
        context.insert(LifecycleRepairLegacySchema.Tab(id: tabID, url: pageURL, container: space))
        context.insert(LifecycleRepairLegacySchema.Folder(container: space))
        context.insert(LifecycleRepairLegacySchema.History(url: pageURL, container: space))
        context.insert(LifecycleRepairLegacySchema.Download(id: downloadID, url: pageURL))
        try context.save()
    }
}
