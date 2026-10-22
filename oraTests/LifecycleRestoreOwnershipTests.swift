import Foundation
@testable import Ora
import SwiftData
import Testing

@MainActor
struct LifecycleRestoreOwnershipTests {
    @Test func inPageReplacementOfUnfinishedRestoreStopsAndReopensTheReplacement() async throws {
        let fixture = try await LifecycleRepairFixture()
        defer { fixture.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("ownership.sqlite")
        let tabID = try await replaceUnfinishedRestore(storeURL: storeURL, fixture: fixture)
        fixture.setHoldSubresources(false)
        let store = try ModelConfiguration.createOraContainer(at: storeURL)
        let manager = TabManager(
            modelContainer: store,
            modelContext: ModelContext(store),
            mediaController: MediaController()
        )
        defer { manager.closeLifecycleFixture() }
        let tab = try #require(manager.modelContext.fetch(FetchDescriptor<Tab>()).first { $0.id == tabID })
        #expect(try tab.url == fixture.url("/b"))
        manager.activateTab(tab)
        let harness = try LifecycleRepairHarness(page: #require(tab.browserPage))
        defer { harness.close() }
        try await harness.loaded(fixture.url("/b"))
        #expect(!harness.page.hasPendingLifecycleRestore)
        #expect(harness.page.canGoBack)
        tab.goBack()
        try await harness.loaded(fixture.url())
    }

    private func replaceUnfinishedRestore(storeURL: URL, fixture: LifecycleRepairFixture) async throws -> UUID {
        let store = try ModelConfiguration.createOraContainer(at: storeURL)
        let manager = TabManager(
            modelContainer: store,
            modelContext: ModelContext(store),
            mediaController: MediaController()
        )
        defer { manager.closeLifecycleFixture() }
        let urlA = try fixture.url(), urlB = try fixture.url("/b")
        let tab = try manager.addTab(url: urlA, container: #require(manager.activeContainer), isPrivate: false)
        let harness = try LifecycleRepairHarness(page: #require(tab.browserPage))
        defer { harness.close() }
        try await harness.loaded(urlA)
        tab.discard()
        let original = try #require(TabLifecycleSnapshotStore.fetch(tabID: tab.id, in: manager.modelContext)?
            .interactionState)
        fixture.setHoldSubresources(true)
        manager.activateTab(tab)
        try harness.attach(#require(tab.browserPage))
        try await LifecycleRepairHarness.waitUntil {
            harness.page.lastCommittedURL == urlA && harness.page.isLoading
        }
        #expect(harness.page.hasPendingLifecycleRestore)
        #expect(TabLifecycleSnapshotStore.fetch(tabID: tab.id, in: manager.modelContext)?.interactionState == original)
        // Use an actual in-page link, bypassing BrowserPage.load/goBack/reload.
        _ = try await harness.evaluate("document.getElementById('next').click(); true")
        try await LifecycleRepairHarness.waitUntil {
            harness.page.lastCommittedURL == urlB && harness.page.isLoading
        }
        #expect(!harness.page.hasPendingLifecycleRestore)
        #expect(TabLifecycleSnapshotStore.fetch(tabID: tab.id, in: manager.modelContext) == nil)
        harness.page.stopLoading()
        try await LifecycleRepairHarness.waitUntil { !harness.page.isLoading }
        #expect(!harness.page.hasPendingLifecycleRestore)
        #expect(harness.page.captureInteractionState() != nil)
        let quit = TabLifecycleQuitCoordinator()
        quit.register(manager)
        #expect(quit.captureAllLiveSnapshots())
        #expect(tab.url == urlB)
        let replacement = try #require(TabLifecycleSnapshotStore.fetch(tabID: tab.id, in: manager.modelContext)?
            .interactionState)
        #expect(replacement != original)
        return tab.id
    }
}
