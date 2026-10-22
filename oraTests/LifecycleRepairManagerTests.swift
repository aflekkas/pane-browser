import Foundation
@testable import Ora
import SwiftData
import Testing

@MainActor
struct LifecycleRepairManagerTests {
    @Test(arguments: [TabType.pinned, .fav])
    func closeThenSelectRecreatesPinnedAndFavoritePage(type: TabType) async throws {
        let fixture = try await LifecycleRepairFixture()
        defer { fixture.stop() }
        let manager = try makeManager()
        let url = try fixture.url()
        let tab = makeTab(manager, url: url)
        tab.type = type
        tab.savedURL = url
        let firstPage = try #require(tab.browserPage)
        let harness = LifecycleRepairHarness(page: firstPage)
        defer { harness.close()
            tab.finishLifecycleDiscard()
        }
        try await harness.loaded(url)
        manager.closeTab(tab: tab)
        #expect(tab.browserPage == nil && !tab.isWebViewReady && tab.isDiscarded)
        manager.activateTab(tab)
        let secondPage = try #require(tab.browserPage)
        #expect(secondPage !== firstPage)
        #expect(!tab.isDiscarded && tab.isWebViewReady)
        harness.attach(secondPage)
        try await harness.loaded(url)
        #expect(tab.browserPage === secondPage)
    }

    @Test func liveProfileMoveUsesOnlyDestinationSessionThroughDiscardAndReopen() async throws {
        let fixture = try await LifecycleRepairFixture()
        defer { fixture.stop() }
        let manager = try makeManager()
        let source = try #require(manager.activeContainer)
        let destination = manager.createContainer(name: "Destination")
        let urlA = try fixture.url(), urlB = try fixture.url("/b")
        let tab = manager.addTab(url: urlA, container: source, isPrivate: false)
        let harness = try LifecycleRepairHarness(page: #require(tab.browserPage))
        defer { harness.close()
            tab.finishLifecycleDiscard()
        }
        try await harness.loaded(urlA)
        _ = try await harness.evaluate("localStorage.setItem('session','source'); true")
        try await harness.load(urlB)
        #expect(tab.captureInteractionState())
        let sourcePage = try #require(tab.browserPage)
        let destinationSeed = LifecycleRepairHarness(profile: BrowserEngine.shared.makeProfile(
            identifier: destination.id, isPrivate: false
        ))
        defer { destinationSeed.close() }
        try await destinationSeed.load(urlA)
        _ = try await destinationSeed.evaluate("localStorage.setItem('session','destination'); true")
        manager.moveTabToContainer(tab, toContainer: destination)
        let movedPage = try #require(tab.browserPage)
        #expect(movedPage !== sourcePage && movedPage.profileIdentifier == destination.id)
        #expect(movedPage.webView.configuration.websiteDataStore !== sourcePage.webView.configuration.websiteDataStore)
        #expect(TabLifecycleSnapshotStore.fetch(tabID: tab.id, in: manager.modelContext) == nil)
        harness.attach(movedPage)
        try await harness.loaded(urlB)
        #expect(try await harness.evaluate("localStorage.getItem('session')") as? String == "destination")
        #expect(!movedPage.canGoBack)
        tab.discard()
        #expect(tab.isDiscarded && tab.browserPage == nil)
        BrowserEngine.shared.releaseProfile(identifier: destination.id)
        manager.activateTab(tab)
        try harness.attach(#require(tab.browserPage))
        try await harness.loaded(urlB)
        #expect(try await harness.evaluate("localStorage.getItem('session')") as? String == "destination")
        #expect(tab.browserPage?.profileIdentifier == destination.id)
    }

    @Test func currentActiveTabWinsOverCapturedInactiveFlagAfterAsyncProbe() async throws {
        let fixture = try await LifecycleRepairFixture()
        defer { fixture.stop() }
        let manager = try makeManager()
        let url = try fixture.url()
        let tab = makeTab(manager, url: url)
        let harness = try LifecycleRepairHarness(page: #require(tab.browserPage))
        defer { harness.close()
            tab.finishLifecycleDiscard()
        }
        try await harness.loaded(url)
        manager.activeTab = nil
        tab.lastAccessedAt = Date().addingTimeInterval(-7200)
        tab.discardIfAllowed(policy: TabLifecyclePolicy(userUnloadDelay: 0), isActive: false)
        // Do not await between probe dispatch and changing the current owner.
        manager.activeTab = tab
        try await LifecycleRepairHarness.waitUntil { tab.lastLifecycleActivity != nil }
        #expect(tab.lastLifecycleActivity?.probeFailed == false)
        #expect(tab.browserPage === harness.page && !tab.isDiscarded)
    }

    @Test func downloadStartingWhileProbeRunsBlocksDiscard() async throws {
        let fixture = try await LifecycleRepairFixture()
        defer { fixture.stop() }
        let manager = try makeManager()
        let url = try fixture.url()
        let tab = makeTab(manager, url: url)
        let harness = try LifecycleRepairHarness(page: #require(tab.browserPage))
        defer { harness.close()
            tab.finishLifecycleDiscard()
        }
        try await harness.loaded(url)
        manager.activeTab = nil
        tab.lastAccessedAt = Date().addingTimeInterval(-7200)
        tab.probeLifecycleForDiscard(policy: TabLifecyclePolicy(userUnloadDelay: 0))
        let transferID = UUID()
        // Exercise the authoritative per-page ownership seam used by normal
        // and resumed transfers; security integration tests cover WKDownload.
        harness.page.downloadActivity.begin(transferID)
        defer { harness.page.downloadActivity.end(transferID) }
        try await LifecycleRepairHarness.waitUntil { tab.lastLifecycleActivity != nil }
        #expect(tab.lastLifecycleActivity?.probeFailed == false)
        #expect(tab.browserPage === harness.page && !tab.isDiscarded)
    }

    @Test func staleUnknownIsReprobedAndClearIdleTabCanDiscard() async throws {
        let fixture = try await LifecycleRepairFixture()
        defer { fixture.stop() }
        let manager = try makeManager()
        let url = try fixture.url()
        let tab = makeTab(manager, url: url)
        let harness = try LifecycleRepairHarness(page: #require(tab.browserPage))
        defer { harness.close()
            tab.finishLifecycleDiscard()
        }
        try await harness.loaded(url)
        tab.lastLifecycleActivity = .unknown
        tab.hasUnsavedFormState = true
        tab.lastAccessedAt = Date().addingTimeInterval(-3 * 24 * 3600)
        manager.activeTab = nil
        // Avoid depending on the user's unload setting in this regression.
        let policy = TabLifecyclePolicy(userUnloadDelay: 3600)
        #expect(policy.shouldProbe(tab.lifecycleFacts(isActive: false), at: Date()))
        tab.probeLifecycleForDiscard(policy: policy)
        try await LifecycleRepairHarness.waitUntil { tab.isDiscarded }
        #expect(tab.browserPage == nil && !tab.isWebViewReady)
    }

    private func makeManager() throws -> TabManager {
        let container = try ModelConfiguration.createOraContainer(isPrivate: true)
        return TabManager(
            modelContainer: container,
            modelContext: ModelContext(container),
            mediaController: MediaController()
        )
    }

    private func makeTab(_ manager: TabManager, url: URL) -> Tab {
        let space = manager.activeContainer ?? manager.createContainer()
        return manager.addTab(url: url, container: space, isPrivate: false)
    }
}
