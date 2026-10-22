import Foundation
@testable import Ora
import SwiftData
import Testing

@MainActor
struct LifecycleReviewRegressionTests {
    @Test func quitPreservesValidCheckpointQueuedBehindPrivacyReadiness() async throws {
        let fixture = try await LifecycleRepairFixture()
        defer { fixture.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("queued.sqlite")
        let tabID = try await writeQueuedCheckpoint(storeURL: storeURL, fixture: fixture)
        let store = try ModelConfiguration.createOraContainer(at: storeURL)
        let manager = TabManager(
            modelContainer: store,
            modelContext: ModelContext(store),
            mediaController: MediaController()
        )
        defer { manager.closeLifecycleFixture() }
        let tab = try #require(manager.modelContext.fetch(FetchDescriptor<Tab>()).first { $0.id == tabID })
        manager.activateTab(tab)
        let harness = try LifecycleRepairHarness(page: #require(tab.browserPage))
        defer { harness.close() }
        try await harness.loaded(fixture.url("/b"))
        #expect(tab.canGoBack)
        try await harness.expectScroll(y: 1200)
        tab.goBack()
        try await harness.loaded(fixture.url())
    }

    private func writeQueuedCheckpoint(storeURL: URL, fixture: LifecycleRepairFixture) async throws -> UUID {
        let store = try ModelConfiguration.createOraContainer(at: storeURL)
        let manager = TabManager(
            modelContainer: store,
            modelContext: ModelContext(store),
            mediaController: MediaController()
        )
        defer { manager.closeLifecycleFixture() }
        let tab = try manager.addTab(url: fixture.url(), container: #require(manager.activeContainer), isPrivate: false)
        let harness = try LifecycleRepairHarness(page: #require(tab.browserPage))
        defer { harness.close() }
        try await harness.loaded(fixture.url())
        try await harness.load(fixture.url("/b"))
        try await harness.scroll(to: 1200)
        #expect(tab.captureInteractionState())
        let before = try #require(TabLifecycleSnapshotStore.fetch(tabID: tab.id, in: manager.modelContext)?
            .interactionState)
        tab.finishLifecycleDiscard()
        var releaseReadiness: (() -> Void)?
        let page = BrowserPage(
            profile: BrowserEngine.shared.makeProfile(identifier: tab.container.id, isPrivate: false),
            configuration: .oraDefault(userScripts: [], privacySettings: SpacePrivacySettings()), delegate: nil,
            navigationReadinessGate: { releaseReadiness = $0 }
        )
        tab.browserPage = page
        harness.attach(page)
        var outcome: TabLifecycleRestoreOutcome?
        page.restoreInteractionState(before) { outcome = $0 }
        try await LifecycleRepairHarness.waitUntil { releaseReadiness != nil }
        #expect(!page.isLoading && page.webView.backForwardList.currentItem == nil)
        #expect(page.hasPendingLifecycleRestore && !page.isLifecycleCaptureReady)
        #expect(tab.captureLifecycleCheckpoint() == .pendingRestore)
        #expect(!tab.captureInteractionState()) // Automatic discard must also refuse.
        let quit = TabLifecycleQuitCoordinator()
        quit.register(manager)
        #expect(quit.captureAllLiveSnapshots())
        #expect(outcome == nil)
        #expect(TabLifecycleSnapshotStore.fetch(tabID: tab.id, in: manager.modelContext)?.interactionState == before)
        // Simulate quitting without ever opening the readiness gate. Reopen uses
        // the shipped Tab.createWebView path, not direct WebKit assignment.
        return tab.id
    }

    @Test func loadedOversizeHistoryAndLoadingPagesDoNotVetoQuit() async throws {
        let fixture = try await LifecycleRepairFixture()
        defer { fixture.stop() }
        let store = try ModelConfiguration.createOraContainer(isPrivate: true)
        let manager = TabManager(
            modelContainer: store,
            modelContext: ModelContext(store),
            mediaController: MediaController()
        )
        defer { manager.closeLifecycleFixture() }
        let tab = try manager.addTab(url: fixture.url(), container: #require(manager.activeContainer), isPrivate: false)
        let harness = try LifecycleRepairHarness(page: #require(tab.browserPage))
        defer { harness.close() }
        try await harness.loaded(fixture.url())
        #expect(tab.captureInteractionState())
        let before = try #require(TabLifecycleSnapshotStore.fetch(tabID: tab.id, in: manager.modelContext)?
            .interactionState)
        _ = try await harness.evaluate("history.replaceState('x'.repeat(5*1024*1024), ''); true")
        let native = try #require(harness.page.webView.interactionState as? Data)
        #expect(native.count > TabInteractionStateCodec.maximumByteCount)
        #expect(tab.captureLifecycleCheckpoint() == .urlOnly)
        #expect(TabLifecycleSnapshotStore.fetch(tabID: tab.id, in: manager.modelContext)?.interactionState == before)
        let quit = TabLifecycleQuitCoordinator()
        quit.register(manager)
        var replies: [Bool] = []
        quit.requestTermination(
            onSaveFailure: { Issue.record("Oversize capture is not a save error")
                return .cancel
            },
            reply: { replies.append($0) }
        )
        #expect(replies == [true])
        try harness.page.load(URLRequest(url: fixture.url("/held")))
        let heldURL = try fixture.url("/held")
        try await LifecycleRepairHarness.waitUntil { harness.page.isLoading && tab.url == heldURL }
        #expect(tab.captureLifecycleCheckpoint() == .urlOnly)
        #expect(quit.captureAllLiveSnapshots())
        #expect(try tab.url == (fixture.url("/held")))
    }

    @Test func durableSaveFailureHasRetryCancelAndExplicitQuitPaths() {
        for choice in [TabLifecycleQuitCoordinator.SaveFailureChoice.cancel, .quitAnyway, .retry] {
            let quit = TabLifecycleQuitCoordinator()
            var attempts = 0, prompts = 0
            var replies: [Bool] = []
            quit.requestTermination(capture: { attempts += 1
                return attempts > 1
            }, onSaveFailure: {
                prompts += 1
                return choice
            }, reply: { replies.append($0) })
            #expect(prompts == 1)
            #expect(replies == [choice != .cancel])
            #expect(attempts == (choice == .retry ? 2 : 1))
        }
    }

    @Test func dragAndMenuPinIntentSurvivesDiskRoundTripsInBothDirections() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("pins.sqlite")
        for step in 0 ... 6 {
            try pinRoundTrip(storeURL: storeURL, step: step)
        }
    }

    private func pinRoundTrip(storeURL: URL, step: Int) throws {
        let store = try ModelConfiguration.createOraContainer(at: storeURL)
        let manager = TabManager(
            modelContainer: store,
            modelContext: ModelContext(store),
            mediaController: MediaController()
        )
        defer { manager.closeLifecycleFixture() }
        let space = try #require(manager.activeContainer)
        let tab: Tab
        if let existing = space.tabs.first {
            tab = existing
            #expect(tab.userPinnedExplicitly == (step % 2 == 1))
            #expect(tab.type == (step % 2 == 1 ? .pinned : .normal))
        } else {
            tab = try Tab(
                url: #require(URL(string: "https://fixture.invalid")),
                title: "Pin",
                container: space,
                order: 0,
                tabManager: manager,
                isPrivate: false
            )
            manager.modelContext.insert(tab)
        }
        guard step < 6 else { return }
        let section: TabType = step % 2 == 0 ? .pinned : .normal
        if step < 2 {
            // Occupied section drag/drop uses switchSections.
            let target = Tab(
                url: tab.url,
                title: "Target",
                container: TabContainer(),
                type: section,
                order: 1,
                tabManager: manager,
                isPrivate: false
            )
            tab.switchSections(from: tab, to: target)
            target.tabManager = nil
        } else if step < 4 {
            // Empty-section delegate calls the same centralized setter.
            tab.setUserSection(section)
        } else {
            manager.togglePinTab(tab)
        }
        #expect(tab.userPinnedExplicitly == (section == .pinned))
        #expect(tab.savedURL == (section == .normal ? nil : tab.url))
        try manager.modelContext.save()
    }
}

extension LifecycleReviewRegressionTests {
    @Test func failedDurableReplacementPreservesRealCheckpointAfterDiskReopen() async throws {
        let fixture = try await LifecycleRepairFixture()
        defer { fixture.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("failure.sqlite")
        let (tabID, expected) = try await failReplacement(storeURL: storeURL, fixture: fixture)
        let reopened = try ModelConfiguration.createOraContainer(at: storeURL)
        let context = ModelContext(reopened)
        #expect(TabLifecycleSnapshotStore.fetch(tabID: tabID, in: context)?.interactionState == expected)
    }

    private func failReplacement(storeURL: URL, fixture: LifecycleRepairFixture) async throws -> (UUID, Data) {
        let store = try ModelConfiguration.createOraContainer(at: storeURL)
        let manager = TabManager(
            modelContainer: store,
            modelContext: ModelContext(store),
            mediaController: MediaController()
        )
        defer { manager.closeLifecycleFixture() }
        let tab = try manager.addTab(url: fixture.url(), container: #require(manager.activeContainer), isPrivate: false)
        let harness = try LifecycleRepairHarness(page: #require(tab.browserPage))
        defer { harness.close() }
        try await harness.loaded(fixture.url())
        #expect(tab.captureInteractionState())
        let before = try #require(TabLifecycleSnapshotStore.fetch(tabID: tab.id, in: manager.modelContext)?
            .interactionState)
        try await harness.scroll(to: 1200)
        let replacement = try #require(harness.page.captureInteractionState())
        struct DiskFailure: Error {}
        #expect(!TabLifecycleSnapshotStore.save(
            tabID: tab.id, containerID: tab.container.id, data: replacement, isPrivate: false,
            in: manager.modelContext, persist: { _ in throw DiskFailure() }
        ))
        #expect(TabLifecycleSnapshotStore.fetch(tabID: tab.id, in: manager.modelContext)?.interactionState == before)
        // Any later context save must also preserve the prior durable row.
        try manager.modelContext.save()
        return (tab.id, before)
    }
}
