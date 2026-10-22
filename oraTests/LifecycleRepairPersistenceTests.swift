import Foundation
@testable import Ora
import SwiftData
import Testing

@MainActor
struct LifecycleRepairPersistenceTests {
    @Test func realWebKitHistoryAndScrollSurviveDiskSaveAndReopen() async throws {
        let fixture = try await LifecycleRepairFixture()
        defer { fixture.stop() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("OraData.sqlite")
        let (tabID, profileID) = try await writeSession(storeURL: storeURL, fixture: fixture)
        let reopened = try ModelConfiguration.createOraContainer(at: storeURL)
        let context = ModelContext(reopened)
        let manager = TabManager(modelContainer: reopened, modelContext: context, mediaController: MediaController())
        let tab = try #require(context.fetch(FetchDescriptor<Tab>()).first { $0.id == tabID })
        #expect(tab.browserPage == nil && tab.isDiscarded)
        defer { manager.closeLifecycleFixture() }
        manager.activateTab(tab)
        let harness = try LifecycleRepairHarness(page: #require(tab.browserPage))
        defer { harness.close()
            tab.finishLifecycleDiscard()
        }
        try await harness.loaded(fixture.url("/b"))
        #expect(tab.browserPage?.profileIdentifier == profileID)
        #expect(tab.canGoBack)
        var scroll = 0.0
        for _ in 0 ..< 40 {
            scroll = try await (harness.evaluate("window.scrollY") as? Double) ?? 0
            if scroll > 1000 {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(scroll > 1000)
        tab.goBack()
        try await harness.loaded(fixture.url())
    }

    @Test func checkpointAThenNavigateBPrivacyRecreateNeverRewindsA() async throws {
        let fixture = try await LifecycleRepairFixture()
        defer { fixture.stop() }
        let store = try ModelConfiguration.createOraContainer(isPrivate: true)
        let manager = TabManager(
            modelContainer: store,
            modelContext: ModelContext(store),
            mediaController: MediaController()
        )
        let tab = try manager.addTab(
            url: fixture.url(), container: #require(manager.activeContainer), isPrivate: false
        )
        let harness = try LifecycleRepairHarness(page: #require(tab.browserPage))
        defer { harness.close()
            tab.finishLifecycleDiscard()
        }
        try await harness.loaded(fixture.url())
        #expect(tab.captureInteractionState())
        try await harness.load(fixture.url("/b"))
        #expect(TabLifecycleSnapshotStore.fetch(tabID: tab.id, in: manager.modelContext) == nil)
        tab.refreshBrowserPageForPrivacySettings()
        try harness.attach(#require(tab.browserPage))
        try await harness.loaded(fixture.url("/b"))
        #expect(tab.canGoBack)
    }

    @Test func corruptNonemptyBlobFallsBackToURLInsteadOfBlankPage() async throws {
        let fixture = try await LifecycleRepairFixture()
        defer { fixture.stop() }
        let store = try ModelConfiguration.createOraContainer(isPrivate: true)
        let manager = TabManager(
            modelContainer: store,
            modelContext: ModelContext(store),
            mediaController: MediaController()
        )
        let tab = try manager.addTab(
            url: fixture.url(), container: #require(manager.activeContainer), isPrivate: false
        )
        tab.finishLifecycleDiscard()
        #expect(TabLifecycleSnapshotStore.save(
            tabID: tab.id, containerID: tab.container.id, data: Data([0x01, 0x02, 0x03]),
            isPrivate: false, in: manager.modelContext
        ))
        manager.activateTab(tab)
        let harness = try LifecycleRepairHarness(page: #require(tab.browserPage))
        defer { harness.close()
            tab.finishLifecycleDiscard()
        }
        try await harness.loaded(fixture.url())
        #expect(tab.isWebViewReady && !tab.isDiscarded)
        #expect(TabLifecycleSnapshotStore.fetch(tabID: tab.id, in: manager.modelContext) == nil)
    }

    @Test func pendingRestoreIsSupersededByReplacementURLBeforePrivacyReadiness() async throws {
        let fixture = try await LifecycleRepairFixture()
        defer { fixture.stop() }
        let source = LifecycleRepairHarness()
        defer { source.close() }
        try await source.load(fixture.url())
        try await source.load(fixture.url("/b"))
        let validState = try #require(source.page.captureInteractionState())
        let harness = LifecycleRepairHarness()
        defer { harness.close() }
        var outcome: TabLifecycleRestoreOutcome?
        // No suspension since construction: production privacy readiness is
        // delivered by DispatchGroup.notify on the main queue.
        harness.page.restoreInteractionState(validState) { outcome = $0 }
        #expect(outcome == nil)
        let replacement = try fixture.url("/b")
        harness.page.load(URLRequest(url: replacement))
        #expect(outcome == .superseded)
        try await harness.loaded(replacement)
        #expect(harness.page.currentURL == replacement)
        #expect(!harness.page.canGoBack)
    }

    @Test func allNormalManagersCheckpointEvenWithPrivateWindowActive() async throws {
        let fixture = try await LifecycleRepairFixture()
        defer { fixture.stop() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("OraData.sqlite")
        let coordinator = TabLifecycleQuitCoordinator()
        var managers: [TabManager] = [], tabs: [Tab] = [], harnesses: [LifecycleRepairHarness] = []
        defer { harnesses.forEach { $0.close() }
            managers.forEach { $0.closeLifecycleFixture() }
        }
        for index in 0 ..< 3 {
            let isPrivate = index == 2
            let store = try isPrivate
                ? ModelConfiguration.createOraContainer(isPrivate: true)
                : ModelConfiguration.createOraContainer(at: storeURL)
            let manager = TabManager(
                modelContainer: store,
                modelContext: ModelContext(store),
                mediaController: MediaController()
            )
            coordinator.register(manager)
            let tab = try manager.addTab(
                url: fixture.url(), container: #require(manager.activeContainer), isPrivate: isPrivate
            )
            let harness = try LifecycleRepairHarness(page: #require(tab.browserPage))
            try await harness.loaded(fixture.url())
            if !isPrivate {
                #expect(tab.captureInteractionState())
            }
            try await harness.load(fixture.url("/b"))
            managers.append(manager)
            tabs.append(tab)
            harnesses.append(harness)
        }
        // Last manager is private and active; it must not determine the capture set.
        #expect(managers.last?.activeTab?.isPrivate == true)
        #expect(coordinator.captureAllLiveSnapshots())
        let reopened = try ModelConfiguration.createOraContainer(at: storeURL)
        let context = ModelContext(reopened)
        let rows = try context.fetch(FetchDescriptor<TabSessionSnapshot>())
        #expect(Set(rows.map(\.tabID)) == Set(tabs.prefix(2).map(\.id)))
        let restoredManager = TabManager(
            modelContainer: reopened,
            modelContext: context,
            mediaController: MediaController()
        )
        defer { restoredManager.closeLifecycleFixture() }
        for tab in try context.fetch(FetchDescriptor<Tab>()) {
            restoredManager.activateTab(tab)
            let harness = try LifecycleRepairHarness(page: #require(tab.browserPage))
            defer { harness.close()
                tab.finishLifecycleDiscard()
            }
            try await harness.loaded(fixture.url("/b"))
        }
        #expect(try managers[2].modelContext.fetch(FetchDescriptor<TabSessionSnapshot>()).isEmpty)
    }

    private func writeSession(storeURL: URL, fixture: LifecycleRepairFixture) async throws -> (UUID, UUID) {
        let store = try ModelConfiguration.createOraContainer(at: storeURL)
        let manager = TabManager(
            modelContainer: store,
            modelContext: ModelContext(store),
            mediaController: MediaController()
        )
        let tab = try manager.addTab(
            url: fixture.url(), container: #require(manager.activeContainer), isPrivate: false
        )
        let harness = try LifecycleRepairHarness(page: #require(tab.browserPage))
        defer { harness.close()
            manager.closeLifecycleFixture()
        }
        try await harness.loaded(fixture.url())
        try await harness.load(fixture.url("/b"))
        try await harness.scroll(to: 1200)
        #expect(tab.captureInteractionState())
        tab.discard()
        #expect(tab.isDiscarded && tab.browserPage == nil)
        try manager.modelContext.save()
        return (tab.id, tab.container.id)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
