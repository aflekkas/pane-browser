import Foundation
@testable import Ora
import SwiftData
import Testing

struct LifecycleRepairPolicyTests {
    @Test func queuedRestoreCompletesOnlyAfterAssignmentAndNavigationSupersedesIt() {
        let restore = TabLifecycleRestoreController()
        var outcomes: [TabLifecycleRestoreOutcome] = []
        restore.enqueue(Data([1])) { outcomes.append($0) }
        #expect(!restore.applyIfReady(false) { _ in Issue.record("assigned before readiness")
            return true
        })
        #expect(outcomes.isEmpty)
        restore.supersede()
        #expect(outcomes == [.superseded])
        #expect(!restore.applyIfReady(true) { _ in Issue.record("replayed superseded state")
            return true
        })
        restore.enqueue(Data([2])) { outcomes.append($0) }
        #expect(restore.applyIfReady(true) { _ in false })
        #expect(outcomes == [.superseded, .invalid])
        restore.enqueue(Data([3])) { outcomes.append($0) }
        #expect(restore.applyIfReady(true) { _ in true })
        #expect(outcomes == [.superseded, .invalid, .restored])
    }

    @Test func previousDynamicBlockersDoNotPreventReprobeButExplicitPinDoes() {
        let now = Date()
        let policy = TabLifecyclePolicy(userUnloadDelay: 3600)
        let blocked = TabLifecycleFacts(
            id: UUID(), kind: .ephemeral, state: .live, hasLivePage: true,
            lastAccessedAt: now.addingTimeInterval(-7200), isActive: false,
            isPlayingAudio: true, hasActiveMediaSession: true, hasUnsavedFormState: true
        )
        #expect(policy.stage(for: blocked, at: now) == .checkpoint)
        #expect(policy.shouldProbe(blocked, at: now))
        let pinned = TabLifecycleFacts(
            id: UUID(), kind: .pinned, state: .live, hasLivePage: true,
            lastAccessedAt: now.addingTimeInterval(-7200), isActive: false, userPinnedExplicitly: true
        )
        #expect(!policy.shouldProbe(pinned, at: now))
        #expect(policy.stage(for: pinned, at: now) == .checkpoint)
    }

    @Test func failedSaveAndOversizeReplacementNeverReportDurabilityOrReuseOldBlob() throws {
        let container = try ModelContainer(
            for: TabSessionSnapshot.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let tabID = UUID(), profileID = UUID()
        #expect(TabLifecycleSnapshotStore.save(
            tabID: tabID, containerID: profileID, data: Data([1]), isPrivate: false, in: context
        ))
        struct WriteFailure: Error {}
        #expect(!TabLifecycleSnapshotStore.save(
            tabID: tabID, containerID: profileID, data: Data([2]), isPrivate: false, in: context,
            persist: { _ in throw WriteFailure() }
        ))
        #expect(TabLifecycleSnapshotStore.restoreData(tabID: tabID, containerID: profileID, in: context) == nil)
        #expect(!TabLifecycleSnapshotStore.save(
            tabID: tabID, containerID: profileID,
            data: Data(count: TabInteractionStateCodec.maximumByteCount + 1), isPrivate: false, in: context
        ))
        #expect(TabLifecycleSnapshotStore.restoreData(tabID: tabID, containerID: profileID, in: context) == nil)
    }
}
