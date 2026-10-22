import Foundation
@testable import Ora
import SwiftData
import Testing

struct TabLifecycleSnapshotTests {
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: TabSessionSnapshot.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @Test func snapshotRoundTripsByteIdentical() throws {
        let context = try makeContext()
        let tabID = UUID()
        let containerID = UUID()
        let blob = Data((0 ..< 4096).map { UInt8($0 % 251) })

        let saved = TabLifecycleSnapshotStore.save(
            tabID: tabID, containerID: containerID, data: blob, isPrivate: false, in: context
        )
        #expect(saved)
        try context.save()

        let restored = TabLifecycleSnapshotStore.restoreData(tabID: tabID, containerID: containerID, in: context)
        #expect(restored == blob)
        #expect(restored?.count == blob.count)
    }

    @Test func saveUpsertsSingleRowPerTab() throws {
        let context = try makeContext()
        let tabID = UUID()
        let containerID = UUID()

        TabLifecycleSnapshotStore.save(
            tabID: tabID, containerID: containerID, data: Data([0x01]), isPrivate: false, in: context
        )
        TabLifecycleSnapshotStore.save(
            tabID: tabID, containerID: containerID, data: Data([0x02, 0x03]), isPrivate: false, in: context
        )
        try context.save()

        #expect(TabLifecycleSnapshotStore.restoreData(tabID: tabID, containerID: containerID, in: context)
            == Data([0x02, 0x03]))
        let descriptor = FetchDescriptor<TabSessionSnapshot>()
        #expect(try context.fetch(descriptor).count == 1)
    }

    @Test func privateTabsNeverPersist() throws {
        let context = try makeContext()
        let tabID = UUID()

        let saved = TabLifecycleSnapshotStore.save(
            tabID: tabID, containerID: UUID(), data: Data([0x01]), isPrivate: true, in: context
        )
        #expect(saved == false)
        try context.save()
        #expect(TabLifecycleSnapshotStore.fetch(tabID: tabID, in: context) == nil)
    }

    @Test func crossContainerBlobIsDroppedNotRestored() throws {
        let context = try makeContext()
        let tabID = UUID()
        let original = UUID()
        let other = UUID()

        TabLifecycleSnapshotStore.save(
            tabID: tabID, containerID: original, data: Data([0x09]), isPrivate: false, in: context
        )
        try context.save()

        // Container isolation: a blob captured under one data store must
        // never be assigned under another, and the stale row is removed.
        #expect(TabLifecycleSnapshotStore.restoreData(tabID: tabID, containerID: other, in: context) == nil)
        #expect(TabLifecycleSnapshotStore.fetch(tabID: tabID, in: context) == nil)
    }

    @Test func invalidPersistedBlobIsDropped() throws {
        let context = try makeContext()
        let tabID = UUID()
        let containerID = UUID()
        context.insert(TabSessionSnapshot(tabID: tabID, containerID: containerID, interactionState: Data()))
        try context.save()

        #expect(TabLifecycleSnapshotStore.restoreData(tabID: tabID, containerID: containerID, in: context) == nil)
        #expect(TabLifecycleSnapshotStore.fetch(tabID: tabID, in: context) == nil)
    }

    @Test func oversizeBlobIsNotPersisted() throws {
        let context = try makeContext()
        let tabID = UUID()
        let oversize = Data(count: TabInteractionStateCodec.maximumByteCount + 1)

        let saved = TabLifecycleSnapshotStore.save(
            tabID: tabID, containerID: UUID(), data: oversize, isPrivate: false, in: context
        )
        #expect(saved == false)
        #expect(TabLifecycleSnapshotStore.fetch(tabID: tabID, in: context) == nil)
    }

    @Test func deleteRemovesRow() throws {
        let context = try makeContext()
        let tabID = UUID()
        TabLifecycleSnapshotStore.save(
            tabID: tabID, containerID: UUID(), data: Data([0x07]), isPrivate: false, in: context
        )
        try context.save()

        TabLifecycleSnapshotStore.delete(tabID: tabID, in: context)
        try context.save()
        #expect(TabLifecycleSnapshotStore.fetch(tabID: tabID, in: context) == nil)
    }
}
